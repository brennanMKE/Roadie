# AirPlay 2 Speaker Support on macOS (HomePod, multi-room)

Handoff doc for implementing AirPlay output in a macOS music player that renders classic Winamp skins. Goal: let the user pick one or more AirPlay 2 speakers (HomePods, Apple TVs) from inside the app, the way Music.app does, with reliable playback and working remote controls.

## TL;DR

1. Apple's AirPlay 2 recipe has four parts: identify as long-form audio, add an `AVRoutePickerView`, integrate `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, and play through an API that supports **enhanced buffering**.
2. Only two playback stacks get enhanced buffering: `AVPlayer`/`AVQueuePlayer`, or `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`. `AVAudioEngine`, `AudioQueue`, and raw Core Audio output units do not.
3. **macOS is the odd platform.** `AVAudioSession` is marked unavailable on macOS in the current Swift SDK, and Apple's "Supporting AirPlay" article only gives the long-form route-sharing step for iOS, tvOS, and watchOS. On macOS, `AVRoutePickerView` has a macOS-only `player: AVPlayer?` property for per-player routing. There is no documented equivalent for `AVSampleBufferAudioRenderer`.
4. Because the macOS story is thinly documented, **start with a spike** (below) that proves routing to HomePods on the current macOS before committing to an architecture.
5. Winamp features (EQ, spectrum/oscilloscope visualizer) collide with enhanced buffering: audio is rendered up to minutes ahead of what's audible on AirPlay 2. Visualizer data must be keyed by media time, and EQ changes need a partial flush to be heard promptly.

## How AirPlay 2 enhanced buffering works (why the API choice matters)

- Legacy AirPlay is a near-real-time stream with a few seconds of buffer on the speaker.
- AirPlay 2 enhanced buffering streams faster than real time into a buffer measured in minutes on the speaker. Result: survives Wi-Fi dropouts, faster play/skip response, tight multi-room sync.
- With `AVSampleBufferAudioRenderer`, how much data the renderer requests depends on the route: a few seconds for local, Bluetooth, or AirPlay 1; **multiple minutes** once routed to an AirPlay 2 speaker. The pipeline must tolerate that change at any moment.
- When using long-form, only **one** audio renderer may be added to a render synchronizer. Multiple simultaneous players (e.g., two `AVPlayer`s for crossfade) are a known AirPlay 2 failure mode: only one player instance plays over AirPlay. Do crossfades/gapless inside a single pipeline.

## The four integration steps

### 1. Long-form audio identification

- iOS/tvOS/watchOS: `AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)`.
- macOS: the Swift overlay marks `AVAudioSession` unavailable. The 2017 WWDC session said macOS gained a minimal `AVAudioSession` just for setting the route sharing policy. **Task for Claude Code:** grep the installed SDK header (`MacOSX.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioSession.h`) for any `macos(` availability on `routeSharingPolicy` / `setRouteSharingPolicy:error:`. If something is exposed to ObjC only, it can be called from a small ObjC shim. If nothing is available, skip this step on macOS and rely on per-player routing.
- Also evaluate the Info.plist key `AVInitialRouteSharingPolicy` = `LongFormAudio` (documented for iOS "intelligent AirPlay"; check whether macOS honors it, harmless if not).

### 2. In-app route picker

- `AVKit.AVRoutePickerView` (macOS 10.15+), an `NSView`. Wrap in `NSViewRepresentable` if the host is SwiftUI.
- Use `AVRouteDetector` (`multipleRoutesDetected`, set `isRouteDetectionEnabled = true` only while the UI is visible) to hide the button when no AirPlay devices exist.
- Styling: `routePickerButtonStyle`, `setRoutePickerButtonColor(_:for:)`, `activeTintColor`, `isRoutePickerButtonBordered`. For a Winamp skin, the stock button will look out of place. Options: place a transparent/hidden `AVRoutePickerView` under a skinned button and forward the click (the picker has no public "present" method, so a known workaround is to find its internal `NSButton` and `performClick`; treat as fragile and isolate it behind one function).
- `player` property (macOS only): set it to the `AVPlayer` to route that player. Known issue (Apple forums, macOS 12.4): with `player` set, choosing a HomePod was ignored; with `player` nil, routing worked but only for one `AVPlayer`. Must be tested on current macOS.

### 3. Media Player integration (required for HomePod/remote control)

