# Releasing Roadie

How a version becomes a notarized `Roadie-X.Y.Z.dmg` on GitHub and on https://roadie.sstools.co/. The script is
`scripts/release.sh`. The design is in [design/release.md](design/release.md) and the hosting contract in
[website-hosting.md](website-hosting.md).

Agents may run the **rehearsal**. Only the user runs `--publish`: it uploads to Apple, pushes, and creates a GitHub
release.

## Before the first release (once)

- A Developer ID Application identity in the login keychain ([code-signing.md](code-signing.md)).
- A notarytool profile, `Roadie-notary` by default ([release-credentials.md](release-credentials.md)).
- The Sparkle key generated, backed up, and its public key in `project.yml` ([sparkle.md](sparkle.md)).
- `gh auth status` shows a login that can create releases on the repo.
- `scripts/preflight.sh --credentials-only` passes.

## Preflight

`scripts/preflight.sh` prints one `PASS`/`FAIL`/`WARN` line per gate, then a summary, and exits non-zero if any gate
fails. It never prints a secret: only identity and profile names and whether the Sparkle key matches.

- `--release X.Y.Z`: clean tree on `main`; `MARKETING_VERSION` is X.Y.Z; X.Y.Z is newer than the appcast's newest
  `sparkle:shortVersionString`; tag `vX.Y.Z` absent locally and on origin; `CHANGELOG.md` has `## [X.Y.Z]`. Plus
  everything below.
- `--credentials-only`: tools (`xcrun`, `hdiutil`, `codesign`, `stapler`, `spctl`, `xmllint`, `gh`, `python3`,
  `tart`); a Developer ID Application identity whose certificate is valid for 30+ days (WARN under 30); the notary
  profile; the Sparkle keychain key equals `ROADIE_PUBLIC_ED_KEY`; `gh auth status`.
- `--build-number YYYYMMDD.HHMM`: must be greater than the appcast's highest `sparkle:version`.
- `--strict`: warnings fail. `--identity NAME`, `--notary-profile NAME` (default `Roadie-notary`),
  `--sparkle-bin DIR` (default `build/sparkle/bin`) override the defaults.

## Steps

1. **Pick the version** (SemVer).
   - Set `MARKETING_VERSION` in `project.yml`, the only place it lives.
   - Move `CHANGELOG.md`'s `[Unreleased]` entries under `## [X.Y.Z] - YYYY-MM-DD`. User-visible changes only; link
     `#NNNN` issues.
   - Commit both as `Bump version to X.Y.Z`.
   - Don't set a build number. The script stamps `CFBundleVersion` with the UTC `YYYYMMDD.HHMM`.
2. **Preflight:** `scripts/preflight.sh --release X.Y.Z`. Fix every ✗.
3. **Rehearse:** `scripts/release.sh X.Y.Z`.
   - Builds and tests in the VM (`--full --launch --dmg`), signs, makes the DMG, `.sha256`, appcast item and notes
     under `build/release/X.Y.Z/`.
   - Doesn't notarize. Doesn't touch `website/`, git or GitHub.
4. **Publish (user):** `scripts/release.sh X.Y.Z --publish`. In order:
   1. VM build and test.
   2. Developer ID signing, inside-out, Sparkle helpers included.
   3. DMG, notarize, staple, `verify-dmg.sh`.
   4. `Roadie-X.Y.Z.dmg` and `.sha256`.
   5. The appcast item prepended; `changelog.html` article; download link.
   6. `check-website.sh`.
   7. Annotated tag `vX.Y.Z` on the built commit; website commit.
   8. A prompt before pushing main and the tag.
   9. `gh release create` with both assets, then re-download to check the hash.
5. **Smoke test** on a fresh user account or a Mac that has never run Roadie:
   - Open the DMG and drag Roadie to Applications.
   - It opens with no Gatekeeper warning.
   - About shows `X.Y.Z (<build>)`.
6. **Deploy:** go through the hand-off checklist the script prints (the same one as in
   [website-hosting.md](website-hosting.md)), then ask for the site to be deployed.
7. **After deploy:** on a Mac running the previous version, **Check for Updates…** offers X.Y.Z and installs it.

## Checklist

- [ ] `MARKETING_VERSION` bumped and `CHANGELOG.md` section written, in one commit
- [ ] `preflight.sh --release X.Y.Z` clean
- [ ] Rehearsal passed
- [ ] `--publish` finished: tag pushed, GitHub release has `Roadie-X.Y.Z.dmg` and `.sha256`
- [ ] `website/appcast.xml` has the new item first; `xmllint` passes
- [ ] `website/changelog.html` has `<article id="vX-Y-Z">`
- [ ] The download button points at `downloads/Roadie-X.Y.Z.dmg`
- [ ] Previewed locally: `cd website && python3 -m http.server 8000`
- [ ] Smoke-tested on a clean account
- [ ] Deploy requested; update offered to the previous version

## Signing and the DMG by hand

`release.sh` runs these two; they also work on their own against a VM zip (`scripts/verify.sh --head --dmg`):

- `scripts/make-dmg.sh <Roadie.app.zip> --release X.Y.Z [--identity NAME] [--notary-profile NAME] [--out DIR]`
  - Version gate: the app and both appexes must report `X.Y.Z (<build>)` with one build number.
  - Signs inside-out in the [code-signing.md](code-signing.md) order (Sparkle helpers when present, a note when
    not), then `codesign --verify --deep --strict` and a check of every Mach-O.
  - Builds `Roadie.dmg` (volume `Roadie`), signs it; notarizes and staples only with `--notary-profile`
    (printing only the submission id and status; on `Invalid` the log goes to `<out>/notary-log.json`).
  - Renames it `Roadie-X.Y.Z.dmg`, writes `Roadie-X.Y.Z.dmg.sha256`, and copies the dSYM zip and `dsym-uuids.txt`.
  - `--out` defaults to `build/release/X.Y.Z`. Without `--release`, the old dev mode writes
    `build/dist/Roadie-<version>-<build>-<commit>.dmg`.
- `scripts/verify-dmg.sh <dmg> [--expect-team ID] [--allow-unnotarized]` prints one `PASS`/`FAIL` line per check:
  DMG signature and team, `stapler validate`, `spctl -t open`, the mounted app's deep verify and `spctl -t exec`,
  every Mach-O's authority, team, runtime and timestamp, and a Safari-quarantine simulation. With
  `--allow-unnotarized`, the four notarization checks are reported as expected failures and don't fail the exit code.

## If something fails

- **Notarization `Invalid`.** The log is in `build/release/X.Y.Z/notary-log.json`. Usual causes: a nested binary
  without the hardened runtime or a timestamp, or one left ad-hoc signed. Fix it, then re-run from the start. Nothing
  was published.
- **Failure after the tag but before the push.** Delete the local tag (`git tag -d vX.Y.Z`) and reset the website
  commit, then re-run.
- **Failure after the push.** Never reuse a version. Bump to X.Y.(Z+1).
- Never edit a published DMG or its appcast item.
