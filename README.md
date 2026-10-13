# SkinAmp

```sh
pip install internetarchive
ia download --search 'collection:winampskins' --glob '*.wsz'
```


## Development

See `winamp-skin-player-brief.md` for goals. The app is named SkinAmp.

```sh
brew install xcodegen
xcodegen generate            # creates SkinAmp.xcodeproj (git-ignored)
open SkinAmp.xcodeproj

swift test --package-path Packages/SkinKit
swift run --package-path Packages/SkinKit skintool Skins/        # parse report
SKIN_CORPUS_DIR=/path/to/skins swift test --package-path Packages/SkinKit
```

- `App/` – SwiftUI app (main window rendering, skin loading by drag-and-drop or File › Open Skin…)
- `Packages/SkinKit/` – UI-free skin parsing (`SkinKit`), `skintool` CLI, tests
- `scripts/port-webamp-sprites.py` – regenerates `SkinSprites.swift` from Webamp
- `References/` – cloned reference projects (git-ignored); `Skins/` – local skins (git-ignored)
