# M14: Ship Roadie

Roadie: a Winamp-skinned player for Music Assistant.

This is the plan for milestone M14 (umbrella [#0151](../../issues/0151.md)). It turns SkinAmp into **Roadie** (bundle id
`co.sstools.roadie`). Roadie is distributed as a notarized DMG from https://roadie.sstools.co/ and on GitHub releases,
and it updates itself through Sparkle 2. The hosting contract is [docs/website-hosting.md](../website-hosting.md).
These docs cover the procedures: [sparkle.md](../sparkle.md), [releasing.md](../releasing.md),
[release-credentials.md](../release-credentials.md) and [code-signing.md](../code-signing.md).

## Order of work

1. Finish the in-repo rename to Roadie, plus any release tooling that is ready by then. The rename must be pushable on
   its own: see **Gate A** below.
2. Push main.
3. The user renames the GitHub repo from SkinAmp to Roadie.
4. Update the remote, the local folder and the repo links together (W14).
5. Release **0.0.1**.

## 1. Current state

Counts are from `git grep` over 814 tracked files on 2026-10-23.

### Names and identifiers

| What | Count | Where |
|---|---|---|
| `SkinAmp` (case-sensitive) | 765 in 214 files | 491 in 105 `issues/` files; 133 in 83 Swift files; 71 in 11 `scripts/` and `project.yml` files; 57 in 11 other Markdown files |
| `com.brennanmke.skinamp` (case-insensitive) | 182 in 93 files | Outside `issues/`: 52× `com.brennanmke.SkinAmp` (mostly `os.Logger` subsystems), 13× `…skinamp.wsz`, 5× `…skinamp.media-id`, 4× each `.Thumbnail` and `.Preview`, plus `.plex`, `.musicAssistant` and 4 dispatch-queue labels |
| Swift identifiers containing SkinAmp | 3 | `SkinAmpApp` (`App/SkinAmpApp.swift:5`), `skinAmpMediaID` (`MediaIDTransfer.swift:7`), `outputsHideSkinAmpsOwnPlayer` |
| Files named SkinAmp | 4 | `App/SkinAmp.entitlements`, `App/SkinAmpApp.swift`, `QuickLook/*/SkinAmp{Thumbnail,Preview}.entitlements` |

- **Bundle ids** (`project.yml`): app `com.brennanmke.SkinAmp` (:89); extensions `com.brennanmke.SkinAmp.Thumbnail` (:125)
  and `.Preview` (:161). The id prefix is `com.brennanmke` (:3). The project, target and scheme are `SkinAmp` (:1, :17,
  :173); the extensions are `SkinAmpThumbnail` and `SkinAmpPreview` (:102, :137). The display name is
  `SkinAmp` (:92).
- **Exported UTIs** (`project.yml:67-81`, regenerated into `App/Info.plist:7-82`):
  - `com.brennanmke.skinamp.wsz` (conforms to `public.zip-archive`), claimed as a Viewer document type.
  - `com.brennanmke.skinamp.media-id` (`public.data`), used only for drags inside the app (#0136).
  - The Quick Look extensions list `…skinamp.wsz` in `QLSupportedContentTypes` (:116, :151).
  - Code: `App/PlayerView.swift:37`, `MediaIDTransfer.swift:7`.
- **Checks that pin these values:**
  - `scripts/check-info-plist.sh:39-44` (the UTIs).
  - `scripts/check-quicklook.sh:22-23,36,46-50` (appex names, content type, pluginkit ids).
  - `scripts/check-entitlements.sh`.
  - `TokenStoreTests.swift:40` (Keychain service).
- **User-visible strings:**
  - About menu item (`Packages/SkinKit/Sources/SkinKit/Menus/MainMenu.swift:95`).
  - Idle marquee (`MarqueeText.swift:7`, `MainWindowState.swift:39`).
  - Sendspin player name "SkinAmp (<host>)" and product/manufacturer (`SendspinIdentity.swift:26`,
    `SendspinMessages.swift:32`, `App/SendspinController.swift:134`).
  - Settings copy (`MusicAssistantSettingsView.swift:47,130,136`).
  - Error text (`MusicAssistantError.swift:32,34`, `SendspinError.swift:16`, `MuseumError.swift:18`,
    `FallbackText.swift:27`).
  - Usage descriptions (`project.yml:58,65,66`).
  - Museum User-Agent `SkinAmp/<v> (+https://github.com/brennanMKE/SkinAmp)` (`MuseumTransport.swift:25`).
  - Keychain label "SkinAmp Music Assistant token" (`MusicAssistantTokenStore.swift:81`).
- **Test-tier environment variables:** `SKINAMP_SLOW_TESTS` (`run-tests-vm.sh:105`, 2 test files, `docs/testing-in-vm.md`).
- **VM infrastructure names:** clone prefix `skinamp-test-` (`run-tests-vm.sh:117`; the stale-clone regex is at :197)
  and lease label `skinamp` (:247).
- **The Xcode project is generated and gitignored** (`.gitignore`: `*.xcodeproj/`). The VM run generates it on the host
  (`run-tests-vm.sh:227`) and builds it with `-project SkinAmp.xcodeproj -scheme SkinAmp` (:318, :399).
- **Tracker and docs:** `issues/project.json` (name `SkinAmp`, url `https://github.com/brennanMKE/SkinAmp`), the
  `issues/Issues.md` heading, `README.md`, `AGENTS.md`, `docs/plan.md` (milestones end at M7).

### Where user data lives

| Data | Key / path | Source |
|---|---|---|
| Settings | `UserDefaults.standard`, domain `com.brennanmke.SkinAmp` (33 `UserDefaults.standard` uses; keys include `MusicAssistantServers`, `LibrarySource`, `LibraryFolderPath`, `skinsFolderPath`, `lastSkinPath`, `sendspin.clientID`, `sendspin.enabled`, `musicAssistant.stopOnQuit`, `equalizer`, window/shade keys, `museumShowsNSFW`, `legacyCleanupVersion`) | e.g. `App/SkinLibraryModel.swift:12`, `FolderBackend.swift:21` |
| Music Assistant token | Login-keychain generic password, service `com.brennanmke.SkinAmp.musicAssistant`, one item per server, account = the server configuration id | `MusicAssistantTokenStore.swift:30-48` |
| Queue | `~/Library/Application Support/<bundle id>/queue.json` (follows `Bundle.main.bundleIdentifier`) | `QueueSnapshot.swift:32-35` |
| Skin index | `~/Library/Application Support/com.brennanmke.SkinAmp/SkinLibrary/index.sqlite` (**hard-coded**) | `SkinIndexStore.swift:38-44` |
| Caches | `~/Library/Caches/<bundle id>/{SkinThumbnails,FolderIndex}` (follows the bundle id); `…/com.brennanmke.SkinAmp/Museum` (**hard-coded**) | `SkinThumbnailCache.swift:32-35`, `FolderIndex.swift:181-185`, `App/PlayerModel.swift:57-59` |
| Skins folder, library folder, last skin | Plain absolute paths in defaults. **No security-scoped bookmarks:** the app is not sandboxed. | `project.yml:99-100` |
| Museum downloads | `<skins folder>/Museum/`, inside the user's own folder | `MuseumDownloader.swift:24-27` |

`App/LegacyDataCleanup.swift` is the existing one-time cleanup pattern: a version key, attribute-only Keychain queries,
counts-only logging. It runs first in `PlayerModel.init` (`App/PlayerModel.swift:321-322`). `AppDelegate.model` is the
first thing that reads defaults (`App/AppDelegate.swift:9`). The views that use `@AppStorage` (4) only appear later.

### Build, version and packaging

- **Versions:**
  - `MARKETING_VERSION: "0.1.0"` and `CURRENT_PROJECT_VERSION: "1"` are repeated per target (`project.yml:94-95`,
    `:128-129`, `:165-166`).
  - The committed `App/Info.plist:32-35` carries `1.0`/`1`, and Xcode's generated keys override them. #0127's review
    confirmed built bundles report `0.1.0 (<build>)`.
  - The deployment target is macOS 14.0 (`project.yml:5,10`).
- **Build number (#0127):** `run-tests-vm.sh --dmg` computes `date -u +%Y%m%d.%H%M` on the host and passes
  `CURRENT_PROJECT_VERSION=$BUILD_NUMBER` to the guest's Release build. The value goes to every target and is written to
  `release/build.txt` (:394-400). `verify.sh:97` reports it.
- **Signing:**
  - Every build is ad-hoc (`CODE_SIGN_IDENTITY: "-"`), with the hardened runtime on.
  - The app is not sandboxed. Its only entitlement is `com.apple.security.personal-information.location`
    (`App/SkinAmp.entitlements`).
  - Both Quick Look extensions are sandboxed and read-only.
- **`scripts/make-dmg.sh` (host):**
  - Unzips the VM's Release app.
  - Re-signs inside-out with Developer ID, the hardened runtime, a timestamp and each bundle's own entitlements minus
    `get-task-allow` (:41-55). Nested code inside a framework is **not** signed separately.
  - Builds `SkinAmp-<version>-<build>-<commit>.dmg` with `hdiutil`, volname `SkinAmp` (:57-66).
  - Optionally notarizes and staples with `--notary-profile` (:68-71).
- **VM rules (`docs/testing-in-vm.md`):**
  - Builds, tests and launches run only in a silent Tart VM through `scripts/verify.sh`.
  - The guest has network access and resolves SwiftPM packages (`testing-in-vm.md:306`).
  - The app project owns package resolution (`.gitignore`: `/Packages/*/Package.resolved`).
- **Dependencies:** ZIPFoundation `from: 0.9.19` (`Packages/SkinKit/Package.swift:16`). `NOTICE` credits Webamp and
  lodash, but not ZIPFoundation.
- **App and Settings UI:**
  - `SettingsView` has three tabs: Library, Music Assistant, Skins (`App/Settings/SettingsView.swift:5-12`).
  - App commands are in `App/SkinAmpApp.swift:35-74`.
  - About uses the standard panel (`App/PlayerModel+MainMenu.swift:16`).
- **No website, no CHANGELOG, no git tags.**

## 2. Design

### 2.1 Rename and order of operations

**New identifiers**

| Old | New |
|---|---|
| `com.brennanmke.SkinAmp` (app, defaults domain, app-support folder, logger subsystem) | `co.sstools.roadie` |
| `com.brennanmke.SkinAmp.Thumbnail` / `.Preview` | `co.sstools.roadie.thumbnail` / `co.sstools.roadie.preview` |
| `com.brennanmke.skinamp.wsz` / `.media-id` | `co.sstools.roadie.wsz` / `co.sstools.roadie.media-id` |
| `com.brennanmke.SkinAmp.musicAssistant` (Keychain service) | `co.sstools.roadie.musicAssistant` |
| `SkinAmp` project, target, scheme, `SkinAmpApp` | `Roadie`, `RoadieApp` |
| `SkinAmpThumbnail`, `SkinAmpPreview` | `RoadieThumbnail`, `RoadiePreview` |
| `SKINAMP_SLOW_TESTS` | `ROADIE_SLOW_TESTS` |
| VM clone prefix `skinamp-test-`, lease label `skinamp` | `roadie-test-`, `roadie` |

The `com.brennanmke.SkinAmp.plex` constant in `LegacyDataCleanup` stays: it still deletes an old Plex Keychain item.

**Release 0.0.1** is a rough draft: its job is to start the release pipeline, not to be a finished product.

**Ordering rule:** every commit must pass `scripts/verify.sh`.

1. **W1: dropped** ([#0152](../../issues/0152.md), won't fix). There is no migration (§2.2).
2. **W2: identity switch.**
   - `project.yml` bundle ids, UTIs and Quick Look content types.
   - The check scripts and tests that pin them.
   - The Keychain service.
   - Hard-coded paths, logger subsystems and queue labels.

   These go in **one commit**: `check-info-plist.sh` and `check-quicklook.sh` run in the same VM run as the build that
   changes them. The product is still named SkinAmp in this commit.
3. **W3: product rename.**
   - `project.yml` name, targets and scheme.
   - Renamed entitlements and app files.
   - Every script path (`SkinAmp.xcodeproj`, `SkinAmp.app`, `SkinAmpThumbnail.appex`, `pgrep -x SkinAmp`,
     `release/SkinAmp.app.zip`, `make-dmg.sh` names).
   - The VM clone prefix and lease label. The stale-clone cleanup keeps matching `skinamp-test-` for one transition.

   This is **one commit**, because the VM runner builds by project and scheme name. Afterwards, delete the stale local
   `SkinAmp.xcodeproj`; it is gitignored.
4. **W4: user-visible strings and remaining identifiers.** UI copy, the About and Check-for-Updates labels, the idle
   marquee, the Sendspin product and player name ("Roadie (<host>)"), errors, the Museum User-Agent
   `Roadie/<v> (+https://roadie.sstools.co/)`, the Keychain label, the temp file name, thread names, `skinAmpMediaID`
   → `roadieMediaID`, the environment variables, and the tests that assert these.
5. **W5: docs and tracker.**
   - `README.md`, `AGENTS.md`, current-state docs, `docs/plan.md` (adds M14).
   - The `issues/Issues.md` heading and `issues/project.json` `name` → `Roadie`. The `url` stays until the repo rename.
   - `NOTICE` gains ZIPFoundation.
   - Historical `issues/NNNN.md` files are **not** rewritten.

**Gate A: ready to push** (all of these, before `git push`):

- [ ] `scripts/verify.sh --head --full --launch --dmg` passes.
- [ ] Outside `issues/NNNN.md`, `git grep -i skinamp` finds only:
  - `LegacyDataCleanup` (its `com.brennanmke.SkinAmp.plex` constant);
  - the GitHub URL in `issues/project.json`;
  - the `README` sentence "formerly SkinAmp";
  - the transitional VM clone cleanup pattern.

  The allowlist lives in `scripts/check-rename.sh` (added in W5), which exits non-zero on anything else.
- [ ] `git grep com.brennanmke` finds only the same allowlist.
- [ ] **The user** installs a locally signed, unnotarized Roadie DMG (`scripts/make-dmg.sh`), enters their Music
      Assistant server and token, picks their folders, and confirms Roadie works.
- [ ] The user says "push".

Phase B tooling (W6–W13) may be in this push if it's ready. It doesn't block the gate.

### 2.2 No migration

Roadie starts fresh and does not migrate SkinAmp's settings, Keychain items or files, because only the user has run
SkinAmp. The user re-enters the Music Assistant server and token and picks folders once.

### 2.3 Sparkle

**Dependency:** add to `project.yml` `packages:`:

```yaml
Sparkle:
  url: https://github.com/sparkle-project/Sparkle
  exactVersion: 2.x.y   # newest 2.x when W7 lands; exact, because the app's Package.resolved is gitignored
```

Add `- package: Sparkle` to the **Roadie app target only**. The packages and Quick Look extensions stay free of Sparkle.
The guest resolves it like ZIPFoundation.

**Sandbox and entitlements:**

- Roadie is **not sandboxed**, so Sparkle installs in-process through `Autoupdate`.
- `SUEnableInstallerLauncherService`, `SUEnableDownloaderService` and the `-spks`/`-spki` mach-lookup entitlements are
  **not** needed and must stay absent. `check-info-plist.sh` asserts that.
- The hardened runtime and the Location entitlement are unchanged.
- If the app is ever sandboxed, those keys and entitlements become necessary. That's a reviewed change; see
  [code-signing.md](../code-signing.md).

**Info.plist** (`project.yml` `info.properties` with per-configuration settings):

| Key | Release | Debug |
|---|---|---|
| `SUFeedURL` | `$(ROADIE_FEED_URL)` = `https://roadie.sstools.co/appcast.xml` | empty |
| `SUPublicEDKey` | `$(ROADIE_PUBLIC_ED_KEY)` (public; set by W15) | empty |
| `SUEnableAutomaticChecks` | absent, so Sparkle asks once, on the second launch | absent |
| `SUEnableSystemProfiling` | absent (off) | absent |

`App/Info.plist` is a real file (XcodeGen writes it), so custom keys work alongside `GENERATE_INFOPLIST_FILE: YES`, the
same way `NSBonjourServices` does. Settings in `project.yml` aren't xcconfig, so `https://` needs no escaping.

**Code (`App/Updates/`):**

- `Updater`, an `@MainActor @Observable` class:
  - Creates `SPUStandardUpdaterController(startingUpdater: isConfigured, …)`. `isConfigured` means both `SUFeedURL`
    and `SUPublicEDKey` are non-empty.
  - Mirrors `canCheckForUpdates`, `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates` and
    `lastUpdateCheckDate` through KVO.
  - Debug builds, and so the VM's `--launch` run, never start the updater: no network and no first-launch alert.
- App menu: `CommandGroup(after: .appInfo) { Button("Check for Updates…") … .disabled(!updater.canCheckForUpdates) }`
  in `RoadieApp`.
- Skinned main menu: a new `MainMenuCommand.checkForUpdates` item right after "About Roadie" (`MainMenu.swift:95`). It's
  handled in `PlayerModel+MainMenu.swift` through a closure the app injects, so SkinKit stays free of Sparkle.
  `MainMenuTests` covers the order.
- **Settings › Updates** tab:
  - "Automatically check for updates" toggle.
  - "Automatically download and install updates" toggle, off by default and disabled while checks are off.
  - "Check Now" button.
  - "Last checked: …".
  - In Debug: "Updates are off in development builds."
- The About panel uses a bundled `Credits.rtf` (picked up automatically). It holds the tagline, the disclaimer
  (§2.8), acknowledgements (Webamp, lodash, ZIPFoundation, Sparkle) and the website link.

**Version comparison:**

- Sparkle compares `CFBundleVersion`. `20261101.0930` and `20261101.1405` compare component by component (20261101,
  then 930 < 1405), so the UTC `YYYYMMDD.HHMM` scheme orders correctly, including several builds in one day.
- `sparkle:minimumSystemVersion` is `14.0`.

**Checks (W7):**

- `check-info-plist.sh --release <plist>` (a VM step after `app-release`) asserts the exact `SUFeedURL`, a non-empty
  `SUPublicEDKey` once W15 lands, and that the installer and downloader service keys are absent.
- Debug mode asserts `SUFeedURL` is empty.
- New `scripts/check-sparkle.sh <app>` (VM) asserts that `Contents/Frameworks/Sparkle.framework` exists with
  `Autoupdate`, `Updater.app` and both XPC services, and that the Quick Look appexes don't link Sparkle (`otool -L`).

### 2.4 Versioning

- One `MARKETING_VERSION` in `project.yml` top-level `settings.base`, set to `0.0.1`. The per-target copies are removed.
  `CURRENT_PROJECT_VERSION: "1"` moves there too, for Debug.
- `info.properties` sets `CFBundleShortVersionString: $(MARKETING_VERSION)` and
  `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` explicitly in all three targets. That removes any dependence on Xcode
  overriding the literal values in the committed plist.
- 0.0.1 is lower than the old 0.1.0. That's harmless: it's a new bundle id, and Sparkle compares the build number.
- `run-tests-vm.sh` gains `--build-number N`, validated against `^[0-9]{8}\.[0-9]{4}$`, and `verify.sh` passes it
  through. When it's absent, the build number is computed as today. `release.sh` always passes it, so it knows the
  number before the build.
- The `--dmg` step also brings back:
  - `release/Roadie.app.dSYM.zip` plus `dsym-uuids.txt` (from `dwarfdump --uuid`), for symbolicating crash reports;
  - `release/sparkle-bin/{sign_update,generate_keys}` from `SourcePackages/artifacts/sparkle/Sparkle/bin/`, the same
    pinned version. The host never builds.
- **Tag `vX.Y.Z` = `MARKETING_VERSION` = `CFBundleShortVersionString` = the DMG name.** `preflight.sh` and `release.sh`
  check all four.
- Version bump: one commit, `Bump version to X.Y.Z`, together with the `CHANGELOG.md` section.

### 2.5 Release pipeline (`scripts/release.sh`)

`scripts/release.sh X.Y.Z [--publish] [--notary-profile NAME] [--identity NAME] [--repo OWNER/NAME]`

- **Without `--publish` (the default):** a rehearsal. It runs every local step except notarization, writes only under
  `build/release/X.Y.Z/`, and doesn't touch `website/`, git or GitHub. Agents may run this.
- **`--publish`:** user-run only.

| # | Step | Where | Notes |
|---|---|---|---|
| 0 | Preflight | host | `scripts/preflight.sh --release X.Y.Z`: clean tree on `main`; `MARKETING_VERSION == X.Y.Z` and greater than the newest appcast version; tag absent; `CHANGELOG.md` has `## [X.Y.Z]`; credential gates (identity, certificate expiry, notary profile, Sparkle key matches `SUPublicEDKey`, `gh auth status`); tools present. |
| 1 | Build and test | **VM** | `BUILD=$(date -u +%Y%m%d.%H%M)`; `scripts/verify.sh --head --full --launch --dmg --build-number $BUILD`. Any failure stops the release. Reads the zip path from the RELEASE line. |
| 2 | Unpack and version gate | host | `ditto -x`; every bundle (app and both appexes) must report `X.Y.Z ($BUILD)`; Sparkle embedded. |
| 3 | Sign | host | Inside-out with Developer ID, `--options runtime --timestamp`, each bundle's entitlements minus `get-task-allow`. Order: `Sparkle.framework/Versions/B/XPCServices/Installer.xpc`, `…/Downloader.xpc` (its entitlements kept), `…/Autoupdate`, `…/Updater.app`, `Sparkle.framework`, the appexes, the app. Then `codesign --verify --deep --strict`, plus a direct check of each nested Mach-O: not ad-hoc, the app's team and authority, runtime flag, timestamp. |
| 4 | DMG | host | Stage `Roadie.app` and an `Applications` symlink. `hdiutil create -volname Roadie -format UDZO` into a working file **named `Roadie.dmg`**: the file name equals the volume name, because otherwise macOS can rename the file during the notarization round trip. Sign the DMG with a timestamp. |
| 5 | Notarize | host | `xcrun notarytool submit Roadie.dmg --keychain-profile "$PROFILE" --wait`. Only the submission id and status are printed. If the result is `Invalid`, fetch `notarytool log` into `build/release/X.Y.Z/notary-log.json` and stop. |
| 6 | Staple and verify | host | `stapler staple` and `stapler validate`; `spctl -a -t open --context context:primary-signature`; `scripts/verify-dmg.sh` (includes a Safari-quarantine simulation). |
| 7 | Final name | host | `mv Roadie.dmg Roadie-X.Y.Z.dmg`. **From here on the bytes are frozen.** |
| 8 | sha256 | host | `(cd build/release/X.Y.Z && shasum -a 256 Roadie-X.Y.Z.dmg > Roadie-X.Y.Z.dmg.sha256)`, run inside the folder so the file holds the bare name. |
| 9 | sign_update and appcast item | host | `scripts/appcast-item.sh`: mounts read-only; reads both versions from the app inside; runs `sign_update --account Roadie` from `build/sparkle/bin`; checks that `length` equals the byte size; prepends the `<item>` to `website/appcast.xml`; `xmllint --noout`. |
| 10 | Changelog | host | `scripts/render-changelog.py X.Y.Z` turns the `CHANGELOG.md` section into: `<article id="vX-Y-Z">` prepended to `website/changelog.html`, the appcast `<description>` HTML, and `build/release/X.Y.Z/release-notes.md` for GitHub. |
| 11 | Download link | host | Rewrites the block between `<!-- download:begin -->` and `<!-- download:end -->` in `website/index.html`: version, `downloads/Roadie-X.Y.Z.dmg`, size. Then `scripts/check-website.sh --expect-dmg X.Y.Z`. |
| 12 | Tag and commit | host | `git tag -a vX.Y.Z -m "Roadie X.Y.Z"` on the **built commit**, then commit `website/` as `Release X.Y.Z: appcast, changelog, download link`. |
| 13 | Push | host | Prompts `Push main and vX.Y.Z to origin? [y/N]`, then `git push origin main vX.Y.Z`. |
| 14 | GitHub release | host | `gh release create vX.Y.Z Roadie-X.Y.Z.dmg Roadie-X.Y.Z.dmg.sha256 --repo "$REPO" --verify-tag --title "Roadie X.Y.Z" --notes-file release-notes.md`. Then `gh release download` into a fresh temp folder and compare its sha256 with the local file. |
| 15 | Hand-off | host | Prints the per-release checklist from `docs/website-hosting.md`, then: "Ask for the site to be deployed." |

**Secrets:**

- The script runs with `set -euo pipefail` and `unsetopt xtrace`, and refuses to start if `XTRACE`/`-x` is set.
- It never sources `.env`.
- It passes no secret on a command line:
  - the notary credentials live in the keychain profile;
  - `sign_update` reads its key from the login keychain (never `-s`/`--ed-key-file`);
  - `gh` uses its own stored auth.
- Output is limited to identity names, profile names, ids, hashes and paths.

**Kept as artifacts:** everything under `build/release/X.Y.Z/` (gitignored): the DMG, the `.sha256`, the dSYM zip and
UUIDs, the notary log and the release notes.

### 2.6 Website (`website/`, per the hosting contract)

```
website/
  index.html         hero: "Roadie" + tagline, screenshot, download block, features, requirements, footer
  changelog.html     one <article id="vX-Y-Z"> per release, newest first
  privacy.html
  appcast.xml        Sparkle feed; empty <channel> until 0.0.1
  site.webmanifest   name, icons, start_url "/"
  favicon.svg, favicon.ico
  css/style.css      hand-written; one Google Fonts import at most
  assets/            app icon PNGs (from App/Assets.xcassets), screenshots, social card (1200x630)
  downloads/.gitkeep
  src/               icon and screenshot sources, notes (never uploaded)
  README.md          maintainer notes (never uploaded)
```

**`index.html` content:**

- **Hero:** "Roadie", then "A Winamp-skinned player for Music Assistant". One screenshot (main, EQ and playlist docked).
- **Download block:**
  - Before 0.0.1 it reads "Coming soon", with no link, because the deploy checks that every link resolves.
  - From 0.0.1 on, `release.sh` maintains it: "Download Roadie X.Y.Z", "Requires macOS 14 Sonoma or later", and a link
    to the GitHub release for the checksum.
- **Features:**
  - Classic Winamp 2.x `.wsz` skins with the main, EQ and playlist windows, docking, shade modes and the visualizer.
  - Browse and play your Music Assistant library; This Mac as a Music Assistant player (Sendspin); local files and
    folders.
  - A built-in skin browser and the Winamp Skin Museum.
  - Quick Look thumbnails for `.wsz`.
  - Updates through Sparkle.
- **Requirements:** a Music Assistant server on your network (or reachable over HTTPS), macOS 14+, Apple silicon or
  Intel (per the build).
- **Footer:** Changelog, Privacy, Source on GitHub (added in W14, after the repo rename), the disclaimer (§2.8),
  "© Brennan Stehling".

**`privacy.html`:**

- Roadie collects nothing and has no analytics.
- Network use: your Music Assistant servers; the Winamp Skin Museum (only when you open it, with User-Agent
  `Roadie/<version>`); `roadie.sstools.co/appcast.xml` for update checks. Sparkle sends the app version in its
  User-Agent and no system profile.
- Location access is used only to read the Wi-Fi network name to pick a server, and is never stored or sent.
- Music Assistant tokens are kept in your login keychain.
- Local data paths.
- Contact.

**`changelog.html`:** generated articles. The `sparkle:releaseNotesLink` is `changelog.html#vX-Y-Z`.

**`scripts/check-website.sh`** (read-only lint; runs on the host, like `check-info-plist.sh`, and as a VM step):

- `xmllint --noout appcast.xml`.
- Every `href`/`src` in the top-level `*.html`, every icon and `start_url` in the manifest, and every `url(...)` in
  `css/*.css` resolves to a file under `website/`. A `downloads/Roadie-X.Y.Z.dmg` link is allowed only for versions
  with a GitHub release or with `--expect-dmg`.
- No `<script src=` from another host, and no external host besides `fonts.googleapis.com` and `fonts.gstatic.com`.
- No `*.dmg` tracked by git.

`.gitignore` gains `website/downloads/*.dmg`.

### 2.7 Docs and README

- **New:** `docs/sparkle.md`, `docs/releasing.md`, `docs/release-credentials.md`, `docs/code-signing.md`, this file,
  and `website/README.md`.
- **`README.md`:**
  - Title "Roadie", the tagline, "formerly SkinAmp".
  - Download link to the website.
  - Requirements.
  - Development: XcodeGen; builds and tests only in the VM through `scripts/verify.sh`.
  - A docs index.
  - The Webamp/NOTICE credit.
- **Other docs:**
  - `AGENTS.md`: the name.
  - `docs/testing-in-vm.md`: `--build-number`, `ROADIE_*`, the new step names.
  - `docs/plan.md`: M14 section.
  - `NOTICE`: adds ZIPFoundation (MIT) and Sparkle (MIT, with its bundled licenses).
- **`CHANGELOG.md`** (new, repo root) uses a strict subset of Keep a Changelog that `render-changelog.py` understands:
  `## [X.Y.Z] - YYYY-MM-DD`, `### Added|Changed|Fixed`, `- ` bullets, inline links and code.

### 2.8 Trademark and disclaimer (proposal, not legal advice)

- **Tagline:** keep "Roadie: a Winamp-skinned player for Music Assistant". It uses "Winamp" descriptively, for the skin
  format the player reads, and doesn't present Roadie as a Winamp product.
  - A more conservative alternative: "Roadie: a Music Assistant player that wears classic Winamp skins".
- **Disclaimer** (site footer, `Credits.rtf`, README):
  > Winamp is a trademark of its owner. Music Assistant is a project of its respective owners. Roadie is an
  > independent project and is not affiliated with, sponsored by or endorsed by Winamp or Music Assistant. Roadie
  > displays skins made in the classic Winamp 2.x format; skins are the work of their authors and are not included
  > with Roadie.
- **Not used:** the Winamp logo, the llama, Winamp's own artwork, or the Winamp base skin in screenshots, the icon or
  the site. Screenshots use an original Roadie skin, or a skin whose author agreed.
- **Name check:** "Roadie" is also used by other music-related products (for example a guitar tuner). The user should
  do a quick trademark search in class 9 before 0.0.1.

## 3. Work items

Each item fits one agent. Builds and tests run only through `scripts/verify.sh`. "User" marks steps only the user can do.

### Phase A: rename (Gate A, then push)

**W1. Dropped** ([#0152](../../issues/0152.md), won't fix). No migration (§2.2).

**W2. Identity switch.** Depends on: nothing.
- `project.yml` bundle ids, UTIs, document types and Quick Look types.
- `MusicAssistantTokenStore.defaultService`.
- Hard-coded paths: `SkinIndexStore.swift:43`, `PlayerModel.swift:59`, and the fallbacks in `QueueSnapshot`,
  `SkinThumbnailCache`, `FolderIndex`, `LegacyDataCleanup:39`.
- Every `com.brennanmke.SkinAmp` logger subsystem and queue label → `co.sstools.roadie`.
- `PlayerView.swift:37` and `MediaIDTransfer.swift:7`.
- `check-info-plist.sh`, `check-quicklook.sh`, `TokenStoreTests.swift:40`.
- One commit.
- Accept: a full VM run passes; `git grep com.brennanmke` outside `issues/` matches only the allowlist.

**W3. Product rename.** Depends on: W2.
- `project.yml` name, targets, scheme, display names; rename the entitlements files and `RoadieApp.swift`.
- `run-tests-vm.sh` (project, scheme, app paths, `pgrep`/`osascript` names, zip name, clone prefix and lease label with
  the transitional cleanup), `verify.sh`, `check-*.sh`, `make-dmg.sh` (`Roadie.app`, `Roadie-<v>-<build>-<commit>.dmg`,
  volname `Roadie`).
- One commit.
- Accept: `verify.sh --launch --dmg` passes and reports `release/Roadie.app.zip`.

**W4. Strings and code identifiers.** Depends on: W3.
- All user-visible text in §1, `ROADIE_SLOW_TESTS`, `roadieMediaID`, `outputsHideRoadiesOwnPlayer`, the Museum
  User-Agent, the Keychain label, thread names.
- Update the tests that assert these strings: `MainMenuTests`, marquee, Sendspin, User-Agent.
- Accept: no `SkinAmp` (case-insensitive) in `App/`, `Packages/`, `QuickLook/`, `scripts/`, `project.yml` beyond the
  allowlist; full VM pass.

**W5. Docs, tracker, NOTICE, rename check.** Depends on: W3 (can run alongside W4).
- §2.7 renames (not the GitHub URL), `issues/project.json` name, the `Issues.md` heading.
- Add this doc and the four docs.
- `scripts/check-rename.sh` with the allowlist, added as a VM step.
- Accept: `check-rename.sh` passes; every relative link in `docs/` resolves.

**Gate A (user).** The §2.1 checklist, including the user's check on their own Mac with a DMG from
`scripts/make-dmg.sh` (Developer ID signed, not notarized). Then the user pushes main.

### Phase B: release tooling (before or after the push)

**W6. Versioning.** Depends on: W3.
- §2.4: one `MARKETING_VERSION = 0.0.1`, explicit plist version keys, `--build-number`, dSYM and `sparkle-bin`
  brought back (`sparkle-bin` once W7 lands).
- Accept: Release bundles report `0.0.1 (<N>)`, Debug reports `0.0.1 (1)`; a bad `--build-number` exits 2.

**W7. Sparkle.** Depends on: W4, W6.
- §2.3 in full: package, `Updater`, both menus, Settings › Updates, `Credits.rtf`, `check-info-plist.sh --release`,
  `check-sparkle.sh`, NOTICE.
- Accept:
  - VM steps `app-release-plist` and `app-sparkle` pass;
  - `MainMenuTests` covers the new item;
  - the `--launch` smoke test still passes, with no alert or network request in Debug.

**W8. Release signing and DMG.** Depends on: W7.
- Add a `--release X.Y.Z` mode to `make-dmg.sh`: Sparkle nested signing order, per-binary checks, `Roadie.dmg` as the
  working name renamed to `Roadie-X.Y.Z.dmg` after stapling, `.sha256`.
- New `scripts/verify-dmg.sh` (stapler, spctl, quarantine simulation, deep verify, hardened runtime, team).
- Accept: on an unnotarized DMG, `verify-dmg.sh` passes everything except the notarization checks and reports exactly
  those as failing; `codesign -dv` on each Sparkle helper shows the Developer ID authority, `runtime` and a timestamp.

**W9. preflight.sh.** Depends on: W6, W7.
- Gates in §2.5 step 0, plus `--credentials-only` and `--strict`.
- Build-number gate: the new build must be greater than the highest `sparkle:version` in the appcast, compared as
  (date, time).
- Accept: prints one line per gate; exits non-zero when any one of these is missing: identity, profile, Sparkle key,
  version bump.

**W10. Appcast and changelog generation.** Depends on: W6, W7.
- `scripts/appcast-item.sh`, `scripts/render-changelog.py`, `CHANGELOG.md` with an `[Unreleased]` section.
- Accept: `scripts/tests/test_render_changelog.py` passes in the VM (headings, bullets, links, escaping, anchor
  `vX-Y-Z`); `appcast-item.sh` on a fixture DMG prints an item that passes `xmllint` and has the checked length.

**W11. release.sh.** Depends on: W8, W9, W10, W12.
- §2.5, with rehearsal as the default and `--publish` for the real thing.
- Accept: `scripts/release.sh 0.0.1` (rehearsal) produces the DMG, `.sha256`, item, notes and dSYM zip under
  `build/release/0.0.1/` and leaves `git status` clean; `zsh -n` passes.

**W12. Website skeleton.** Depends on: W5.
- §2.6 pages, CSS, icons from the app icon, the empty appcast, `site.webmanifest`, `downloads/.gitkeep`,
  `website/README.md`, `.gitignore`, `scripts/check-website.sh` as a VM step.
- Accept: `check-website.sh` passes; previewing with `python3 -m http.server` shows every page; no external hosts
  besides Google Fonts.

**W13. Credential tooling.** Depends on: W7.
- `scripts/setup-notary.sh` (prompts for key path, key id and issuer; nothing hard-coded or committed).
- `scripts/export-release-credentials.sh` and `scripts/import-release-credentials.sh`.
- `docs/release-credentials.md`.
- Accept: the scripts refuse a destination inside the repo, never pass `-P`, skip existing items, never call
  `generate_keys -f` when `-p` already finds a key, and end with `preflight.sh --credentials-only`.

### Phase C: repo rename

**U1 (user).** Rename `brennanMKE/SkinAmp` to `brennanMKE/Roadie` on GitHub.

**W14. Remote, folder and links.** Depends on: U1.
- `git remote set-url origin …/Roadie.git`. The user moves the local folder to `…/brennanMKE/Roadie`.
- `issues/project.json` url; README and website GitHub links (add "Source on GitHub"); the default
  `--repo brennanMKE/Roadie` in `release.sh`.
- Accept: `git ls-remote origin` works; a VM run from the new folder passes; `check-website.sh` passes.

### Phase D: 0.0.1

**U2 (user).**
- Run `build/sparkle/bin/generate_keys --account Roadie` on the release Mac (from a `--dmg` run's `sparkle-bin`).
- Export a backup with `-x` to the password manager or an encrypted volume.
- Give the **public** key to W15.

**W15. Public key.** Depends on: U2.
- Set `ROADIE_PUBLIC_ED_KEY` in `project.yml` (Release).
- Accept: `check-info-plist.sh --release` asserts it; `preflight.sh --credentials-only` key check passes.

**U3 (user).** `scripts/setup-notary.sh` stores the `Roadie-notary` profile. An existing team profile also works,
through `--notary-profile`.

**W16. 0.0.1 prep.** Depends on: W11, W14, W15.
- The `CHANGELOG.md` 0.0.1 section; screenshots in `website/assets/` (user-provided, §2.8); a `release.sh 0.0.1`
  rehearsal.
- Accept: `preflight.sh --release 0.0.1 --strict` is clean apart from the user-run publish; the rehearsal passes.

**U4 (user).**
- Run `scripts/release.sh 0.0.1 --publish`.
- Smoke-test on a fresh user account: drag to Applications, open with no warning, enter a server and token, play.
- Ask for the site to be deployed.
- Accept: the `v0.0.1` GitHub release has both assets; the hand-off checklist is complete.

## 4. Open questions (recommended defaults)

1. **Automatic update checks.** *Default:* `SUEnableAutomaticChecks` unset, so Sparkle asks on the second launch.
   Automatic download is off. Both are toggles in Settings › Updates.
2. **Release notes source.** *Default:* `CHANGELOG.md` at the repo root, rendered into `changelog.html`, the appcast
   and GitHub.
3. **Minimum macOS on the site.** *Default:* "macOS 14 Sonoma or later" (`project.yml:5`).
4. **Sparkle private key.** *Default:* login keychain on the release Mac, account `Roadie`, with an exported backup in
   the user's password manager or an encrypted volume. Never in the repo or on the web host.
5. **Notary profile name.** *Default:* `Roadie-notary`, created with an App Store Connect API key; `--notary-profile`
   accepts any existing profile for the same team.
6. **Tagline and disclaimer wording.** *Default:* as in §2.8, plus a quick trademark search on "Roadie" before 0.0.1.
7. **Screenshot skin.** *Default:* an original Roadie skin (could seed the default look); never the Winamp base skin.
8. **Test tier for releases.** *Default:* `--full --launch --dmg` (slow tier included).
9. **Notarize the app on its own as well as the DMG?** *Default:* no. One DMG submission, stapled.
10. **Rename the VM clone prefix and lease label.** *Default:* yes, with one transitional cleanup pattern.
11. **Sendspin player name.** *Default:* "Roadie (<host>)". Roadie starts with a new client id, so Music Assistant
   sees a new player.
12. **Idle marquee text.** *Default:* "Roadie".
