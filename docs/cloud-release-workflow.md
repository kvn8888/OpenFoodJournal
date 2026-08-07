# Cloud CI, TestFlight, and App Store Workflow

Status: workflows, GitHub environments, verified credentials, both protected release branches, environment branch restrictions, the production reviewer gate, immutable future releases, and both deployment enablement variables are configured. Future trusted branch updates now use the cloud release train.

Last updated: 2026-08-03

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
| Build host | Kevin's local Mac and external SSD | Ephemeral GitHub `macos-26` runner |
| Source branch | `app-store` was development, TestFlight, and App Store release state | `testflight` is integration/beta; `app-store` is production promotion |
| Pull requests | Local compile verification was performed when requested | Every PR to either protected branch runs cloud compile and non-UI tests |
| Xcode | Local `/Volumes/DevDisk/Xcode-beta.app` | Stable Xcode 26.6 on GitHub `macos-26` |
| Xcode drift | Selected manually | Workflow requires Xcode 26.6 build `17F113` and fails on drift |
| DerivedData | Accumulated under local `.asc` or other local paths | Created under `RUNNER_TEMP` and destroyed after the job |
| Unit tests | Often compile-only because the local simulator store is unreliable | Executed on a hosted iPhone simulator through the unit-test-only scheme |
| Gemini image contract | Manual/ad hoc API probes could drift from the app payload | A protected billable canary executes the exact production request builder and blocks archive/upload on contract failure |
| UI tests | Not required | UI-test execution remains excluded |
| Build number | Bumped locally before an archive | Allocated from processed and in-flight App Store Connect builds under a serialized deployment |
| Signing | Local Keychain and provisioning profile | Temporary runner keychain and profile from protected environment secrets |
| Upload | Manual `asc` archive/export/upload | Trusted `testflight` push runs signed archive, export, upload, processing wait, and internal distribution |
| Release identity | Build number and local notes had to be tracked manually | TestFlight prerelease stores commit SHA, build ID, version, IPA hash, toolchain, and notes |
| App Store | A new local archive could be made for release | The exact TestFlight build is promoted; binary changes after the tested tag are rejected |
| Metadata | Maintained in docs and entered manually | Existing public metadata is copied; version-specific notes are drafted, validated, sealed into the TestFlight manifest, and shown before approval |
| AI role | Ad hoc assistance | GitHub Models drafts bounded public notes from commit-derived evidence; deterministic fallback and validation own the artifact |
| Public submission | Manual | Still requires an explicit workflow input and protected-environment approval |

## Implemented workflows

### `.github/workflows/cloud-ci.yml`

Triggers on:

- Pull requests to `testflight`.
- Pull requests to `app-store`.
- Manual dispatch.
- Calls from either deployment workflow.

It:

1. Uses the pinned `macos-26` image.
2. Selects and confirms stable Xcode 26.6 build `17F113`.
3. Runs the release-note and promotion-manifest contract tests.
4. Compiles the app, unit-test target, and UI-test target with `build-for-testing`.
5. Selects an available hosted iPhone simulator.
6. Executes only `OpenFoodJournalUnitTests`, which includes provider-contract tests.
7. Uploads an `.xcresult` for three days only when the test job fails.

It receives no App Store Connect, signing, or AI-provider credentials. Pull-request live provider tests continue to skip when their opt-in credentials are absent. The protected TestFlight workflow owns the required billable Gemini image canary so provider secrets are never exposed to pull-request jobs.

### `.github/workflows/release-credentials-check.yml`

Runs only by manual dispatch and performs no release mutation. It authenticates
to App Store Connect from both deployment environments, reads the configured app
and build list, and independently verifies the TestFlight distribution
certificate/password and provisioning profile. Splitting the certificate and
profile checks ensures one missing secret does not hide the state of the other
asset. It does not allocate a build number, archive, upload, distribute, change
metadata, stage a version, or submit for review.

### `.github/workflows/testflight.yml`

Triggers on pushes to `testflight` or manual dispatch. The deployment job runs only when the repository variable `ENABLE_TESTFLIGHT_AUTOMATION` equals `true`.

After cloud CI succeeds, a protected `gemini-image-contract` job uses the `testflight-internal` environment to execute the exact production `ScanService.foodIconImageRequest(prompt:)` payload against `gemini-3.1-flash-lite-image`. It requires a real returned image and fails closed on missing credentials, HTTP errors, or response-contract drift. This is a small billable canary and runs before any archive or upload.

The deployment then:

1. Enters the protected `testflight-internal` environment.
2. Installs the pinned `asc` 3.1.1 binary after SHA-256 verification.
3. Validates the App Store Connect API credentials.
4. Reads the source-controlled marketing version and rejects malformed versions; a release PR must intentionally change `MARKETING_VERSION` when moving from 1.4 to 1.5.
5. Asks App Store Connect for the next remote-safe build number. Build numbers are automatic.
6. Generates deterministic “What to Test” evidence from commits since the previous TestFlight tag.
7. Uses GitHub Models to draft public “What’s New” text from that bounded evidence, with deterministic notes as a fallback.
8. Validates the locale, non-empty content, control characters, and Apple’s 4,000-character limit.
9. Imports the distribution certificate into a temporary keychain and installs the provisioning profile.
10. Archives once, exports the signed IPA, uploads it, waits for processing, and assigns it to the internal `Testing` group.
11. Creates `testflight/<version>-<build>` as a GitHub prerelease pointing to the exact source commit.
12. Attaches the immutable schema-2 manifest, “What to Test,” “What’s New,” and generation metadata.
13. Retains small release evidence for 14 days, but does not retain DerivedData, the archive, or the IPA.

The prerelease manifest is the bridge between TestFlight and App Store promotion:

```json
{
  "schemaVersion": 2,
  "appStoreAppID": "6761086648",
  "buildID": "App Store Connect build UUID",
  "buildNumber": "11",
  "commitSHA": "full Git commit SHA",
  "createdAt": "ISO-8601 timestamp",
  "ipaSHA256": "SHA-256 of the uploaded IPA",
  "primaryLocale": "en-US",
  "whatToTest": "Internal verification notes",
  "whatsNew": "Public, version-specific release notes",
  "whatsNewSHA256": "SHA-256 of the attached notes file",
  "releaseNotes": {
    "source": "bifrost",
    "model": "openai/gpt-5.6-sol",
    "requiresHumanApproval": true
  },
  "version": "1.4",
  "xcodeBuild": "17F113"
}
```

### `.github/workflows/app-store.yml`

Triggers on pushes to `app-store` or manual dispatch. The promotion job runs only when `ENABLE_APP_STORE_AUTOMATION` equals `true`.

After cloud CI succeeds, it:

1. Runs an unprivileged preparation job with no Apple credentials.
2. Finds the newest `testflight/*` prerelease tag reachable from `app-store`.
3. Downloads and verifies the schema-2 manifest and the hash-bound “What’s New” asset.
4. Rejects promotion if app source or Xcode project files changed after that tested tag.
5. Publishes a promotion-plan artifact and job summary showing the exact version, build, note source, requested action, and public text.
6. Pauses at the protected `app-store-production` environment. Secrets are unavailable until approval.
7. Re-downloads the plan into the approved job and re-verifies provenance and notes.
8. Verifies that the App Store Connect build is still `VALID`.
9. Copies version metadata from the current public App Store version, excluding “What’s New.”
10. Attaches the exact TestFlight build to the target version and applies the approved manifest text.
11. Runs strict App Store submission validation.
12. Submits to App Review only when a manual dispatch explicitly sets `submit_for_review=true` and the protected job is approved.

A normal push is the required staging run: it requests approval to stage and validate with `submit_for_review=false`. Public submission requires a separate intentional manual dispatch and protected-environment approval. Neither path recompiles the app.

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
- Default GitHub Models release-note model.
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
- `OFJ_GEMINI_API_KEY`

The App Store Connect key must be able to inspect apps/builds, allocate build numbers, upload builds, and manage internal TestFlight distribution. The provisioning profile must match `k3vnc.OpenFoodJournal`, team `83B48K23H4`, and the capabilities used by the Release archive.

`OFJ_GEMINI_API_KEY` is a dedicated, restricted Gemini credential for the billable Nano Banana 2 Lite release canary. Do not reuse a personal unrestricted key. Restrict it to the Gemini API where supported, monitor its usage, and rotate it independently of keys stored on user devices. A missing or rejected key blocks TestFlight before archive/upload.

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
- Preserve the `testflight` commit with a normal merge commit so the immutable TestFlight tag remains an ancestor of `app-store`; do not squash or rebase promotion PRs.
- Prevent force pushes and deletion.
- Do not permit app-affecting commits after the selected TestFlight tag. The workflow enforces this again before promotion.

The legacy `main` branch remains historical and is not part of the release train.

## AI release assistant boundary

The TestFlight workflow drafts release notes through the self-hosted Bifrost router at `vars.BIFROST_BASE_URL`, authenticated with the `BIFROST_VIRTUAL_KEY` and `BIFROST_AUTHORIZATION` secrets. It sends only bounded commit-derived change evidence—never source code, app data, Apple credentials, signing assets, or AI-provider keys. `RELEASE_NOTES_MODEL` may override the versioned default in `ci/release-config.json`. A reviewed file at `metadata/releases/<version>/<locale>/whats-new.txt` takes precedence when exact copy is required.

Sources are attempted in order, and `releaseNotes.source` in the manifest records which one produced the text:

| Order | `source` | Condition |
| --- | --- | --- |
| 1 | `repository-override` | A committed `whats-new.txt` exists for the version and locale. |
| 2 | `bifrost` | `BIFROST_BASE_URL` and `BIFROST_VIRTUAL_KEY` are set and the reply passes validation. |
| 3 | `github-models` | Legacy path; GitHub Models is being retired and now answers with a brownout error, so expect this tier to fail. |
| 4 | `deterministic-git-history` | No generator succeeded; notes are cleaned commit subjects. |

