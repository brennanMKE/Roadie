# Roadie website: hosting requirements

What the repo has to provide so the Roadie website can be published at
**https://roadie.sstools.co/**, and what the host provides in return. It
answers the hosting questions in [#0151](../issues/0151.md): domain, TLS,
upload method and paths.

The site follows the same pattern as the other sstools.co Mac app sites
(Batty, Curator, Changeover). Deploying it is handled outside this repo. This
repo only prepares `website/` and publishes GitHub releases.

## What the host provides

- **Hostname:** `roadie.sstools.co`, HTTPS only. Plain `http://` requests get
  a permanent redirect to `https://`. The certificate is valid and renews
  automatically, so the app and the site never handle TLS.
- **Static files only.** No server-side code, no build step, no rewrites. A
  path serves the file of the same name relative to `website/`.
- **Content types** for everything the site needs, including:

  | Extension | Served as |
  |---|---|
  | `.dmg` | `application/x-apple-diskimage` |
  | `.xml` (the appcast) | `text/xml` |
  | `.webmanifest` | `application/manifest+json` |
  | `.html`, `.css`, `.svg`, `.png`, `.ico`, `.jpg`, `.mp4` | the standard types |

- **No long-lived caching of `appcast.xml`.** It is served with
  `Last-Modified` and `ETag`, so Sparkle sees a new entry on its next check.

## What `website/` contains

```
website/
  index.html          landing page: tagline, screenshots, download button
  changelog.html      release notes, one <article id="vX-Y-Z"> per release
  privacy.html
  appcast.xml         the Sparkle feed
  site.webmanifest    optional
  favicon.svg, favicon.ico
  css/style.css
  assets/             icons, screenshots, social card
  downloads/.gitkeep  DMGs are added at deploy time and never committed
  src/                templates and sources (not uploaded)
  README.md           notes for maintainers (not uploaded)
```

Add this to `.gitignore`:

```
# Release DMGs live on GitHub releases and, once deployed, on the web host; never in git.
website/downloads/*.dmg
```

`src/` and every `README.md` stay in the repo but are never uploaded. Keep
private notes there and nowhere else under `website/`, because everything
else becomes public.

## App settings that depend on the site

| Setting | Value |
|---|---|
| `SUFeedURL` | `https://roadie.sstools.co/appcast.xml` |
| `SUPublicEDKey` | the EdDSA public key (the private key never leaves the release Mac) |
| Enclosure URL in each appcast item | `https://roadie.sstools.co/downloads/Roadie-X.Y.Z.dmg` |
| `sparkle:releaseNotesLink` | `https://roadie.sstools.co/changelog.html#vX-Y-Z` |

`SUFeedURL` is compiled into every shipped build, so this hostname is
permanent once the first build ships. An installed copy only ever checks that
name.

## Release artifacts on GitHub

Every DMG listed in `appcast.xml` must first exist on a GitHub release. The
deploy downloads it from GitHub and doesn't read it from the repo.

- **Tag:** `vX.Y.Z` (SemVer, same as `CFBundleShortVersionString`).
- **Assets on that release**, named exactly:
  - `Roadie-X.Y.Z.dmg`, Developer ID signed, notarized and stapled.
  - `Roadie-X.Y.Z.dmg.sha256`, the output of `shasum -a 256 Roadie-X.Y.Z.dmg`.
- The enclosure's file name must match `Roadie-<version>.dmg`, where the
  version starts with a digit. The deploy reads the version out of that name
  to find the tag.

## Rules that keep updates working

1. **Generate the appcast entry from the built DMG, never by hand.**
   `length` and `sparkle:edSignature` cover exactly those bytes, and
   `sparkle:version` must equal the `CFBundleVersion` inside the app.
2. **The DMG on GitHub and on the site is the same file.** Never re-compress,
   rename or re-sign it after `sign_update` runs, or every installed copy
   rejects the update.
3. **Never remove an older item's DMG.** Older appcast items and old links keep
   pointing at their files. Keep each `<item>` in `appcast.xml` once
   published, newest first.
4. **`appcast.xml` must be valid XML.** A malformed feed stops the deploy
   before anything is uploaded.
5. **Every local reference must resolve.** After uploading, the deploy
   requests every `href` and `src` in the top-level `*.html` pages, the icons
   and `start_url` in `*.webmanifest`, and every `url(...)` in `css/*.css`.
   Any of them returning anything but 200 fails the deploy. Don't link a
   screenshot or page before the file exists.
6. **Nothing external that phones home.** No analytics, trackers or
   third-party scripts. Web fonts from Google Fonts are the one external
   reference the other sites use.

## Per-release hand-off

A release is ready to deploy when:

- [ ] The `vX.Y.Z` GitHub release is published with `Roadie-X.Y.Z.dmg` and
      `Roadie-X.Y.Z.dmg.sha256`.
- [ ] `website/appcast.xml` has the new item first, generated from that DMG.
- [ ] `website/changelog.html` has `<article id="vX-Y-Z">`.
- [ ] The download button in `index.html` points at the new DMG.
- [ ] `xmllint --noout website/appcast.xml` passes.
- [ ] Previewed locally with `cd website && python3 -m http.server 8000`.
- [ ] Committed and pushed.

Then ask for the site to be deployed. The deploy uploads `website/`, fetches
any DMG the appcast lists that the site doesn't have yet, checks it against
the `.sha256` and the enclosure `length`, and verifies everything over HTTPS.

## Repo rename

The GitHub repo was renamed from `SkinAmp` to `Roadie` on 2026-10-23, so
releases are read from `brennanMKE/Roadie`. The deploy side is told the current
repo name, so nothing in `website/` changed with the rename. GitHub redirects the
old release URLs, but the deploy only needs to know the current name.
