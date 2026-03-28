/**
 ClaudeKey Lite — Agentic Coding Control Panel (Lite Edition)

 6 buttons + LED status bar + context/rate bars + activity log.
 Simulates the Lite hardware: 6 Cherry MX keys + WS2812B LED strip.

 Build:  cd app/lite && ./build.sh
 Run:    ./ClaudeKeyLite
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech

// ── SPEECH ENGINE ──────────────────────────────────────
class SpeechEngine: NSObject, AVAudioRecorderDelegate {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recorder: AVAudioRecorder?
    private var startTime: Date?
    private(set) var isListening = false
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var onError:  ((String) -> Void)?
    var onResult: ((String) -> Void)?
    var onLog:    ((String) -> Void)?   // daemon status messages

    // whisper-daemon script (persistent process, lazy-loaded)
    private let whisperDaemonScript: String?

    // Daemon process state
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonOutputBuffer = ""
    private var daemonReady = false
    private var pendingAudio: URL?          // queued while daemon is warming up
    private var idleTimer: Timer?
    private let idleTimeout: TimeInterval = 600  // 10 min idle → kill → free ~800MB

    private var tempFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claudekey_ptt.wav")
    }

    override init() {
        let bin = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let candidates = (1...4).map { depth -> String in
            var u = bin
            for _ in 0..<depth { u = u.deletingLastPathComponent() }
            return u.appendingPathComponent("scripts/whisper-daemon").path
        }
        whisperDaemonScript = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    deinit { killDaemon() }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authStatus = status
                if status != .authorized { self.onError?("Speech permission denied") }
                completion(status == .authorized)
            }
        }
    }

    var backendDescription: String {
        if whisperDaemonScript != nil { return "Whisper daemon (loads on first PTT)" }
        return "Apple STT (\(Locale.current.identifier))"
    }

    func startRecording() -> Bool {
        guard authStatus == .authorized else { onError?("Speech not authorized"); return false }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do { recorder = try AVAudioRecorder(url: tempFileURL, settings: settings) }
        catch { onError?("Mic init failed: \(error.localizedDescription)"); return false }
        recorder?.delegate = self
        guard recorder?.record() == true else { onError?("Mic failed to start"); return false }
        isListening = true; startTime = Date(); return true
    }

    func stopRecording() {
        guard isListening else { return }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        recorder?.stop(); recorder = nil; isListening = false
        guard duration > 0.3 else { onError?("Recording too short"); return }

        let fileURL = tempFileURL
        if whisperDaemonScript != nil {
            if daemonProcess == nil {
                startDaemon()           // lazy: first PTT starts the daemon
                pendingAudio = fileURL  // queued until READY
            } else if daemonReady {
                sendToDaemon(fileURL: fileURL)
                resetIdleTimer()
            } else {
                pendingAudio = fileURL  // daemon still warming up
            }
        } else {
            transcribeWithApple(fileURL: fileURL)
        }
    }

    // MARK: — Daemon lifecycle

    private func startDaemon() {
        guard let script = whisperDaemonScript, daemonProcess == nil else { return }
        onLog?("STT: Whisper loading model…")

        let process   = Process()
        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL  = URL(fileURLWithPath: script)
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // stderr: watch for "READY" (emitted after model pre-warm)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            guard str.contains("READY") else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.daemonReady = true
                self.onLog?("STT: Whisper ready ✓")
                if let pending = self.pendingAudio {
                    self.pendingAudio = nil
                    self.sendToDaemon(fileURL: pending)
                    self.resetIdleTimer()
                }
            }
        }

        // stdout: line-buffer transcription results
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.daemonOutputBuffer += chunk
                while let nl = self.daemonOutputBuffer.firstIndex(of: "\n") {
                    let line = String(self.daemonOutputBuffer[..<nl])
                        .trimmingCharacters(in: .whitespaces)
                    self.daemonOutputBuffer = String(
                        self.daemonOutputBuffer[self.daemonOutputBuffer.index(after: nl)...])
                    if !line.isEmpty { self.onResult?(line) }
                }
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.daemonProcess = nil
                self?.daemonStdin   = nil
                self?.daemonReady   = false
                self?.daemonOutputBuffer = ""
            }
        }

        do {
            try process.run()
            daemonProcess = process
            daemonStdin   = stdinPipe.fileHandleForWriting
        } catch {
            onError?("Whisper daemon launch failed: \(error.localizedDescription)")
        }
    }

    private func sendToDaemon(fileURL: URL) {
        guard let handle = daemonStdin else { return }
        handle.write((fileURL.path + "\n").data(using: .utf8)!)
    }

    private func killDaemon() {
        idleTimer?.invalidate(); idleTimer = nil
        daemonStdin = nil
        daemonProcess?.terminate(); daemonProcess = nil
        daemonReady = false; daemonOutputBuffer = ""; pendingAudio = nil
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.killDaemon()
            self?.onLog?("STT: Whisper idle — memory freed (reload on next PTT)")
        }
    }

    // MARK: — Apple STT fallback (no whisper-daemon found)

    private func transcribeWithApple(fileURL: URL) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable"); return
        }
        let req = SFSpeechURLRecognitionRequest(url: fileURL)
        recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.onError?("Recognition failed: \(error.localizedDescription)"); return
                }
                guard let result = result, result.isFinal else { return }
                self?.onResult?(result.bestTranscription.formattedString)
            }
        }
    }
}

// ── KEYBOARD OUTPUT ────────────────────────────────────
func typeString(_ text: String) {
    for char in text {
        var chars = Array(String(char).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up.post(tap: .cgAnnotatedSessionEventTap)
        usleep(5000)
    }
}

func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cgAnnotatedSessionEventTap)
    usleep(10000)
    up.post(tap: .cgAnnotatedSessionEventTap)
}

// ── NON-ACTIVATING CONTROLS ────────────────────────────
class NonActivatingButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    var onPress: (() -> Void)?
    override func mouseDown(with event: NSEvent) { isHighlighted = true; onPress?() }
    override func mouseUp(with event: NSEvent) { isHighlighted = false }
}

class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ── CLAUDE STATUS ──────────────────────────────────────
struct ClaudeStatus {
    var contextPercent: Int = 0
    var model: String = ""
    var costUSD: Double = 0
    var rate5h: Int = 0
    var rate7d: Int = 0
    var project: String = ""
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var version: String = ""
    var totalDurationMs: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var contextWindowSize: Int = 0

    var activity: String = ""
    var activityTool: String = ""
    var needsAttention: Bool = false
    var isIdle: Bool = false

    static func read() -> ClaudeStatus? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claudekey-status.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var s = ClaudeStatus()

        if let cw = json["context_window"] as? [String: Any] {
            s.contextPercent = cw["used_percentage"] as? Int ?? 0
            s.contextWindowSize = cw["context_window_size"] as? Int ?? 0
            if let cu = cw["current_usage"] as? [String: Any] {
                s.inputTokens = cu["input_tokens"] as? Int ?? 0
                s.outputTokens = cu["output_tokens"] as? Int ?? 0
                s.cacheReadTokens = cu["cache_read_input_tokens"] as? Int ?? 0
            }
        }
        if let m = json["model"] as? [String: Any] {
            s.model = m["display_name"] as? String ?? ""
        }
        if let c = json["cost"] as? [String: Any] {
            s.costUSD = c["total_cost_usd"] as? Double ?? 0
            s.totalDurationMs = c["total_duration_ms"] as? Int ?? 0
            s.linesAdded = c["total_lines_added"] as? Int ?? 0
            s.linesRemoved = c["total_lines_removed"] as? Int ?? 0
        }
        if let rl = json["rate_limits"] as? [String: Any] {
            if let h5 = rl["five_hour"] as? [String: Any] {
                s.rate5h = Int(h5["used_percentage"] as? Double ?? 0)
            }
            if let d7 = rl["seven_day"] as? [String: Any] {
                s.rate7d = Int(d7["used_percentage"] as? Double ?? 0)
            }
        }
        if let ws = json["workspace"] as? [String: Any] {
            let dir = ws["current_dir"] as? String ?? ""
            s.project = (dir as NSString).lastPathComponent
        }
        s.version = json["version"] as? String ?? ""

        let now = Int(Date().timeIntervalSince1970)
        if let actData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claudekey-activity.json")),
           let actJson = try? JSONSerialization.jsonObject(with: actData) as? [String: Any] {
            let ts = actJson["ts"] as? Int ?? 0
            if now - ts < 10 {
                s.activity = actJson["activity"] as? String ?? ""
                s.activityTool = actJson["tool"] as? String ?? ""
            }
        }
        if let notifData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claudekey-notify.json")),
           let notifJson = try? JSONSerialization.jsonObject(with: notifData) as? [String: Any] {
            let ts = notifJson["ts"] as? Int ?? 0
            if now - ts < 30 {
                let type = notifJson["type"] as? String ?? ""
                s.needsAttention = (type == "permission")
                s.isIdle = (type == "idle")
            }
        }
        return s
    }
}

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: ControlPanel!
    var statusItem: NSStatusItem!
    let speech = SpeechEngine()

    // UI elements
    var headerLabel: NSTextField!
    var modelLabel: NSTextField!
    var pttButton: NonActivatingButton!
    var acceptButton: NonActivatingButton!

    // Context section
    var ctxBarView: NSView!
    var ctxBarFill: NSView!
    var ctxLabel: NSTextField!

    // Rate limit bars
    var rate5hBar: NSView!
    var rate5hFill: NSView!
    var rate7dBar: NSView!
    var rate7dFill: NSView!
    var rateLabel: NSTextField!

    // Stats
    var statsLabel: NSTextField!

    // Activity log
    var logView: NSScrollView!
    var logText: NSTextView!
    var activityLog: [(Date, String, NSColor)] = []
    let maxLogEntries = 100

    var pollTimer: Timer?
    var blinkState = false
    var lastActivity = ""
    var alwaysAccept = false
    var alwaysAcceptCount = 0
    var alwaysAcceptButton: NonActivatingButton!

    // Hook fix state
    var pendingHookScript: String?
    var pendingSettingsPath: String?

    let panelW: CGFloat = 360
    let panelH: CGFloat = 480

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        setupPanel()
        setupMenuBar()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        speech.onError = { [weak self] msg in
            self?.logActivity(msg, color: .systemRed)
        }
        speech.onResult = { [weak self] text in
            guard let self = self, !text.isEmpty else { return }
            self.logActivity("Voice: \(text)", color: .systemPurple)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                typeString(text)
                sendKey(36)
            }
        }
        speech.onLog = { [weak self] msg in
            self?.logActivity(msg, color: .systemGray)
        }
        speech.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.logActivity("STT: \(self.speech.backendDescription)", color: .systemGreen)
            } else {
                self.logActivity("Speech permission denied", color: .systemRed)
            }
        }

        checkHookStatus()
        logActivity("ClaudeKey Soft ready", color: .systemGreen)
    }

    func checkHookStatus() {
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryURL  = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        // Lite binary lives at <root>/app/lite/ClaudeKeyLite
        let projectRoot = binaryURL.deletingLastPathComponent()
                                   .deletingLastPathComponent()
                                   .deletingLastPathComponent().path
        let hookScript  = projectRoot + "/scripts/claude-status-hook"
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        let fm = FileManager.default

        // 1. Hook script exists?
        guard fm.fileExists(atPath: hookScript) else {
            logActivity("✗ Hook not found: \(hookScript)", color: .systemRed)
            return
        }
        // 2. Executable?
        if !fm.isExecutableFile(atPath: hookScript) {
            logActivity("✗ Hook not executable — fixing…", color: .systemOrange)
            let _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"),
                                     arguments: ["+x", hookScript])
            logActivity("  chmod +x applied", color: .systemGreen)
        }
        // 3. settings.json exists?
        guard let data = fm.contents(atPath: settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logActivity("✗ ~/.claude/settings.json not found", color: .systemRed)
            logActivity("  Run Claude Code at least once first", color: .systemRed)
            return
        }
        // 4. Check current statusLine.command
        let sl  = json["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? "(not set)"

        if cmd.contains("claude-status-hook") {
            logActivity("✓ Hook linked: \(hookScript)", color: .systemGreen)
        } else {
            logActivity("✗ Hook mismatch", color: .systemOrange)
            logActivity("  Current: \(cmd)", color: .systemOrange)
            logActivity("  → Click 'Fix Hook' in menu to auto-configure", color: .systemYellow)
            // Store for auto-fix
            pendingHookScript = hookScript
            pendingSettingsPath = settingsPath
        }
    }

    // Called from menu "Fix Hook"
    @objc func fixHook() {
        guard let hook = pendingHookScript,
              let path = pendingSettingsPath else {
            logActivity("Hook already configured ✓", color: .systemGreen)
            return
        }
        let fm = FileManager.default
        guard let data = fm.contents(atPath: path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logActivity("Cannot read settings.json", color: .systemRed)
            return
        }
        json["statusLine"] = ["type": "command", "command": hook]
        guard let newData = try? JSONSerialization.data(withJSONObject: json,
                                                        options: [.prettyPrinted, .sortedKeys]) else {
            logActivity("Cannot encode settings.json", color: .systemRed)
            return
        }
        do {
            try newData.write(to: URL(fileURLWithPath: path))
            logActivity("✓ Hook configured!", color: .systemGreen)
            logActivity("  Restart Claude Code to apply", color: .systemGreen)
            pendingHookScript   = nil
            pendingSettingsPath = nil
        } catch {
            logActivity("✗ Write failed: \(error.localizedDescription)", color: .systemRed)
        }
    }

    // ── PANEL LAYOUT ───────────────────────────────────
    func setupPanel() {
        let screen = NSScreen.main!.visibleFrame
        panel = ControlPanel(
            contentRect: NSRect(x: screen.maxX - panelW - 16, y: screen.minY + 16,
                                width: panelW, height: panelH),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "ClaudeKey"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.97)
        panel.minSize = NSSize(width: 300, height: 380)

        let cv = panel.contentView!
        let pad: CGFloat = 10
        let w = panelW - pad * 2  // usable width

        // Layout top-down: y starts at top of content view and decreases
        // Content view origin is bottom-left, so we compute from top
        let contentH = cv.frame.height
        var y = contentH

        // ── Header ──
        y -= 6  // top padding
        y -= 18
        headerLabel = makeLabel("ClaudeKey", size: 13, weight: .bold, color: .white)
        headerLabel.frame = NSRect(x: pad, y: y, width: w, height: 18)
        cv.addSubview(headerLabel)

        y -= 14
        modelLabel = makeLabel("waiting for Claude Code...", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        modelLabel.frame = NSRect(x: pad, y: y, width: w, height: 14)
        cv.addSubview(modelLabel)

        // ── Buttons ──
        y -= 8
        let btnDefs: [(String, Selector, NSColor)] = [
            ("🎙 PTT",     #selector(pttToggle),       NSColor(white: 0.28, alpha: 1)),
            ("✓ Accept",   #selector(doAccept),         NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1)),
            ("✗ Reject",   #selector(doReject),         NSColor(red: 0.3, green: 0.15, blue: 0.15, alpha: 1)),
            ("↑ Up",       #selector(doUp),             NSColor(white: 0.25, alpha: 1)),
            ("⚡ Always",  #selector(doAlwaysAccept),   NSColor(white: 0.25, alpha: 1)),
            ("↓ Down",     #selector(doDown),           NSColor(white: 0.25, alpha: 1)),
        ]
        let btnGap: CGFloat = 5
        let btnW = (w - btnGap * 2) / 3
        let btnH: CGFloat = 36

        for (i, (title, action, bgColor)) in btnDefs.enumerated() {
            let col = i % 3
            let row = i / 3
            let bx = pad + CGFloat(col) * (btnW + btnGap)
            let by = y - CGFloat(row + 1) * btnH - CGFloat(row) * 4  // row+1 because y is top edge

            let btn = NonActivatingButton(frame: NSRect(x: bx, y: by, width: btnW, height: btnH))
            btn.wantsLayer = true
            btn.layer?.backgroundColor = bgColor.cgColor
            btn.layer?.cornerRadius = 6
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            btn.onPress = { [weak self] in NSApp.sendAction(action, to: self, from: btn) }
            cv.addSubview(btn)

            if title.contains("PTT") { pttButton = btn }
            if title.contains("Accept") { acceptButton = btn }
            if title.contains("Always") { alwaysAcceptButton = btn }
        }
        y -= btnH * 2 + 4 + 6  // 2 rows + gap + spacing

        // ── Divider 1 ──
        y -= 4
        addDivider(cv, y: y)
        y -= 8

        // ── CONTEXT ──
        y -= 12
        let ctxLbl = makeLabel("CONTEXT", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        ctxLbl.frame = NSRect(x: pad, y: y, width: 60, height: 12)
        cv.addSubview(ctxLbl)

        ctxLabel = makeLabel("—", size: 10, weight: .bold, color: .systemGreen)
        ctxLabel.frame = NSRect(x: pad + 60, y: y, width: w - 60, height: 12)
        ctxLabel.alignment = .right
        cv.addSubview(ctxLabel)

        y -= 4
        y -= 8
        ctxBarView = NSView(frame: NSRect(x: pad, y: y, width: w, height: 8))
        ctxBarView.wantsLayer = true
        ctxBarView.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        ctxBarView.layer?.cornerRadius = 4
        cv.addSubview(ctxBarView)

        ctxBarFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 8))
        ctxBarFill.wantsLayer = true
        ctxBarFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        ctxBarFill.layer?.cornerRadius = 4
        ctxBarView.addSubview(ctxBarFill)

        // ── RATE LIMITS ──
        y -= 12
        y -= 12
        let rateLbl = makeLabel("RATE", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        rateLbl.frame = NSRect(x: pad, y: y, width: 40, height: 12)
        cv.addSubview(rateLbl)

        rateLabel = makeLabel("5h: —  |  7d: —", size: 10, weight: .regular, color: NSColor(white: 0.6, alpha: 1))
        rateLabel.frame = NSRect(x: pad + 40, y: y, width: w - 40, height: 12)
        rateLabel.alignment = .right
        cv.addSubview(rateLabel)

        y -= 4
        y -= 6
        let halfW = (w - 5) / 2
        rate5hBar = makeBar(x: pad, y: y, width: halfW)
        cv.addSubview(rate5hBar)
        rate5hFill = rate5hBar.subviews.first!

        rate7dBar = makeBar(x: pad + halfW + 5, y: y, width: halfW)
        cv.addSubview(rate7dBar)
        rate7dFill = rate7dBar.subviews.first!

        // ── Stats ──
        y -= 10
        y -= 12
        statsLabel = makeLabel("", size: 9, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        statsLabel.frame = NSRect(x: pad, y: y, width: w, height: 12)
        cv.addSubview(statsLabel)

        // ── Divider 2 ──
        y -= 6
        addDivider(cv, y: y)
        y -= 6

        // ── ACTIVITY header ──
        y -= 12
        let logLbl = makeLabel("ACTIVITY", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        logLbl.frame = NSRect(x: pad, y: y, width: 80, height: 12)
        cv.addSubview(logLbl)

        // ── Activity Log (fills remaining space) ──
        y -= 4
        let logH = y - 6  // bottom padding
        logView = NSScrollView(frame: NSRect(x: pad, y: 6, width: w, height: logH))
        logView.hasVerticalScroller = true
        logView.borderType = .noBorder
        logView.drawsBackground = false
        logView.autoresizingMask = [.width, .height]

        logText = NSTextView(frame: logView.bounds)
        logText.isEditable = false
        logText.isSelectable = true
        logText.drawsBackground = false
        logText.textContainerInset = NSSize(width: 2, height: 2)
        logText.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logText.textColor = NSColor(white: 0.6, alpha: 1)
        logText.autoresizingMask = [.width]

        logView.documentView = logText
        cv.addSubview(logView)

        panel.orderFront(nil)

        // Poll every 1s
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateClaudeStatus()
        }
    }

    func addDivider(_ parent: NSView, y: CGFloat) {
        let div = NSView(frame: NSRect(x: 10, y: y, width: panelW - 20, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        parent.addSubview(div)
    }

    // ── HELPERS ────────────────────────────────────────
    func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.backgroundColor = .clear
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func makeBar(x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: x, y: y, width: width, height: 6))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        bar.layer?.cornerRadius = 3

        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 6))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        fill.layer?.cornerRadius = 3
        bar.addSubview(fill)
        return bar
    }

    func logActivity(_ text: String, color: NSColor) {
        let now = Date()
        activityLog.append((now, text, color))
        if activityLog.count > maxLogEntries { activityLog.removeFirst() }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: now)

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "\(ts) ", attributes: [
            .foregroundColor: NSColor(white: 0.4, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ]))
        line.append(NSAttributedString(string: "\(text)\n", attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ]))

        logText.textStorage?.append(line)

        // Auto-scroll to bottom
        logText.scrollToEndOfDocument(nil)
    }

    func barColor(for percent: Int) -> NSColor {
        if percent < 25 { return .systemGreen }
        if percent < 50 { return .systemBlue }
        if percent < 75 { return .systemYellow }
        return .systemRed
    }

    func styledTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text,
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
    }

    // ── STATUS UPDATE ──────────────────────────────────
    func updateClaudeStatus() {
        guard let s = ClaudeStatus.read() else { return }

        // Header
        headerLabel.stringValue = s.project.isEmpty ? "ClaudeKey" : s.project
        modelLabel.stringValue = "\(s.model)  v\(s.version)"

        // Context bar
        let barW = ctxBarView.frame.width
        ctxBarFill.frame.size.width = barW * CGFloat(min(s.contextPercent, 100)) / 100
        let cc = barColor(for: s.contextPercent)
        ctxBarFill.layer?.backgroundColor = cc.cgColor
        ctxLabel.textColor = cc

        let tokensK = (s.inputTokens + s.outputTokens) / 1000
        let ctxSizeK = s.contextWindowSize / 1000
        ctxLabel.stringValue = "\(s.contextPercent)%  \(tokensK)k/\(ctxSizeK)k"

        // Rate limits
        rate5hFill.frame.size.width = rate5hBar.frame.width * CGFloat(min(s.rate5h, 100)) / 100
        rate5hFill.layer?.backgroundColor = barColor(for: s.rate5h).cgColor
        rate7dFill.frame.size.width = rate7dBar.frame.width * CGFloat(min(s.rate7d, 100)) / 100
        rate7dFill.layer?.backgroundColor = barColor(for: s.rate7d).cgColor
        rateLabel.stringValue = "5h: \(s.rate5h)%  |  7d: \(s.rate7d)%"

        // Stats
        let cost = String(format: "$%.2f", s.costUSD)
        let dur = s.totalDurationMs / 1000
        let cacheK = s.cacheReadTokens / 1000
        statsLabel.stringValue = "\(cost) | \(dur)s | +\(s.linesAdded)/-\(s.linesRemoved) lines | cache: \(cacheK)k"

        // Activity log (only add if new)
        if !s.activity.isEmpty && s.activity != lastActivity {
            lastActivity = s.activity
            let color: NSColor = s.activityTool.contains("Agent") ? .systemPurple
                : s.activityTool.contains("Bash") ? .systemOrange
                : s.activityTool.contains("Write") || s.activityTool.contains("Edit") ? .systemYellow
                : .systemCyan
            logActivity(s.activity, color: color)
        }

        // Needs attention
        if s.needsAttention {
            if alwaysAccept {
                // Auto-accept: send Enter immediately
                alwaysAcceptCount += 1
                sendKey(36)
                try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
                logActivity("Auto-accept #\(alwaysAcceptCount): Enter", color: .systemGreen)
                return
            }
            blinkState.toggle()
            if blinkState {
                logActivity(">>> NEEDS APPROVAL <<<", color: .systemYellow)
            }
            acceptButton.layer?.backgroundColor = blinkState
                ? NSColor.systemGreen.cgColor
                : NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1).cgColor
            statusItem.button?.title = blinkState ? "⚠️" : "⌨"
        } else if s.isIdle {
            if lastActivity != "_idle" {
                lastActivity = "_idle"
                logActivity("Waiting for input...", color: .systemGreen)
            }
        } else {
            acceptButton.layer?.backgroundColor = NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1).cgColor
            if !speech.isListening {
                statusItem.button?.title = s.contextPercent > 75 ? "🔴" : "⌨"
            }
        }
    }

    // ── MENUBAR ────────────────────────────────────────
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"

        let menu = NSMenu()
        menu.addItem(withTitle: "ClaudeKey Lite", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Panel", action: #selector(hidePanel), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Fix Hook (configure settings.json)", action: #selector(fixHook), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showPanel() { panel.orderFront(nil) }
    @objc func hidePanel() { panel.orderOut(nil) }
    @objc func quit() { NSApp.terminate(nil) }

    // ── BUTTON ACTIONS ─────────────────────────────────
    @objc func doAccept() {
        sendKey(36)  // Enter only — Claude Code defaults to accept
        logActivity("Sent: Enter (accept)", color: .systemGreen)
        try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
    }

    @objc func doReject() {
        sendKey(53)
        logActivity("Sent: Esc", color: .systemOrange)
        try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
    }

    @objc func doUp() {
        sendKey(126)
        logActivity("Sent: Up", color: .systemBlue)
    }

    @objc func doDown() {
        sendKey(125)
        logActivity("Sent: Down", color: .systemBlue)
    }

    @objc func pttToggle() {
        if speech.isListening {
            speech.stopRecording()
            pttButton.layer?.backgroundColor = NSColor(white: 0.28, alpha: 1).cgColor
            pttButton.attributedTitle = styledTitle("🎙 PTT")
            statusItem.button?.title = "⌨"
            logActivity("PTT: recognizing...", color: .systemYellow)
        } else {
            let started = speech.startRecording()
            if started {
                pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
                pttButton.attributedTitle = styledTitle("⏹ STOP")
                statusItem.button?.title = "🎙"
                logActivity("PTT: recording...", color: .systemRed)
            }
        }
    }

    @objc func doAlwaysAccept() {
        alwaysAccept.toggle()
        if alwaysAccept {
            alwaysAcceptCount = 0
            alwaysAcceptButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            alwaysAcceptButton.attributedTitle = styledTitle("⏹ Stop")
            logActivity("Always-Accept ON — auto Enter on approval requests", color: .systemRed)
        } else {
            alwaysAcceptButton.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
            alwaysAcceptButton.attributedTitle = styledTitle("⚡ Always")
            logActivity("Always-Accept OFF (auto-accepted \(alwaysAcceptCount)x)", color: .systemYellow)
        }
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
