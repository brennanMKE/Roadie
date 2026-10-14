# Tests in a Tart VM

SkinAmp is built and tested inside a disposable macOS VM, never on the host. That covers package
tests, app builds, launching the app, and later the XCUITests. The VM also has no audio path to the
host, so nothing a test does can reach the speakers. This doc covers why, how to run it, and how a
run works. It is adapted from the host-level runbook, `~/Developer/Homelab/cameron/tart-ui-test-vm.md`,
which records how this approach was proven with Changeover. Check that runbook for anything about
the golden image itself.

## Quick start

```bash
scripts/run-tests-vm.sh            # working tree: SkinKit tests, PlayerKit tests, app build, Info.plist check
scripts/run-tests-vm.sh --launch   # also launch the built app in the guest for 5 s, then quit it
scripts/run-tests-vm.sh --skins "untitled folder"  # copy a folder of .wsz into the guest: runs sampleSkinsAreOk and the skintool report (#0020)
scripts/run-tests-vm.sh --head     # test the last commit instead of the working tree
scripts/run-tests-vm.sh --stress 30         # also loop the real-time gapless test 30 times in the guest (#0055)
scripts/run-tests-vm.sh --stress 30 --load  # same, with four CPU hogs running in the guest
```

A run takes a few minutes: about 15 s to boot, then SwiftPM resolution and the builds, since every
clone starts cold. The summary at the end looks like this:

```
==> PASS  skinkit-tests
==> PASS  playerkit-tests
==> PASS  app-build
==> PASS  app-plist
==> PASS  app-launch
    ** BUILD SUCCEEDED **
    ✔ Test run with 50 tests in 6 suites passed after 0.558 seconds.
    ✔ Test run with 94 tests in 12 suites passed after 1.514 seconds.
    ✔ Test run with 100 tests in 24 suites passed after 4.267 seconds.
    ✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
==> AUDIO  silent: no host 'Starting IO' events during the run
==> Logs: build/vm-tests/<run-id>
```

It exits non-zero if any step fails, or if the host's audio daemon started output during the run.
The logs for each step, plus the guest's audio device list, are in `build/vm-tests/<run-id>/`
(gitignored). This is the verification command for issue work; see `issues/Issues.md`.

## Why a VM

`XCTAutomationSupport` loads into *other* running GUI apps on the machine running the tests. On
cameron it once segfaulted Batty and killed about 38 terminal sessions, so UI tests are banned from
the host. A macOS guest has its own WindowServer, its own apps and its own TCC database, so whatever
the test runner loads stays inside the guest. On the host, the only new processes are `tart` and
Virtualization.framework's VM service.

The same isolation is worth having for everything else. Test runs on the host played audible tones
through cameron's speaker (#0046), and a launched app or a crashing test is one more process on a
machine people are working on. Each run uses a fresh clone that is deleted afterwards, so no
permission approvals build up, nothing lingers from an earlier run, and every build starts clean.

## Ground rules

- **Builds, tests and app launches run in the guest.** The host only exports the source and runs
  XcodeGen. Don't run `swift test`, `xcodebuild` or the app on the host to verify a change.
