# Cloud CI, TestFlight, and App Store Workflow

Status: implementation foundation added; deployment remains disabled until the owner configures GitHub environments, secrets, branch protections, and enablement variables.

Last updated: 2026-07-25

## Decision

OpenFoodJournal moves iOS compilation, non-UI test execution, signed archives, TestFlight delivery, and App Store staging from the developer Mac to ephemeral GitHub-hosted macOS runners.

The release flow uses two protected branches:

```text
feature branch
    ↓ pull request + cloud CI
testflight
    ↓ compile, test, archive once, upload, distribute internally
immutable TestFlight build + release manifest
    ↓ promote the exact processed build
app-store
    ↓ metadata staging, strict validation, optional reviewed submission
App Review
```

TestFlight and the App Store do not receive separately rebuilt binaries. A binary uploaded to App Store Connect becomes a build resource that can be assigned to internal TestFlight testers and later attached to an App Store version. The production workflow therefore promotes the exact tested build instead of recompiling it.

## Old versus new

| Concern | Previous workflow | New workflow |
| --- | --- | --- |
| Build host | Kevin's local Mac and external SSD | Ephemeral GitHub `xcode-27` runner |
| Source branch | `app-store` was development, TestFlight, and App Store release state | `testflight` is integration/beta; `app-store` is production promotion |
| Pull requests | Local compile verification was performed when requested | Every PR to either protected branch runs cloud compile and non-UI tests |
| Xcode | Local `/Volumes/DevDisk/Xcode-beta.app` | Pinned GitHub `xcode-27` preview image |
| Xcode drift | Selected manually | Workflow requires Xcode 27.0 build `27A5218g` and fails on drift |
| DerivedData | Accumulated under local `.asc` or other local paths | Created under `RUNNER_TEMP` and destroyed after the job |
| Unit tests | Often compile-only because the local simulator store is unreliable | Executed on a hosted iPhone simulator through the unit-test-only scheme |
| UI tests | Not required | UI-test execution remains excluded |
| Build number | Bumped locally before an archive | Allocated from processed and in-flight App Store Connect builds under a serialized deployment |
| Signing | Local Keychain and provisioning profile | Temporary runner keychain and profile from protected environment secrets |
| Upload | Manual `asc` archive/export/upload | Trusted `testflight` push runs signed archive, export, upload, processing wait, and internal distribution |
| Release identity | Build number and local notes had to be tracked manually | TestFlight prerelease stores commit SHA, build ID, version, IPA hash, toolchain, and notes |
| App Store | A new local archive could be made for release | The exact TestFlight build is promoted; binary changes after the tested tag are rejected |
| Metadata | Maintained in docs and entered manually | Existing public metadata is copied; release notes are applied from the reviewed manifest |
| AI role | Ad hoc assistance | AI may draft bounded metadata from release evidence; deterministic code owns state changes |
| Public submission | Manual | Still requires an explicit workflow input and protected-environment approval |

## Implemented workflows

### `.github/workflows/cloud-ci.yml`

Triggers on:

- Pull requests to `testflight`.
- Pull requests to `app-store`.
- Manual dispatch.
- Calls from either deployment workflow.

It:

1. Uses the pinned `xcode-27` image.
2. Confirms Xcode 27.0 build `27A5218g`.
3. Compiles the app, unit-test target, and UI-test target with `build-for-testing`.
4. Selects an available hosted iPhone simulator.
5. Executes only `OpenFoodJournalUnitTests`, which includes provider-contract tests.
6. Uploads an `.xcresult` for three days only when the test job fails.

It receives no App Store Connect, signing, or AI-provider credentials. Live provider tests continue to skip when their opt-in credentials are absent.

### `.github/workflows/testflight.yml`

Triggers on pushes to `testflight` or manual dispatch. The deployment job runs only when the repository variable `ENABLE_TESTFLIGHT_AUTOMATION` equals `true`.

After cloud CI succeeds, it:

