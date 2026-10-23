# Code signing

Which identity signs which Roadie build, what gets signed inside the bundle, the entitlements, and the rules that keep
the account's certificates safe.

## Identities

| Build | Signed with | Where |
|---|---|---|
| Debug and Release builds in the Tart VM (`scripts/verify.sh`, including `--dmg`) | Ad-hoc (`CODE_SIGN_IDENTITY: "-"`) | `project.yml` |
| Release DMG (`scripts/make-dmg.sh`, `scripts/release.sh`) | **Developer ID Application** for the team, on the host | Re-signs the VM's Release app |
| DMG notarization | notarytool profile `Roadie-notary` | [release-credentials.md](release-credentials.md) |
| Update archives | Sparkle EdDSA key (not a code-signing identity) | [sparkle.md](sparkle.md) |

The VM has no signing identities, and no `xcodebuild` call uses `-allowProvisioningUpdates`. That way no build can
create, renew or revoke a certificate. Signing for distribution happens only on the host, in the release scripts.

## The Developer ID certificate

- It's the only identity Apple's notary service accepts for distribution outside the App Store. An Apple Development
  certificate from the same team doesn't qualify.
- It lives in the login keychain **together with its private key**.
- **Move it, don't re-issue it.** Export and import a `.p12` ([release-credentials.md](release-credentials.md)).
- Never click "+" in Xcode's Manage Certificates. Never accept a prompt to revoke or replace a certificate.
- Apps signed and notarized before the certificate expires keep working afterwards. Only new signing needs a valid
  certificate. `preflight.sh` warns 30 days ahead.
- A Developer ID Installer certificate isn't needed: Roadie ships a DMG, not a `.pkg`.

## What gets signed, in order

`release.sh` (step 3) signs inside-out, each item with `--force --options runtime --timestamp` and the item's own
entitlements minus `com.apple.security.get-task-allow`:

1. `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc`
2. `…/XPCServices/Downloader.xpc` (keeps its entitlements)
3. `…/Versions/B/Autoupdate`
4. `…/Versions/B/Updater.app`
5. `Contents/Frameworks/Sparkle.framework`
6. Any other framework or dylib in `Contents/Frameworks`
7. `Contents/PlugIns/RoadieThumbnail.appex`, `RoadiePreview.appex`
8. `Roadie.app`
9. The DMG (`codesign --timestamp`, no runtime option)

Then:
- `codesign --verify --deep --strict` on the app;
- a direct check of every Mach-O: not ad-hoc, same team and authority as the app, `runtime` flag, secure timestamp;
- after notarization, `stapler validate`, `spctl` and `scripts/verify-dmg.sh` (which includes a simulated Safari
  quarantine).

`--deep` signing is never used: it would apply the app's entitlements to nested code.

## Entitlements

| Bundle | Sandbox | Entitlements | Why |
|---|---|---|---|
| Roadie.app | No | `com.apple.security.personal-information.location` | Wi-Fi network name for picking a server (#0075). The app isn't sandboxed so it can read a skin folder by path. |
| RoadieThumbnail.appex, RoadiePreview.appex | Yes | `app-sandbox`, `files.user-selected.read-only` | Quick Look extensions must be sandboxed |
| Sparkle helpers | as shipped by Sparkle | Downloader.xpc keeps its own | Unchanged from Sparkle |

- The hardened runtime is on for every target, as notarization requires.
- No entitlement needs a provisioning profile, so none is embedded.
- Adding an entitlement changes what notarization accepts. Treat it as a reviewed change, and extend
  `scripts/check-entitlements.sh`.
- **If Roadie is ever sandboxed**, Sparkle then needs `SUEnableInstallerLauncherService` (and the downloader service,
  or the network-client entitlement) plus the matching mach-lookup entitlements. That's a design change, not a quick
  edit.

## Checks

- `scripts/check-entitlements.sh` and `scripts/check-sparkle.sh` run in the VM on every run.
- `scripts/verify-dmg.sh <dmg>` checks a finished DMG from a recipient's point of view.
- `scripts/preflight.sh --credentials-only` checks the identity, its expiry, the notary profile and the Sparkle key.
