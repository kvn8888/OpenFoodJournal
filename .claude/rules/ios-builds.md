# iOS builds — hard rules

These exist because they were broken once and it cost real user data.
On 2026-07-31 a SwiftUI Preview run on the connected iPhone replaced the
TestFlight app with a developer build, and ten days of journal entries stopped
being visible. Recovery required a manual CloudKit export and re-import.

## Never build locally

Do not run `xcodebuild` on this machine. Not to verify a change, not as a
lint or typecheck pass, not with `CODE_SIGNING_ALLOWED=NO`.

The default DerivedData path is shared (`~/Library/Developer/Xcode/DerivedData/
OpenFoodJournal-*`). A local build evicts the signing artifacts —
`Entitlements.plist`, `*.xcent`, `_CodeSignature`, `embedded.mobileprovision` —
and reverts the checkout's build products to an inconsistent state.

**To find out whether something compiles, use Cloud CI.** It runs the same
command safely because it isolates DerivedData per job
(`-derivedDataPath "${RUNNER_TEMP}/DerivedData-generic"`).

```
gh workflow run cloud-ci.yml --ref <branch>
```

Ask before dispatching — a CI run is the user's call. Until then, reason about
the code and say plainly that it is unverified. Never claim a change builds
when you have not seen it build.

## Never run previews or the app on the physical device

There are no simulator devices installed on this Mac, so Xcode's run
destination falls through to the connected iPhone — which carries the user's
real journal. If you need a preview destination, create a simulator device
first; do not target hardware.

## Debug and Release are different apps — keep them that way

| | Release / TestFlight | Debug |
|---|---|---|
| Bundle ID | `k3vnc.OpenFoodJournal` | `k3vnc.OpenFoodJournal.dev` |
| Display name | OpenFoodJournal | OFJ Dev |
| Entitlements | `OpenFoodJournal.entitlements` | `OpenFoodJournal-Debug.entitlements` |
| CloudKit container | `iCloud.k3vnc.OpenFoodJournal` | `iCloud.k3vnc.OpenFoodJournal.dev` |
| HealthKit | enabled | no entitlement, `isAvailable` returns false |
| Turso mirror | enabled by user setting | hard-disabled (`isEnabled` returns false) |
| `CURRENT_PROJECT_VERSION` | stamped by CI | `0` |

Do not collapse any row of that table. Debug must not reach production data by
any path. The CloudKit separation is by *container identifier*, deliberately —
not by CloudKit environment, which is decided by code signing and is invisible
in source.

If you add a new service that talks to anything outside the device, it needs a
Debug guard before it ships.

## Release path

`testflight` and `app-store` branches trigger protected release pipelines on
push. Merging a PR into them ships a build. Build numbers come from
`asc builds next-build-number` at build time and are never committed, so the
`CURRENT_PROJECT_VERSION` in the repo is not the shipped number.
