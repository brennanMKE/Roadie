# Release credentials

What a Mac needs before it can release Roadie, how to set it up, how to move it to another Mac, and what to back up.
This doc contains procedures only. No secret is ever written into the repo, printed by a script, or passed on a
command line.

## Check

```sh
scripts/preflight.sh --credentials-only
```

Fast, and needs no build. One line per item; non-zero exit if anything is missing. `release.sh --publish` runs it
first and stops if it fails.

| Item | Breaks if missing |
|---|---|
| Developer ID Application identity (certificate **and** private key) | signing |
| Certificate expiry (warning at 30 days) | signing, once expired |
| notarytool keychain profile (`Roadie-notary`) | notarization |
| `sign_update` and `generate_keys` in `build/sparkle/bin` | appcast signing |
| Sparkle private key (login keychain, account `Roadie`), with public half equal to `SUPublicEDKey` | installed copies reject the update |
| `gh` signed in with release rights | GitHub release |
| `xcrun`, `codesign`, `hdiutil`, `stapler`, `spctl`, `xmllint`, `shasum` | various steps |

## Set up (once per Mac)

### 1. Developer ID Application certificate

- If the team already has one, move it with its private key as a password-protected `.p12` (step "Move to another
  Mac"). **Don't create a new one** and never accept a prompt to revoke or replace a certificate: that invalidates it
  everywhere. See [code-signing.md](code-signing.md).
- `security find-identity -v -p codesigning` lists it only when both the certificate and its key are present.

### 2. Notary profile

1. In App Store Connect › Users and Access › Integrations, create (or reuse) an API key with the Developer role.
   Download the `.p8` once and keep it at `~/.appstoreconnect/` with mode 600.
2. Run `scripts/setup-notary.sh`. It asks for the `.p8` path, the key id and the issuer id, and runs
   `xcrun notarytool store-credentials Roadie-notary …`. Nothing is written to the repo.
3. Check: `xcrun notarytool history --keychain-profile Roadie-notary`.

An existing profile for the same team works too: `release.sh --notary-profile NAME`.

### 3. Sparkle EdDSA key (once, ever)

1. Run `scripts/verify.sh --dmg` once. `release.sh`, or copying `release/sparkle-bin/*` by hand, puts the tools in
   `build/sparkle/bin/`.
2. Check there's no key yet: `build/sparkle/bin/generate_keys --account Roadie -p`. It must find nothing.
3. Generate: `build/sparkle/bin/generate_keys --account Roadie`. The private key goes into the login keychain and the
   public key is printed.
4. **Back up now:** `generate_keys --account Roadie -x <outside the repo>/roadie-sparkle.key`. Store it in a password
   manager or an encrypted volume, then delete that file.
5. Put the public key in `project.yml` (`ROADIE_PUBLIC_ED_KEY`, Release). It's public.

**Losing the private key can't be recovered:** every installed copy would refuse future updates. Never run
`generate_keys` again for an account that already has a key, and never import over one.

## Move to another Mac

```sh
scripts/export-release-credentials.sh ~/Backups/roadie-release-credentials   # on the Mac that works
scripts/import-release-credentials.sh ~/Backups/roadie-release-credentials   # on the new Mac
```

- Export refuses a destination inside the repo, creates it with mode 700, and only reads. It exports:
  - the `.p8`;
  - the Developer ID identity as `DeveloperID.p12` (`security` asks for the passphrase in its own dialog; `-P` is never
    used);
  - the Sparkle key as `roadie-sparkle.key`.
- Import skips anything already present:
  - an existing identity is never duplicated;
  - an existing Sparkle key is never replaced (`-p` is checked before `-f`).
  It then prints the `setup-notary.sh` command and runs `preflight.sh --credentials-only`.
- Move the bundle only over a channel you trust, then delete the copies.

## Back up

| Item | If lost | Recoverable |
|---|---|---|
| Sparkle private key | No update can ever reach installed copies | **No** |
| Developer ID `.p12` | Can't sign on a new Mac | Re-issue from Apple: a last resort |
| App Store Connect `.p8` | Can't create a notary profile on a new Mac | Make a new key in App Store Connect |

Keep all three in one place you control and that isn't the release Mac.
