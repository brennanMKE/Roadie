@preconcurrency import AVFoundation
import AVKit
import AppKit
import SpikeKit
import UniformTypeIdentifiers

// Throwaway harness for #0050. One window: engine selector, transport, route picker, status pane.
// `--smoke --log-dir <path>` constructs every engine without playing and exits (the VM check).

@main
enum AirPlaySpikeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AVRoutePickerViewDelegate, NSWindowDelegate {
    private var log = SpikeLog()
    private var smoke = false
    private var window: NSWindow?
    private let picker = AVRoutePickerView()
    private let detector = AVRouteDetector()
    private var engine: (any SpikeEngine)?
    private var remote: RemoteCommandProbe?
    private var urls: [URL] = []
    private var tickURL: URL?
    private var devices: [OutputDevice] = []
    private var selectedDeviceUID: String?
    private var timer: Timer?
    private var lastSecond = -1

    private let engineControl = NSSegmentedControl(labels: EngineKind.allCases.map(\.shortName), trackingMode: .selectOne, target: nil, action: nil)
    private let devicePopup = NSPopUpButton()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let gainSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let statusBox = NSView()
    private var markCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        smoke = args.contains("--smoke")
        if let i = args.firstIndex(of: "--log-dir"), args.indices.contains(i + 1) {
            log = SpikeLog(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
        log.log("-", "launch smoke=\(smoke) log \(log.fileURL.path)")
        buildWindow()
        if smoke {
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { exit(2) }
            runSmoke()
            return
        }
        remote = RemoteCommandProbe(log: log)
        detector.isRouteDetectionEnabled = true
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirPlaySpike", isDirectory: true)
        tickURL = support.appendingPathComponent("tick-120s.wav")
        try? TestTone.write(to: tickURL!)
        refreshDevices()
        selectEngine(.a)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { self.refreshStatus() } }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        detector.isRouteDetectionEnabled = false
        engine?.teardown()
        remote?.tearDown()
        log.log("-", "terminate")
    }

    // MARK: Smoke

