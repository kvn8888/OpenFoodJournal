# From Local Xcode Archives to a Cloud iOS Release Train

OpenFoodJournal's release process worked, but it depended heavily on one Mac:
compile locally, archive locally, keep signing credentials in the local
Keychain, and upload manually. I set out to move that work to ephemeral cloud
runners without creating a pipeline that could accidentally publish an
untested build or expose Apple credentials to pull requests.

This retrospective explains not only what I built, but how I reasoned about it.
The goal is that I could reproduce the same design independently for another
iOS project.

The companion
[`cloud-release-workflow.md`](cloud-release-workflow.md) is the operational
specification; this document is the learning narrative behind it.

## The Starting Point

Before this work, `app-store` carried several meanings at once. It was an active
development branch, the source for TestFlight builds, and the source for App
Store releases. Verification and deployment were also coupled to the local
machine:

```text
local source
    → local Xcode compile
    → local signing identity and provisioning profile
    → local archive and IPA
    → manual App Store Connect upload
```

That approach is reasonable for a young iOS app, but it develops pressure
points:

- Xcode DerivedData, simulator runtimes, and archives consume local storage.
- A release depends on the state of one machine.
- Build-number selection and release notes are manual.
- It is easy to rebuild between TestFlight and App Store submission, losing the
  guarantee that production contains the exact binary that was tested.
- Credentials and deployment authority are not separated from ordinary build
  verification.

The repository also had a substantially dirty working tree, and the local
`app-store` branch was ahead of its remote. That mattered because creating a
new `testflight` branch immediately would have forced an unsafe choice: either
omit current work or accidentally include unrelated work.

So I treated this session as building the release foundation, not activating
the release train.

## The Mental Model: CI Is Not Deployment

The first useful distinction was between **continuous integration** and
**continuous delivery**:

- **CI** answers, “Does this exact source revision compile and pass its automated
  checks?”
- **Delivery** answers, “Can this verified revision become a signed,
  distributable build?”
- **Deployment** answers, “Should that build change external state for testers
  or customers?”

Those stages have different risk. A pull request should be able to compile code
without receiving an App Store Connect key or distribution certificate.
Uploading a build needs credentials. Submitting to App Review additionally
needs an explicit human decision because it can expose legal, privacy,
health-claim, and export-compliance declarations.

That led to three workflows instead of one large release script:

```text
cloud-ci.yml
    ↓ required check
testflight.yml
    ↓ signed build and internal distribution
app-store.yml
    ↓ promote the already-tested build
explicit App Review submission
```

Splitting the workflows makes the permissions legible. It also means a failure
has a smaller blast radius: a unit-test failure cannot partially stage an App
Store version because that job never receives deployment authority.

## Step 1: Build a Secret-Free CI Gate

I began with [`cloud-ci.yml`](../.github/workflows/cloud-ci.yml). It runs for
pull requests to `testflight` or `app-store`, can be dispatched manually, and
can be reused by both deployment workflows.

The CI job has two intentionally different checks:

1. `build-for-testing` against generic iOS compiles the app and all test
   targets, including the UI-test target.
2. The unit-test-only scheme runs `OpenFoodJournalTests` on a hosted iPhone
   simulator.

Compiling a UI-test target is not the same as executing it. This satisfies the
project requirement that every target compile while avoiding automated phone
or simulator UI interaction.

The important security property is almost invisible:

```yaml
permissions:
  contents: read

jobs:
  validate:
    runs-on: xcode-27
```

There are no Apple signing secrets, App Store Connect credentials, or live AI
provider keys in this workflow. Provider-contract tests can use fixtures, while
opt-in live tests skip when their credentials are absent.

I also directed DerivedData and failed test results into `RUNNER_TEMP`. A
GitHub-hosted runner is a temporary virtual machine, so those large files
disappear after the job. Only a failed `.xcresult` is retained, and only for
three days.

### Why pin the Xcode build?

“Run on the latest Xcode” sounds convenient until Apple changes a compiler,
SDK, linker, or signing behavior between builds. The local project was using
Xcode 27.0 build `27A5218g`, and GitHub's `xcode-27` preview image exposed the
same build. I added [`verify-xcode.sh`](../.github/scripts/verify-xcode.sh) so a
runner-image update fails visibly:

```bash
if [[ "${actual_version}" != "${expected_version}" ||
      "${actual_build}" != "${expected_build}" ]]; then
  echo "The hosted image no longer matches the pinned toolchain." >&2
  exit 1
fi
```

Failing on drift is preferable to silently generating a release with an
unreviewed toolchain. Updating the pin should be an intentional repository
change.

## Step 2: Turn `testflight` Into the Build-Producing Branch

The TestFlight workflow runs only after cloud CI succeeds. Its job is to turn a
verified commit into one signed build and preserve enough evidence to identify
that build later.

I first inventoried the real release state instead of guessing from local
filenames:

- App Store Connect app ID: `6761086648`
- Bundle ID: `k3vnc.OpenFoodJournal`
- Apple team ID: `83B48K23H4`
- Internal `Testing` group ID:
  `12593eb5-970d-4a68-a2a8-921f09fd2c8a`
- Toolchain: Xcode 27.0 build `27A5218g`
- App Store Connect CLI: pinned to version 3.1.1
- Current signing identity: `iPhone Distribution`

Non-secret facts belong in
[`ci/release-config.json`](../ci/release-config.json). Credentials do not. This
separation means code review can see which app, team, tool version, and
TestFlight group the workflow targets without exposing a private key.

### Remote-safe build numbers

Two cloud jobs must not independently decide that the next build is `11`.
The workflow therefore:

- serializes TestFlight deployments with a GitHub concurrency group; and
- asks App Store Connect for the next available build number.

The build number is then passed to Xcode as an archive-time setting:

```yaml
--xcodebuild-flag="CURRENT_PROJECT_VERSION=${{ steps.release.outputs.build_number }}"
```

This was a correction to my first approach. Initially, I used a command that
edited the Xcode project file before archiving. It worked mechanically, but it
made the checked-out source differ from the source revision named in the
release manifest. Passing `CURRENT_PROJECT_VERSION` preserves a clean source
tree while still embedding the allocated number in the app.

This is a reusable DevOps principle: runtime build metadata should not require
an uncommitted source mutation.

### Ephemeral code signing

An iOS archive must be signed by a distribution certificate and matched to a
provisioning profile. The workflow receives both from the protected
`testflight-internal` environment:

- the password-protected certificate as base64;
- the certificate password; and
- the provisioning profile as base64.

[`install-signing-assets.sh`](../.github/scripts/install-signing-assets.sh)
creates a temporary keychain, imports the certificate, installs the profile,
and exposes only the profile name to later steps. The runner and its temporary
keychain are destroyed after the job.

The App Store Connect API key is separate from code signing:

- The certificate proves who signed the app.
- The provisioning profile authorizes the app identifier and entitlements.
- The App Store Connect key authorizes API operations such as upload and
  TestFlight distribution.

Keeping those concepts distinct makes signing failures much easier to debug.

### Pin the release tool too

The workflow downloads `asc`, verifies a version-specific SHA-256 checksum, and
only then executes it. A checksum is a fingerprint of the downloaded binary.
If the bytes differ from the reviewed artifact, installation stops.

Pinning a GitHub Action by commit and a standalone CLI by checksum solves the
same supply-chain problem: a mutable name such as `latest` should not be able
to change release behavior without a repository diff.

## Step 3: Record Build Provenance

A successful upload is not enough. The next workflow needs to answer:

> Which source commit produced which App Store Connect build?

That relationship is **build provenance**. The TestFlight job records it in a
small manifest:

```json
{
  "buildID": "App Store Connect build UUID",
  "buildNumber": "11",
  "commitSHA": "full Git commit SHA",
  "ipaSHA256": "SHA-256 of the uploaded IPA",
  "version": "1.4",
  "xcodeBuild": "27A5218g"
}
```

The manifest also includes release notes and a creation timestamp. It is
attached to a GitHub prerelease named `testflight/<version>-<build>`.

My first wording called this manifest “immutable” simply because it was
attached to a release. That was too optimistic. Normal GitHub release assets
can be replaced by someone with sufficient permission.

The corrected design requires repository release immutability and publishes in
three phases:

```bash
gh release create ... --draft
gh release upload ... release-manifest.json
gh release edit ... --draft=false
```

The draft ensures every asset exists before publication. Once published with
GitHub release immutability enabled, the associated tag and assets are locked.
This is an example of a subtle but important difference between naming a
security property and actually enforcing it.

## Step 4: Promote Instead of Rebuilding