Because the router is a single self-hosted machine, none of its failure modes fail the release—an unreachable host, a rejected key, or a reply that fails validation each fall through to the next tier. A run that lands on `deterministic-git-history` still ships, but the notes will read like a changelog; treat that source in the approval summary as a signal to write the copy by hand.

The prompt is versioned at `ci/prompts/whats-new-system.txt` and `ci/prompts/whats-new-user.txt` rather than embedded in the script, so wording changes are reviewable. `{{VERSION}}` and `{{EVIDENCE}}` are substituted at run time, and `{{EVIDENCE}}` must remain alone on its own line. The prompt deliberately instructs the model to discard internal changes (toolchain, CI, tests, refactors, debug-only builds, credential handling) rather than paraphrase them, to avoid naming gestures or screens the evidence does not name, and to translate developer vocabulary into user-visible terms.

`max_tokens` is set well above the visible output length on purpose: reasoning models bill hidden reasoning tokens against the same cap, and too small a budget returns an empty message that silently demotes the run to deterministic notes.

AI can safely prepare a release proposal containing:

- A user-visible change summary tied to merged PRs and commits.
- Draft internal “What to Test” notes.
- Draft App Store “What’s New” text.
- Suggested reviewer notes.
- A checklist of screenshots, privacy metadata, entitlements, or disclosures that may have changed.
- Links to the source PRs and tests supporting each claim.

AI output is written to the TestFlight prerelease, promotion artifact, and workflow summary. It follows a versioned JSON schema and remains explicitly unapproved until the protected production job is approved. If inference or validation fails, deterministic commit-derived notes remain the fallback.

AI must not own:

- Build-number allocation.
- Source-to-build identity.
- Signing or credential access.
- Archive/export/upload commands.
- Build selection.
- App Store Connect state transitions.
- Export-compliance, privacy, content-rights, health-claim, or age-rating certification.
- Final public submission without an explicit owner action and protected-environment approval.

## Owner setup checklist

1. Use the reconciled `app-store` head as the reviewed source for `testflight`.
2. Keep the centralized HealthKit, Assistant, container, and cloud-release work together; it is reconciled and pushed.
3. Keep the remote `testflight` branch aligned with reviewed release candidates.
4. Keep the existing `testflight-internal` and `app-store-production` GitHub environments.
5. Keep the verified environment secrets in place, including the dedicated `OFJ_GEMINI_API_KEY` release-canary credential, and rerun **Release Credential Check** after any Apple key, certificate, password, or profile rotation.
6. Keep `testflight-internal` restricted to `testflight`; keep `app-store-production` restricted to `app-store` with Kevin as a required reviewer.
7. Enable immutable releases in the repository's GitHub settings.
8. Add the branch protection rules and required `Cloud CI` check.
9. Run `Cloud CI` manually once while both deployment variables remain disabled.
10. Keep `ENABLE_TESTFLIGHT_AUTOMATION=true` after the first validated workflow rollout.
11. Push a reviewed commit to `testflight` and verify the first cloud-signed build.
12. Confirm the prerelease manifest points to the correct commit and build.
13. Keep `ENABLE_APP_STORE_AUTOMATION=true` after the first schema-2 TestFlight manifest exists.
14. Promote `testflight` to `app-store`; leave `submit_for_review` false for the first staging run.
15. Review strict validation, metadata, legal declarations, and reviewer notes before manually dispatching submission.

## Current blockers

- `testflight-internal` App Store Connect authentication, app/build reads, distribution-certificate decode/password/identity, and provisioning-profile decode/bundle/team/expiration checks all passed on 2026-07-26.
- `OFJ_GEMINI_API_KEY` is present in `testflight-internal` as of 2026-07-31. Its actual request validity is intentionally checked by every trusted TestFlight candidate before archive/upload.
- `app-store-production` App Store Connect credentials passed app and build-list reads on 2026-07-26. These checks prove authentication/read access and signing-asset integrity, not upload or App Store mutation permissions.
- `testflight-internal` accepts deployments only from `testflight`; `app-store-production` accepts only `app-store` and requires approval from `kvn8888`.
- Both release branches require pull requests, resolved review conversations, and the GitHub Actions-owned `Compile and unit tests` check; force pushes and deletion are disabled. `testflight` is linear, while `app-store` deliberately permits auditable merge commits so a tested TestFlight commit remains in production ancestry.
- Repository release immutability is enabled for future releases.
- The first production promotion requires a new schema-2 TestFlight build; legacy schema-1 manifests fail closed.
- Release archives use stable Xcode 26.6 rather than an Xcode beta. Beta toolchains can become invalid for App Store Connect uploads as soon as Apple advances the supported beta.

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