- **No audio.** See [No audio](#no-audio).
- **Never share a live working copy or `$HOME` into the guest read-write.** The guest runs test
  code. The only share is a read-only directory that holds this run's export.
- **Results come back through `tart exec … tar`**, not through the share.
- **No secrets in the guest.** Tests do not use the Plex token, and they never reach `joe`. PlexKit's opt-in integration test skips itself when `PLEX_URL`/`PLEX_TOKEN` are unset, which is always the case in the guest. The plex.tv sign-in tests use hand-written fixtures with a fake PIN code and token; nothing is recorded from the account, and the opener that would launch a browser is a closure. TrackCache's tests download from the `URLProtocol` stub or an in-process stub downloader, and its integration test skips itself the same way.
- **No Keychain in the guest.** Unit tests use `InMemoryPlexTokenStore`; the real `KeychainPlexTokenStore` has an opt-in test (`PLEX_KEYCHAIN_TEST=1`) that only runs on the host by hand. A keychain dialog in the headless guest would hang the run.
- **Never hardcode the image name.** It comes from `tart-golden require`.

## No audio

Three layers keep a run silent, and the script checks the result:

1. **Nothing reaches the host.** The guest boots with `tart run --no-audio`, which cuts audio
   pass-through to the host. The guest still lists an "Apple Virtual Sound Device", but its output
   goes nowhere.
2. **The guest is muted.** Before any step runs, the script sets the guest's output volume to 0 and
   mutes it. `audio-devices.txt` in the run's logs records the device list and the mute state.
3. **The tests are silent anyway.** Most of the suite renders offline (manual rendering mode) and
   never opens an output device. The three real-time tests, opt-in with `AUDIOCORE_REALTIME=1`,
   mute the main mixer. The VM is the one place they are turned on: they play into the guest's
   muted virtual device, which has no path to the host, so the full suite runs and stays silent.

The check: after the run, the script reads the host's log for `coreaudiod` "Starting IO" events
since the run started and fails if there are any. Another app playing sound at the same time also
trips it, so a failure there means "look", not necessarily "the tests did it".

```bash
/usr/bin/log show --last 5m --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"'
```

In zsh, a bare `log` is a shell builtin, so use the full path.

## Host prerequisites

Everything below already exists on cameron and is shared by every project that runs tests there.

| Piece | What it does | Where |
|---|---|---|
| Tart | Clones, boots and runs commands in macOS guests (`brew install cirruslabs/cli/tart`) | Homebrew |
| `tart-golden` | Resolves the one shared golden image and checks its Xcode version | `~/bin`; protocol at `~/Developer/Homelab/protocols/tart-golden/` |
| `tart-lease` | Lets at most two guests run at once, gated on free memory | `~/bin`; protocol at `~/Developer/Homelab/protocols/tart-lease/` |
| memory-signal | Asks the host's observer to free memory (unload LM Studio models) when it is short | `~/Developer/Homelab/protocols/memory-signal/` |
| XcodeGen | Generates `SkinAmp.xcodeproj` into the export on the host | Homebrew |

The shell that runs the script must be in the GUI (Aqua) session with `login.keychain` unlocked.
Otherwise Virtualization.framework refuses to boot a macOS guest, with the misleading error
`Code=-9`, "Failed to create new HostKey". A terminal opened in the logged-in session is fine.

### The golden image

There is one golden image per host, `uitest-golden`, and no project gets its own. As of
2026-10-11, `tart-golden manifest` reports:

| | |
|---|---|
| Image | `uitest-golden` (from `ghcr.io/cirruslabs/macos-tahoe-xcode:27`) |
| Guest macOS | 26.6.2 |
| Guest Xcode | 27.0, at `/Applications/Xcode_27.app` |
| CPU / memory | 6 / 12288 MB |
| Baked in | admin auto-login, Automation Mode without authentication, developer mode, no screen lock, no sleep, SSH logins refused |
| Access | `tart exec` only (Tart Guest Agent) |

SkinAmp targets macOS 14, so the guest's 26.6.2 is fine. Never clone the golden into a
`skinamp-golden`. When SkinAmp needs a newer Xcode, the golden is replaced for every project with
`tart-golden stage` → `validate` → `promote`. That is how seven 68 GB per-project images were
consolidated on 2026-10-11.

## How a run works

`scripts/run-tests-vm.sh`, modelled on Changeover's `run-ui-tests-vm.sh`:

1. **Preflight.** `GOLDEN="$(tart-golden require --xcode 27.0)"`, Tart and XcodeGen present, at
   least 20 GiB free on `/`, and memory checked: the guest needs `GUEST_MEM_MB + 4096` (16 GB). If
   the host is short, the script sends a memory-signal request and waits for the observer.
2. **Sweep stale clones.** A SIGKILL (for example, an OOM kill) skips the `EXIT` trap and leaves a
   clone behind. The sweep only touches names shaped exactly like this script's run IDs,
   `skinamp-test-<YYYYMMDD>-<HHMMSS>-<pid>`. A prefix match once deleted a golden image.
3. **Export a snapshot.** By default, the working tree: tracked files plus untracked files that
   aren't ignored, so a change can be verified before it is committed. With `--head`,
   `git archive HEAD`. Then `xcodegen generate` runs on the host against the export, because
   `SkinAmp.xcodeproj` is gitignored and the guest has no XcodeGen.
4. **Take a slot.** `tart-lease acquire --label skinamp`. If `tart-lease` is missing, the script
   warns and continues; it must never be a reason a run fails.
5. **Clone and boot.** `tart clone`, then
   `tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro &`, polling `tart exec … true`
   for up to 120 s.
6. **Prepare the guest.** Copy `/Volumes/My Shared Files/run/src` to `~/src`, mute the output, and
   record the audio devices.
7. **Steps.** Each runs in the guest with its output teed to a log: SkinKit tests, PlayerKit tests
   (with `AUDIOCORE_REALTIME=1`, so the real-time tests run too), the Debug app build, the Info.plist check of the built app, and with `--launch`, opening the app, checking
   it is still running after 5 s, and quitting it. With `--stress N` a `playerkit-stress` step follows
   the PlayerKit tests: `scripts/stress-realtime-gapless.sh` repeats the real-time gapless test N times
   against the built binary (`--load` adds four `yes` hogs, killed by an `EXIT` trap) and prints
   `stress: <fails>/<N> failed`; it also saves the guest's CoreAudio log as `guest-coreaudio.log`. `set -o pipefail` is set **inside the guest's
   shell**; without it the status is `tee`'s, which is always 0. Changeover reported false passes
   that way until 2026-10-04.
8. **Pull results** with `tart exec … tar -cf - . | tar -x`, into `build/vm-tests/<run-id>/`.
9. **Check the host's audio log**, then print the summary.
10. **Clean up in the `EXIT` trap.** Release the lease first, so a waiting run starts sooner, then
    the memory-signal request; `tart stop` and `tart delete` the clone; `rm -rf` the export.

Run it in the foreground of a terminal. A dropped session costs a clone, not a work session.

## UI tests (not built yet)

The XCUITests will run the same way, as a further step in the guest:

```bash
xcodebuild -project SkinAmp.xcodeproj -scheme 'SkinAmp UI Tests' \
  -destination 'platform=macOS' -resultBundlePath ~/results/UITests.xcresult test
```

The `SkinAmp` scheme's Test action holds unit tests only. UI tests go in a separate scheme,
`SkinAmp UI Tests`, that only the VM script runs. A passing UI run also needs:

- No prompt appeared in the guest. A blocking prompt shows up as a timeout, not a pass.
- No new crash reports on the host (`ls -lt ~/Library/Logs/DiagnosticReports | head` before and
  after), and the host's GUI apps were not restarted (`lsappinfo list` ASNs unchanged).

Test design for a headless, silent guest:

- **No Plex.** The guest is on Tart's NAT network and *can* reach the LAN, so isolation has to come
  from the app. Launch with an argument such as `-UITestStubPlex YES` that swaps in the
  `URLProtocol` stub and recorded JSON fixtures from PlexKit's unit tests. No token is passed in.
- **No user skins or music.** `Skins/`, `*.wsz` and `*.mp3` are gitignored, and third-party skins
  are never committed. Commit a small skin made for the project (or generate one at test time) plus
  a few seconds of generated audio, and pass their paths in through launch arguments.
- **No sound.** Even muted, the app shouldn't drive a real output device under UI tests. Add a
  launch argument that runs the engine in manual rendering mode, and assert on player state (time
  display, play indicator, analyzer data) rather than on sound.
- **Skinned windows are borderless.** XCUITest finds them through accessibility, so give every
  sprite button, slider and display an `accessibilityIdentifier`. Don't rely on coordinates.
- **Screenshots** from `XCTAttachment` land in the result bundle, which is the main way to see the
  skin rendering a headless run produced. Compare against `skintool --png` output (#0026).

## Debugging a run

- To keep a failed clone, comment out the `tart delete` in `cleanup`, then `tart exec <clone> …` to
  look around. Delete it by hand afterwards; a kept clone still counts against the two-guest limit.
- To see the guest's screen, `tart run <clone> --no-audio` without `--no-graphics`. Memory is the
  constraint on cameron: an idle VM opened with graphics was OOM-killed after about an hour on
  2026-09-12.
- SSH is deliberately refused in the golden image. Use `tart exec`.
- `[DisplayManager] Could not find any displays containing rect` in a log is expected in a headless
  guest.

## Known limits

- Apple allows at most two macOS guests per host, and they are shared with every other project on
  cameron. `tart-lease status` shows who holds them.
- A run takes 6 CPUs and 12 GB while it lasts. Interactive work on the host will notice during the
  build.
- Disk, not memory, is usually what runs out first. The script refuses to start below 20 GiB free.
- Every clone resolves SwiftPM packages from the network (ZIPFoundation), so a run needs internet.
- On the host, the real-time tests stay off. Run them through the VM, where they are silent.
- The guest's GPU is paravirtualized. Fine for 2D sprite rendering; don't use it for visualizer
  performance numbers.