The biggest architectural decision was that `app-store` does not build another
IPA.

Uploading an IPA creates a build resource in App Store Connect. That same
processed build can be used for internal TestFlight and later attached to an
App Store version. Rebuilding on the production branch would create a new
binary—even if the source looked identical—and would discard much of the value
of TestFlight testing.

The App Store workflow therefore:

1. Finds the newest reachable `testflight/*` tag.
2. Downloads its manifest.
3. Confirms the tag, manifest commit, and current branch ancestry agree.
4. Rejects app or Xcode-project changes after the tested tag.
5. Confirms the referenced App Store Connect build remains `VALID`.
6. Copies metadata from the current public version.
7. Attaches the exact TestFlight build.
8. Applies reviewed “What's New” notes.
9. Runs strict readiness validation.

The interesting guard is deliberately small:

```bash
if ! git diff --quiet "${testflight_tag}..HEAD" \
  -- OpenFoodJournal OpenFoodJournal.xcodeproj; then
  echo "Create a new TestFlight build before promotion." >&2
  exit 1
fi
```

Documentation and release-automation changes may occur after the tag because
they do not alter the already-uploaded app. App source or project changes
require a new TestFlight build.

A normal `app-store` push stages and validates the version. It does not submit
to public review. Submission requires both a manual workflow input and approval
through the protected `app-store-production` environment.

## The Gotcha: “Apple Distribution” Was Not This Project's Identity

The first export configuration hard-coded `Apple Distribution`, the modern
certificate name commonly seen in examples.

That was plausible, but the actual installed project certificate was:

```text
iPhone Distribution: Kevin Chen (83B48K23H4)
```

If the certificate stored in CI has that legacy identity, asking Xcode for
`Apple Distribution` can cause archive signing to fail even though a valid
certificate is present.

I fixed this by making `signingCertificateName` a versioned, non-secret setting.
Both the archive command and generated export plist now read the same value.
If the certificate is later rotated to `Apple Distribution`, there is one
reviewable configuration change instead of two hidden hard-coded strings.

The broader lesson is to inventory real signing assets before copying a
generic CI example. Apple signing errors often come from a mismatch between
four independently named things: team, bundle identifier, certificate, and
provisioning profile.

## The Revision: Local Verification Exposed the Reason for Moving

Static validation was clean:

- `actionlint` accepted all workflow YAML.
- `bash -n` accepted every shell script.
- `jq` validated the release configuration.
- `plutil` validated the export plist.
- `git diff --check` found no whitespace errors.
- The pinned `asc` binary downloaded and matched its checksum.
- The Xcode verifier confirmed Xcode 27.0 build `27A5218g` when pointed at the
  project Xcode installation.

But a lightweight local `xcodebuild -list` encountered these messages inside
the current execution environment:

```text
CoreSimulatorService connection became invalid.
xcode-select: error: ... active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
```

The second problem was resolved by setting `DEVELOPER_DIR` to the full Xcode
installation before running the verifier. The first could have been caused by
the local simulator service or by the restricted execution environment, so I
did not mislabel it as an application failure. Neither issue invalidated the
workflow files, but both illustrated the original problem: local
developer-machine state is ambient and must be made explicit.

I did **not** claim that the cloud pipeline had passed. It cannot run until the
workflow files are committed and pushed, the remote branch exists, and the
owner-controlled GitHub environments are configured. Deployment is gated
behind variables that default to disabled, so landing the foundation alone
cannot upload or submit an app.

This distinction matters in DevOps work:

- “The configuration is statically valid” is one claim.
- “The hosted build passed” is another.
- “The signed upload succeeded” is another.
- “The build was safely promoted” is another.

A useful pipeline reports those as separate facts.

## The AI Boundary

It is tempting to let an AI “handle the bureaucracy,” including build numbers,
release notes, and submission. I separated creative administrative work from
identity and state-changing work.

AI is a good fit for drafts that a person can review:

- “What to Test”
- “What's New”
- reviewer notes
- user-visible change summaries
- checklists for screenshots, entitlements, and disclosures

AI should not decide:

- the next build number;
- which commit produced a binary;
- which build is promoted;
- whether signing or upload succeeded;
- legal, health, privacy, or export declarations; or
- whether to submit publicly.

