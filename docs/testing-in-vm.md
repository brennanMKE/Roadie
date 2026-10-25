# Tests in a Tart VM

Roadie is built and tested inside a disposable macOS VM, never on the host. That covers package
tests, app builds, launching the app, and later the XCUITests. The VM also has no audio path to the
host, so nothing a test does can reach the speakers. This doc covers why, how to run it, and how a
run works. It is adapted from the host-level runbook, `~/Developer/Homelab/cameron/tart-ui-test-vm.md`,
which records how this approach was proven with Changeover. Check that runbook for anything about
the golden image itself.

## Quick start

Agents call `scripts/verify.sh` with the same options instead. It keeps the run's full output out of
their context: it goes to `build/vm-tests/<run-id>/run.out`, and the agent sees a five-line pass report or
the filtered failure lines (failing steps, compiler errors, failing tests with their `↳` values, crashes).
`--expect testA,testB` fails the run unless those tests ran and passed. Exit codes are the run's; INFRA (3)
is retried once. `--expect-fail testA` is the reverse, for a bug fix's regression test: the run
passes only if those tests ran and failed and nothing else did. Recipe: write the test, run
`--expect-fail` it (proves it fails before the fix), fix the code, run `--expect` it; quote both reports.

```bash
scripts/verify.sh --expect newTestName       # what agents run: the fast tier, reported in a few lines
scripts/verify.sh --expect-fail newTestName  # bug fix, before the fix: passes only if that test (and nothing else) fails
scripts/run-tests-vm.sh            # fast tier: SkinKit tests, PlayerKit tests, app build, app unit tests (RoadieTests), Info.plist check (slow tests skipped)
scripts/run-tests-vm.sh --build-only   # compile check only: both packages with their tests, then the app; no tests run, not verification
scripts/run-tests-vm.sh --full     # full tier: also the 100k SkinLibrary scale tests and the real-time audio tests (milestone end, or a change they guard)
scripts/run-tests-vm.sh --launch   # also launch the built app in the guest for 5 s (with -firstRunVersion 1, so no Welcome window), then quit it
scripts/run-tests-vm.sh --skins "untitled folder"  # copy a folder of .wsz into the guest: runs sampleSkinsAreOk and the skintool report (#0020)
scripts/fetch-webamp-references.sh "untitled folder"   # host, once: public Webamp screenshots into build/webamp-reference (#0026)
scripts/run-tests-vm.sh --skins "untitled folder" --references build/webamp-reference  # also diff each skin's skintool --png render against them
scripts/run-tests-vm.sh --spike    # also build, test and smoke-launch the AirPlay routing spike harness (#0050); never plays
scripts/run-tests-vm.sh --dmg      # also a Release build, back in release/: Roadie.app.zip, Roadie.app.dSYM.zip, dsym-uuids.txt (dwarfdump --uuid), build.txt, sparkle-bin/{sign_update,generate_keys}; then steps app-release-plist (check-info-plist.sh --release) and app-sparkle (check-sparkle.sh), see docs/sparkle.md
scripts/run-tests-vm.sh --dmg --build-number 20261023.1200   # set the Release CFBundleVersion (YYYYMMDD.HHMM, UTC; default: now)
scripts/run-tests-vm.sh --head     # test the last commit instead of the working tree
scripts/run-tests-vm.sh --stress 30         # also loop the real-time gapless test 30 times in the guest (#0055)
scripts/run-tests-vm.sh --stress 30 --load  # same, with four CPU hogs running in the guest
scripts/run-tests-vm.sh --stress 200 --stress-filter 'ClientConnectionTests/pingIsSentEveryIntervalWhileConnected'  # loop another single test instead (#0083)
scripts/run-tests-vm.sh --stress 50 --stress-filter 'SkinThumbnailCacheTests' --stress-package SkinKit --load  # loop SkinKit tests instead (#0094)
scripts/run-tests-vm.sh --corpus ~/Skins/museum                      # every skin under the folder through `skintool corpus` in the guest (#0038)
scripts/run-tests-vm.sh --corpus ~/Skins/museum --corpus-sample 1000 # the fast loop: a seeded sample of 1000 unique skins
```

