# Test automation (M16)

Design for milestone **M16: Test automation** ([#0192](../../issues/0192.md)). Written 2026-10-24, after 0.0.4 shipped with bugs that every automated check passed over ([#0186](../../issues/0186.md)–[#0191](../../issues/0191.md)): double-clicking a row of a Music Assistant queue played the first track, because the real server sends `"index": 0` for every queue item and the hand-made fixtures numbered rows correctly; Library → playlist drags never worked; playlists couldn't be played. None of that was reachable by the tests that exist: there is no UI test target, the App target has no unit tests, and the VM's `app-launch` step only checks that the app is still running after five seconds.

The user's requirements, which this doc follows:

> we need test automations to ensure we do not have any regressions. First, we need fast unit tests which are as comprehensive as possible. These would use mocks for talking with Music Assistant or real mp3/m4a files so they can be fast and catch regressions. These fast tests would be run and pass before moving onto review. We are also going to use a Haiku subagent to run builds and tests which ensures logs are kept out of the context. Only failures will collect log lines for warnings and errors to use to fix the problems.
>
> For unit tests which cannot be fast but still guard against regressions, we can run those once per milestone. We also need UI test automations. This will require including a selection of skins which we do not include in source control but you can fetch from the skins museum by name and cache locally to pass into the VM. Everything the user is supposed to be able to do should be included in UI test automations.

Companion docs: [testing-in-vm.md](../testing-in-vm.md) (how a VM run works), [verify-runner-plan.md](../verify-runner-plan.md) (the Haiku runner), [issues/Issues.md](../../issues/Issues.md) (the workflow this changes).

## 1. Tiers and when each runs

| Tier | Command | What runs | When | Budget |
|---|---|---|---|---|
| **Fast** | `scripts/verify.sh [--expect …]` | Build stage; `swift test` for SkinKit and PlayerKit (fast gates off); **new** `app-unit-tests` (the `RoadieTests` bundle, §2.1); the app checks (plist, entitlements, Quick Look, identifiers, changelog, release tools, website) | Every issue, every review. **Must pass before an issue goes to review**, with the issue's new tests in `--expect`. | ≤ 4 min wall (today 2.6 min; the app bundle adds about 1 min) |
| **UI** | `scripts/verify.sh --ui [--ui-filter Class,…]` | Fast tier plus `ui-build` (build-for-testing of the `Roadie UI Tests` scheme) and `ui-tests` (XCUITest in the guest, base skin only, optional `-only-testing` filter) | **Per issue when the change touches `App/` UI** (views, windows, menus, drag and drop, accessibility): the plan names the UI test classes for that feature area in `--ui-filter`, so the run stays short. **Per milestone**: the whole UI suite plus the per-skin smoke over every skin in the manifest (`--ui-skins all`). | Per issue: fast tier + ≤ 4 min (build-for-testing ≈ 1.5 min, 10–20 tests at 3–8 s each). Milestone: ≤ 25 min. |
| **Slow** | `scripts/verify.sh --full` | Fast tier plus the 100k SkinLibrary scale tests (`ROADIE_SLOW_TESTS=1`), the real-time AudioCore tests (`AUDIOCORE_REALTIME=1`), and any new slow test behind those gates (the fixture-corpus decode pass, §2.3) | Changes to code a slow test guards (as today), and **once per milestone**. | ≤ 6 min |
| **Milestone end** | `scripts/verify.sh --head --full --ui --ui-skins all --coverage` | Everything above, plus the coverage report (§2.4) with its floors | When the last child of a milestone resolves, and before a release (`scripts/release.sh` already runs the VM; it gains `--ui`). | ≤ 35 min; may run in the background runner |

Why UI tests are both per issue and per milestone, and not one or the other: a UI regression like #0187 is only caught by driving the UI, so an issue that changes the UI needs its UI test to run before review. But an XCUITest run costs an extra `xcodebuild build-for-testing` plus one app launch per test, and some flakiness is unavoidable in a headless guest, so running the whole suite on every issue would double the per-issue loop and add noise. The compromise is a filtered run per issue (only the feature area's classes, base skin only) and the full suite with every skin once per milestone. Issues that touch only packages, scripts or docs don't run UI tests at all; the plan's `## Which tier` line says which.

What "fast" buys: package tests run against built binaries in about 6 s total; the app bundle tests target under 20 s. The per-issue budget is held by keeping anything that waits on real time (audio devices, network timeouts, animations) out of the fast tier: it renders offline, uses stub transports with scripted replies, and uses injected clocks.

## 2. Fast unit tests

### 2.1 Making the App's logic testable

Today every piece of pure logic the App needs has been moved into a package and tested there (`LibraryBrowser`, `SkinKit`, `MusicBackendKit`), while `App/` holds the composition root (`PlayerModel`, 1,171 lines), the view models that need AppKit or both packages (`PlaylistModel`, `JumpToFilePanel`, `SkinWindowController`), the menus, and the SwiftUI views. The bugs of 0.0.4 lived in exactly that App layer (`PlaylistModel.playRow`, `PlaylistListInputView.performDragOperation`, `PlaylistListView` rows) and in a package seam fed by unrealistic fixtures. So two things are needed: a test target that can reach App code, and more realistic fixtures.

**A hosted App unit-test bundle, `RoadieTests`** (#0193). An XcodeGen target of type `bundle.unit-test` with `TEST_HOST` set to the Roadie app, in the `Roadie` scheme's test action next to the package test targets. Hosted, because `PlayerModel`, `PlaylistModel` and the window controllers import AppKit and SwiftUI and are `@MainActor`; a hosted bundle runs them in a real app process with a run loop. The cost is that `main` runs: `AppDelegate.applicationDidFinishLaunching` would build a `PlayerModel`, open the skinned windows and maybe the Welcome window. The app therefore checks `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]` (set by XCTest for a hosted run) and, when present, builds no model and opens no window; each test constructs its own `PlayerModel` in test mode (§2.2). The `Roadie` scheme runs it with `xcodebuild test-without-building -only-testing:RoadieTests` in a new VM step, `app-unit-tests`, after `app-build` (which becomes `build-for-testing`). The step is part of the fast tier, so `verify.sh`'s `--expect` sees its `Test Case '…' passed` lines (it already matches the XCTest format).

Moving more logic out of `App/` into packages stays the first choice when the code has no AppKit dependency (as `QueueSaveTarget.loadChoices` did in #0190). `RoadieTests` is for what can't move. Per area:

| Area | Where it lives | Recommendation | Issue |
|---|---|---|---|
| `PlayerModel` (composition root, output selection, feeds, menus, notices) | `App/PlayerModel*.swift` | Keep in App; give it a `PlayerModel.Configuration` (§2.2) so tests build it with stub backends, in-memory stores and a temp data directory. Test the dispatchers (`perform(MainMenuCommand)`, `perform(WinampHotkey)`, `loadList()`, `pickLibraryPlaylist()`, `selectOutput`, `playFromLibrary`, `appendDroppedLibraryItems`) in `RoadieTests`. | #0194, #0211 |
| `PlaylistModel` (rows, selection, play row, queue markers, sort, remote refusals) | `App/Playlist/PlaylistModel.swift` | Keep in App (it needs `Player` from AudioCore and `PlaylistLayout` from SkinKit, and the two packages can't depend on each other). Test in `RoadieTests` with a real `Player` (opens no device until something plays) and a `RemoteQueueSnapshot` for the remote path. | #0210 |
| Jump to File | `App/JumpToFile/JumpToFilePanel.swift` (AppKit panel); matcher already in `LibraryBrowser` | Split the panel: a `JumpToFileController` (query → results → chosen row → `playRow`/`toggleQueue`, empty-state text) with no views, tested in `RoadieTests`; the `NSPanel` keeps only layout and delegates. | #0210 |
| Drag and drop decoding | `PlaylistListInputView` (`hasMediaID`, `mediaIDs(from:)`, `operation(for:)`), `MediaIDTransfer.decode` (package, tested) | Move the three statics to a `LibraryDropDecoder` enum in App and test them against a private `NSPasteboard` with one and several `NSPasteboardItem`s, lazily provided data, and a mask without `.copy` (the #0188 candidates). | #0210 |
| Menus | `MainMenu` entries (SkinKit, tested); `MainMenuBuilder` (App); `PlaylistContextMenus` (App); SwiftUI `Commands` | `RoadieTests`: build the `NSMenu` from entries and check titles, key equivalents and enabled states against `MainMenuState`; `PlaylistContextMenus.rowMenu` titles (Queue / Dequeue / Clear Queue / File Info… enabled). The menu bar `Commands` are SwiftUI and are driven by the UI tests (§3). `MainMenuTests.shortcutsMatchMenuBar` already pins pop-up ⇄ menu-bar parity. | #0193, #0211 |
| First launch | `FirstRunPolicy` (package, tested); `PlayerModel.firstRunState(defaults:)`; `WelcomeWindowController` | `RoadieTests`: `firstRunState` from a temp `UserDefaults` suite for the four "configured" cases. The Welcome window itself is a UI test. | #0193 |
| Settings | Models in packages (`FolderSettingsModel`, `MusicAssistantSettingsModel`, `SkinLibraryModel` is App) | `SkinLibraryModel` in `RoadieTests` with a temp defaults suite and database URL. The views are UI tests. | #0211 |
| Window docking, skin windows | `WindowDocking` (package, tested); `SkinWindowController`, `WindowDockingCoordinator` (App) | `RoadieTests` for layout persistence round trips (`windowLayout` data) and `applyLayout` sizes at scale 1 and 2, with windows created but never ordered in. | #0211 |

Rule for new code: logic goes in a package when it can; otherwise it is reachable from `RoadieTests` through an injected dependency, never only through a view.

### 2.2 Test mode: one configuration for unit and UI tests

`PlayerModel.init()` wires the real world: Keychain token store, `URLSessionWebSocketTransportFactory`, Bonjour discovery, Wi-Fi, the Museum over HTTP, `QueueStore.defaultURL()`, `SkinIndexStore.defaultURL`, caches. Test mode replaces each with a seam that already exists in the packages (#0194):

```swift
struct RoadieConfiguration {
    var dataDirectory: URL?                      // queue.json, skins.sqlite, thumbnails, folder index, Museum caches
    var defaults: UserDefaults                   // .standard, or a suite in test mode
    var musicAssistant: MusicAssistantMode       // .live | .scripted(scenario: String) | .none
    var museum: MuseumMode                       // .live | .fixtures(skinsFolder:) (SkinMuseumStub, no network)
    var discovery: Bool                          // Bonjour, Wi-Fi name, network events, wake notifications
    var externalOpens: ExternalOpenMode          // .workspace | .record (Help links, Open in Skin Museum)
    var isUITest: Bool                           // -RoadieUITest 1
    var silentOutput: Bool                       // reserved: manual rendering (see Risks)
    static func fromProcess(arguments:hostedTestRun:) -> RoadieConfiguration   // -RoadieUITest 1 -RoadieDataDir …, or the hosted unit-test run
}
```

- **Music Assistant**: `MusicAssistantBackend(transports:)` takes `StubWebSocketTransport` from `MusicAssistantKitStub`, scripted by a `ScriptedMusicAssistant` (#0197): a small stateful server built on `FixtureScript.recorded(token:)` that holds players, queues and library items from the recorded fixtures, answers `player_queues/items`, `players/all`, `music/*` from them, and **applies** `player_queues/play_index`, `play_media`, `move_item`, `delete_item`, `clear`, `players/cmd/*`, favorites and playlist writes to its state, pushing `player_updated` / `queue_updated` / `queue_items_updated` events with the recorded envelope. Scenarios: `libraryIdle` (recorded, nothing playing), `queueLoaded` (the recorded loaded queue, `index: 0` on every row), `playingOnSpeaker` (`SyntheticPlayback`), `unreachable`, `badToken`. The token is a fixed fake (`InMemoryMusicAssistantTokenStore`), the server store is seeded with one verified server at `http://ma.example:8095` (the recordings' scrubbed host), and `hasVerifiedServer` is true, so the app connects at launch as it does for a real user.
- **Folder library**: the real `FolderBackend`, pointed at a fixture music folder (§2.3) through the existing `LibraryFolderPath` default.
- **Storage**: `QueueStore`, `SkinIndexStore`, `SkinThumbnailCache`, `FolderIndex` and the Museum caches take their root from `dataDirectory`; the model's defaults are `configuration.defaults`: in UI test mode the emptied `co.sstools.roadie.uitest` suite, which still reads `-key value` launch arguments from `NSArgumentDomain` (every scene and hosting root sets `.defaultAppStorage(model.defaults)`, so the views' `@AppStorage` uses the same suite). Unit tests pass a `UserDefaults(suiteName:)`. The hosted unit-test run's own host model uses an isolated configuration too (temp data directory, fresh suite, Music Assistant `.none`, no discovery).
- **Network off**: `discovery == false` swaps `SystemServiceBrowser`, `SystemWiFiNetwork` and `SystemNetworkEvents` for inert stubs; the Museum uses `FixtureMuseumTransport` from the `SkinMuseumStub` product (which also holds the committed GraphQL fixtures `SkinMuseumTests` reads), answering pages from the fixtures and downloads from the test skins folder instead of fetching. Sparkle is already off in Debug (empty feed URL). Test mode is Debug only: in Release `fromProcess` always returns `.standard`, and the post-build phase strips the `MusicAssistantKitStub` / `SkinMuseumStub` fixture bundles, which hold recordings of a real library (checked by the `--dmg` step `app-release-fixtures` and `scripts/verify-dmg.sh`).
- **Audio**: see Risks. In v1 the app plays through the guest's muted virtual device, which has no path to the host (`tart run --no-audio`); the `AUDIO` host check stays the proof.

`RoadieTests` builds `PlayerModel(configuration:)` directly; the UI tests pass `-RoadieUITest 1 -RoadieDataDir … -RoadieMAScenario queueLoaded …` as launch arguments. One mechanism, two consumers.

### 2.3 Fixtures

**Music Assistant: real recordings only.** `scripts/record-ma-fixtures.py` (#0060) is the one way a fixture is made: host only, reads `.env` itself, sends only allow-listed read commands, scrubs the token, hosts, ids and names in process, and runs a secret gate before writing to `Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/`. The token never enters the VM or a fixture: `.env` is gitignored, so the export (`git ls-files -co --exclude-standard`) never carries it, and `--check` fails if any fixture contains the token or the `.env` host. Rules this milestone adds (#0196):

1. **Fixtures are verbatim.** Never hand-edit a frame. A test that needs a variation builds it from the recording with `FixtureScript.override` or `SyntheticPlayback`, and its name says `synthetic`.
2. **Quirks are kept, and pinned.** `docs/ma-protocol-notes.md` gets a "Quirks" list (first entry: `player_queues/items` rows carry `"index": 0` whatever their position, MA 2.10.6), and `MAFixtureTests.recordedQuirksHold` asserts each one against the fixture it was seen in. A re-record that loses a quirk fails that test, so the change is noticed and the code that depends on it (`MAQueueWatch.item(_:position:)`) is reconsidered on purpose, not by accident.
3. **Loaded state is recorded, not imagined.** `player-queue-items.json` was recorded against an empty queue, which is why `BackendQueueTests.itemJSON` invented `"index": n`. The recorder gets `--record-queue` (read-only, like the rest): with a queue loaded and playing on the user's server it records `player-queue-items-loaded`, `player-queue-get-loaded`, `players-all-playing` and thirty seconds of events. These replace the synthetic rows in `BackendQueueTests` and feed `ScriptedMusicAssistant.queueLoaded`. Until the user runs it, `MAFixture.isRecorded` is false for those names and the scenario falls back to `SyntheticPlayback` with `index: 0` applied on purpose (so the #0187 regression test still runs).
4. **Both libraries, always.** Every behaviour that can run against the folder library and Music Assistant has a test for each (`FolderBackend` with a fixture folder; the scripted server). Music Assistant is optional for users, so no test may assume it is configured.

**Audio: tiny real files, committed.** Today the tests write WAVs on the fly (`writeWAV`, `writeSine`) and one tagged M4A. That exercises the decoder for PCM only. #0195 adds `Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio/` (a plain library target with resources, so several test targets and the UI test fixture folder can share it) holding generated, licence-clean files: a distinct sine per track so a test can tell them apart by analysing samples, 2–3 s each, under 100 KB each, with real tags:

| File | Made with | Guards |
|---|---|---|
| `01 Tone A.mp3`, `02 Tone B.mp3` (ID3v2 title/artist/album/track, 64 kbps) | `lame` on the host once (`scripts/make-test-audio.sh`; the script records the lame version) | MP3 decode, ID3 reading, gapless across two MP3s (encoder delay/padding), `bogusMP3IsSkipped` keeps its junk file |
| `03 Tone C.m4a` (AAC, iTunes-style tags), `04 Tone D.m4a` (ALAC) | `afconvert` (ships with macOS) from the generated WAV; tags via `AVAssetWriter` metadata | AAC and ALAC decode, priming, metadata |
| `05 Tone E.flac` (Vorbis comments) | `afconvert -f flac` | FLAC decode and tags |
| `06 Tone F.wav` | the existing generator | PCM reference |
| `cover.jpg` (64 px) | the existing `writeJPEG` | album art |

`.gitignore` currently ignores `*.mp3` everywhere (third-party music must never be committed); it gets a negation for this one directory, and `scripts/check-identifiers.sh`-style check `scripts/check-fixtures.sh` fails the run if any audio file outside it is tracked or any fixture exceeds 200 KB. `scripts/make-test-library.sh <out>` lays the files out as `Artist/Album/Track` (two artists, three albums, one with two discs, one single in the artist folder, one M3U) for `FolderBackend` tests and the UI tests' music folder. The slow tier adds a `fixtureCorpusDecodes` pass that renders every fixture offline end to end and checks the sample count against the duration (`ROADIE_SLOW_TESTS=1`).

**Skins: generated plus the Museum cache.** Unit tests keep the synthetic skins they build (`TestSkin`, `ZipFixtures`, `GeneratedBaseSkin`). UI tests default to the `base-2.91` skin from the cache (§4) and fall back to a generated skin written by `scripts/make-test-skin.swift` when the cache is absent, so a developer without the cache can still run the UI smoke test.

### 2.4 Coverage: measuring and picking the gaps

`scripts/run-tests-vm.sh --coverage` (#0212) turns on `swift test --enable-code-coverage` for both packages and `-enableCodeCoverage YES` on the `xcodebuild test` steps (the UI tests' coverage of the app counts too), then a `coverage-report` step runs `scripts/coverage-report.sh` in the guest: `llvm-cov report` per SwiftPM target (via `swift test --show-codecov-path`) and `xcrun xccov view --report --json` for the app, writing `coverage/report.md` (one row per target: lines, covered, %) and `coverage/lowest.txt` (the twenty least-covered source files with their line %) into the results. The summary prints one `COVERAGE` line per package; `verify.sh` passes it through on a pass.

Targets (line coverage, measured in the milestone run; the first `--coverage` run sets the baseline in `issues/0212.md`):

| Scope | Floor | Rationale |
|---|---|---|
| `SkinKit`, `SkinLibrary`, `SkinBrowser`, `SkinMuseum`, `WindowDocking` | 85 % | Pure logic, already well tested |
| `MusicBackendKit`, `LibraryBrowser`, `MusicAssistantKit`, `FolderBackendKit`, `LocalPlayback`, `SendspinKit`, `SendspinPlayback` | 85 % | Pure logic plus stubs |
| `AudioCore` | 70 % (fast) / 80 % (full) | Real-time paths only run in the full tier |
| `App` (Roadie target, `RoadieTests` + UI tests) | 60 %, rising 10 points per milestone to 80 % | Views are covered by UI tests; the composition root has start-up paths (Keychain, Sparkle) that tests must not run |

The floors fail only the milestone run (`--coverage` sets them; per-issue runs don't measure). Gaps are picked from `lowest.txt`: each file under its target's floor that holds user-facing logic becomes a row in the backfill issue (#0212 lists the first set), highest-risk first (anything on the play, queue, drag or Music Assistant paths).

## 3. UI tests

### 3.1 Target and runner

`RoadieUITests` (#0200): an XcodeGen target of type `bundle.ui-testing` with `TEST_TARGET_NAME: Roadie`, in its own scheme `Roadie UI Tests`, which only the VM script runs (the host never runs XCUITest; see testing-in-vm.md "Why a VM"). In the guest, `ui-build` runs `xcodebuild build-for-testing -scheme 'Roadie UI Tests' -derivedDataPath build/DerivedData` in the build stage, and `ui-tests` runs `xcodebuild test-without-building … -resultBundlePath ~/results/ui/UITests.xcresult [-only-testing:RoadieUITests/<Class>]…` with the fixture paths in the environment (`ROADIE_TEST_SKINS`, `ROADIE_TEST_MUSIC`, `ROADIE_TEST_DATA`). The run sets the guest display to 2560×1300 (as `make-screenshots.sh` does) before boot, so the docked skinned stack, the Library window and Jump to File fit on screen without overlapping.

A shared `RoadieApp` helper in the test bundle launches the app with the test mode arguments (§2.2), waits for the main window, and exposes typed accessors (`app.main.play`, `app.playlist.row(3)`, `app.jump`, `app.library`). Each test's `setUp` runs `defaults delete co.sstools.roadie` and empties the data directory through `Process` (allowed in a macOS UI test bundle), so every test starts from the same state. `tearDown` attaches a screenshot of every screen and of each Roadie window (`XCTAttachment`, `.keepAlways` on failure, `.deleteOnSuccess` otherwise), plus the app's state probe JSON (§3.3).

### 3.2 Making the skinned windows testable

The skinned windows are borderless `SkinWindow`s whose content is a `SkinShapeView` holding an `NSHostingView` of SwiftUI views; the controls are SwiftUI `Button`s with `EmptyView` labels and custom `ButtonStyle`s that draw sprites, `SkinSlider`s, and, for the playlist rows, an AppKit `PlaylistListInputView` that sits over the SwiftUI rows and handles the mouse. Nothing changes visually (#0199):

- **Every control gets an `accessibilityIdentifier`** from one registry, `enum AXID` in `App/Accessibility/AXID.swift`, so the UI tests and the app share the strings and a `RoadieTests` test checks they are unique: `main.previous`, `main.play`, `main.pause`, `main.stop`, `main.next`, `main.eject`, `main.shuffle`, `main.repeat`, `main.eq`, `main.playlist`, `main.volume`, `main.balance`, `main.position`, `main.time`, `main.marquee`, `main.kbps`, `main.khz`, `main.stereo`, `main.visualizer`, `main.title.menu|minimize|shade|close`, `main.clutter.o|a|i|d|v`; `eq.on`, `eq.auto`, `eq.presets`, `eq.preamp`, `eq.band.0`–`eq.band.9`, `eq.level.plus|zero|minus`, `eq.title.shade|close`; `pl.row.N`, `pl.scrollbar`, `pl.scroll.up|down`, `pl.resize`, `pl.menu.add|rem|sel|misc|list` and each entry `pl.menu.add.file|dir|url`, `pl.menu.rem.selected|crop|all|misc`, `pl.menu.sel.invert|zero|all`, `pl.menu.misc.info|sort|options`, `pl.menu.list.new|save|load`, `pl.transport.*`, `pl.runningTime`, `pl.miniTime`, `pl.title.shade|close`; `shade.*` for the three shade views; the existing `library.*`, `skins.*`, `ma.*` identifiers stay and the Library gets `library.sidebar.<section>`, `library.row.<kind>.<id>`, `library.output`; Jump to File `jump.search`, `jump.row.N`, `jump.queue`, `jump.empty`.
- **Values, not pixels.** Sliders expose `accessibilityValue` (volume 0–100, balance −100…100, position as `mm:ss / mm:ss`); `main.time` exposes the digits and the mode (`elapsed 01:23`); `main.marquee` the full (unscrolled) text; `main.stereo` `stereo|mono`; `main.kbps`/`main.khz` the numbers; toggles use `.isSelected`. Each playlist row is one accessibility element (`.accessibilityElement(children: .combine)`) whose label is the row text (`3. Artist - Title`), whose value is `marker=[2] duration=3:21`, and whose traits carry `.selected` and a custom `current` attribute; the `PlaylistListInputView` is not an accessibility element, so it never shadows the rows, and because `XCUIElement.click()` posts a real mouse event at the element's centre, the AppKit view still receives it.
- **Skinned pop-up menus.** The playlist's ADD/REM/SEL/MISC/LIST menus are SwiftUI entries with `.onTapGesture`; each becomes an accessibility button with its `pl.menu.*` identifier. The main window's menu button and right-click pop up a native `NSMenu`, which XCUITest reads as `app.menus` → `app.menuItems["Jump to File…"]`. SORT and MISC › options pop up `NSMenu`s the same way.
- **State probe.** A hidden accessibility element `state.probe` (an `NSAccessibilityElement` child of the main window's content view) whose value is a JSON string from `PlayerModel.testProbe()` (`output`, `feed`, `playbackState`, `currentIndex`, `queue: [{title, marker, isCurrent}]`, `notice`, `lastExternalOpen`, `maRequests: [lastN commands the scripted server received]`). Primary assertions read the real controls; the probe is for compound state (what the stub server received, the queue after a drag) and for the failure attachment. It exists only in test mode (`-RoadieUITest 1`).

### 3.3 Driving the app

| Interaction | How |
|---|---|
| Click, double-click | `element.click()`, `element.doubleClick()` (rows: the AppKit overlay gets the event) |
| Drag within a window (reorder rows, sliders) | `from.press(forDuration: 0.1, thenDragTo: to)`; sliders also `adjust(toNormalizedSliderPosition:)` where SwiftUI exposes the slider role |
| Drag between windows (Library row → playlist editor row, bottom bar; album → playlist row in the Library) | `from.press(forDuration: 0.3, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)` across two windows of the same app; the drop is verified through the rows and the probe. Finder drops can't be driven (another app): the decoder is unit-tested (#0210) and `open -a Roadie <files>` covers the `application(_:open:)` path |
| Keyboard | `app.typeKey("j", modifierFlags: [])` for Winamp bare keys (`Z X C V B S R L J`, arrows) with the skinned window key; `typeKey("j", .command)`, `typeKey("l", .command)`, `typeKey("1", .command)`, `typeKey("x", [.command, .control])` for the menu bar; `typeText("party")` into the Jump to File field; `typeKey(.return)`, `typeKey(.escape)`, `typeKey(.delete)`, `typeKey("q", [])` for Queue |
| Menu bar | `app.menuBars.menuBarItems["Playback"].click(); app.menuItems["Jump to File…"].click()`; check marks via `menuItem.value` |
| Skinned pop-up menu (main) | `app.main.titleMenu.click()` or `app.main.element.rightClick()`, then `app.menuItems[…]` and submenus `app.menuItems["Options"].menus.menuItems["Double Size"]` |
| Playlist SORT / MISC options | `app.pl.menu.misc.click(); app.pl.menu.misc.sort.click(); app.menuItems["Reverse List"].click()` |
| Context menus | `row.rightClick(); app.menuItems["Play Next"].click()` |
| System dialogs (`NSOpenPanel`, `NSSavePanel`) | Not driven. The actions behind them are unit-tested, and test mode accepts `-RoadieOpenFiles <paths>` / `-RoadieSaveTo <path>` so the UI tests can exercise what happens after the panel. |
| Waiting | `XCTNSPredicateExpectation` on `value` / `exists` with a 5 s default; never `sleep` |

### 3.4 Assertions and failure capture

Assertions read accessibility values: the current row (`pl.row.3` has `current`), what's playing (`main.marquee` text, `main.time` advancing: two reads 1.5 s apart differ), queue contents and `[n]` markers (`pl.row.N` values), stub server traffic (`state.probe.maRequests` ends with `player_queues/play_index index=3`), notices (`main.marquee` shows "Not for Music Assistant queues"). Never a pixel comparison; skin rendering is covered by `skintool --png` and the Webamp references (docs/skin-comparison.md).

On failure the result bundle holds the attachments. `run-tests-vm.sh` brings `ui/UITests.xcresult` back and runs `xcrun xcresulttool get test-results summary` and `… export attachments` **on the host** into `build/vm-tests/<run-id>/ui/` (`summary.json`, `attachments/<test>/<n>.png`, `probe.json`). `verify.sh` prints, per failing test, the test name, each assertion message (`XCTAssertEqual failed: ("0") is not equal to ("3") - row 3 should be current`), and the paths of its screenshots, within the 60-line cap.

## 4. Skins for the UI tests

Third-party skins are never committed (`.gitignore`: `*.wsz`, `Skins/`). The UI tests need real skins, so (#0198):

- **Manifest, committed:** `scripts/test-skins.tsv` with `name<TAB>museum_id<TAB>md5<TAB>why`. The md5 is both the Museum's key (`https://r2.webampskins.org/skins/<md5>.wsz`, `fetch_skin_by_md5`) and the integrity check.
- **Fetch script, host only:** `scripts/fetch-test-skins.sh [--cache DIR] [--check]`. For each row: skip if `<cache>/<name>.wsz` exists with the right md5; else POST `fetch_skin_by_md5` to `https://skins.webamp.org/graphql` (as `MuseumClient` does; the `download_url` it returns is preferred over the built URL, per docs/winamp-skin-museum-access.md), download with the project's User-Agent, verify the md5, write to `*.part` and rename. The cache defaults to `~/Library/Caches/co.sstools.roadie-test-skins/` (outside the repo, like `make-screenshots.sh`'s music cache), is gitignored if pointed into `build/`, and is never modified by a run. One request per skin, sequential, with a 1 s pause; this is one person's hobby infrastructure. A `scripts/tests/test_fetch_test_skins.py` unit-tests the manifest parsing and md5 check with a fake fetcher, in the existing `release-tools`-style step.
- **Into the VM:** `run-tests-vm.sh --ui` copies the cache into the export as `TestSkins/` (the same way `--skins` copies `Skins/`; the guest has no network) and refuses to start if a manifest row is missing from the cache (`!! run scripts/fetch-test-skins.sh first`). `--ui-skins base` (default) gives the tests the base skin only; `--ui-skins all` also runs `SkinSmokeUITests` over every manifest row.
- **Skin Museum feature tests** use the same folder as the stubbed downloader's source, so "Download" in the Museum tab copies from `TestSkins/` and the test can assert the file landed in the skins folder.

The selection, checked against the Museum on 2026-10-24 (md5s verified by download):

| Name | Museum id | md5 | Why it is in the set |
|---|---|---|---|
| `base-2.91` | S119636 | `5e4f10275dcb1fb211d4a8b4f1bda236` | The Winamp 2.91 base skin: every sheet, `region.txt`, cursors. The reference layout; the default for every UI test. |
| `Expensive_HI_FI_Sony_2005` | S118715 | `6a2843f40058f86406630671b454d66b` | Odd shape: `region.txt` with 2,324 transparent pixels (the Museum's count), so hit-testing and docking at the cut-outs matter. The zip has a nested folder, a stray DLL, a TTF and `Posbar2.bmp`, which exercises the archive walker. |
| `base` | S190947 | `76f97817eeaa4dcae165c1162c7c5abd` | Missing sprites: 20 KB, main-window sheets only, no `eqmain.bmp`, no `pledit.bmp`, no `pledit.txt`, no readme, plus `region.txt`. The EQ and playlist windows come entirely from `GeneratedBaseSkin` and the Webamp fallbacks. |
| `Windows_Classic` | S210427 | `15bd4305c66d69b6d2ef39a3d92ff352` | Unusual playlist colours: white `NormalBG`, orange text, yellow `SelectedBG`, `Font=times new roman`; the zip carries the same files twice in different letter cases (`PLEDIT.TXT` and `pledit.txt`), a case-folding trap. |
| `Pika_Amp` | S152414 | `061589029dde4c811f5c8013aae603d7` | Small region (78 px), `Font=Tempus Sans ITC` which macOS doesn't have (font fallback in the rows), no cursors, no GEN/VIDEO sheets. |
| `Windows_98_Amp` | S140245 | `09309bea91c2634f5f8935a919862e46` | Shade-heavy: the complete set of windowshade cursors (`WS*.CUR`, `PWS*.CUR`), `nums_ex.bmp` only (no `numbers.bmp`), all names in mixed case. The shade-mode tests run on it. |
| `internet-archive-winamp-skin-by-luigihann` | S149125 | `f86f47ed539e393678f805fe776e4d30` | A modern-era classic skin with `nums_ex.bmp` only, GEN and VIDEO sheets and a dark playlist; already known to render in Roadie (it is in the local sample set), so it anchors the smoke suite against a skin that must keep working. |

Seven skins, about 850 KB in total. Per-skin smoke runs once per milestone (`SkinSmokeUITests`: launch, three windows present, shade on and off for each, five playlist rows readable, screenshot attached always). All the other UI tests run on `base-2.91` only.

## 5. Feature inventory

Everything a user can do, and the test that proves it. **UI** names a class in `RoadieUITests` (filtered per issue with `--ui-filter`); **Unit** names a test target. Rows marked *by hand* can't be automated in the headless guest and stay in the plan's by-hand list. New features add a row here (Issues.md, "Filing a new issue").

### 5.1 Menu bar

| Feature | Test |
|---|---|
| Roadie › About, Settings… (⌘,), Quit (⌘Q; stops a Music Assistant target first, #0121) | UI `MenuBarUITests` (about panel appears; Settings opens; quit stop: `QuitStopTests` unit) |
| Check for Updates… (Sparkle; disabled in Debug) | UI `MenuBarUITests.checkForUpdatesIsDisabledInDebug`; release-side `check-sparkle.sh` |
| File › Open… ⌘O, Add to Playlist… ⌥⌘O, Open Skin… ⇧⌘O, Load Playlist…, Save Playlist… ⌘S | UI `MenuBarUITests` (item exists and enabled); the panel path through `-RoadieOpenFiles` in `PlaylistUITests.openFilesReplacesTheQueue`; Unit `RoadieTests.PlayerModelFilesTests` (M3U/PLS round trip via `PlaylistFileTests`) |
| Skins › Skin Library… ⌘K, Next ⌘], Previous ⌘[, Random ⇧⌘R | UI `SkinsUITests` |
| Playback › Library ⌘L (opens on the search field, #0185) | UI `LibraryUITests.commandLOpensTheLibraryWithSearchFocused` |
| Playback › Previous/Play/Pause/Stop/Next ⌃⌘Z X C V B | UI `MainWindowUITests.menuBarTransport` |
| Playback › Jump to File… ⌘J | UI `JumpToFileUITests` |
| Playback › Seek ±5 s ⌃⌘←/→, Volume ⌃⌘↑/↓ | UI `MainWindowUITests.seekAndVolumeShortcuts` |
| Playback › Shuffle ⌃⌘S, Repeat ⌃⌘R (check marks) | UI `MainWindowUITests.shuffleRepeatToggles` |
| Playback › Save Queue as Playlist…, Load Playlist from Library… (#0190) | UI `MusicAssistantUITests.saveQueueAsPlaylist`, `.loadPlaylistFromLibraryMenuItem`; Unit `QueueSaveTargetTests` |
| Playback › Favorite Current Track ⌃⌘L | UI `MusicAssistantUITests.favoriteCurrentTrack`; Unit `BackendFavoritesTests` |
| Playlist › Add File… / Add Folder… / Add URL…, Remove Selected, Crop, Clear Playlist, Select All / None / Invert, Sort by Title / File Name / Path ⌥⌘1–3, Reverse List, Randomize List, File Info…, Generate HTML Playlist, Load Playlist… ⌥⌘L, Save Playlist… ⌥⌘S; enabled as the shown queue allows (#0226) | UI `PlaylistUITests.testPlaylistMenuBarHasEveryCommand`, `.testPlaylistMenuBarEditsTheQueue`, `.testPlaylistMenuBarLoadsAndSaves`; Unit SkinKit `PlaylistMenuTests`, `RoadieTests.PlaylistCommandTests`, `.PlaylistMenuBuilderTests` |
| Window › Library, Player ⌘1, Windowshade ⌃⌘W, Equalizer ⌘2, EQ Windowshade ⌃⌘E, Playlist Windowshade ⌃⌘P, Playlist Editor ⌘3, Always on Top, Double Size | UI `MainWindowUITests.windowMenu` |
| Help › Welcome to Roadie…, Playlists and the Queue… (opens the help URL) | UI `FirstLaunchUITests.helpMenu` (URL recorded by `-RoadieExternalOpens record`) |

### 5.2 Skinned pop-up menu (main window)

| Feature | Test |
|---|---|
| Opens from the title-bar button and right-click | UI `MainWindowUITests.popUpMenuOpens` |
| About Roadie, Check for Updates… (enabled state) | UI `MainWindowUITests.popUpMenuItems`; Unit `RoadieTests.MainMenuBuilderTests` |
| Play File…, Add to Playlist… | Unit `MainMenuBuilderTests` (dispatch to `openFiles(replace:)`) |
| Equalizer / Playlist Editor / Media Library with check marks | UI `MainWindowUITests.popUpTogglesWindows` |
| Skins ▸ Open Skin…, Next, Previous, Random (enabled with an index) | UI `SkinsUITests.popUpSkinsSubmenu` |
| Options ▸ Time Elapsed / Remaining, Always On Top, Double Size, Windowshade ×3, Repeat, Shuffle | UI `MainWindowUITests.optionsSubmenu`; Unit `MainMenuTests` (SkinKit) |
| Playback ▸ transport, Jump to File… | UI `MainWindowUITests.playbackSubmenu` |
| Exit | Unit `MainMenuBuilderTests.exitTerminates` (dispatch only) |
| Every pop-up shortcut matches the menu bar | Unit `MainMenuTests.shortcutsMatchMenuBar` (exists) |

### 5.3 Main window

| Feature | Test |
|---|---|
| Transport buttons (previous, play, pause, stop, next, eject = open files) | UI `MainWindowUITests.transportButtons` (folder library); `MusicAssistantUITests.transportOnSpeaker` (stub receives `players/cmd/*`) |
| Position slider: scrub and seek; time display elapsed/remaining (click toggles) | UI `MainWindowUITests.seekAndTimeMode`; Unit `MainWindowStatusTests`, `MiniTimeTests` (exist) |
| Volume and balance sliders, marquee shows the value while dragging | UI `MainWindowUITests.volumeAndBalance`; Unit `MainSlidersTests` (exists) |
| Shuffle, repeat toggles | UI `MainWindowUITests.shuffleRepeatToggles`; Unit `PlayQueueTests` |
| EQ and PL toggle buttons open/close the windows | UI `MainWindowUITests.eqAndPlaylistToggles` |
| Marquee: title scroll, `N. Artist - Title (m:ss)`, notices | UI `MainWindowUITests.marqueeShowsTheTrack`; Unit `MarqueeTextTests`, `StatusNoticeTests` (exist) |
| kbps / kHz / mono-stereo indicators | UI `MainWindowUITests.formatIndicators` (fixture formats differ per file) |
| Visualizer (spectrum / oscilloscope / off via the clutter bar `V` menu) | UI `MainWindowUITests.visualizerMenu`; Unit `VisBarsTests`, `VisRendererTests` (exist) |
| Clutter bar: O (options menu), A (always on top), I (file info), D (double size) | UI `MainWindowUITests.clutterBar`; Unit `ClutterBarLayoutTests` (exists) |
| Title bar: menu, minimize, shade, close; double-click title shades | UI `MainWindowUITests.titleBar` |
| Shade mode: transport, position, time, marquee | UI `MainWindowUITests.shadeMode`, `SkinSmokeUITests` |
| Always on top, double size (persist across launches) | UI `MainWindowUITests.alwaysOnTopAndDoubleSize`; Unit `RoadieTests.WindowLayoutTests` |
| Window drag, docking, snapping, group raise; layout restored at launch | UI `MainWindowUITests.dragDocksTheEqualizer`; Unit `WindowDockingTests` (exist), `RoadieTests.WindowLayoutTests` |
| Drop audio files / folders / a `.wsz` on the window | Unit `RoadieTests.DropDecoderTests`, `PlayerModelSkinTests`; `open -a` path in `PlaylistUITests.openFilesReplacesTheQueue` |
| Bare hotkeys Z X C V B, arrows, S R L J while a skinned window is key | UI `MainWindowUITests.bareHotkeys`; Unit `WinampHotkeysTests` (exists) |
| "No Skin Loaded" placeholder with Browse Museum / Open Skin | UI `SkinsUITests.noSkinPlaceholder` |
| Playback failure notice (missing file) | UI `PlaylistUITests.missingFileShowsANotice`; Unit `PlaybackFailureTests` (exists) |

### 5.4 Equalizer window

| Feature | Test |
|---|---|
| On/off, auto (no-op), preamp, 10 bands, +12/0/−12 labels set all bands | UI `EqualizerUITests.bandsAndToggles`; Unit `EQTests`, `EQLayoutTests` (exist) |
| Presets menu: built-ins, From EQF…, Save… | UI `EqualizerUITests.presetsMenu` (built-ins apply); Unit `EQFFileTests` (exists) for the files |
| EQ graph follows the bands | UI `EqualizerUITests.graphValue` (accessibility value is the band list); Unit `EQGraphTests` (exists) |
| Shade mode, close, docking under the main window | UI `EqualizerUITests.shadeAndClose` |
| EQ state persists across launches | Unit `RoadieTests.PlayerModelPersistenceTests` |

### 5.5 Playlist editor

| Feature | Test |
|---|---|
| Rows: number, `Artist - Title`, `[n]` marker, duration; current row colour | UI `PlaylistUITests.rowsShowTheQueue`; Unit `PlaylistTextTests`, `QueueRowsTests` (exist), `RoadieTests.PlaylistModelTests.rows` |
| Click / ⌘-click / ⇧-click / ⌘A selection | UI `PlaylistUITests.selection`; Unit `PlaylistSelectionTests` (exists) |
| **Double-click plays that row; Return plays the first selected (local queue)** | UI `PlaylistUITests.doubleClickPlaysThatRow`; Unit `RoadieTests.PlaylistModelTests.playRowLocalSelectsTheRow` |
| **Double-click plays that row on a Music Assistant queue (#0187)** | UI `MusicAssistantUITests.doubleClickRowSendsItsPosition` (probe: `play_index index=3`); Unit `BackendQueueTests.queueRowsUsePositionWhenTheServerSendsIndexZero` (exists), `RoadieTests.PlaylistModelTests.playRowRemoteSendsTheRowNumber` |
| Delete removes selected; REM › crop / all | UI `PlaylistUITests.removeCropClear`; Unit `PlayQueueTests` |
| Drag rows to reorder | UI `PlaylistUITests.dragReordersRows` |
| Scroll wheel, scrollbar, arrow buttons; resize corner; shade mode | UI `PlaylistUITests.scrollResizeShade`; Unit `PlaylistScrollTests`, `PlaylistLayoutTests` (exist) |
| ADD › file / dir / URL (panels: unit; URL sheet: UI) | UI `PlaylistUITests.addURL` (folder library: Add URL adds nothing, the URL sheet needs a radio source, #0147), `.scrollResizeShade` (ADD › dir via `-RoadieAddFolder`); Unit `RoadieTests.PlayerModelFilesTests` |
| SEL › invert / zero / all | UI `PlaylistUITests.selectMenu` |
| MISC › file info, sort (Sort by Title / File Name / Path and File Name, Reverse List, Randomize List; titles shared with the Playlist menu, #0226), options › Generate HTML Playlist | UI `PlaylistUITests.sortMenu` (entries picked by keyboard: the sort pop-up isn't in the accessibility tree, #0230), `.fileInfoPanel`; Unit `PlaylistSortKeyTests`, `PlaylistHTMLTests` (exist) |
| LIST › new, save (M3U/PLS or a server playlist), load (file / Library playlist, #0190) | UI `PlaylistUITests.listMenuLocal` (save via `-RoadieSaveTo`, load via `-RoadieLoadList`), `MusicAssistantUITests.listLoadOffersLibraryPlaylist`; Unit `QueueSaveTargetTests` (exists) |
| ADD / REM / SEL / MISC / LIST tooltips name the button and its entries (#0227) | UI `PlaylistUITests.testMenuButtonsHaveTooltips` (one hover: a help tag appears beside ADD; its text isn't readable in the guest); Unit `RoadieTests.PlaylistTooltipTests` (the five strings), SkinKit `PlaylistLayoutTests.entrySpritesMatchMenuEntries`; *by hand* for the visible text, double size, resize and docking |
| Bottom transport buttons, running time, mini time | UI `PlaylistUITests.bottomBar` |
| Right-click row menu: Play, Queue/Dequeue, Clear Queue, Remove, File Info… | UI `PlaylistUITests.rowMenu`; Unit `RoadieTests.PlaylistMenusTests` |
| `Q` queues the selection, `[n]` markers, playback order honours up-next | UI `PlaylistUITests.queueMarkers` (unshuffled, the list carries on after the queued row that played); Unit `UpNextTests`, `RemoteUpNextTests` (exist) |
| Finder files dropped at a row (inserted there), on the bottom bar (appended) | Unit `RoadieTests.DropDecoderTests`, `FolderBackendTests.playInsert…` (exist); *by hand* for the real Finder drag |
| **Library rows dropped at a row / bottom bar (#0188)** | UI `LibraryUITests.dragAlbumOntoPlaylistRow`, `.dragTrackOntoBottomBar`, `.dragArtistOntoPlaylist`; Unit `RoadieTests.DropDecoderTests.readsEveryPasteboardItem` |
| Remote queue: edits go to the server, refusals show "Not for Music Assistant queues" | UI `MusicAssistantUITests.sortIsRefusedOnARemoteQueue`; Unit `QueueEditPlanTests`, `BackendQueueTests` (exist) |
| Queue restored at launch (stopped on the saved track) | UI `PlaylistUITests.queueSurvivesRelaunch`; Unit `QueueAutosaverTests`, `QueueSnapshotTests` (exist) |

### 5.6 Jump to File

| Feature | Test |
|---|---|
| `J` and ⌘J open the panel over the playlist's rows | UI `JumpToFileUITests.opensWithJAndCommandJ` |
| Typing filters (artist, title, file name words) | UI `JumpToFileUITests.typingFilters`; Unit `JumpToFileMatcherTests` (exists) |
| **Return / double-click plays the chosen row (local and Music Assistant, #0187)** | UI `JumpToFileUITests.returnPlaysTheChosenRow`, `MusicAssistantUITests.jumpToFilePlaysTheChosenRow`; Unit `RoadieTests.JumpToFileControllerTests` |
| Queue button adds `[n]`; Esc closes | UI `JumpToFileUITests.queueButtonAndEscape` |
| Empty playlist: the panel points at the Library (#0190) | UI `JumpToFileUITests.emptyStateMentionsTheLibrary` |

### 5.7 Library window

| Feature | Test |
|---|---|
| Opens from ⌘L / Playback / Window / the pop-up's Media Library, search focused | UI `LibraryUITests.commandLOpensTheLibraryWithSearchFocused` |
| Sidebar: Artists, Albums, Playlists (Music Assistant only), Discover rows, Favorites, Radio | UI `LibraryUITests.sidebarSections` (folder), `MusicAssistantUITests.sidebarSections` |
| Artists → albums → tracks; album art; paging | UI `LibraryUITests.browseArtistAlbumTracks`; Unit `LibraryBrowserModelTests`, `PagedListTests` (exist) |
| Search (debounced, sections) | UI `LibraryUITests.search`; Unit `LibraryBrowserModelTests.search…` |
| Double-click album / track / playlist plays | UI `LibraryUITests.doubleClickAlbumPlays`, `MusicAssistantUITests.doubleClickPlaylistPlays` (#0189) |
| Context menus: Play, Play Next, Add to Queue, Add to Playlist ▸, Favorite; artist and playlist containers (#0188, #0189) | UI `LibraryUITests.contextMenus`, `MusicAssistantUITests.playlistRowMenu`; Unit `PlayRequestTests`, `AddToPlaylistMenuTests` (exist) |
| Drag album / track / artist / playlist to the playlist editor | UI `LibraryUITests.dragAlbumOntoPlaylistRow`…, `MusicAssistantUITests.dragPlaylistAppendsToQueue` |
| Drag tracks/albums onto a playlist row (adds to that playlist) | UI `MusicAssistantUITests.dropOntoPlaylistAdds`; Unit `PlaylistEditorTests` (exist) |
| Toolbar: New Playlist, Import Playlist…, Refresh, Add Radio URL…, output picker | UI `MusicAssistantUITests.toolbar`, `LibraryUITests.addRadioURL` |
| Playlists: create, rename, delete (confirmation), export/import, reorder tracks, remove track, edit bar errors | UI `MusicAssistantUITests.playlistCRUD`, `PlaylistGroupsUITests.testCreatedPlaylistIsUnderMyPlaylists` (exists, #0221); Unit `PlaylistsModelTests`, `PlaylistMappingTests`, `PlaylistWriteTests`, `PlaylistEditorTests` (exist) |
| Favorites section, favorite button and menu | UI `MusicAssistantUITests.favorites`; Unit `FavoritesModelTests` (exists) |
| Discover rows, Play All, Refresh, Show all rows | UI `MusicAssistantUITests.discover`; Unit `DiscoverTests`, `RecommendationDecodingTests` (exist) |
| Radio list, play a station | UI `MusicAssistantUITests.radio`; Unit `RadioTests`, `RadioSectionTests` (exist) |
| Status view: connecting, failed with Open Settings… / Retry | UI `LibraryUITests.unreachableSourceShowsRetry` (scenario `unreachable`); Unit `LibraryFallbackControllerTests` (exists) |
| Output picker: This Mac, speakers, groups, toggle members, Only, leader | UI `MusicAssistantUITests.outputPicker`; Unit `OutputPickerModelTests`, `OutputSelectionTests` (exist) |
| Library source fallback to the folder when Music Assistant fails, with notice | UI `LibraryUITests.fallbackToFolderNotice`; Unit `LibraryFallbackPolicyTests` (exists) |

### 5.8 Skins window and Skin Museum

| Feature | Test |
|---|---|
| Skin Library grid from the skins folder: thumbnails, status filter, count label, Random, Refresh, click applies, trash | UI `SkinsUITests.libraryGrid`; Unit `SkinBrowserModelTests`, `SkinTrashTests` (exist) |
| Next / Previous / Random skin from the menu bar and pop-up | UI `SkinsUITests.nextPreviousRandom`; Unit `SkinBrowserModelTests` (incl. a skin loaded before its row was indexed) |
| Open Skin… / Finder `.wsz` open / drop | Unit `RoadieTests.PlayerModelSkinTests`; UI `SkinsUITests.openWszViaOpenCommand` (`open -a`) |
| Museum tab: search, grid, Download, Apply, Retry, Open in Skin Museum, Show in Finder, Move to Trash | UI `SkinsUITests.museumTab` (stub transport, fixtures); Unit `MuseumBrowserModelTests`, `MuseumClientTests`, `MuseumDownloaderTests` (exist) |
| NSFW setting hides flagged skins | UI `SkinsUITests.nsfwToggle`; Unit `MuseumBrowserModelTests` |
| Browse the Museum from the no-skin placeholder and the Welcome window | UI `SkinsUITests.noSkinPlaceholder`, `FirstLaunchUITests.welcomeOpensMuseum` |
| Settings › Skins: folder, counts, Scan / Rescan / Cancel, Reset Index | UI `SkinsUITests.settingsSkinsTab`; Unit `RoadieTests.SkinLibraryModelTests` |
| Every manifest skin renders all three windows and both shade modes | UI `SkinSmokeUITests.smokeEverySkin` (`--ui-skins all`, milestone; base skin otherwise) |

### 5.9 Settings, first launch, updates

| Feature | Test |
|---|---|
| Welcome window on a fresh install: Skins (Browse Museum / Choose Folder / Open Skin), Music Folder (Choose / Open Library), Music Assistant (Set Up…), Continue marks `firstRunVersion` | UI `FirstLaunchUITests.welcomeOnFreshDefaults`; Unit `FirstRunPolicyTests` (exists), `RoadieTests.FirstRunStateTests` |
| Existing user: no Welcome, version recorded | UI `FirstLaunchUITests.existingUserSkipsWelcome` |
| Settings › Library: source picker (Music Assistant / folder), status and Retry Now, folder Choose/Clear, index status, Reindex | UI `SettingsUITests.libraryTab`; Unit `FolderSettingsModelTests`, `LibrarySourceControllerTests` (exist) |
| Settings › Music Assistant: servers add/remove, name, address, token, Remove Token, Test Connection / Cancel, Check Now, Replace With This Server…, Play on this Mac, Stop when quitting, Wi-Fi networks, Find Servers | UI `SettingsUITests.musicAssistantTab` (scripted server answers the test); Unit `SettingsModelTests`, `ServerStoreTests`, `DiscoveryTests`, `AddressInputTests` (exist) |
| Settings › Updates: toggles, Check Now, last check, "off in development builds" | UI `SettingsUITests.updatesTab` (Debug: controls disabled) |
| Sparkle appcast, EdDSA, feed URL in Release | `app-sparkle`, `app-release-plist` steps and `scripts/verify-dmg.sh` (exist); *by hand*: the update prompt on a real install |

### 5.10 Music Assistant flows

| Feature | Test |
|---|---|
| Connect at launch when a verified server exists; reconnect; server re-pick on failure | UI `MusicAssistantUITests.connectsAtLaunch`; Unit `ClientConnectionTests`, `SelectionControllerTests` (exist) |
| Browse the server's library (all sections) | UI `MusicAssistantUITests.sidebarSections` |
| Play on This Mac (Sendspin feed) and on a speaker; the playlist editor shows the server queue | UI `MusicAssistantUITests.playAlbumShowsRemoteQueue`; Unit `MusicAssistantThisMacTests`, `SendspinPlayerTests` (exist) |
| Transport and volume on a speaker; balance refused quietly | UI `MusicAssistantUITests.transportOnSpeaker`; Unit `BackendTransportTests` (exists) |
| Queue edits: play row, remove, move, queue (`Q` moves after current), clear | UI `MusicAssistantUITests.queueEdits`; Unit `BackendQueueTests`, `QueueEditPlanTests` (exist) |
| Save queue as a server playlist; load a server playlist from LIST › Load and the Playback menu | UI `MusicAssistantUITests.saveQueueAsPlaylist`, `.listLoadOffersLibraryPlaylist`; Unit `BackendSaveQueueTests` (exists) |
| Output selection, groups, moving playback between outputs | UI `MusicAssistantUITests.outputPicker`; Unit `OutputMoveTests`, `PlaybackOwnershipTests` (exist) |
| Now playing follows the server (title, position, artwork) | UI `MusicAssistantUITests.nowPlayingFollowsTheServer` (event push); Unit `NowPlayingMappingTests`, `BackendNowPlayingTests` (exist) |
| Fallback to the folder library when the server is unreachable | UI `LibraryUITests.fallbackToFolderNotice` |
| Quit stops the Music Assistant target | Unit `QuitStopTests` (exists); UI `MusicAssistantUITests.quitSendsStop` (probe after ⌘Q) |
| Bonjour discovery, Wi-Fi network preference | Unit `DiscoveryTests`, `ServerRankingTests` (exist); *by hand* on a real network |

### 5.11 System integration

| Feature | Test |
|---|---|
| Quick Look thumbnail and preview for `.wsz` | `app-quicklook` step (exists) |
| Now Playing / media keys | Unit `NowPlayingTests` (full tier); *by hand* |
| Dock reopen shows the windows | UI `MainWindowUITests.reopenShowsWindows` (`open -a` while running) |
| Legacy data cleanup | Unit `RoadieTests.LegacyDataCleanupTests` |
| Info.plist, entitlements, bundle identifiers, website, changelog | existing steps |

## 6. Runner and logging

The Haiku runner (Issues.md phase 2v) doesn't change: it runs one `scripts/verify.sh …` command and returns the stdout verbatim. UI runs can exceed the 600 s foreground timeout, so a `--ui` or `--coverage` command runs in the background and the runner waits for its completion notification, as `--stress` and `--corpus` already do. Everything else is in `verify.sh` and `run-tests-vm.sh`:

**On a pass** (unchanged shape, two new lines):

```
==> VERIFY  PASS (exit 0) 20261101-101500-12345: 15 steps passed, 1810 tests in 15 test runs
==> TIER  fast: 100k scale and real-time audio tests skipped (scripts/run-tests-vm.sh --full runs them)
==> UI  12 tests passed (PlaylistUITests, JumpToFileUITests) on base-2.91
==> AUDIO  silent: no host 'Starting IO' events during the run
==> EXPECT  all 3 expected test(s) passed
==> COVERAGE  SkinKit 88%  PlayerKit 86%  App 63%        (only with --coverage)
```

**On a failure**: the `FAIL`/`BUILD`/`ERRORS`/`INFRA`/`AUDIO` lines, compiler errors as `file:line:col`, then per failed test step the failing tests. For `app-unit-tests` and `ui-tests` (XCTest format) that is the `Test Case '-[Class test]' failed` line, each `file:line: error: -[Class test] : <assertion message>` line, and for UI tests the screenshot paths:

```
==> ui-tests failures:
    Test Case '-[RoadieUITests.PlaylistUITests testDoubleClickPlaysThatRow]' failed (6.102 seconds).
    PlaylistUITests.swift:48: error: -[RoadieUITests.PlaylistUITests testDoubleClickPlaysThatRow] : XCTAssertTrue failed - row 3 should be current; probe: currentIndex=0
    screenshots: build/vm-tests/20261101-101500-12345/ui/attachments/testDoubleClickPlaysThatRow/
    xcresult: build/vm-tests/20261101-101500-12345/ui/UITests.xcresult
```

Still capped at 60 lines with the full text in `failure.txt`; never a log. Warnings are not collected on a pass; on a failure, `verify.sh` adds the `warning:` lines from the failing step's log only when they mention a file the failing test's assertion names (so a deprecation warning in an unrelated file stays out).

**Script changes** (#0193, #0200, #0201, #0212):

| Change | Where |
|---|---|
| `app-build` becomes `xcodebuild build-for-testing`; new step `app-unit-tests` (`test-without-building -only-testing:RoadieTests`) after `playerkit-tests` | `run-tests-vm.sh` |
| `--ui`, `--ui-filter Class[,Class]`, `--ui-skins base\|all`: steps `ui-build` (build stage) and `ui-tests`; copies the test skins cache into the export; sets the guest display; brings `ui/UITests.xcresult` back and exports summary and attachments on the host | `run-tests-vm.sh` |
| `--expect-fail NAMES`: the run passes only if those tests ran and **failed** (the regression-test-first proof, §7) | `verify.sh` |
| XCTest failure extraction (`Test Case … failed`, `: error:` lines), screenshot and xcresult paths, `UI` summary line, warnings filter | `verify.sh` |
| `--coverage`: coverage flags on every test step, `coverage-report` step, `COVERAGE` line, floors | `run-tests-vm.sh`, `scripts/coverage-report.sh`, `verify.sh` |
| `make-test-library.sh`, `make-test-audio.sh`, `fetch-test-skins.sh`, `check-fixtures.sh` | new scripts; `check-fixtures` joins the fast tier's checks |

## 7. Process changes

**In force since #0213 (2026-10-24)**: the rules below are in `issues/Issues.md`, `AGENTS.md` and `docs/issues-workflow.md`.

In `issues/Issues.md` (#0213):

1. **Fast tests pass before review.** Already the rule; it becomes explicit that `app-unit-tests` is part of the fast tier, and that `DONE` without a quoted `VERIFY PASS` of a complete fast run (plus the UI classes the plan names) is a bail, not a hand-off. The reviewer re-runs the same command with `--head`.
2. **Every bug fix adds a regression test that fails before the fix.** The plan's `## Tests` names it. The implementer writes the test first and asks for `VERIFY: scripts/verify.sh --expect-fail <test>` before touching the fix; `verify.sh` exits 0 only if the test ran and failed. That run and the later passing run are both quoted in `## Verification`. One extra VM run per bug, on the Haiku runner.
3. **Every user-facing feature adds or updates a UI test**, and its row in §5 of this document. The plan has a `## UI tests` section naming the class and test; `## Which tier` gains the value `ui` with the `--ui-filter` classes to run. Issues whose change is only in packages, scripts or docs say `## UI tests: none (no UI change)`.
4. **Milestone end** runs `scripts/verify.sh --head --full --ui --ui-skins all --coverage` and records the `PASS`/`FAIL`, `TIER`, `UI` and `COVERAGE` lines in the umbrella's `## Notes`. A coverage floor failure files a backfill issue under the milestone, like any other failure.
5. **Resolution notes cite the tests** by name (`## Resolution notes` and `## Verification` list the `--expect` tests and the UI classes that ran), so a later reader can find the proof.
6. The Haiku runner section says UI and coverage runs go in the background.

In `AGENTS.md`: a **Tests** section: builds and tests only in the VM through the runner; XCUITest never on the host; `scripts/fetch-test-skins.sh` and `scripts/record-ma-fixtures.py` are host-only, read-only, and `.env` never enters the VM or a fixture; the regression-test-first rule in one line.

In `docs/testing-in-vm.md`: the "UI tests (not built yet)" section is replaced with the real steps, flags and prerequisites; the tier table in `docs/issues-workflow.md` gains the UI row.

## 8. Risks and open questions

- **XCUITest in the Tart guest.** The golden image bakes in admin auto-login, "Automation Mode without authentication" and developer mode (testing-in-vm.md), which is what Changeover's UI tests needed. Still unproven for Roadie: the first `--ui` run (#0200's smoke test) is the gate; if a TCC prompt blocks it, the fix is in the golden image (`tart-golden stage/validate/promote`), not in Roadie. A blocked prompt shows as a timeout, so `ui-tests` gets a 20 min step timeout and `verify.sh` reports it as `FAIL ui-tests (timeout)`.
- **Headless display.** `--no-graphics` still gives the guest a WindowServer and a display; `make-screenshots.sh` already captures windows that way. The display is set to 2560×1300 so nothing overlaps; if `XCUIElement.click()` misses because a window is off screen, the test fails with a screenshot that shows it.
- **Audio in test mode.** v1 plays through the guest's muted virtual device (no path to the host, `--no-audio`), as `make-screenshots.sh` does, so time advances and the visualizer moves. If the virtual device turns out to stall or to vary between boots, `RoadieConfiguration.silentOutput` switches the engine to manual rendering driven by a timer; that is the reserved field, not built in M16 unless needed.
- **Flakiness budget.** A UI test may be retried once by `xcodebuild -retry-tests-on-failure -test-iterations 2`; a test that needs the retry twice in a milestone is filed as a flaky-test issue under the tooling milestone and marked `XCTSkip` until fixed, never left to fail intermittently. Target: zero retries needed in the per-issue runs over a milestone.
- **Run time.** Fast tier ≤ 4 min, per-issue `--ui` ≤ 8 min total, milestone ≤ 35 min. Measured in #0200 and #0212 and recorded in their notes; if the fast tier passes 4 min, the app bundle's slower tests move behind `ROADIE_SLOW_TESTS`.
- **Drag and drop fidelity.** `press(forDuration:thenDragTo:)` drives SwiftUI `.draggable` sources in the same app; whether the AppKit destination sees the SwiftUI pasteboard is exactly what #0188 could not confirm, so `LibraryUITests.dragAlbumOntoPlaylistRow` is also the answer to that open question. If XCUITest can't produce the drag, the fallback is a unit test that performs the drop with a constructed `NSDraggingInfo` through `LibraryDropDecoder`, and the drag itself stays by hand.
- **Recorded queue fixtures need the user.** `--record-queue` must run on the host against the user's server with a queue loaded. Until then `queueLoaded` is synthetic with `index: 0` applied on purpose. Nothing blocks on it.
- **MP3 encoder.** `lame` isn't on stock macOS; the generator uses it if installed (`brew install lame`) and otherwise says so. The files are committed, so this is a one-time host step.
- **Hosted unit tests start the app.** `RoadieTests` runs inside Roadie.app; the `XCTestConfigurationFilePath` guard keeps `AppDelegate` from opening windows. If a test needs a window it creates one and never orders it in. The headless guest tolerates ordered-in windows anyway.
- **Winamp artwork in the cache.** `base-2.91` is Nullsoft's own base skin. It is fetched into a local cache for tests and never committed or published, which is the same rule as every other Museum skin (docs/winamp-skin-museum-access.md). The website's screenshots keep their own trademark rules (`make-screenshots.sh`).
- **Open question for the user:** should the per-issue UI run be mandatory for every `App/` change (even a one-line view fix), or only when the plan says so? The design says "the plan says so", with the reviewer able to bounce an issue whose plan skipped it.
