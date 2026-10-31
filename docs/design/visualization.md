# Visualization (MilkDrop)

Design for [#0231](../../issues/0231.md), milestone M18: a separate, resizable visualization window that goes full
screen, shows the song over the picture until the mouse goes idle, changes presets from the arrow keys and on its
own, and otherwise behaves the way Winamp's MilkDrop did. Written 2026-10-29 against Roadie at `863e2e8` and
MilkDropMetalKit at `ce8d9c1` plus its uncommitted 1.0 review (`docs/api-1.0.md`, read only). Section 10 turns this
into child issues #0232–#0243.

The user, 2026-10-29:

> Winamp had really great visualizations. We are working on recreating them with Swift and Metal in
> ../MilkDropMetalKit right now. Plan out how Roadie will support visualizations. What I want for full screen mode
> to show the song and artist and playback details but when the mouse cursor has been idle it should disappear and
> just show the visualization. The arrow keys should move between visualizations. Make sure to replicate the classic
> Winamp behavior beyond that. Once the plan is done break it down into issues in a milestone and start working on it.

And earlier: "We will use MilkDropMetalKit once it is ready." The package isn't 1.0 yet, so everything Roadie owns
(window, full screen, overlay, keys, presets, settings, audio feed, accessibility) is built and tested now behind a
small Roadie-owned renderer seam (§3.2), drawn by a Core Graphics **classic visualizer** that needs no Metal. One
late issue (#0243), blocked on the package's `1.0.0` tag, adds the package and the MilkDrop renderer behind that seam.

Non-goals: editing or saving presets (MilkDrop's M and S), preset ratings, desktop mode, AVS, a skinned (`gen.bmp`)
frame around the window, hard cuts on beats (§1, deferred), sprites and custom messages, MilkDrop's own config
dialog, iOS.

The behaviour notes on Winamp 2.x/5.x and MilkDrop 1.x/2.x below are from memory of those programs (their help
screens, `milkdrop.ini` defaults and menus), not from their source: the 2024 Winamp source release is under a
non-free licence and is not to be read for this (handoff §3). Where a number matters (default times) the plans use
it as a default the user can change, and the design says so.

---

## 1. Winamp and MilkDrop behaviour inventory

**Kept** means Roadie does what Winamp/MilkDrop did, with the Mac's modifier in place of Ctrl/Alt. **Adapted**
means the same intent, done the Mac way or changed for a reason given. **Dropped** means not in M18.

### 1.1 Opening the visualization from the player (Winamp)

| Winamp | Roadie | | Why |
|---|---|---|---|
| Ctrl+Shift+K: start/stop the visualization plug-in | **⇧⌘K**: Window › Visualization (a check item; opens or closes the window) | Kept | Same letter and modifiers, ⌘ for Ctrl. Free in Roadie today |
| Ctrl+K: Preferences › Visualization (pick a plug-in) | **⌥⌘K**: Window › Visualization Settings… opens Settings › Visualization | Adapted | ⌘K is Roadie's Skin Library (#0115-era choice), so Ctrl+K can't map to ⌘K. There is one visualizer, so "select plug-in" becomes its settings |
| Alt+K: configure plug-in (MilkDrop's config dialog) | Folded into Settings › Visualization (§2.9) | Adapted | One settings pane instead of two dialogs |
| Main menu (title-bar button / right-click) › Visualization ▸ Preferences, Plug-in options, Start/Stop plug-in | Skinned main menu gains **Visualization ▸** Start/Stop Visualization ⇧⌘K, Visualization Settings… ⌥⌘K | Kept | Same place; shortcuts match the menu bar (`MainMenuTests.shortcutsMatchMenuBar`) |
| Clutter bar **V**: the visualization menu | Roadie's V menu (Spectrum / Oscilloscope / Off) gains a separator, Start/Stop Visualization, Visualization Settings… | Kept | It was Winamp's way in |
| Left-click the built-in vis: cycle spectrum → scope → off | Unchanged (`VisualizerView`) | Kept | Already there |
| Right-click the built-in vis: the visualization menu | Right-click on `main.visualizer` pops the V menu instead of the main menu | Kept | Winamp did; today it pops the main menu |
| Prefs › Visualization: "Auto execute visualization plug-in on play" | Setting **Open the visualization when playback starts** (default off) | Kept | Cheap, and it's how many people ran MilkDrop |
| The plug-in's window docked to Winamp's (Winamp 5: inside a `gen.bmp` frame) | A native, resizable, titled window; not docked; frame remembered | Adapted | Roadie's other native windows (Library, Skins) don't dock; a skinned frame is a later option (handoff §8) |
| The vis runs only while its window is open; closing it stops the plug-in | Same: closing the window stops rendering and the stereo feed | Kept | Energy |
| The open plug-in restarted with Winamp if it was running at exit | The window reopens at launch if it was open at quit (windowed, never full screen) | Kept | Like the EQ and playlist windows' open state |

### 1.2 Windowed and full screen (MilkDrop)

| MilkDrop | Roadie | | Why |
|---|---|---|---|
| Alt+Enter: toggle full screen | **⌥Return** in the vis window | Kept | ⌥ for Alt |
| Double-click the window: toggle full screen | Same | Kept | |
| — | **⌃⌘F** / View-style "Enter Full Screen" from the window's green button and the Window menu | Added | The Mac's standard; free with `.fullScreenPrimary` |
| Escape: leave full screen (and close the help screen / menus first) | Same order: Esc closes the help, then the preset browser, then leaves full screen; windowed, it does nothing | Kept | |
| Full screen on a chosen monitor (config) | Native full screen on the screen the window is on; move the window first to pick | Adapted | Native Spaces; no device picker |
| "Fake full screen" (a borderless topmost window) | Not offered; native full screen only (it works in the guest, #0237; the unused Debug borderless hook was removed, #0245) | Dropped | Native is what Mac users expect |
| The cursor hidden in full screen | The cursor hides **with the overlay** after the idle timeout, in full screen and windowed (pointer inside the view only), and comes back on movement | Adapted | The user's request |
| Desktop mode (render behind the desktop icons) | — | Dropped | A DirectX overlay trick with no sane macOS equivalent |

### 1.3 MilkDrop's keys

Keys work while the vis window is key, bare (no ⌘). ⌘ shortcuts still go to the menu bar, so ⌃⌘←/→ seek and ⌃⌘↑/↓
volume work in the vis window too.

| MilkDrop | Roadie | | Why |
|---|---|---|---|
| — (the user's request) | **→ next preset, ← previous preset** (with the user blend, as Space and Backspace) | Added | "The arrow keys should move between visualizations." In MilkDrop ← → seeked Winamp 5 s; seek stays on ⌃⌘←/→ |
| ↑ ↓ (passed through to Winamp: volume) | **↑ ↓ volume**, as Winamp's bare keys and `WinampHotkeys.volumeStep` | Kept | Up/down keep the one Winamp binding MilkDrop already passed through, so only ← → change meaning. Up/down as previous/next too would leave no bare volume key in full screen, where the main window isn't reachable. Repeats while held, as in the main window |
| Space: next preset, blended (user blend time) | Same | Kept | |
| H: next preset, hard cut (no blend) | Same (a blend instead under Reduce Motion, §7) | Kept | |
| Backspace: previous preset (history) | Same (⌫) | Kept | |
| R: toggle random / sequential order | Same; persisted | Kept | Shadows Winamp's bare R (repeat) in this window, as in MilkDrop |
| Scroll Lock (also \` in later builds): lock the current preset (no automatic changes) | **\`** (backtick); keys still change it, as in MilkDrop | Kept | Macs have no Scroll Lock |
| L: preset browser (in-picture list; arrows, Enter loads) | Same: an in-window list with a search field (§2.8) | Kept | Shadows Winamp's bare L (open file) here, as in MilkDrop |
| F1: help screen (the key list) | **F1** or **?** | Kept | Mac laptops need fn for F-keys, hence `?` |
| T: play the song title animation now | Same | Kept | |
| F2: show the song title (persistent corner text) | Same, as a corner readout (§2.7) | Kept | |
| F3: show the song time | Same | Kept | |
| F4: show the preset name | Same | Kept | |
| F5: show fps | Same | Kept | Cheap; useful on slow Macs |
| F6 / + / −: preset rating (weights random picks) | — | Dropped | Ratings live in the preset file; editing presets is a non-goal |
| Z X C V B: Winamp transport | Same (previous, play, pause, stop, next) | Kept | |
| S R L J and arrows from Winamp | Only Z X C V B, ↑ ↓ pass through; S, R, L are MilkDrop's here; J (Jump to File) is dropped in this window | Adapted | MilkDrop's keys win in its window, as in Winamp. A Jump to File panel over full screen would land in another Space |
| M: preset-editing menu; S: save preset; A: random mash-up; N: audio-level debug; Y/K: custom messages and sprites; F7 F8 F9 | — | Dropped | Preset editing and authoring tools; F8 (change preset directory) is Settings' folder |
| Right-click / M menu with the commands | Right-click menu listing every key command with its key (§2.6) | Adapted | Makes the commands findable without F-keys and readable by VoiceOver |

### 1.4 Preset changes (MilkDrop)

| MilkDrop | Roadie | | Why |
|---|---|---|---|
| Auto-advance: "time between auto preset changes" (16 s) plus a random extra (up to about 10 s), on by default | **Change presets automatically** (on), every **16 s**, **vary the time** (adds 0–10 s, on) | Kept | Numbers are MilkDrop 2's defaults as remembered; the user can change them |
| Blend time: auto 2.7 s, user (Space) 1.7 s | **Blend time** setting (2.7 s) for automatic changes; key changes blend over 1.7 s, H cuts | Kept | Two values in MilkDrop; one setting is enough, the key blend stays MilkDrop's |
| MilkDrop 2 blend patterns (wipe, plasma, radial, plain) chosen at random | The package's `transitionPattern = .random`; `.crossfade` under Reduce Motion | Kept | The package does the drawing |
| Hard cuts on loud beats (threshold, half-life; **off by default in MilkDrop 2**) | — | Dropped (deferred) | The default MilkDrop 2 experience has none, and it needs a beat detector. A follow-up if wanted |
| Random order avoids repeats; sequential follows file name order | Random never repeats the current preset or the last few; sequential is case-insensitive file name order | Kept | |
| History: Backspace walks back through what was shown | Back/forward history, 64 deep (§5.3) | Kept | |
| Lock: no automatic changes while locked | Same | Kept | |
| Starts on a random preset (or the locked one) | Starts on the **last preset shown** | Adapted | The user asked for it; random is one key away |
| Auto-advance pauses while the browser or menu is open | Same (browser, help, menu) | Kept | |

### 1.5 Song title and readouts (MilkDrop)

| MilkDrop | Roadie | | Why |
|---|---|---|---|
| Song title animation when the track changes (fly-in, on by default; about 1.7 s) | **Show the song title when the track changes** (on): "Artist – Title" fades and grows in at the centre, holds, fades out (about 3.5 s in all); fade only under Reduce Motion | Kept | MilkDrop's letters flew in with random effects; a plain grow-and-fade keeps the moment without the cost |
| "Time between random song title animations" (off by default) | — | Dropped | Off by default in MilkDrop |
| Preset name shown briefly on change | A small toast with the preset name for 2 s after a key change (not after automatic changes unless the overlay is up) | Kept | |
| Custom fonts and colours for the texts | System font, white on a dark shadow | Adapted | |

### 1.6 Presets folder (MilkDrop)

| MilkDrop | Roadie | | Why |
|---|---|---|---|
| `Plugins\Milkdrop2\presets\` with subfolders; F8 changes it | Built-in **classic** visualizations, the package's licence-clean presets, and an optional **user folder** of `.milk` files (subfolders included), chosen in Settings | Adapted | §5 |
| Presets that fail to load show an error and are skipped | Same: the overlay says "Couldn't load <name>", the navigator skips it this session | Kept | |

---

## 2. UI

### 2.1 Ways in

- **Window › Visualization ⇧⌘K** (check item), after Playlist Editor in the Window group (`RoadieApp`).
- **Window › Visualization Settings… ⌥⌘K**: sets `SettingsTab.visualization` and opens Settings (as the Welcome
  window does, `openSettings`).
- **Skinned main menu › Visualization ▸** Start/Stop Visualization ⇧⌘K, Visualization Settings… ⌥⌘K
  (`MainMenu.visualizationEntries`, new `MainMenuCommand.toggleVisualization`, `.visualizationSettings`; state
  `isVisualizationOpen`).
- **Clutter bar V** and **right-click on the built-in visualizer**: Spectrum Analyzer / Oscilloscope / Off, a
  separator, Start/Stop Visualization, Visualization Settings….
- **Open the visualization when playback starts** (setting): playback going from stopped to playing opens the
  window (windowed), once per play, not on every track change.

### 2.2 The window

```
┌ ● ● ●   Visualization — Classic Spectrum ─────────────────────┐
│                                                                 │
│                  (the picture, edge to edge)                    │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ ▶  Daft Punk — One More Time                    1:12 / 5:20│ │  ← overlay (§2.4)
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

- An `NSWindow` (`.titled, .closable, .miniaturizable, .resizable`), `collectionBehavior` `.fullScreenPrimary`,
  black background, title "Visualization — <preset name>", minimum 320×200, default 640×400 placed right of the
  skinned column. Frame autosave `VisualizationWindow`. Not docked, not always-on-top, not affected by Double Size.
- Content: `VisualizationHostView` (AppKit) holding the renderer's view and, above it, the overlay
  (`NSHostingView` of SwiftUI; hit-testing only on its own controls, so double-click and the mouse still reach the
  host view).
- Closing it (red button, ⇧⌘K, Start/Stop) stops rendering and the stereo feed. Its open state persists
  (`visualization.windowOpen`) and it reopens windowed at launch.
- In `-RoadieWindowLayout column` (UI tests) it moves right of the column when it comes forward, like the Library.

### 2.3 Full screen

- ⌥Return, double-click, ⌃⌘F or the green button: `window.toggleFullScreen`. Esc leaves (after closing help or the
  browser). The overlay, keys, cursor hiding and readouts are the same in both modes.
- Entering full screen shows the overlay and restarts its idle timer, so the user sees what's playing first.
- The skinned windows stay where they are on their own Space.

### 2.4 The overlay

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Classic Spectrum                                         🔀 random  🔒   │  ← top strip: preset, order, lock
│                                                                          │
│                                                                          │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  One More Time                                                     │  │  ← title (large)
│  │  Daft Punk — Discovery                                             │  │  ← artist — album
│  │  ▶  1:12 ━━━━━━━━━━━━━━━━━━○──────────────────────────────  5:20   │  │  ← state, elapsed, progress, total
│  │  Next: Aerodynamic · This Mac · Volume 72%                         │  │  ← next track (if known), output, volume
│  │  ← → presets   Space next   L list   F1 help                       │  │  ← key hint (hidden after 3 shows)
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

- Contents, from `PlayerModel`: title and artist (`nowPlaying`), album when known, play state (▶ ❚❚ ■, and
  "Loading…"), elapsed / total and a progress bar (not a control: seeking stays on the main window and ⌃⌘←/→),
  the next track when the local queue knows it (`player.queue` up-next; Music Assistant's next when the remote queue
  snapshot has it, else omitted), the output's name, and the volume. With nothing playing: "Nothing is playing".
- **Audio note.** When the output isn't This Mac (a Music Assistant speaker or group without This Mac), the overlay
  adds: "Playing on Kitchen. The visualization needs the music playing on this Mac." and a dim corner badge
  "No audio on this Mac" stays when the overlay hides (§4.4).
- Style: a dark translucent material card (`.ultraThinMaterial` over black, white text with a shadow), 24 pt
  margin, at most 720 pt wide, centred at the bottom; system fonts; numbers monospaced.
- **Idle rule** (`OverlayVisibility`, §3.1): visible when the window opens, enters full screen, or the pointer moves
  over the view; hidden `overlayIdleSeconds` (default **3 s**) after the last movement, and the cursor with it
  (only while the pointer is inside the view, via `NSCursor.setHiddenUntilMouseMoves(true)`). It stays up while the
  pointer is over the card, while playback is paused or stopped, while the browser, help or right-click menu is
  open, and while VoiceOver runs (§7). Key presses don't show or hide it. Setting "Never" keeps it up.
- Animations: 0.25 s fade in and out (none under Reduce Motion: it just appears and goes).

### 2.5 Keys

`VisKeyMap` (§3.1) is the single source for the handler, the help screen and the context menu's key labels.

| Key | Command |
|---|---|
| → / Space | Next preset (1.7 s blend) |
| ← / ⌫ | Previous preset (1.7 s blend) |
| H | Next preset, hard cut |
| R | Random / sequential order |
| \` | Lock / unlock the preset |
| L | Preset list |
| T | Show the song title now |
| F2 / F3 / F4 / F5 | Title / time / preset name / fps readout on or off |
| F1 or ? | Help |
| ⌥Return, double-click | Full screen on / off |
| Esc | Close help or the list; else leave full screen |
| Z X C V B | Previous, Play, Pause, Stop, Next |
| ↑ ↓ | Volume up / down (repeats) |

Letters and preset keys don't repeat when held (so holding → doesn't race through presets); ↑ ↓ do. Any ⌘, ⌃ or ⇧
combination goes to the menu bar. While the preset list's search field has focus it gets the keys (except Esc and
Return).

### 2.6 Right-click menu

Next Preset (Space), Previous Preset (⌫), Next Preset Without Blending (H), separator, Random Order ✓ (R), Lock
Preset ✓ (\`), Presets… (L), separator, Show Song Title (T), Song Title / Song Time / Preset Name / Frame Rate
readouts ✓ (F2–F5), separator, Enter/Exit Full Screen (⌥↩), Keyboard Shortcuts (F1), Visualization Settings… (⌥⌘K).
The key labels are display only (titles carry them as `"Next Preset\tSpace"`-style key equivalents where AppKit allows
a bare key, else in the title). Popped in the host view (`popUpContextMenu(_:with:for:)`), so XCUITest and VoiceOver
reach it (docs/ui-tests-in-vm.md).

### 2.7 Song title animation, readouts, help

- **Song title** (`showSongTitleOnTrackChange`, on): when the current track changes while the window is open, or on
  T, "Artist – Title" (or the title alone) appears at the centre: 0.5 s fade and grow from 90 %, 2 s hold, 1 s fade.
  Under Reduce Motion: fade only. Not shown when the change is the first track after the window opens.
- **Readouts** (F2–F5, persisted, all off by default): top-left preset name, top-right fps, bottom-left "Artist –
  Title", bottom-right elapsed / total. Small, shadowed, and they **stay when the overlay hides** (that's their
  point). While the overlay card is up, the bottom two hide (the card has the same).
- **Help** (F1 / ?): a centred card listing §2.5's table, Esc / F1 / click closes it.

### 2.8 Preset list (L)

An in-window panel (works in full screen, where a sheet or separate window would be awkward): a search field
(type-to-filter, `localizedStandardContains`) and a list of every preset in catalogue order with a small source tag
(Classic, MilkDrop, Yours), the current one highlighted and scrolled to. ↑ ↓ move, Return or double-click loads it
(1.7 s blend) and closes, Esc closes. Auto-advance pauses while it's open. A preset that failed this session is shown
dimmed with "Couldn't load".

### 2.9 Settings › Visualization

```
┌ Visualization ───────────────────────────────────────────────────────┐
│ Presets                                                               │
│   [✓] Change presets automatically   every [ 16 ] seconds  [✓] Vary   │
│       (Paused while Reduce Motion is on.  [ ] Change them anyway)     │
│   Blend time  ───────○──────  2.7 s                                   │
│   Order       (•) Random  ( ) In order                                │
│   Your presets folder   ~/Music/MilkDrop       [Choose…] [Clear]      │
│                         214 presets found          [Show in Finder]   │
│ Overlay                                                               │
│   Hide the overlay and pointer after  [ 3 seconds ▾ ]  (2,3,5,10,Never)│
│   [✓] Show the song title when the track changes                      │
│ Window                                                                │
│   [ ] Open the visualization when playback starts                     │
└───────────────────────────────────────────────────────────────────────┘
```

A fifth tab, `SettingsTab.visualization` (symbol `sparkles.tv`, falling back to `waveform` if unavailable on 14).
The presets folder row appears only when the active renderer can draw `.milk` presets (after #0243; in Debug, the
classic renderer claims it for tests, §3.3).

---

## 3. Architecture

### 3.1 `VisualizationKit` (new PlayerKit target, Foundation only)

Pure models, unit-tested in `VisualizationKitTests` (swift-testing, fast tier). No AppKit, no Metal, no clocks of
their own: every time is a `TimeInterval` passed in, every random choice comes from a seeded generator.

```swift
public struct VisualizationPreset: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case classic(ClassicStyle), milk }
    public enum Source: Sendable { case builtIn, bundled, user }
    public var id: String          // "classic:spectrum", "bundled:spike-tunnel.milk", "user:Geiss/Rovastar - X.milk"
    public var name: String        // the classic title, or the file name without ".milk"
    public var kind: Kind
    public var source: Source
    public var url: URL?           // .milk only
}
public enum ClassicStyle: String, CaseIterable, Sendable { case spectrum, oscilloscope, spectrumAndScope, mirror, stereoScope }

public enum PresetCatalog {                                  // #0233
    public static let classics: [VisualizationPreset]
    public static func scan(folder: URL, source: VisualizationPreset.Source) -> [VisualizationPreset]   // *.milk, recursive, skips hidden/packages
    public static func ordered(_ presets: [VisualizationPreset]) -> [VisualizationPreset]               // classics first, then by name, then id
}

public struct PresetNavigator: Sendable {                    // #0233
    public enum Order: String, Sendable { case random, sequential }
    public init(presets: [VisualizationPreset], order: Order, isLocked: Bool, startingAt id: String?, seed: UInt64)
    public private(set) var current: VisualizationPreset?
    public var order: Order
    public var isLocked: Bool
    public mutating func next() -> VisualizationPreset?        // forward history first, else by order
    public mutating func previous() -> VisualizationPreset?    // back history, else the one before in list order
    public mutating func advanceAutomatically() -> VisualizationPreset?  // nil while locked
    public mutating func select(id: String) -> VisualizationPreset?
    public mutating func markFailed(id: String)               // skipped for the rest of the session
    public mutating func replacePresets(_ presets: [VisualizationPreset])  // keeps current if present; prunes history
}

public struct AutoAdvanceClock: Sendable {                   // #0234
    public struct Policy: Equatable, Sendable { var isEnabled: Bool; var interval: TimeInterval; var varies: Bool }
    public init(policy: Policy, seed: UInt64)
    public mutating func restart(at now: TimeInterval)        // after every preset change, manual or automatic
    public mutating func suspend(at now: TimeInterval)        // browser/help open, window not rendering, Reduce Motion
    public mutating func resume(at now: TimeInterval)         // shifts the deadline by the suspended time
    public mutating func isDue(at now: TimeInterval) -> Bool  // true once per deadline; the caller then restarts it
    public private(set) var deadline: TimeInterval?
}

public struct OverlayVisibility: Sendable {                  // #0234
    public enum Hold: Hashable, Sendable { case notPlaying, voiceOver, browser, help, menu, pointerOnOverlay, notice }
    public init(idleTimeout: TimeInterval?, now: TimeInterval)   // nil = never hide
    public private(set) var isOverlayVisible: Bool
    public private(set) var isCursorHidden: Bool
    public mutating func pointerMoved(at now: TimeInterval, inside: Bool)
    public mutating func pointerExited(at now: TimeInterval)
    public mutating func setHolds(_ holds: Set<Hold>, at now: TimeInterval)
    public mutating func show(at now: TimeInterval)           // window opened, entered full screen
    public mutating func tick(at now: TimeInterval)
    public var nextDeadline: TimeInterval? { get }            // for a one-shot timer instead of polling
}

public enum VisCommand: Hashable, Sendable { … }             // #0234, §2.5
public enum VisKeyMap {                                       // #0234
    public static func command(for key: VisKey, command: Bool, control: Bool, option: Bool, shift: Bool,
                               isRepeat: Bool) -> VisCommand?
    public static let help: [(keys: String, title: String, command: VisCommand)]
}
public enum VisKey: Hashable, Sendable { case character(String), left, right, up, down, space, delete, escape, returnKey, function(Int) }

public struct VisualizationSettings: Equatable, Sendable {   // #0234, §6
    public static func load(from defaults: UserDefaults) -> VisualizationSettings
    public func save(to defaults: UserDefaults)
}
```

`UserDefaults` is a Foundation type, so the settings struct can live here and be tested with a suite.

### 3.2 The renderer seam (App)

```swift
/// What draws the visualization. #0235: `ClassicVisualizer` (Core Graphics). #0243: `MilkVisualizer` (MilkMetal).
@MainActor
protocol VisualizationRenderer: AnyObject {
    var view: NSView { get }
    var kindName: String { get }                         // "classic" | "milk", for the probe and logs
    func canLoad(_ preset: VisualizationPreset) -> Bool
    /// Shows `preset`, blended over `transition` seconds (0 cuts). Throws when the preset can't be read or drawn.
    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws
    /// Audio since the previous tick: interleaved Float32, `channels` 2. Called on the main actor, once per tick.
    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double)
    /// Draws one frame. `time` rises steadily from 0 while the window is open (paused time excluded).
    func draw(at time: TimeInterval)
    func setReducedMotion(_ on: Bool)                    // crossfade-only transitions
    var problems: [String] { get }                       // the last load's warnings
}
```

Roadie owns the render loop (§3.4), not the renderer: one display link calls feed, then the auto-advance check,
then `draw`. That keeps pausing, frame rate and occlusion in Roadie: MilkMetal 1.0.0's `MilkView` runs its own
display link with no pause, frame-rate cap or shared clock (api-1.0.md F7 not taken), and the shared loop lets both renderers share it. `MilkVisualizer` (#0243) therefore uses a Roadie
`CAMetalLayer` view and `MilkRenderer.render(to:commandBuffer:time:)`, committing every command buffer (F3).

`VisualizationRendererFactory.make(configuration:colors:)` picks: Debug `-RoadieVisRenderer classic` builds
`ClassicVisualizer` alone (the UI tests' default); otherwise (no hook, `milk`, and always in Release) a
`MixedVisualizer` (#0257) with a `MilkVisualizer` when `MTLCreateSystemDefaultDevice()` returns a device and the
renderer initializes, else with classic presets only (logged). An unknown hook value logs and uses classic.

### 3.3 `ClassicVisualizer`

Roadie's own full-window take on Winamp's built-in visualizer, drawn with Core Graphics into a small bitmap (about
240×135 "pixels", aspect-matched to the view) shown nearest-neighbour in a `CALayer`, in the current skin's
`viscolor.txt` colours (`VisRenderer.defaultColors` with no skin). Five styles (`ClassicStyle`): Spectrum (75 bars
with falling peaks, `VisBars` falloff), Oscilloscope, Spectrum and Scope, Mirror (bars from the centre line),
Stereo Scope (left above, right below). Analysis uses AudioCore's public `SpectrumAnalyzer` on a mono mix of the window (and per channel for Stereo Scope).
Transitions: a crossfade of the two bitmaps over the blend time (H cuts).

It is the stand-in that makes the whole milestone testable now and in the VM (no Metal, deterministic for a given
input), the fallback when Metal is unavailable or a `.milk` preset fails to load (the navigator skips it and the
overlay says so), and a feature on its own: the classic presets stay in the list after MilkDrop lands. `canLoad`
accepts classic presets only, in every configuration (#0257 removed the Debug `.milk`-as-Spectrum stand-in; unit tests
use a recording MilkDrop double inside `MixedVisualizer` instead).

### 3.4 `VisualizationModel` and the render loop (App)

The model holds one renderer. With MilkDrop available that is a `MixedVisualizer` (#0257): it owns the classic and
MilkDrop renderers, routes each preset to the one whose `canLoad` accepts it, and names the active one in `kindName`
(the probe's `renderer`). Crossing kinds loads the incoming renderer first (a throw keeps the current one), resets
MilkDrop when it becomes active (no stale audio), and crossfades the two views over the blend time, driven by
`draw(at:)` time (0 cuts). Only the visible renderer(s) are fed and drawn.

`VisualizationModel` (`@MainActor @Observable`, owned by `PlayerModel` like `visualizer`): the navigator, clock,
overlay state, settings, the renderer, the audio feed (§4.2), the readout and help state, and the window's open /
full-screen state for the probe. `VisualizationWindowController` owns the window and the host view and forwards
events (keys, mouse, occlusion) to the model.

- **Display link:** `hostView.displayLink(target:selector:)` (macOS 14), so it follows the view's screen.
  `preferredFrameRateRange` 30–60, preferred **60 while This Mac is playing**, **30 otherwise** (paused, stopped,
  remote), and 30 under Low Power Mode or `thermalState >= .serious`.
- **Not rendering** (link paused, clock suspended, stereo feed off) while the window is closed, miniaturized, or
  occluded (`NSWindow.didChangeOcclusionStateNotification`, `occlusionState.contains(.visible)` false: another Space,
  covered, screen asleep), or the app is hidden.
- **Timers:** the overlay uses a one-shot `Timer` for `nextDeadline`, not the display link, so it hides on time even
  when rendering is paused.
- Tick: read the stereo feed → `renderer.feed` → `clock.isDue` → maybe `navigator.advanceAutomatically()` + `load`
  → `renderer.draw(at:)`.

```
 AVAudioEngine mainMixer tap (audio thread)
   └─ TapSink.handle ─┬─ mono  → VisSampleRing ──→ VisualizerModel (main window, unchanged)
                      └─ stereo (when enabled) → VisSampleRing (interleaved)
                                                   └─ StereoFeedReader (main, paced by display time)
                                                        └─ VisualizationRenderer.feed → draw
```

### 3.5 Menus, probe, identifiers

- `MainMenuCommand.toggleVisualization`, `.visualizationSettings`; `MainMenuState.isVisualizationOpen`.
- `AXID.Vis`: `vis.window`, `vis.canvas` (label "Visualization", value = preset name), `vis.preset` (the top strip's
  name, also the probe's), `vis.overlay`, `vis.overlay.title|artist|time|state|next|output|note`, `vis.toast`,
  `vis.songTitle`, `vis.readout.title|time|preset|fps`, `vis.help`, `vis.browser`, `vis.browser.search`,
  `vis.browser.row.N`, `vis.badge.noAudio`, `vis.flashNotice`, `vis.flashNotice.continue`; plus
  `main.clutter.v` menu items by title.
- `TestProbe.visualization` (nil until the window first opens): `open`, `fullScreen`, `renderer`, `preset` (id),
  `presetName`, `order`, `locked`, `autoAdvance` (`on|off|suspended`), `overlay` (`shown|hidden`), `cursorHidden`,
  `audio` (`local|remote|none`), `lastTransition` (`blend 1.7`, `blend 2.7`, `cut`), `presetChanges` (count),
  `songTitleShows` (count), `readouts`, `failed` (ids), `dimmed`.

---

## 4. Audio

### 4.1 A stereo sink beside the mono ring (#0232)

`AnalyzerTap`'s `TapSink.handle` mixes to mono for `VisSampleRing` (the 75-column spectrum and the scope). It gains a
second ring, `stereo: VisSampleRing` of **interleaved** L, R samples (capacity 32,768 floats = 16,384 frames), and a
preallocated interleave scratch. In the same tap block, when `stereoEnabled` (an atomic flag, `ca_load_acquire`):

- stereo source: `vDSP_ztoc` of (left, right) into the scratch, then `stereo.write(scratch, count: 2n)`;
- mono source: the left channel written twice per frame (`vDSP_ztoc` of (left, left));
- more than two channels: the first two.

No allocation, no locks; `maxChunk` (capacity/4) is even, so the producer never publishes half a frame. With
`stereoEnabled` off (the default, and whenever the vis window isn't rendering) the tap does exactly what it does
today. `AnalyzerTap.setStereoEnabled(_:)` and `stereoSampleRate` (the rate of the last install) are the API.

### 4.2 Pacing and feeding (#0232 reader, #0235 wiring)

The engine's tap delivers about 100 ms at a time whatever `bufferSize` says; fed straight to a renderer, the
picture would step in chunks (MilkDropMetalKit api-1.0.md F5, and the reason the Gallery has a 120 Hz drain). Roadie
already solved this for the main-window vis with `VisReadCursor`. `StereoFeedReader` (AudioCore, #0232) does the same
for the stereo ring: each display tick it advances its own cursor by real elapsed time (lagging the write head by a
window, as `VisReadCursor` does) and returns the **frames since the previous tick** (interleaved, into a reusable
buffer, at most 4,096 frames; a gap longer than that re-lags rather than replaying). The model then calls
`renderer.feed` on the main actor.

So the package's `feed` is called from one thread only (the main actor), which meets its single-producer contract
(F4). Since 1.0 the renderer paces its own feed (F5 option b): each `render` analyzes the 1,024 frames that should be
playing at its `time`. Roadie keeps the reader and feeds once per tick on the main actor, so audio plays straight
through one tick later (#0243).

The reader has its own cursor; the main window's `VisualizerModel` keeps `resetCursor()` on the mono ring, so the
two consumers never move each other.

### 4.3 Silence, pause, sample rate

- **Silence** (quiet passages, between tracks): fed as is. MilkMetal reads silence as "normal" levels and keeps
  moving (`longSilenceReadsAsNormal`); the classic styles fall flat, as Winamp's did.
- **Paused / stopped:** the engine stops delivering, so the reader returns no frames and the renderer gets none. The
  picture keeps animating on its own clock (MilkDrop kept running in Winamp's pause) at 30 fps; classic styles let
  their bars fall to zero and freeze.
- **Sample rate changes** (a 44.1 → 48 kHz track, an output device change): `AudioGraph.start` re-installs the tap at
  the new processing rate; `prepare(sampleRate:)` records it, the stereo reader sees the rate change, re-lags its
  cursor and passes the new rate to `feed`. A test drives this without an engine.

### 4.4 Local vs Music Assistant playback

| Output | PCM through this Mac? | `audio` | What the window shows |
|---|---|---|---|
| This Mac, local queue (`thisMacFeed == .local`) | yes (Player, AudioGraph) | `local` | the music |
| This Mac as a Sendspin player (`thisMacFeed == .musicAssistant`) | yes (`Player+Stream` into the same graph) | `local` | the music |
| A Music Assistant speaker or group (`selectedOutput != thisMacID`) | no | `remote` | the picture idling on silence; overlay note "Playing on <name>. The visualization needs the music playing on this Mac."; corner badge "No audio on this Mac" stays when the overlay hides |
| Nothing selected or stopped | — | `none` | idle picture; overlay "Nothing is playing" |

`audio` comes from `PlayerModel.selectedOutput` and `playbackState`, not from sniffing the ring, so a quiet passage
isn't mistaken for remote playback.

---

## 5. Presets

### 5.1 Sources

1. **Classic** (always): the five `ClassicStyle`s, ids `classic:<style>`, names "Classic Spectrum", "Classic
   Oscilloscope", "Classic Spectrum and Scope", "Classic Mirror", "Classic Stereo Scope".
2. **Bundled** (#0258): MilkDropMetalKit's own licence-clean presets (MIT, written for the package): the 42 feature
   demos in its `Presets/` folder, with `spike-tunnel.milk` as the showcase. 1.0 doesn't vend them, so
   `scripts/update-milkdrop-presets.sh` copies them at the pinned tag (`1.0.0`) into `App/Visualization/Presets/`
   (with a `VERSION` file), which ships as one folder, `Contents/Resources/Presets`; `NOTICE` records them. Names come
   from the folder's `gallery.json` (`PresetCatalog.bundled`, e.g. "Spike Tunnel", "Mode 0: Circle"), else the file
   name. Ids `bundled:<file name>`.
3. **User folder** (#0241): any folder of `.milk` files, scanned recursively (hidden files and packages skipped),
   ids `user:<path relative to the folder>`. Rescanned when the folder setting changes and when the window opens
   (cheap: names only, no parsing). A folder that's gone shows "Folder not found" in Settings and contributes nothing.
   Converted `.milkpreset` bundles are accepted too once the package reads them (`MilkPreset(contentsOf:)` does).

Catalogue order: classics, then every `.milk` by name (`localizedStandardCompare`), ties by id. A preset appears in
the navigator only if the active renderer `canLoad` it.

### 5.2 Loading and failures

`.milk` files are parsed when shown, not when listed: `MilkPreset(contentsOf:)` is `Sendable`, so #0243 parses off
the main actor and loads on it. A preset that throws, or whose renderer reports it can't draw it, is
`markFailed`: skipped by next/previous/auto for the session, dimmed in the list, and the overlay toast says
"Couldn't load <name>". The previous preset stays on screen. Equation warnings (`presetErrors`) go to the log only.

### 5.3 Order, history, lock, memory

- **Sequential:** catalogue order, wrapping. **Random:** uniform over the presets, never the current one nor any of
  the last `min(8, count / 2)` shown; seeded (Debug `-RoadieVisSeed N` for tests).
- **History:** every change pushes the previous preset (64 deep). → / Space first replays forward history after
  ← / ⌫ went back, then picks a new one by the order; ← / ⌫ walks back, and with empty history goes to the previous
  in catalogue order. A preset change by the list or auto-advance truncates forward history, as a browser does.
- **Lock** (\`): auto-advance stops; keys and the list still change the preset (MilkDrop's rule); persisted.
- **Last preset:** `visualization.lastPreset` (id) is restored when the window opens; if it's gone, the first
  classic. A fresh install (no `lastPreset`) starts on `bundled:spike-tunnel.milk` where MilkDrop can draw, else the
  first classic (#0258).

---

## 6. Settings

All in the model's `defaults` (the test suite under `-RoadieUITest`), loaded by `VisualizationSettings.load`.

| Key | Type | Default | Where |
|---|---|---|---|
| `visualization.autoAdvance` | Bool | true | Settings |
| `visualization.autoAdvanceSeconds` | Double (5…300) | 16 | Settings |
| `visualization.autoAdvanceVaries` | Bool (adds 0–10 s) | true | Settings |
| `visualization.blendSeconds` | Double (0…10) | 2.7 | Settings (automatic changes; keys use 1.7, H 0) |
| `visualization.order` | `random` \| `sequential` | random | Settings, R |
| `visualization.locked` | Bool | false | \` |
| `visualization.lastPreset` | String id | — | automatic |
| `visualization.presetsFolder` | path | — | Settings |
| `visualization.overlayIdleSeconds` | Double; 0 = never | 3 | Settings |
| `visualization.songTitleOnTrackChange` | Bool | true | Settings |
| `visualization.readouts` | [String] of `title time preset fps` | [] | F2–F5 |
| `visualization.openOnPlay` | Bool | false | Settings |
| `visualization.windowOpen` | Bool | false | automatic |
| `visualization.changeWithReduceMotion` | Bool | false | Settings (shown only with Reduce Motion on) |
| `visualization.flashNoticeShown` | Bool | false | automatic (§7) |

Debug-only launch arguments (test hooks, never in Release; `RoadieConfiguration`): `-RoadieVisRenderer classic|milk`,
`-RoadieVisOverlayIdle <seconds>` (overrides the setting, e.g. 1 for UI tests), `-RoadieVisSeed <n>`,
`-RoadieVisAutoAdvance <seconds>` (a short interval, no variation), `-RoadieVisReduceMotion 1`, `-RoadieVisDimFlashing 1`
and `-RoadieVisVoiceOver 1` (stand in for the system settings, which a test can't change),
`-RoadieVisPresetsFolder <path>` (instead of the folder panel) with `-RoadieVisSeedPresets <n>` (the app writes n tiny
`.milk` files there; the sandboxed test runner can't). Plain settings are passed as
`-visualization.order sequential` through `NSArgumentDomain`, as other tests do.

---

## 7. Accessibility and photosensitivity

- **Labels.** Every overlay text is a static text with a label ("Title, One More Time", "Elapsed 1:12 of 5:20",
  "Playing"); the card is one accessibility group "Now playing". The canvas is an image element "Visualization",
  value the preset name. The right-click menu and the help card make every key command reachable without F-keys.
- **VoiceOver.** While VoiceOver runs (`NSWorkspace.shared.isVoiceOverEnabled`, observed) the overlay never
  auto-hides and the cursor never hides. A preset change by key or list posts an announcement ("Classic Mirror");
  automatic changes don't (every 16 s would be noise).
- **Reduce Motion** (`accessibilityDisplayShouldReduceMotion`, observed): automatic preset changes pause (Settings
  says so and offers **Change them anyway**); transitions use the crossfade pattern; H blends instead of cutting;
  the song title fades without growing; overlay and toast appear without animation. The picture itself still moves:
  it is the feature, and the user opened it.
- **Photosensitivity.** MilkDrop presets can flash and strobe. The first time the window opens a card says
  "Some visualizations flash or change quickly. If flashing lights affect you, turn on Reduce Motion or Dim Flashing
  Lights in System Settings › Accessibility." with **Continue** (`vis.flashNotice`); the picture is dimmed and
  auto-advance waits until it's dismissed; shown once (`flashNoticeShown`).
  With **Dim Flashing Lights** (`MADimFlashingLightsEnabled()`, MediaAccessibility, macOS 14) Roadie draws the
  picture under a 40 % black layer, uses crossfades only, never cuts (H blends), and blends over at least 5 s. Roadie
  can't detect flashes in a preset's output, so this is a blanket dimming, and the design says so in the Help page.

---

## 8. Testing

### 8.1 Fast (unit)

- **AudioCore** (#0232): the stereo ring and reader (`AnalyzerTapTests` additions), with the existing offline-render
  harness and synthetic buffers; no device, no sound.
- **VisualizationKit** (#0233, #0234): catalogue scan over a temp folder, ordering, navigator (sequential, random with
  a seed, history back/forward, lock, failures, replace), auto-advance clock with explicit times, overlay visibility
  with explicit times and holds, key map, settings round trip in a `UserDefaults` suite.
- **SkinKit**: `MainMenuTests` for the Visualization submenu and shortcut parity.
- **RoadieTests**: `VisualizationModelTests` (a model with the classic renderer and a fake clock: open/close turns the
  stereo feed on/off, occlusion pauses, auto-advance loads the next preset, remote output sets `audio = remote`, track
  change triggers the song title), menu builder tests for the new items.

### 8.2 UI tests in the guest

One class, **`VisualizationUITests`** (created by #0235, extended by each child), launched with the classic renderer
(`-RoadieVisRenderer classic`), `-visualization.order sequential`, `-RoadieVisOverlayIdle 1`, and the fixture folder
library. A `RoadieUIApp.Visualization` helper: `open()` (⇧⌘K), `window`, `preset` (`vis.preset` value), `overlay`,
`probe.visualization`. The tests read preset names and probe state, never pixels.

- Open from ⇧⌘K, the Window menu, the clutter V menu, the skinned main menu; close with ⇧⌘K.
- ← / → / Space / ⌫ change `vis.preset` in catalogue order; R and \` flip the probe's `order` / `locked`; H's
  `lastTransition` is `cut`.
- The overlay exists after a hover, is gone (and `cursorHidden`) after the 1 s idle, and comes back on hover.
- Full screen: ⌥Return → probe `fullScreen` true; Esc → false (#0237 spikes this in the guest first).
- L opens `vis.browser`, typing filters, Return loads; F1/`?` shows `vis.help`, Esc closes.
- Settings › Visualization changes the probe's policy; Reduce Motion stand-in suspends auto-advance.

### 8.3 What the guest can and can't do

- **No GPU worth measuring.** The guest's GPU is the paravirtual `mac2`-family device: MilkMetal's shaders run there
  (the package's own VM tests render frames), but timing is meaningless. UI tests use the classic renderer;
  #0243 adds one smoke test with `-RoadieVisRenderer milk` that skips (`XCTSkip`) when the probe says the factory
  fell back to classic (no Metal device).
- **Full screen** works natively in the headless guest (#0237's spike), so the UI tests drive the real transition. In
  full screen the main window's probe leaves the accessibility tree, so the tests read full-screen state from the
  canvas frame (docs/ui-tests-in-vm.md). The Debug borderless fallback was never needed and was removed (#0245).
- **Cursor hiding** can't be observed by XCUITest; the probe's `cursorHidden` reports the state machine, and the real
  cursor is a by-hand check.
- **Function keys:** `typeKey(.F1, [])` is supported by XCUITest; `?` is tested too.
- **MilkDropMetalKit** resolves from GitHub by URL and version (the guest resolves SwiftPM from the network, as it does
  for Sparkle); the sibling checkout `../MilkDropMetalKit` is not in the export and must never be a path dependency.

### 8.4 Feature inventory

`docs/design/test-automation.md` gets a new **§5.12 Visualization**, one row per feature, added by each child when it
lands (not now): window and ways in (#0235), preset keys and auto-advance (#0236), full screen (#0237), overlay
(#0238), title/readouts/help (#0239), list (#0240), settings (#0241), accessibility (#0242), MilkDrop presets (#0243).
Each user-facing child also adds a CHANGELOG `[Unreleased]` bullet and, at the end (#0242), a Help page section
`#visualization` (website/help.html) listing the keys.

---

## 9. Risks

1. **MilkDropMetalKit's 1.0 API differs from today's.** api-1.0.md proposes changes (errors, `MilkView` options,
   pacing F5, products F1). Mitigation: Roadie depends on four calls (`init`, `load`, `feed`, `render`) behind its
   own seam; #0243 adapts to whatever 1.0 ships and is the only issue that imports the package.
2. **Pacing twice.** 1.0 paces `feed` internally (F5 b). Roadie's per-tick feeding still works (it feeds as played)
   and adds one tick of delay; #0243's by-hand step 2 checks the picture pulses on the beat.
3. **Main-actor stalls.** `render` waits on a 3-frame semaphore; a command buffer never committed stalls the main
   thread (F3). #0243 commits every buffer and draws only when a drawable is available.
4. **Full screen in the headless guest.** Covered by #0237's spike: native full screen works in the guest.
5. **Hidden cursor stuck.** `setHiddenUntilMouseMoves` unhides on any movement, and the window unhides on close,
   resign key and exit of full screen. A by-hand check on a second display.
6. **Key conflicts.** S, R, L, J change meaning in this window (as in MilkDrop). The help card and right-click menu
   make that visible.
7. **Energy.** A 60 fps Metal window can drain a laptop. Occlusion/minimize/close stop it; 30 fps when nothing local
   plays, under Low Power Mode and thermal pressure.
8. **Photosensitivity.** No detection is possible; the first-open notice, Reduce Motion and Dim Flashing Lights
   handling are the mitigation, plus a Help page note.
9. **Remote playback is the common case for this user** (Music Assistant speakers). The overlay explains the idle
   picture; Sendspin on This Mac gives real audio.

---

## 10. Children and their order

| Issue | Title | Blocked by | Tier |
|---|---|---|---|
| [#0232](../../issues/0232.md) | The analyzer tap mixes everything to mono, so nothing can read the stereo signal a MilkDrop visualization needs | — | full |
| [#0233](../../issues/0233.md) | Roadie has no model of visualization presets: no catalogue, order, history or lock | — | fast |
| [#0234](../../issues/0234.md) | Nothing decides when a visualization changes preset on its own, when its overlay hides, or what its keys do | #0233 | fast |
| [#0235](../../issues/0235.md) | Roadie has no visualization window | #0232, #0234 | ui |
| [#0236](../../issues/0236.md) | The visualization window has no keys for changing presets, and presets never change on their own | #0234, #0235 | ui |
| [#0237](../../issues/0237.md) | The visualization can't go full screen | #0235 | ui |
| [#0238](../../issues/0238.md) | The full-screen visualization has no song overlay | #0234, #0237 | ui |
| [#0239](../../issues/0239.md) | The visualization never shows the song title when the track changes, and has no help or readouts | #0238 | ui |
| [#0240](../../issues/0240.md) | There is no way to pick a visualization preset from a list | #0236 | ui |
| [#0241](../../issues/0241.md) | There are no visualization settings | #0236 | ui |
| [#0242](../../issues/0242.md) | The visualization ignores Reduce Motion, Dim Flashing Lights and VoiceOver | #0238, #0239, #0241 | ui |
| [#0243](../../issues/0243.md) | Roadie renders no MilkDrop presets | #0235, MilkDropMetalKit 1.0.0 tag | ui |
| [#0258](../../issues/0258.md) | Roadie ships no MilkDrop presets, and Release hides the presets folder setting | #0257 | ui |

Order: #0232 and #0233 first (independent: AudioCore and the new VisualizationKit target), then #0234, then the
window #0235 (it needs the stereo reader and the catalogue), then #0236 → #0237 → #0238 → #0239, with #0240 and #0241
after #0236 in either order, and #0242 last of the host side. #0243 waits for the package's `1.0.0` tag and can land
any time after #0235; ideally after #0242, so the MilkDrop renderer meets the finished host. Milestone end:
`scripts/verify.sh --head --full --ui --ui-skins all --coverage`.

---

## 11. Open questions for the user (defaults in the plans)

1. **↑ ↓ in the vis window.** Default: volume (Winamp's bare keys, which MilkDrop passed through), so only ← →
   change meaning. Alternative: ↑ ↓ also previous/next preset, or random preset.
2. **Overlay idle time.** Default 3 s, settable (2, 3, 5, 10 s, Never).
3. **Overlay while paused.** Default: stays up while paused or stopped (as video players do); hides only while
   playing.
4. **Ship before MilkDrop?** Default: the window with the five classic visualizations ships in the next release
   even if MilkDropMetalKit 1.0 isn't out; say if it should stay hidden in Release until #0243.
5. **Bundled presets.** Default: the package's own MIT demo presets (feature demos, not a curated "best of"). A
   curated pack needs presets whose licences are clear (handoff §9); say if you have one in mind. **Answered
   (#0258):** all 42 of MilkDropMetalKit 1.0.0's presets ship.
6. **Hard cuts on beats.** Default: not in M18 (off by default in MilkDrop 2). A follow-up issue if wanted.
7. **Start preset.** Default: the last one shown (you asked); MilkDrop started on a random one.
8. **Skinned frame.** Default: a native window. Winamp 5 drew MilkDrop's window in the skin's `gen.bmp` frame; a
   follow-up if wanted.
9. **Shortcut for Visualization Settings.** Default ⌥⌘K (⌘K is the Skin Library). Say if you'd rather move the Skin
   Library to ⌥S-style Winamp parity and give ⌘K to the visualization (a breaking shortcut change; not planned).