- `MPNowPlayingInfoCenter.default().nowPlayingInfo`: title, artist, album, artwork (`MPMediaItemArtwork`), `MPMediaItemPropertyPlaybackDuration`, `MPNowPlayingInfoPropertyElapsedPlaybackTime`, `MPNowPlayingInfoPropertyPlaybackRate`.
- On macOS also set `MPNowPlayingInfoCenter.default().playbackState` (`.playing`, `.paused`, `.stopped`). macOS uses this explicitly; do not leave it at default.
- `MPRemoteCommandCenter.shared()`: play, pause, togglePlayPause, nextTrack, previousTrack, changePlaybackPosition, stop. HomePod touch controls, Siri on HomePod, Control Center, and other Apple devices controlling the session all arrive here.
- Update elapsed time on play/pause/seek/track change only (the system extrapolates from rate). Do not spam it on a timer.

### 4. Enhanced-buffering playback stack

Pick one (see Architecture options).

## Architecture options for a Winamp-style player

Winamp-relevant requirements: wide format support (MP3, AAC, FLAC, possibly OGG/Opus, tracker modules), gapless, 10-band EQ, preamp, balance, spectrum + oscilloscope visualizer, crossfade (optional).

### Option A: `AVQueuePlayer` + `MTAudioProcessingTap`

- Routing: `AVRoutePickerView.player = queuePlayer`. This is the path Apple documents for macOS per-player routing.
- EQ/visualizer: attach an `MTAudioProcessingTap` via `AVMutableAudioMix` / `AVMutableAudioMixInputParameters.audioTapProcessor` on each `AVPlayerItem`. Do biquad EQ with vDSP in the tap; copy samples out for FFT.
- Pros: least code, Apple's recommended path, gapless-ish via queue.
- Cons: format support limited to what AVFoundation decodes (no OGG Vorbis, no tracker modules). Crossfade hard (single player). **Unknown:** whether an attached tap disables or alters enhanced buffering over AirPlay, and when the tap runs relative to audible time. Must verify in the spike.

### Option B: Custom decode + `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` (recommended if the spike proves routing works)

- Pipeline: decoder (AVAudioFile/ExtAudioFile for native formats; libopenmpt, libvorbis/opus, or ffmpeg for the rest) → DSP (EQ, preamp, balance, crossfade mixer, all in one stream) → analysis tap (FFT/oscilloscope, timestamped) → package as `CMSampleBuffer` → `audioRenderer.enqueue(_:)`.
- Model it on Apple's "Playing custom audio with your own player" sample (`SampleBufferPlayer` / `SampleBufferSerializer` / `SampleBufferItem` / `SampleBufferSource`). That sample is currently listed as iOS 17+, so port it; the AVFoundation classes themselves exist on macOS.
- Rules from Apple:
  - Drive enqueueing from `requestMediaDataWhenReady(on:using:)`; loop while `isReadyForMoreMediaData`; call `stopRequestingMediaData()` at end of data.
  - Prefer 1 to 2 seconds of audio per `CMSampleBuffer`, interleaved channels. Mixed formats/sample rates back to back are fine.
  - One continuous timeline: offset each track's local time onto the synchronizer's timeline.
  - Track boundaries: add a boundary time observer on the synchronizer at each item's end time to advance "current track" UI and Now Playing.
  - Seek: rate 0 → `stopRequestingMediaData()` → `flush()` → reposition decoder → reinstall request closure → rate 1.
  - Playlist edits after the next track is already enqueued: `flush(fromSourceTime:completionHandler:)` at the boundary. It can fail if too close to the playhead; always wait for the completion and handle failure (full flush or skip).
- Routing on macOS: **this is the risk.** `AVRoutePickerView.player` only accepts `AVPlayer`. The spike must answer whether a renderer-based pipeline follows the picker's selection when `player` is nil (the forum report suggests nil-player picks route app audio). `AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID` (macOS) selects a Core Audio device, which is not the same as an AirPlay 2 enhanced-buffering route.

### Option C: Fallback, system-wide AirPlay output

- Keep any engine (including `AVAudioEngine`) and let the user pick HomePods as the Mac's system output (Control Center Sound menu / System Settings > Sound).
- Pros: zero routing code; works with anything.
- Cons: no enhanced buffering, no in-app picker that matches Music.app, all system sounds go to the speaker, ~2 s latency. Use only if A and B both fail the spike, or as the "local" path.

## Winamp-specific gotchas under enhanced buffering

