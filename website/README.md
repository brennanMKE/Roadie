# website/ (maintainer notes; never uploaded)

The static site for https://roadie.sstools.co/. Plain HTML and one hand-written stylesheet, no build step. The hosting
contract is [docs/website-hosting.md](../docs/website-hosting.md); the content plan is
[docs/design/release.md](../docs/design/release.md) §2.6. Everything here except `README.md` and `src/` is public.

| File | What it is |
|---|---|
| `index.html` | Landing page: hero, download block, screenshot, features, requirements |
| `changelog.html` | Release notes, one `<article id="vX-Y-Z">` per release, newest first |
| `privacy.html` | Privacy statement |
| `help.html` | How playlists, the queue and Jump to File work |
| `appcast.xml` | Sparkle feed (`SUFeedURL`); empty `<channel>` until 0.0.1 |
| `site.webmanifest`, `favicon.svg`, `favicon.ico` | Icons; the favicon is an original bolt mark, not Winamp artwork |
| `css/style.css` | All styling; the one external reference is the Google Fonts import at its top |
| `assets/icon-*.png` | Copies of `App/Assets.xcassets/AppIcon.appiconset` (32, 128, 256, 512) |
| `assets/screens/` | Skin screenshots for the home-page carousel, plus `manifest.json`; made by `scripts/make-screenshots.sh` |
| `downloads/` | DMGs are added at deploy time; `*.dmg` is gitignored |

Preview locally with `cd website && python3 -m http.server 8000`. Lint with `scripts/check-website.sh`
(also the `website` step of `scripts/run-tests-vm.sh`).

## Contracts with the release scripts

### Download block (`index.html`, maintained by `release.sh`)

`release.sh` replaces everything between the two markers, keeping the markers. Before 0.0.1 it is:

```html
<!-- download:begin -->
<div class="download" id="download">
<span class="coming-soon">Coming soon</span>
<span class="download-meta">For macOS 14 Sonoma or later</span>
</div>
<!-- download:end -->
```

For release `X.Y.Z` it writes exactly this (substitute the version in the three places):

```html
<!-- download:begin -->
<div class="download" id="download">
<a class="download-button" href="downloads/Roadie-X.Y.Z.dmg"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"></path><path d="M7 10l5 5 5-5"></path><path d="M5 21h14"></path></svg>Download Roadie X.Y.Z</a>
<div class="download-meta">Requires macOS 14 Sonoma or later<br><a href="https://github.com/brennanMKE/Roadie/releases/tag/vX.Y.Z">Checksum and release notes on GitHub</a></div>
</div>
<!-- download:end -->
```

The DMG is not in git, so `scripts/check-website.sh` accepts the `downloads/Roadie-X.Y.Z.dmg` link only when the
`vX.Y.Z` GitHub release exists or with `--expect-dmg X.Y.Z` (use that during the release, before the deploy).

### Changelog (`changelog.html`, written by `scripts/render-changelog.py`)

Generated articles go between `<!-- releases:begin -->` and `<!-- releases:end -->`, newest first; a new release is
inserted right after the begin marker. Each article's id is `vX-Y-Z` (the `sparkle:releaseNotesLink` anchor). Classes
the stylesheet knows:

```html
<article class="release" id="vX-Y-Z">
<div class="release-head"><h2>X.Y.Z</h2><span class="release-date">YYYY-MM-DD</span><a class="release-link" href="index.html#download">Download</a></div>
<p>Optional summary.</p>
<div class="release-group"><h3>Added</h3><ul><li>…</li></ul></div>
</article>
```

The "No releases yet" note sits outside the markers and hides itself once an article exists (CSS `:has`); it can be
deleted after the first release.

### Appcast

Items are generated from the built DMG by the release tooling, never by hand, and prepended inside `<channel>`, newest
first. Never remove a published item. `xmllint --noout website/appcast.xml` must pass.

## Screenshots

`index.html` shows the skin screenshots in a carousel (`js/carousel.js`: swipe or drag, dot buttons, arrow keys,
a new slide every 3 s; paused on hover or focus and still under reduced motion). Each slide is a `<figure>` with a
WebP `<source>`, a PNG `<img>` and the skin's name and author. Feature only skins with no third-party trademarks or
characters, and never the Winamp base skin (§2.8); `scripts/make-screenshots.sh` lists what is left out and why.
Every `src` must exist before deploying. A 1200x630 `assets/social-card.png` and its `og:image` tag can be added the
same way.

### Regenerating the skin screenshots (#0168)

```sh
scripts/make-screenshots.sh            # about 5 minutes; one Tart VM, silent
```

It builds Roadie in a disposable Tart VM (never on the host), docks the main, equalizer and playlist windows on a
plain dark desktop, plays the same eight Electronic tracks as local files on This Mac (the guest boots with
`--no-audio` and is muted; Music Assistant is not configured, so no speaker can be reached), and captures each skin
4 s into the first track. It writes `assets/screens/<slug>.png` at twice the skin's native size (550 px wide for a
classic skin, nearest-neighbour), `<slug>.webp` (lossless) when `cwebp` is installed, and `manifest.json`:
`[{"slug", "file", "width", "height", "skin", "author", "source"}]`, author from the readme inside the `.wsz` or
`null`. The run replaces the previous set.

- Skins: the featured list is the `SKINS` table at the top of the script; the `.wsz` files come from the gitignored
  `Skins/` of the main checkout (`--skins DIR` to override) and are never committed.
- Music: fetched once over ssh from the media host (`MEDIA_HOST`, default `joe`) into
  `~/Library/Caches/co.sstools.roadie-screens/music` (`--music DIR` to override); never committed.
- Look at every image before committing: no server address or id may show, and no window but Roadie's.
