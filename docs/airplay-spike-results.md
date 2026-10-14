# AirPlay routing spike results (#0050)

Results of the Phase 0 spike from [airplay-macos-handoff.md](airplay-macos-handoff.md): which macOS playback stacks can be routed per app to AirPlay 2 speakers (HomePods), and what that costs. The harness is `Spikes/AirPlaySpike/`; the hand-test protocol is in [issue #0050](../issues/0050.md) section 6. Every hand-test cell below is `untested` until the user has run it.

## Environment

| | |
|---|---|
| Host macOS | tbd |
| Xcode / SDK | Xcode 27.0, MacOSX27.0.sdk (SDK facts below were read from the SDK) |
| HomePod model(s) | tbd |
| HomePod software | tbd |
| Test files | tbd (the generated tick file unless noted) |

## How to run the harness

On the host, by the user (subagents never build or play on the host):

```bash
xcodegen generate --spec Spikes/AirPlaySpike/project.yml
open Spikes/AirPlaySpike/AirPlaySpike.xcodeproj      # run the AirPlaySpike scheme
/usr/bin/log stream --predicate 'subsystem == "com.brennanmke.AirPlaySpike"' --style compact
```

The app writes `~/Library/Logs/AirPlaySpike/spike-<timestamp>.log` (override with `--log-dir <path>`) and the 120 s tick file to `~/Library/Application Support/AirPlaySpike/tick-120s.wav`. The Info.plist carries `AVInitialRouteSharingPolicy = LongFormAudio` (the key under test). `--smoke` constructs every engine without playing and exits; the VM uses it (`scripts/run-tests-vm.sh --spike`).

The five engines:

- **A**: `AVQueuePlayer` with one item per file; the route picker's `player` is set to it. The documented macOS path.
- **A′**: the same player, but `picker.player` is nil. Tests whether the picker is needed at all or the system route follows the app.
- **A+tap**: A with an `MTAudioProcessingTap` (pre-effects) doing a gain and an RMS. Its processed PTS minus `currentTime` is the only requested-ahead number on the player side. Tests that a tap does not break routing and when it runs relative to audible output.
- **B**: `AVSampleBufferAudioRenderer` on an `AVSampleBufferRenderSynchronizer`, fed interleaved Float32 PCM, picker `player` nil. The written docs say renderer routing is iOS and tvOS only; this tests macOS.
- **B-dev**: B with `audioOutputDeviceUniqueID` set to the HomePod's CoreAudio device UID, picker not involved. The per-app, no-enhanced-buffering fallback.

## SDK findings

Read from the installed SDK (host: Xcode 27.0, MacOSX27.0.sdk). `Spikes/AirPlaySpike/check-sdk.sh` repeats the grep; its output from the VM guest's SDK is quoted in issue #0050 Verification.

- `AVFAudio/AVAudioSession.h`: every member, including `-setCategory:mode:routeSharingPolicy:options:error:` and `routeSharingPolicy`, is `API_UNAVAILABLE(macos)`. No ObjC-only path exists, so no shim is possible; on macOS, long-form identification is the Info.plist key or nothing.
- `AVFAudio/AVAudioSessionTypes.h`: `AVInitialRouteSharingPolicy` is documented only next to `LongFormVideo`. The `LongFormAudio` policy says it plays "to the same output as the built-in Music (iOS), Podcasts, or iTunes (macOS) applications", so a shared long-form route exists system-side on macOS; whether the plist key opts an app in is the hand test.
- `AVKit/AVRoutePickerView.h`: macOS 10.15+; `player` is macOS-only. The class discussion reads: "Media from an AVPlayer, or from an AVSampleBufferAudioRenderer on iOS and tvOS, can be routed to compatible AirPlay destinations." That is the written case against option B on macOS.
- `AVRouteDetector` is in AVFoundation on macOS (10.13+), not AVKit; `detectsCustomRoutes` is unavailable on macOS.
- `AVSampleBufferAudioRenderer` / `AVSampleBufferRenderSynchronizer`: the classic API (`requestMediaDataWhenReady`, `enqueue`, `flush`, `addRenderer`) is deprecated in macOS 27 in favour of `sampleBufferReceiver()` / `addReceiver(_:)`. The deployment target is 14, so the spike uses the classic API and accepts the warnings.
- `MTAudioProcessingTap` / `audioTapProcessor`: macOS 10.9+. `MPNowPlayingInfoCenter.playbackState`: macOS 10.12.2+.

## Results

The table is `ResultsSheet().markdown()` (a test keeps this file in step with the code). Fill a cell with `yes`, `no`, `n/a` or a short value.

| Check | A: AVQueuePlayer, picker.player set | A′: picker.player nil | A+tap | B: renderer+synchronizer, picker nil | B-dev: renderer to CoreAudio AirPlay device |
|---|---|---|---|---|---|
| Picker lists HomePods, multi-select | untested | untested | untested | untested | untested |
| Long-form plist key honored | untested | untested | untested | untested | untested |
| Moves off the Mac with one HomePod | untested | untested | untested | untested | untested |
| Other system audio stays local | untested | untested | untested | untested | untested |
| Two HomePods in sync | untested | untested | untested | untested | untested |
| Requested ahead, local vs AirPlay | untested | untested | untested | untested | untested |
| Survives 10 s Wi-Fi off | untested | untested | untested | untested | untested |
| Remote commands reach MPRemoteCommandCenter | untested | untested | untested | untested | untested |
| Tap timing vs audible output | untested | untested | untested | untested | untested |
| Clock includes AirPlay latency | untested | untested | untested | untested | untested |
| Volume mapping | untested | untested | untested | untested | untested |
| Pause, seek, next, quit | untested | untested | untested | untested | untested |

### Picker UI

| # | Question | Result |
|---|---|---|
| P1 | `multipleRoutesDetected` with the HomePods powered on | untested |
| P2 | HomePods listed; multi-select (Music.app style) or single-choice; Mac listed | untested |
| P3 | "Present picker" finds and clicks the picker's `NSButton` (`picker button: found` or `missing`); same menu opens | untested |
| P4 | Local-network permission prompt shown | untested |

### Remote commands

Which of play / pause / togglePlayPause / next / previous / changePlaybackPosition reached `MPRemoteCommandCenter` from a HomePod touch and from "Hey Siri, pause": untested. Home app shows the Now Playing title: untested.

## Recommendation

Pending the hand test in #0050 section 6.
