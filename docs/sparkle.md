# Updates (Sparkle)

Roadie updates itself with Sparkle 2. This doc covers how an update reaches an installed copy, the keys, the
Info.plist settings and the appcast rules. The release procedure is in [releasing.md](releasing.md); key setup and
backup are in [release-credentials.md](release-credentials.md).

## How it works

1. Every Release build carries `SUFeedURL` (`https://roadie.sstools.co/appcast.xml`) and `SUPublicEDKey` (the EdDSA
   public key).
2. Sparkle fetches the appcast: on its schedule if automatic checks are on, or from **Check for Updates…**.
3. It compares each item's `sparkle:version` with the running `CFBundleVersion`. Roadie's build number is the UTC
   `YYYYMMDD.HHMM` of the build, so later builds always compare higher, even on the same day.
4. It downloads the enclosure (`https://roadie.sstools.co/downloads/Roadie-X.Y.Z.dmg`) and checks
   `sparkle:edSignature` against `SUPublicEDKey`.
5. It replaces the app and relaunches.

`SUFeedURL` and `SUPublicEDKey` are compiled into every shipped copy. Once 0.0.1 ships, the hostname and the key are
permanent for those copies.

## In the app

- **Roadie › Check for Updates…** and the same item in the skinned main menu, right after About Roadie.
- **Settings › Updates:**
  - "Automatically check for updates";
  - "Automatically download and install updates" (off by default);
  - "Check Now";
  - the date of the last check.
- Sparkle asks once, on the second launch, whether to check automatically. The answer is the toggle above.
- **Debug builds** (including every VM test run) have an empty `SUFeedURL`, so the updater never starts: no network,
  no prompts, and the menu item is disabled.

Code: `App/Updates/Updater.swift` wraps `SPUStandardUpdaterController`. Only the app target links Sparkle; the
packages and Quick Look extensions don't.

## Settings

| Key | Release | Debug |
|---|---|---|
| `SUFeedURL` | `https://roadie.sstools.co/appcast.xml` | empty |
| `SUPublicEDKey` | the public key | empty |
| `SUEnableAutomaticChecks` | not set (Sparkle asks) | not set |
| `SUEnableSystemProfiling` | not set (off) | not set |
| `SUEnableInstallerLauncherService`, `SUEnableDownloaderService` | **must be absent**: Roadie isn't sandboxed | absent |

They are set in `project.yml`: `info.properties` maps `SUFeedURL` and `SUPublicEDKey` to the per-configuration
settings `ROADIE_FEED_URL` and `ROADIE_PUBLIC_ED_KEY` (Release: the feed URL and the public key; Debug: both empty).
Until W15 sets the public key, `ROADIE_PUBLIC_ED_KEY` is empty in Release too, so the updater stays off there as well.

## Checks

- `scripts/check-info-plist.sh <plist>` (the VM step `app-plist`, on the Debug app) asserts `SUFeedURL` is empty and
  the installer and downloader service keys, `SUEnableAutomaticChecks` and `SUEnableSystemProfiling` are absent.
- `scripts/check-info-plist.sh --release <plist>` (VM step `app-release-plist`, with `--dmg`) asserts the exact
  `SUFeedURL` and the same absent keys. An empty `SUPublicEDKey` prints a `WARN` instead of failing until W15 lands.
- `scripts/check-sparkle.sh <app>` (VM step `app-sparkle`, with `--dmg`) asserts `Contents/Frameworks/Sparkle.framework`
  has `Autoupdate`, `Updater.app` and both XPC services, that the app links Sparkle and the Quick Look appexes don't
  (`otool -L`), and that the sandbox-only `-spks`/`-spki` entitlements are absent.
- `MainMenuTests` covers Check for Updates… right after About Roadie in the skinned main menu.

The dependency is pinned with `exactVersion` in `project.yml` (2.10.0). To upgrade Sparkle:
1. Change that version.
2. Run `scripts/verify.sh --dmg`.
3. Read Sparkle's release notes for signing changes.

## Keys

- **EdDSA key pair**, made once with `generate_keys --account Roadie`. The private key stays in the release Mac's
  login keychain, with an exported backup kept off the machine.
- **Losing the private key means no installed copy can ever accept another update.** Back it up before 0.0.1 ships;
  see [release-credentials.md](release-credentials.md).
- The **public** key is not secret. It lives in `project.yml`.
- The tools (`generate_keys`, `sign_update`) come from the same pinned Sparkle version (the guest's
  `SourcePackages/artifacts/sparkle/Sparkle/bin/`). A `scripts/verify.sh --dmg` run brings them back from the VM to
  `build/vm-tests/<run-id>/release/sparkle-bin/`; they are never run in the guest. `release.sh` copies them
  to `build/sparkle/bin/` after its build step.
- Always pass `--account Roadie`. Without it the tools look under the default account and fail with
  "Signing key not found for account ed25519".

## Appcast rules

1. **Generate each item from the finished DMG.** `scripts/appcast-item.sh`:
   - mounts the DMG;
   - reads `CFBundleShortVersionString` and `CFBundleVersion` from the app inside;
   - runs `sign_update`;
   - checks `length` against the file size.
   Never type `sparkle:version`, `length` or `sparkle:edSignature` by hand.
2. **The DMG is frozen once signed.** The same bytes go to GitHub and the website. Never re-compress, rename or
   re-sign it after `sign_update`.
3. **Newest item first. Never remove an item or its DMG.**
4. **Valid XML:** `xmllint --noout website/appcast.xml`.
5. Each item carries:
   - `sparkle:minimumSystemVersion` `14.0`;
   - `sparkle:releaseNotesLink` `https://roadie.sstools.co/changelog.html#vX-Y-Z`;
   - a short `<description>` rendered from `CHANGELOG.md`.

Item shape:

```xml
<item>
  <title>0.0.1</title>
  <pubDate>…</pubDate>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>https://roadie.sstools.co/changelog.html#v0-0-1</sparkle:releaseNotesLink>
  <description><![CDATA[ … ]]></description>
  <enclosure url="https://roadie.sstools.co/downloads/Roadie-0.0.1.dmg"
             sparkle:version="20261101.0930" sparkle:shortVersionString="0.0.1"
             sparkle:edSignature="…" length="…" type="application/octet-stream"/>
</item>
```

## Troubleshooting

- **"You're up to date" while a newer item exists.** That item's `sparkle:version` isn't higher than the installed
  `CFBundleVersion`. Regenerate the item from the DMG.
- **"The update is improperly signed".** Either the DMG changed after `sign_update`, or it was signed with a key that
  doesn't match `SUPublicEDKey`. `preflight.sh --credentials-only` compares the two keys.
- **Menu item greyed out.** It's a Debug build (empty feed), or `SUPublicEDKey` is empty.