A run takes a few minutes: about 15 s to boot, then SwiftPM resolution and the builds, since every
clone starts cold. The summary at the end looks like this:

```
==> PASS  skinkit-build
==> PASS  playerkit-build
==> PASS  app-build
==> PASS  skinkit-tests
==> PASS  playerkit-tests
==> PASS  app-unit-tests
==> PASS  app-plist
==> PASS  app-entitlements
==> PASS  app-quicklook
==> PASS  app-launch
==> TIER  fast: 100k scale and real-time audio tests skipped (scripts/run-tests-vm.sh --full runs them)
    Build complete! (15.35 sec)
    Build complete! (23.01 sec)
    ** TEST BUILD SUCCEEDED **
    ✔ Test run with 50 tests in 6 suites passed after 0.558 seconds.
    ✔ Test run with 94 tests in 12 suites passed after 1.514 seconds.
    ✔ Test run with 100 tests in 24 suites passed after 4.267 seconds.
    ✔ Test run with 5 tests in 1 suite passed after 0.001 seconds.
    Executed 8 tests, with 0 failures (0 unexpected) in 0.052 (0.060) seconds
==> AUDIO  silent: no host 'Starting IO' events during the run
==> Logs: build/vm-tests/<run-id>
==> Cleaning up (exit 0)
==> Summary: build/vm-tests/<run-id>/summary.txt
```

When something does not compile, the run stops after the build stage and prints the errors:

```
==> PASS  skinkit-build
==> FAIL  playerkit-build (exit 1)
==> SKIP  app-build (build failed)
==> SKIP  skinkit-tests (build failed)
==> SKIP  playerkit-tests (build failed)
==> SKIP  app-unit-tests (build failed)
==> SKIP  app-plist (build failed)
==> SKIP  app-entitlements (build failed)
==> SKIP  app-quicklook (build failed)
==> BUILD  failed: 7 step(s) skipped; fix the errors below and rerun
==> ERRORS  1 compiler error(s) (first 30; full logs: playerkit-build.log)
    Packages/PlayerKit/Sources/MusicBackendKit/Example.swift:12:9: error: cannot find 'foo' in scope
```

A run with `SKIP` lines is a failed run. `--build-only` stops after the build stage; it is a
compile check before a complete run, never verification.

If the guest goes away mid-run (the VM stopped, or `tart exec` lost its transport), the step it was
in is reported as lost and the rest are skipped, with no compiler-error block:

```
==> FAIL  skinkit-build (guest lost)
==> SKIP  playerkit-build (guest lost)
==> SKIP  app-build (guest lost)
==> INFRA  guest lost during skinkit-build: the VM stopped or tart exec lost its transport; not a build or test failure -- rerun
```

An `INFRA` line (exit 3) means the VM went away, not the code: rerun rather than looking for a
compile error.

It exits non-zero if any step fails, or if the host's audio daemon started output during the run.
Exit codes: `0` everything passed and silent; `1` a build/test/check step failed, the host audio
check tripped, or a preflight check failed; `2` bad arguments; `3` infrastructure (the guest didn't
boot or was lost mid-run), rerun.
Every run that prints a summary (a pass, a failure, a build failure, `INFRA`) also writes it, exactly
as printed and ending with `Cleaning up (exit N)`, to `build/vm-tests/<run-id>/summary.txt`, and the
last line of the output names that file. Quote from it; never re-run only to see the summary again.
Bad arguments (exit 2) and preflight failures (exit 1, `!!` on stderr) happen before a run starts
and write no file.
The logs for each step, plus the guest's audio device list, are in `build/vm-tests/<run-id>/`
(gitignored). This is the verification command for issue work; see `issues/Issues.md`.

## Test tiers

- **Fast tier** (the default, `scripts/run-tests-vm.sh`): every step, but the slow tests skip
  themselves. Plain `swift test` on its own is also the fast tier, since both gates are off.
- **Full tier** (`scripts/run-tests-vm.sh --full`): the fast tier plus the slow tests, turned on by
  two env gates: `ROADIE_SLOW_TESTS=1` on the SkinKit and PlayerKit steps (the three 100k SkinLibrary tests (`SkinIndexScaleTests`, `SkinSearchBudgetTests`) and the fixture-corpus decode, `AudioFixtureDecodeTests.fixtureCorpusDecodesEndToEnd`) and
  `AUDIOCORE_REALTIME=1` on the PlayerKit step (the six real-time AudioCore tests, muted).