1. Enters the protected `testflight-internal` environment.
2. Installs the pinned `asc` 3.1.1 binary after SHA-256 verification.
3. Validates the App Store Connect API credentials.
4. Asks App Store Connect for the next remote-safe build number.
5. Generates deterministic draft “What to Test” notes from commits since the previous TestFlight tag.
6. Imports the distribution certificate into a temporary keychain.
7. Installs the provisioning profile on the ephemeral runner.
8. Archives and exports the signed IPA.
9. Uploads the IPA, waits for processing, and assigns it to the internal `Testing` group.
10. Creates `testflight/<version>-<build>` as a GitHub prerelease pointing to the exact source commit.
11. Attaches an immutable release manifest and the test notes.
12. Retains the manifest and upload result for 14 days, but does not retain DerivedData or the archive.

The prerelease manifest is the bridge between TestFlight and App Store promotion:

```json
{
  "schemaVersion": 1,
  "appStoreAppID": "6761086648",
  "buildID": "App Store Connect build UUID",
  "buildNumber": "11",
  "commitSHA": "full Git commit SHA",
  "createdAt": "ISO-8601 timestamp",
  "ipaSHA256": "SHA-256 of the uploaded IPA",
  "notes": "Reviewed release notes",
  "notesSource": "deterministic-git-history",
  "version": "1.4",
  "xcodeBuild": "27A5218g"
}
```

### `.github/workflows/app-store.yml`

Triggers on pushes to `app-store` or manual dispatch. The promotion job runs only when `ENABLE_APP_STORE_AUTOMATION` equals `true`.

After cloud CI succeeds, it:

1. Enters the protected `app-store-production` environment.
2. Finds the newest `testflight/*` prerelease tag reachable from `app-store`.
3. Downloads and validates the release manifest.
4. Rejects promotion if app source or Xcode project files changed after that tested tag.
5. Verifies that the App Store Connect build is still `VALID`.
6. Copies version metadata from the current public App Store version, excluding “What’s New.”
7. Attaches the exact TestFlight build to the target version.
8. Applies the manifest release notes as “What’s New.”
9. Runs strict App Store submission validation.
10. Submits to App Review only when a manual dispatch explicitly sets `submit_for_review` and the protected job is approved.

A normal push stages and validates the release. It does not silently submit it for public review.

## Versioned release configuration

Non-secret identifiers and toolchain pins live in [`ci/release-config.json`](../ci/release-config.json):

- App Store Connect app ID.
- Bundle ID.
- Apple team ID.
- Internal TestFlight group ID.
- Primary locale.
- GitHub runner label.
- Required Xcode version and build.
- Pinned `asc` version and checksums.
- TestFlight tag prefix.

These values are reviewable configuration, not credentials.

## Credentials and environments

Create these GitHub environments:

### `testflight-internal`

Secrets:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_B64`
- `APPLE_DISTRIBUTION_CERTIFICATE_B64`
- `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_B64`

The App Store Connect key must be able to inspect apps/builds, allocate build numbers, upload builds, and manage internal TestFlight distribution. The provisioning profile must match `k3vnc.OpenFoodJournal`, team `83B48K23H4`, and the capabilities used by the Release archive.

The repository currently expects the certificate identity `iPhone Distribution`,
matching the installed project credential. If the certificate is rotated to a
modern `Apple Distribution` identity, update `signingCertificateName` in
`ci/release-config.json`; archive and export both consume that one value.

### `app-store-production`

Secrets:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_B64`

Use an App Store Connect key with the minimum role that can create/stage a version, update metadata, attach a build, validate readiness, and submit to App Review.

Configure a required reviewer for `app-store-production`. Restrict it to the `app-store` branch. A required reviewer for internal TestFlight is optional but reasonable while the hosted Xcode image remains in preview.

The current scripts consume GitHub environment secrets as environment variables. An external secrets manager can replace their source later. Prefer OIDC-based, short-lived retrieval where the selected manager supports it. Do not expose deployment secrets to pull-request jobs.

## Branch protections

### `testflight`

- Create it from the intended current app source, not automatically from the stale remote base.
- Require `Cloud CI / Compile and unit tests`.
- Require pull requests for source changes.
- Prevent force pushes and deletion.
- Permit the TestFlight workflow to create `testflight/*` tags and prereleases.
- Enable repository release immutability. The workflow creates a draft, attaches
  the manifest and test notes, then publishes it so GitHub locks the release
  assets and tag.

