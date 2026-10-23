# Roadie

**Roadie: a Winamp-skinned music player for macOS.**

Roadie is a native macOS music player that renders classic Winamp 2.x `.wsz` skins (main window, equalizer
and playlist) and plays music from a local folder on your Mac, or optionally from a [Music Assistant](https://music-assistant.io/) server.
It can also play on this Mac as a Sendspin player, and browse and apply skins from a local skins folder or the
Winamp Skin Museum. The project was called SkinAmp during development.

## Download

Get the latest release from **https://roadie.sstools.co/**.

## Requirements

- macOS 14 Sonoma or later.
- A folder of music on your Mac.
- Optional: a Music Assistant server, with a long-lived token for it, to stream its library.

## Development

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`
(`Roadie.xcodeproj` is gitignored):

```sh
brew install xcodegen
xcodegen generate
```

Builds and tests run only in a disposable Tart VM, never on the host, through `scripts/verify.sh`. See
[docs/testing-in-vm.md](docs/testing-in-vm.md).

- `App/` – the SwiftUI/AppKit app
- `Packages/SkinKit/` – UI-free skin parsing, rendering, the skin library and the `skintool` CLI
- `Packages/PlayerKit/` – playback (AudioCore), Music Assistant and Sendspin clients, the library browser
- `QuickLook/` – Quick Look thumbnail and preview extensions for `.wsz` files
- `scripts/` – VM verification, release and maintenance scripts
- `issues/` – the issue tracker ([issues/Issues.md](issues/Issues.md)); agents start at [AGENTS.md](AGENTS.md)

## Docs

- [docs/plan.md](docs/plan.md) – architecture and milestones
- [docs/testing-in-vm.md](docs/testing-in-vm.md) – building and testing in the Tart VM
- [docs/issues-workflow.md](docs/issues-workflow.md) – how issues move from filed to resolved
- [docs/music-assistant-integration.md](docs/music-assistant-integration.md) – Music Assistant integration
- [docs/ma-protocol-notes.md](docs/ma-protocol-notes.md) – Music Assistant API notes and fixtures
- [docs/sendspin-notes.md](docs/sendspin-notes.md) – playing on this Mac as a Sendspin player
- [docs/winamp-skin-museum-access.md](docs/winamp-skin-museum-access.md) – Winamp Skin Museum access
- [docs/skin-comparison.md](docs/skin-comparison.md) – comparing renders with Webamp
- [docs/releasing.md](docs/releasing.md), [docs/code-signing.md](docs/code-signing.md),
  [docs/sparkle.md](docs/sparkle.md), [docs/release-credentials.md](docs/release-credentials.md) – shipping a release
- [docs/design/release.md](docs/design/release.md) – the Roadie release design

## License and acknowledgements

Roadie ports sprite data, parsers and layout rules from [Webamp](https://github.com/captbaritone/webamp) by
Jordan Eldredge, a character table from lodash, and uses [ZIPFoundation](https://github.com/weichsel/ZIPFoundation),
all under the MIT License; see [NOTICE](NOTICE). Winamp is a trademark of its owners; Roadie is not affiliated with
Winamp or Nullsoft.