Phases 2 and 3 of an issue run the fast tier, and the full tier too when the change touches code a
slow test guards; at the end of each milestone the orchestrator runs the full tier once. See
[issues/Issues.md](../issues/Issues.md) ("Build / verify command"). The summary's `TIER` line says
which tier ran, and `tier.txt` in the run's logs records it. In a fast run the slow tests still
show by name, as `➜ Test <name>() skipped.` lines in `skinkit-tests.log` and `playerkit-tests.log`.

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
- **The corpus share is read-only and never enters git or the export.** `--corpus DIR` (#0038) adds a second named virtio-fs share (`--dir=corpus:DIR:ro`, mounted at `/Volumes/My Shared Files/corpus`); the guest copies it to `~/corpus` when the disk has the corpus size plus 2 GiB free (else it reads in place and `env.json` says so) before anything is timed. Steps `corpus-run` (`scripts/run-skin-corpus.sh`: release build of `skintool`, `skintool corpus --resume` restarted after a crash, hang or memory abort) and `corpus-report` (`skintool corpus-report`, prints `corpus:` and `gate:` lines and fails the step when the gate fails) follow the normal steps; `results.jsonl`, `report.md`, `summary.json`, `env.json`, `corpus-stderr.log` and `crashes/` come back in `build/vm-tests/<run-id>/corpus/`. The full ~103k-skin set is roughly 10-20 minutes of parsing plus the copy and the release build, and holds the VM lease the whole time.
- **Results come back through `tart exec … tar`**, not through the share.
- **No secrets in the guest.** Tests don't use any server token. `MusicAssistantIntegrationTests` is opt-in (`MA_URL`/`MA_TOKEN`) and skips itself in the guest, where those are never set.
- **No Keychain in the guest.** Unit tests use `InMemoryMusicAssistantTokenStore`; `KeychainMusicAssistantTokenStore` is never exercised in the guest. A keychain dialog in the headless guest would hang the run.
- **Never hardcode the image name.** It comes from `tart-golden require`.

## No audio

Three layers keep a run silent, and the script checks the result:

1. **Nothing reaches the host.** The guest boots with `tart run --no-audio`, which cuts audio
   pass-through to the host. The guest still lists an "Apple Virtual Sound Device", but its output
   goes nowhere.
2. **The guest is muted.** Before any step runs, the script sets the guest's output volume to 0 and
   mutes it. `audio-devices.txt` in the run's logs records the device list and the mute state.
3. **The tests are silent anyway.** Most of the suite renders offline (manual rendering mode) and
   never opens an output device. The real-time tests (six, in `MixedFormatRealtimeTests`,
   `ProgressiveRealtimeTests`, `OutputDeviceRealtimeTests` and `NowPlayingTests`) are opt-in with
   `AUDIOCORE_REALTIME=1` and mute the main mixer. The VM's full tier (`--full`) is the one place
   they are turned on: they play into the guest's muted virtual device, which has no path to the
   host, so they stay silent.

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
| XcodeGen | Generates `Roadie.xcodeproj` into the export on the host | Homebrew |

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

Roadie targets macOS 14, so the guest's 26.6.2 is fine. Never clone the golden into a
`roadie-golden`. When Roadie needs a newer Xcode, the golden is replaced for every project with
`tart-golden stage` → `validate` → `promote`. That is how seven 68 GB per-project images were
consolidated on 2026-10-11.

## How a run works

`scripts/run-tests-vm.sh`, modelled on Changeover's `run-ui-tests-vm.sh`:

1. **Preflight.** `GOLDEN="$(tart-golden require --xcode 27.0)"`, Tart and XcodeGen present, at
   least 20 GiB free on `/`, and memory checked: the guest needs `GUEST_MEM_MB + 4096` (16 GB). If
   the host is short, the script sends a memory-signal request and waits for the observer.
2. **Sweep stale clones.** A SIGKILL (for example, an OOM kill) skips the `EXIT` trap and leaves a
   clone behind. The sweep removes `roadie-test-<YYYYMMDD>-<HHMMSS>-<pid>` clones whose `<pid>`
   is no longer a live `run-tests-vm.sh` process, or whose run id is older than 8 h. Clones of a
   live run (another agent's concurrent run) are left alone, and nothing outside that exact name
   shape is ever touched. A prefix match once deleted a golden image.
3. **Export a snapshot.** By default, the working tree: tracked files plus untracked files that
   aren't ignored, so a change can be verified before it is committed. With `--head`,
   `git archive HEAD`. Then `xcodegen generate` runs on the host against the export, because
   `Roadie.xcodeproj` is gitignored and the guest has no XcodeGen.
4. **Take a slot.** `tart-lease acquire --label roadie`. If `tart-lease` is missing, the script
   warns and continues; it must never be a reason a run fails.
5. **Clone and boot.** `tart clone`, then
   `tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro &`, polling `tart exec … true`
   for up to 120 s.
6. **Prepare the guest.** Copy `/Volumes/My Shared Files/run/src` to `~/src`, mute the output, and
   record the audio devices.
7. **Steps.** Each runs in the guest with its output teed to a log. **Build stage**: `swift build --build-tests` for SkinKit and PlayerKit, then the Debug app build (and with `--spike` the spike's package and app). If any fails, the steps after it are marked `SKIP` without running, and the summary prints the `file:line:col: error:` lines from the build logs. Then the tests, with `swift test --skip-build` against those builds: SkinKit tests, PlayerKit tests
   (with `--full`, `AUDIOCORE_REALTIME=1` so the real-time tests run too, and `ROADIE_SLOW_TESTS=1` on the SkinKit and PlayerKit steps for the scale tests and the fixture-corpus decode), the Info.plist check of the built app, `app-quicklook` (#0043: `scripts/check-quicklook.sh` registers the embedded Quick Look extensions with Launch Services and `pluginkit`, generates a test `.wsz` with `scripts/make-test-skin.swift`, asks `QLThumbnailGenerator` (`scripts/ql-thumb.swift`; `qlmanage -t` hangs in the headless guest for extension-provided types, so it is informational only) for thumbnails of it and of a corrupt and a modern skin, samples the thumbnail with `scripts/pixel-at.swift`, and runs `qlmanage -p` to start the preview extension, and prints `quicklook: <check> ok|FAIL` lines; its files, including the PNGs, come back in `build/vm-tests/<run-id>/ql/`), and with `--launch`, opening the app, checking
   it is still running after 5 s, and quitting it. With `--skins` a `skintool-png` step follows `skintool`:
   it renders every skin's main window headless to `build/vm-tests/<run-id>/png/<name>.png`, and with
   `--references DIR` (the host-fetched Webamp screenshots, copied into the export's `Skins/reference/`;
   the guest has no network) also writes `<name>.diff.png` and prints one `diff` or `noref` line per skin
   (also in the terminal summary). The numbers are documented in [skin-comparison.md](skin-comparison.md), never gated. With `--stress N` a `playerkit-stress` step follows
   the PlayerKit tests: `scripts/stress-realtime-gapless.sh` repeats the real-time gapless test N times
   (or, with `--stress-filter F`, the tests matching the `swift test --filter` F, without `AUDIOCORE_REALTIME=1`; #0083; with `--stress-package SkinKit` it tests SkinKit and the step is `skinkit-stress`, #0094)
   against the built binary (`--load` adds four `yes` hogs, killed by an `EXIT` trap) and prints
   `stress: <fails>/<N> failed`; it also saves the guest's CoreAudio log as `guest-coreaudio.log`. `set -o pipefail` is set **inside the guest's
   shell**; without it the status is `tee`'s, which is always 0. Changeover reported false passes
   that way until 2026-10-04.
8. **Pull results** with `tart exec … tar -cf - . | tar -x`, into `build/vm-tests/<run-id>/`.
9. **Check the host's audio log**, then print the summary and write it to `summary.txt`.
10. **Clean up in the `EXIT` trap.** Release the lease first, so a waiting run starts sooner, then
    the memory-signal request; `tart stop` and `tart delete` the clone; `rm -rf` the export.
    The last line printed is `==> Summary: <path>`.

Run it in the foreground of a terminal. A dropped session costs a clone, not a work session.

## UI tests (not built yet)

The XCUITests will run the same way, as a further step in the guest:

```bash
xcodebuild -project Roadie.xcodeproj -scheme 'Roadie UI Tests' \
  -destination 'platform=macOS' -resultBundlePath ~/results/UITests.xcresult test
```

The `Roadie` scheme's Test action holds unit tests only. UI tests go in a separate scheme,
`Roadie UI Tests`, that only the VM script runs. A passing UI run also needs:

- No prompt appeared in the guest. A blocking prompt shows up as a timeout, not a pass.
- No new crash reports on the host (`ls -lt ~/Library/Logs/DiagnosticReports | head` before and
  after), and the host's GUI apps were not restarted (`lsappinfo list` ASNs unchanged).

Test design for a headless, silent guest:

- **No Music Assistant server.** The guest is on Tart's NAT network and *can* reach the LAN, so isolation has to
  come from the app. Launch with an argument such as `-UITestStubMusicAssistant YES` (when UI tests exist) that
  swaps in `MusicAssistantKitStub`'s scripted transports and #0060's fixtures. No token is passed in.
- **No user skins or music.** `Skins/`, `*.wsz` and `*.mp3` are gitignored, and third-party skins
  are never committed. Commit a small skin made for the project (or generate one at test time) plus
  a few seconds of generated audio, and pass their paths in through launch arguments.
- **No sound.** Even muted, the app shouldn't drive a real output device under UI tests. Add a
  launch argument that runs the engine in manual rendering mode, and assert on player state (time
  display, play indicator, analyzer data) rather than on sound.
- **Test skins** (#0198). The UI tests use seven real Museum skins listed in `scripts/test-skins.tsv`
  (name, Museum id, md5, why). Fetch them once on the host with `scripts/fetch-test-skins.sh` into
  `~/Library/Caches/co.sstools.roadie-test-skins` (`--cache DIR` to change it); later runs say `ok (cached)` and
  download nothing. `scripts/fetch-test-skins.sh --check` reports `ok|missing|bad-md5` per skin without downloading.
  `run-tests-vm.sh --ui --test-skins DIR` checks the cache and copies it into the export's `TestSkins/`; the skins
  are never committed.
- **Skinned windows are borderless.** XCUITest finds them through accessibility, so give every
  sprite button, slider and display an `accessibilityIdentifier`. Don't rely on coordinates.
- **Screenshots** from `XCTAttachment` land in the result bundle, which is the main way to see the
  skin rendering a headless run produced. Compare against `skintool --png` output (#0026).

## Debugging a run

- To keep a failed clone, comment out the `tart delete` in `cleanup`, then `tart exec <clone> …` to
  look around. Delete it by hand afterwards; a kept clone still counts against the two-guest limit.
  The next run sweeps it once its run has exited; to keep it longer, `tart rename` it to a name
  outside the pattern (e.g. `roadie-keep-<id>`) and delete it by hand later.
- To see the guest's screen, `tart run <clone> --no-audio` without `--no-graphics`. Memory is the
  constraint on cameron: an idle VM opened with graphics was OOM-killed after about an hour on
  2026-09-12.
- SSH is deliberately refused in the golden image. Use `tart exec`.
- `[DisplayManager] Could not find any displays containing rect` in a log is expected in a headless
  guest.

## Known limits

- Apple allows at most two macOS guests per host, and they are shared with every other project on
  cameron. `tart-lease status` shows who holds them. Two runs at once are fine; a third waits for
  a slot.
- A run takes 6 CPUs and 12 GB while it lasts. Interactive work on the host will notice during the
  build.
- Disk, not memory, is usually what runs out first. The script refuses to start below 20 GiB free.
- Every clone resolves SwiftPM packages from the network (ZIPFoundation), so a run needs internet.
- On the host, the real-time and scale tests stay off; run them through the VM's full tier, where they are silent.
- The guest's GPU is paravirtualized. Fine for 2D sprite rendering; don't use it for visualizer
  performance numbers.
