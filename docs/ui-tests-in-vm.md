# UI tests in the Tart VM

How Roadie's XCUITests (M16, #0200 onward) run safely on cameron. The general VM setup (export, clone, lease,
results, audio) is in [testing-in-vm.md](testing-in-vm.md); this page covers what is specific to UI tests.

Source: `~/Developer/Homelab/cameron/tart-ui-test-vm.md` (the cameron VM setup, written for Changeover and now
shared by every project on cameron). Facts below were checked against it and against `tart-golden manifest`
on 2026-10-24.

## Why UI tests only ever run in a guest

XCUITest loads `XCTAutomationSupport` into **other running GUI apps** in the same login session. On cameron that
once segfaulted Batty and killed about 38 terminal sessions, so UI tests are banned from cameron's host.

A guest is a separate macOS with its own WindowServer, apps and TCC database. `XCTAutomationSupport` loads into
processes in the *guest's* GUI session. On the host the only new processes are `tart` and Virtualization.framework's
VM service, which the test runner can't attach to. Destroying the guest after every run also means no prompt
approvals pile up.

Rules that follow:

- **Never run the UI tests on the host.** Not `xcodebuild test` with the UI scheme, not ⌘U in Xcode with it
  selected. The `Roadie` scheme's Test action holds unit tests only (`RoadieTests` and the packages). UI tests
  live in their own target and scheme (`RoadieUITests`, `Roadie UI Tests`), which only `run-tests-vm.sh --ui`
  invokes, inside the guest.
- **Change nothing on the host's security state** for UI tests: no Automation Mode, no `DevToolsSecurity`, no TCC
  grants. All of that is baked into the golden image.
- **Never share a live working copy or `$HOME` into the guest read-write.** The guest runs test code. Shares are
  read-only and point at the per-run export (`--dir=run:$EXPORT:ro`); results come back through `tart exec … tar`.

## What the golden image already has

`tart-golden manifest` (validated 2026-10-11): image `uitest-golden`, from `ghcr.io/cirruslabs/macos-tahoe-xcode:27`,
guest macOS 26.6.2, Xcode 27.0 at `/Applications/Xcode_27.app`, 6 CPUs / 12288 MB.

Baked in, and verified across a reboot in the Homelab doc:

| Setting | Why a UI test needs it |
|---|---|
| `admin` auto-login (`stat -f %Su /dev/console` → `admin`) | XCUITest needs a logged-in GUI session |
| Automation Mode enabling **without authentication** | otherwise the first test blocks on an auth prompt |
| Developer mode (`DevToolsSecurity`) enabled | lets `testmanagerd` attach to the app |
| No screen lock, screensaver `idleTime` 0, `pmset` sleeps 0 | a locked or sleeping guest can't be driven |
| SSH logins refused (`com.apple.access_ssh` emptied) | `admin`/`admin` isn't an open login on the VM network; use `tart exec` |

Roadie never builds its own golden (`roadie-golden` must not exist) and never hardcodes the name: the script runs
`tart-golden require --xcode 27.0`. A newer Xcode means replacing the shared golden for every project with
`tart-golden stage` → `validate` → `promote`. Check the registry's tag list first; tags track the Xcode version, so
a tag that already carries the wanted Xcode needs no copy-in.

### Reading the permission checks correctly

If a run times out on a suspected prompt, check the golden (on a kept clone) with:

```bash
tart exec <clone> automationmodetool          # prints TWO facts
tart exec <clone> DevToolsSecurity -status
tart exec <clone> sysadminctl -screenLock status
tart exec <clone> stat -f %Su /dev/console    # must be admin
```

- `automationmodetool` prints the current mode *and* whether enabling it needs authentication. "Automation Mode is
  disabled" is normal. **The line that matters says authentication is not required.** Misreading this made an
  earlier result inconclusive.
- Never run `DevToolsSecurity` with no arguments: it tries to change an authorization right instead of printing usage.
- `sudo automationmodetool enable-automationmode-without-authentication` may print "Enter the password for user
  'root':" and still succeed (sudo is passwordless in the guest). It isn't hanging.

A real fix to the golden is a `tart-golden` change for every project, recorded in the Homelab doc, never a
per-run workaround in Roadie's scripts.

## How a UI run differs from a unit-test run

The flow is `run-tests-vm.sh`'s (export → `tart-lease` → clone → `tart run --no-graphics --no-audio` → copy
`/Volumes/My Shared Files/run/src` to `~/src` → steps → pull results → delete the clone). A `--ui` run adds:

- **Test skins** from the host cache (`scripts/fetch-test-skins.sh`, #0198) copied into the export's `TestSkins/`.
  The guest has no Museum access during tests and the skins are never committed.
- **Test mode** (#0194): the app launches with `-RoadieUITest 1` and its own data directory, defaults suite,
  scripted Music Assistant (`-RoadieMAScenario`, #0197), no discovery and recorded external opens. The guest is on
  Tart's NAT network and *can* reach cameron's LAN and the real Music Assistant server, so isolation has to come
  from the app's test mode, not the network. Test mode is Debug-only; Release ignores `-RoadieUITest`.
- **A guest-only guard.** Before each launch the harness (`RoadieUIApp.launch`) runs
  `defaults delete co.sstools.roadie` and empties its data directory. On a developer's Mac that would wipe their
  real Roadie preferences, so the harness refuses (the test is skipped, and `launch` fails the test if reached) unless
  both hold: `ROADIE_UI_GUEST=1`, which only `run-tests-vm.sh --ui` sets (as `ROADIE_UI_GUEST` and
  `TEST_RUNNER_ROADIE_UI_GUEST`, like the `ROADIE_TEST_*` paths), and `NSUserName() == "admin"`, the guest's user.
  Setting `ROADIE_TEST_SKINS`/`ROADIE_TEST_MUSIC` by hand on the host isn't enough.
- **A timeout around the UI step** (`timeout 1200` in the guest). A blocking prompt shows up as a hang, never as a
  pass, and a timed-out step reports "a blocked prompt in the guest?".
- **Results:** `UITests.xcresult` with `XCTAttachment` screenshots comes back under `build/vm-tests/<run-id>/ui/`.
  Screenshots are the main way to see what a headless run rendered.

### A UI run passes only if all of these hold

- `** TEST SUCCEEDED **` with the expected test count (the `--expect` list).
- No prompt appeared in the guest (no timeout; test times in line with earlier runs).
- No new crash reports on the host: compare `ls -lt ~/Library/Logs/DiagnosticReports | head` before and after.
- The host's GUI apps weren't restarted: compare `lsappinfo list | grep -E '^ *[0-9]+\) "'` before and after (same
  ASNs). Don't use `pgrep -x <AppName>`; it matches the binary name case-sensitively and misses apps.
- No clone left behind: `tart list` shows no `roadie-test-*`.
- The host stayed silent (`--no-audio`; the script's AUDIO check).

### Expected noise in a headless guest

- `[DisplayManager] Could not find any displays containing rect (inf, inf, 0.0, 0.0)`
- `IDELaunchParametersSnapshot: no debugger version`
- Build-log lines mentioning `XCUIAutomation` / "automation" are framework paths, not prompts.

## Gotchas carried over from the cameron setup

- **Always `--no-audio`.** Without it Tart passes guest audio to the host. Don't use `--suspendable` instead: it
  also changes input devices.
- **Shares don't pass symlinks.** Tart's virtio-fs share fails `ditto` on every symlink ("Too many levels of
  symbolic links"). To bring a tree with symlinks into the guest, archive it on the host (`ditto -c`, which keeps
  symlinks and signatures), share the folder holding the archive and extract in the guest. A share of
  `name:/path` appears as `/Volumes/My Shared Files/name/` and maps the directory itself (an app bundle shows up as
  `name/Contents/…`).
- **Keychain.** Virtualization.framework won't boot a macOS guest unless the host's `login.keychain` is unlocked;
  the error is the misleading `Code=-9`, "Failed to create new HostKey". Run from a terminal in the GUI (Aqua)
  session (`launchctl managername` → `Aqua`).
- **Memory is the constraint.** A guest costs about 15 GB resident and Apple allows two at once (shared with every
  other project through `tart-lease`). An idle VM opened with graphics was OOM-killed after about an hour. A
  SIGKILL skips the cleanup trap, which is why the script sweeps stale `roadie-test-<YYYYMMDD>-<HHMMSS>-<pid>`
  clones and nothing else (a prefix-match sweep once deleted Changeover's golden).
- **Watching a run.** UI tests are headless. To look at the screen, keep the clone and run it with graphics
  (`tart run <clone> --no-audio`), briefly; delete it afterwards.
- **Guest agent drops.** `tart exec` can fail mid-run with "Failed to connect to the VM using its control socket
  … is the Tart Guest Agent running?". That's VM infrastructure, not a test failure (seen 2026-10-24, #0149); rerun.

## Reference timings

Changeover's first full UI run on cameron (4 tests, a menu bar app) took about 90 s clone to delete: boot ~14 s,
build ~30 s, tests ~19 s. Roadie's runs are longer (packages, app, unit tests, then UI tests); record the
`ui-build` and `ui-tests` step times in #0200's notes for the run-time budget (design §8).