1. **Visualizer sync.** With AirPlay 2 the analysis runs at enqueue time, potentially minutes before it's audible. Store analysis frames in a ring buffer keyed by presentation timestamp (PTS on the synchronizer timeline). The render loop (CVDisplayLink / `CADisplayLink` on macOS 14+) reads `renderSynchronizer.currentTime()` (or `player.currentTime()` for Option A) and draws the frame nearest that time. Verify in the spike whether the synchronizer's time already accounts for AirPlay output latency; if not, subtract the reported latency.
2. **EQ / preamp / balance latency.** DSP baked in before enqueue won't be heard until the buffer drains (minutes on AirPlay 2). On DSP change: `flush(fromSourceTime: now + small margin)` and re-render from there. Debounce slider drags (e.g., 150 ms). Locally the buffer is seconds, so it's less noticeable but the same code path works.
3. **Volume.** Use `audioRenderer.volume` / `player.volume` rather than scaling samples, so the change isn't delayed by the buffer. Confirm how this maps to HomePod volume in the spike.
4. **Crossfade and gapless.** Must be done by mixing inside the single stream (Option B). Never run two players simultaneously.
5. **Pause/resume.** Setting synchronizer rate 0/1 is near-instant on AirPlay 2 thanks to enhanced buffering; don't flush on pause.

## Phase 0 spike (do this first)

Build a minimal macOS app (no skin rendering) with three toggleable engines and an `AVRoutePickerView`:

- Engine A: `AVQueuePlayer` with two local tracks; picker `player` set.
- Engine A': same, picker `player` nil.
- Engine A+tap: same with an `MTAudioProcessingTap` doing a trivial gain + RMS meter.
- Engine B: `AVSampleBufferAudioRenderer` + synchronizer playing decoded PCM from a file; picker `player` nil.

For each, record on the current macOS release:

- Does the picker list HomePods? Does it allow **multiple** selection (checkboxes, like Music.app's menu)?
- After selecting one HomePod: does audio move off the Mac? Does the rest of the system's audio stay local?
- After selecting two HomePods: do both play in sync?
- Renderer requested-ahead duration local vs AirPlay (log how far ahead of `currentTime()` the last enqueued PTS is). Minutes ahead = enhanced buffering active.
- Wi-Fi off for 10 s on the Mac: does playback continue?
- HomePod tap / "Hey Siri, pause": does `MPRemoteCommandCenter` fire?
- Tap timing: when does the tap callback run relative to audible output?

Log results to `docs/airplay-spike-results.md` and choose A or B based on them.

## Implementation plan (after spike)

1. `AudioOutputRouting` module: picker view wrapper, `AVRouteDetector`, skinned-button bridge, route change observation.
2. `PlaybackEngine` protocol (play, pause, seek, enqueue playlist, current time, rate) with the chosen implementation.
3. `DSPChain`: EQ (10 biquads matching Winamp bands 60, 170, 310, 600, 1k, 3k, 6k, 12k, 14k, 16k Hz), preamp, balance; vDSP; parameter changes trigger flush-from-time.
4. `AnalysisBuffer`: PTS-keyed ring buffer of FFT bins (Winamp classic uses 75-band spectrum, 576-sample oscilloscope) consumed by the skin's vis area.
5. `NowPlayingController`: owns `MPNowPlayingInfoCenter` (including macOS `playbackState`) and `MPRemoteCommandCenter` handlers.
6. Tests: deterministic unit tests for timeline offset math, boundary observers, flush-failure handling; manual checklist from the spike for AirPlay.

## Open questions to resolve with the user

- Required formats beyond what AVFoundation decodes (OGG, Opus, MOD/XM/IT)? If yes, Option B is effectively required.
- Is crossfade a requirement?
- Minimum macOS version target.
- Is it acceptable to ship with Option C as the AirPlay path if per-app routing proves unsupported for custom renderers?

## Sources

- Apple: Supporting AirPlay in your app. https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app
- Apple sample: Playing custom audio with your own player. https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player
- Apple: AVRoutePickerView. https://developer.apple.com/documentation/avkit/avroutepickerview
- Apple: AVRoutePickerView.player (macOS only). https://developer.apple.com/documentation/avkit/avroutepickerview/player
- WWDC17 509, Introducing AirPlay 2 (transcript). https://nonstrict.eu/wwdcindex/wwdc2017/509/
- WWDC23 10238, Tune up your AirPlay audio experience. https://developer.apple.com/videos/play/wwdc2023/10238/
- Apple Developer Forums: AVRoutePickerView player property (macOS). https://developer.apple.com/forums/thread/708248
- Apple Developer Forums: AirPlay 2 with multiple instances of AVPlayer. https://developer.apple.com/forums/thread/105877
- Swift Package Index build logs showing `AVAudioSession` unavailable in macOS (Xcode 26.4 SDK). https://swiftpackageindex.com/builds/653D2D04-85F9-4411-A481-80A7CC3D5DD2