    private func runSmoke() {
        let smokeLog = log.directory.appendingPathComponent("smoke.log")
        FileManager.default.createFile(atPath: smokeLog.path, contents: nil)
        func line(_ s: String) {
            log.log("smoke", s)
            if let h = try? FileHandle(forWritingTo: smokeLog), let d = (s + "\n").data(using: .utf8) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: d)
                try? h.close()
            }
        }
        line("picker created, window \(window != nil)")
        detector.isRouteDetectionEnabled = true
        line("detector multipleRoutesDetected \(detector.multipleRoutesDetected)")
        detector.isRouteDetectionEnabled = false
        let tick = log.directory.appendingPathComponent("tick-smoke.wav")
        do { try TestTone.write(to: tick, seconds: 10) } catch { line("error writing tick: \(error)"); exit(1) }
        line("tick file written")
        for kind in EngineKind.allCases {
            let e = EngineFactory.make(kind, log: log)
            do { try e.load([tick]) } catch { line("error load \(kind.shortName): \(error)"); exit(1) }
            e.attach(to: picker)
            let probe = e.probe().map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            line("probe \(kind.shortName): \(probe)")
            e.detach()
            e.teardown()
        }
        line("smoke: ok (\(EngineKind.allCases.count) engines)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    // MARK: Window

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func buildWindow() {
        picker.isRoutePickerButtonBordered = true
        picker.delegate = self
        engineControl.target = self
        engineControl.action = #selector(engineChanged)
        engineControl.selectedSegment = 0
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        gainSlider.target = self; gainSlider.action = #selector(gainChanged)
        devicePopup.target = self; devicePopup.action = #selector(deviceChanged)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.translatesAutoresizingMaskIntoConstraints = false
        statusBox.wantsLayer = true
        statusBox.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: statusBox.topAnchor, constant: 8),
            status.bottomAnchor.constraint(equalTo: statusBox.bottomAnchor, constant: -8),
        ])

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }
        let top = row([engineControl, button("Open Files\u{2026}", #selector(openFiles)), button("Use tick file", #selector(useTick)), picker, button("Present picker", #selector(presentPicker)), devicePopup])
        let transport = row([
            button("Play", #selector(play)), button("Pause", #selector(pause)), button("Seek +30 s", #selector(seekForward)), button("Next", #selector(next)),
            NSTextField(labelWithString: "Volume"), volumeSlider, NSTextField(labelWithString: "Tap gain"), gainSlider,
            button("Mark", #selector(mark)), button("Snapshot", #selector(snapshot)),
        ])
        let stack = NSStackView(views: [top, transport, statusBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        statusBox.widthAnchor.constraint(equalToConstant: 760).isActive = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "AirPlaySpike"
        w.contentView = stack
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    // MARK: Picker delegate

    nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated { log.log("-", "picker will present routes") }
    }

    nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated { log.log("-", "picker did end presenting routes") }
    }

    // MARK: Actions

    private var kindName: String { engine?.kind.shortName ?? "-" }

    private func selectEngine(_ kind: EngineKind) {
        if let engine { engine.detach(); engine.teardown() }
        let e = EngineFactory.make(kind, log: log, deviceUID: selectedDeviceUID)
        engine = e
        remote?.engine = e
        e.attach(to: picker)
        if !urls.isEmpty { do { try e.load(urls) } catch { log.log(kind.shortName, "load failed: \(error)") } }
        engineControl.selectedSegment = EngineKind.allCases.firstIndex(of: kind) ?? 0
        gainSlider.isEnabled = kind == .aTap
        e.volume = Float(volumeSlider.doubleValue)
        lastSecond = -1
        log.log(kind.shortName, "engine selected")
    }

    @objc private func engineChanged() { selectEngine(EngineKind.allCases[engineControl.selectedSegment]) }

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        urls = panel.urls
        reload()
    }

    @objc private func useTick() {
        guard let tickURL else { return }
        urls = [tickURL]
        reload()
    }

    private func reload() {
        guard let kind = engine?.kind else { return }
        selectEngine(kind)
    }

    @objc private func presentPicker() {
        func findButton(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton { return b }
            for s in v.subviews { if let b = findButton(s) { return b } }
            return nil
        }
        if let b = findButton(picker) {
            log.log(kindName, "picker button: found")
            b.performClick(nil)
        } else {
            log.log(kindName, "picker button: missing")
        }
    }

    @objc private func deviceChanged() {
        let i = devicePopup.indexOfSelectedItem - 1
        selectedDeviceUID = devices.indices.contains(i) ? devices[i].uid : nil
        (engine as? SampleBufferEngine)?.deviceUID = selectedDeviceUID
        log.log(kindName, "device selected: \(selectedDeviceUID ?? "default")")
    }

    private func refreshDevices() {
        devices = CoreAudioOutputs.list()
        devicePopup.removeAllItems()
        devicePopup.addItem(withTitle: "B-dev device: default")
        for d in devices { devicePopup.addItem(withTitle: d.label) }
    }

    @objc private func play() {
        guard let engine else { return }
        if engine.kind == .bDevice { refreshDevices() }
        engine.play()
        publish()
    }
    @objc private func pause() { engine?.pause(); publish() }
    @objc private func seekForward() { engine?.seek(by: 30); publish() }
    @objc private func next() { engine?.next(); publish() }
    @objc private func volumeChanged() {
        engine?.volume = Float(volumeSlider.doubleValue)
        log.log(kindName, "volume \(volumeSlider.doubleValue)")
    }
    @objc private func gainChanged() { (engine as? QueuePlayerEngine)?.tapGain = Float(gainSlider.doubleValue) }
    @objc private func mark() { markCount = log.mark(engine: kindName) }
    @objc private func snapshot() {
        let text = statusText()
        var all = text
        if let engine { all += "\nprobe:\n" + engine.probe().map { "  \($0.0): \($0.1)" }.joined(separator: "\n") }
        log.log(kindName, "SNAPSHOT\n\(all)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(all, forType: .string)
    }

    private func publish() {
        guard let engine else { return }
        remote?.publish(engine: engine, duration: nil)
    }

    // MARK: Status

    private func statusText() -> String {
        guard let engine else { return "no engine" }
        var lines = [
            "engine \(engine.kind.title)",
            String(format: "currentTime %.2f s  rate %.1f", engine.currentTime, engine.rate),
        ]
        if let lead = engine.leadSeconds {
            var meter: LeadMeter?
            if let q = engine as? QueuePlayerEngine { meter = q.leadMeter }
            if let b = engine as? SampleBufferEngine { meter = b.leadMeter }
            let cls = meter?.classification?.rawValue ?? "-"
            lines.append(String(format: "lead %.1f s (%@)  max %.1f s", lead, cls, meter?.max ?? lead))
        } else {
            lines.append("lead n/a")
        }
        lines.append("multipleRoutesDetected \(detector.multipleRoutesDetected)")
        lines.append("default output: \(CoreAudioOutputs.defaultOutputLabel() ?? "?")")
        lines.append("lastCommand \(remote?.lastCommand ?? "none")  playbackState \(remote?.playbackStateText ?? "-")")
        if let q = engine as? QueuePlayerEngine, let t = q.tapSnapshot {
            lines.append(String(format: "tap: PTS end %.2f s  rms %.4f  calls %d  gain %.2f", t.lastProcessedEnd, t.rms, t.processCalls, t.gain))
        }
        if let b = engine as? SampleBufferEngine { lines.append("renderer isReadyForMoreMediaData \(b.isReadyForMoreMediaData)") }
        lines.append("marks \(markCount)")
        return lines.joined(separator: "\n")
    }

    private func refreshStatus() {
        status.stringValue = statusText()
        guard let engine, engine.rate > 0 else { return }
        let second = Int(engine.currentTime)
        if second != lastSecond {
            lastSecond = second
            statusBox.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [statusBox] in statusBox.layer?.backgroundColor = nil }
        }
    }
}