### `app-store`

- Require `Cloud CI / Compile and unit tests`.
- Accept promotion pull requests from `testflight`.
- Require linear or otherwise auditable history.
- Prevent force pushes and deletion.
- Do not permit app-affecting commits after the selected TestFlight tag. The workflow enforces this again before promotion.

The legacy `main` branch remains historical and is not part of the release train.

## AI release assistant boundary

AI can safely prepare a release proposal containing:

- A user-visible change summary tied to merged PRs and commits.
- Draft internal “What to Test” notes.
- Draft App Store “What’s New” text.
- Suggested reviewer notes.
- A checklist of screenshots, privacy metadata, entitlements, or disclosures that may have changed.
- Links to the source PRs and tests supporting each claim.

AI output must be written to a reviewable artifact or pull request. It must follow a versioned JSON schema and include source commit/PR references. If generation fails, deterministic commit-derived notes remain the fallback.

AI must not own:

- Build-number allocation.
- Source-to-build identity.
- Signing or credential access.
- Archive/export/upload commands.
- Build selection.
- App Store Connect state transitions.
- Export-compliance, privacy, content-rights, health-claim, or age-rating certification.
- Final public submission without an explicit owner action and protected-environment approval.

The first implementation intentionally uses deterministic git-derived notes. Connecting an AI drafting provider is a separate step because the provider, model, data-sharing policy, and secret source have not been selected.

## Owner setup checklist

1. Decide which commit should seed `testflight`. The current local `app-store` checkout contains work that is not all present on `origin/app-store`.
2. Merge or otherwise reconcile the current focused HealthKit PR and the separate local build-10 work.
3. Create the remote `testflight` branch from the chosen reviewed commit.
4. Create the `testflight-internal` and `app-store-production` GitHub environments.
5. Add the environment secrets listed above through GitHub or the selected secrets manager.
6. Configure required reviewers and deployment-branch restrictions.
7. Enable immutable releases in the repository's GitHub settings.
8. Add the branch protection rules and required `Cloud CI` check.
9. Run `Cloud CI` manually once while both deployment variables remain disabled.
10. Set `ENABLE_TESTFLIGHT_AUTOMATION=true`.
11. Push a reviewed commit to `testflight` and verify the first cloud-signed build.
12. Confirm the prerelease manifest points to the correct commit and build.
13. Set `ENABLE_APP_STORE_AUTOMATION=true` only after TestFlight promotion succeeds.
14. Promote `testflight` to `app-store`; leave `submit_for_review` false for the first staging run.
15. Review strict validation, metadata, legal declarations, and reviewer notes before manually dispatching submission.

## Current blockers

- The remote `testflight` branch does not exist.
- GitHub deployment environments, protections, variables, and secrets are not configured.
- GitHub release immutability is not yet confirmed enabled.
- The signing certificate and provisioning profile must be exported into the selected secrets manager.
- `xcode-27` is currently a GitHub preview image. It matches the local Xcode build, but preview capacity and naming may change.
- The exact AI provider/model and data policy for release-note drafting are not selected.
- The current local `app-store` working tree is dirty and ahead of the remote branch. Creating `testflight` from the wrong ref would omit current work or publish unrelated work.

The workflows remain non-deploying until their enablement variables are set, so committing this foundation alone cannot upload or submit a build.

## Storage behavior

Cloud runners are ephemeral:

- DerivedData, simulator state, archive, temporary keychain, certificate, provisioning profile, and IPA disappear with the job.
- Failed `.xcresult` bundles remain for three days.
- TestFlight manifests and upload results remain for 14 days.
- App Store Connect retains the processed build.
- GitHub prereleases retain the small manifest and notes, not the IPA.

This removes ongoing Xcode/DerivedData/archive growth from the local SSD while preserving enough evidence to reproduce and audit a release.

## References

- [Apple: Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple: App Store Connect build resources](https://developer.apple.com/documentation/appstoreconnectapi/builds)
- [GitHub: Workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub: Prevent changes to releases](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
- [App Store Connect CLI](https://github.com/rorkai/App-Store-Connect-CLI)