Those decisions need deterministic evidence. The first implementation
therefore generates notes from Git history. An AI drafting step can be added
later as a reviewable artifact, with deterministic notes as the fallback.

This does not make the pipeline less agentic. It makes the agent operate inside
a trustworthy control plane.

## How I Would Build This Independently Next Time

If I were recreating this without an existing plan, I would use this sequence.

### 1. Inventory the release truth

Before writing YAML, record:

- repository branches and their intended meanings;
- Xcode version and build;
- scheme names and which tests they execute;
- bundle ID, team ID, app ID, and TestFlight group;
- certificate identity and provisioning-profile name;
- current public and TestFlight versions; and
- which credentials are needed for read, upload, metadata, and submission.

The output should be a non-secret configuration file plus a secret inventory.

### 2. Write invariants before commands

For OpenFoodJournal, the important invariants were:

- pull-request code never receives deployment secrets;
- UI tests are compiled but not executed;
- every deployment follows successful CI;
- one TestFlight commit produces one archived binary;
- App Store promotion never rebuilds that binary;
- build numbers come from App Store Connect;
- deployment operations are serialized;
- public submission is explicit and reviewed; and
- large build products remain ephemeral.

Invariants are easier to review than hundreds of lines of workflow syntax.

### 3. Implement CI with no secrets

Make compilation and unit tests pass in the hosted environment first. Do not
debug signing and tests simultaneously.

### 4. Pin the environment

Pin:

- GitHub Actions by full commit;
- Xcode by version and build;
- third-party CLIs by version and checksum.

When a pin breaks, update it deliberately.

### 5. Add protected deployment environments

Use one environment for internal TestFlight and a stricter one for production.
Store credentials in environment secrets or retrieve them from an external
secrets manager using short-lived identity federation where possible.

### 6. Build TestFlight delivery

Allocate the build number remotely, import signing assets ephemerally, archive
once, upload, wait for processing, and distribute internally.

### 7. Persist provenance

Record commit SHA, build ID, build number, version, toolchain, and artifact hash
in a protected manifest.

### 8. Promote the exact build

Reject source drift, verify App Store Connect state, attach the existing build,
and stage metadata.

### 9. Add human approval at the irreversible boundary

Internal builds can be automated after tests. Public review submission should
require an explicit action and protected-environment approval.

### 10. Roll out in layers

Keep deployment variables disabled initially:

1. Commit the workflows.
2. Run cloud CI manually.
3. Enable TestFlight automation.
4. Inspect the first manifest and build.
5. Enable App Store staging.
6. Stage without submitting.
7. Only then test reviewed submission.

That sequence turns one dangerous “launch CI/CD” event into several observable,
reversible steps.

## A Small DevOps Checklist I Want to Keep

For any future pipeline, I would ask:

- **Reproducibility:** Can I identify the source and toolchain that produced the
  artifact?
- **Provenance:** Can I prove which artifact is being promoted?
- **Least privilege:** Does each job receive only the credentials it needs?
- **Isolation:** Can untrusted pull-request code reach deployment secrets?
- **Idempotency:** If a job retries, will it duplicate or corrupt external
  state?
- **Concurrency:** What happens if two deployments start together?
- **Observability:** Can I distinguish compile, test, upload, processing,
  distribution, staging, and submission failures?
- **Retention:** Which artifacts must persist, and which should disappear?
- **Approval:** Where does automation cross into a costly, public, legal, or
  irreversible action?
- **Recovery:** Can I safely resume after a runner or network failure?

These questions are more transferable than any particular GitHub Actions
syntax.

## What's Next

The foundation exists locally, but activation still needs owner-controlled
setup:

1. Choose the reviewed commit that should seed `testflight`.
2. Create and protect the remote `testflight` branch.
3. Create `testflight-internal` and `app-store-production` environments.
4. Add App Store Connect, certificate, and provisioning-profile secrets.
5. Enable immutable GitHub releases.
6. Require the cloud CI check on both release branches.
7. Run secret-free Cloud CI.
8. Enable and verify TestFlight delivery.
9. Enable App Store staging only after that succeeds.
10. Choose an AI provider and data policy if AI-drafted release copy is still
    desired.

I would also add small tests for the promotion guard and release-manifest schema
before activating production. Shell scripts deserve tests when they control
external state just as much as application code does.

---

The most useful thing I learned here is that CI/CD is not mainly about making
deployment automatic; it is about making every transition explainable.
