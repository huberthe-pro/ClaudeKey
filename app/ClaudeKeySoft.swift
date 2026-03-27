/**
 ClaudeKey Soft v0.2 — Agentic Coding Control Panel

 NSPanel + .nonActivatingPanel: clicks NEVER steal focus from iTerm.
 Shows real-time Claude Code status, activity log, and controls.

 Build:  cd app && ./build-soft.sh
 Run:    ./ClaudeKeySoft
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
    var onError: ((String) -> Void)?
    var onResult: ((String) -> Void)?

    private var tempFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claudekey_ptt.wav")
    }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authStatus = status
                if status != .authorized {
                    self.onError?("Speech permission denied")
                }
                completion(status == .authorized)
            }
        }
    }

    func startRecording() -> Bool {
        guard authStatus == .authorized else {
            onError?("Speech not authorized")
            return false
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable")
            return false
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            recorder = try AVAudioRecorder(url: tempFileURL, settings: settings)
        } catch {
            onError?("Mic init failed: \(error.localizedDescription)")
            return false
        }

        recorder?.delegate = self
        guard recorder?.record() == true else {
            onError?("Mic failed to start")
            return false
        }

        isListening = true
        startTime = Date()
        return true
    }

    func stopRecording() {
        guard isListening else { return }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0

        recorder?.stop()
        recorder = nil
        isListening = false

        guard duration > 0.3 else {
            onError?("Recording too short")
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: tempFileURL)
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.onError?("Recognition failed: \(error.localizedDescription)")
                    return
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
        speech.requestPermission { [weak self] granted in
            self?.logActivity(granted ? "Speech ready" : "Speech permission denied",
                              color: granted ? .systemGreen : .systemRed)
        }

        logActivity("ClaudeKey Soft ready", color: .systemGreen)
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
        var y = panelH - 32

        // ── Header: project + model ──
        headerLabel = makeLabel("ClaudeKey", size: 13, weight: .bold, color: .white)
        headerLabel.frame = NSRect(x: 10, y: y, width: 200, height: 18)
        cv.addSubview(headerLabel)

        modelLabel = makeLabel("", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        modelLabel.frame = NSRect(x: 10, y: y - 16, width: panelW - 20, height: 14)
        cv.addSubview(modelLabel)
        y -= 38

        // ── Buttons: 2 rows x 3 ──
        let btnDefs: [(String, Selector, NSColor)] = [
            ("🎙 PTT",    #selector(pttToggle), NSColor(white: 0.28, alpha: 1)),
            ("✓ Accept",  #selector(doAccept),  NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1)),
            ("✗ Reject",  #selector(doReject),  NSColor(red: 0.3, green: 0.15, blue: 0.15, alpha: 1)),
            ("↑ Up",      #selector(doUp),      NSColor(white: 0.25, alpha: 1)),
            ("⚡ Auto",   #selector(doAutoYes), NSColor(white: 0.25, alpha: 1)),
            ("↓ Down",    #selector(doDown),    NSColor(white: 0.25, alpha: 1)),
        ]
        let btnW: CGFloat = (panelW - 40) / 3
        let btnH: CGFloat = 36

        for (i, (title, action, bgColor)) in btnDefs.enumerated() {
            let col = i % 3
            let row = i / 3
            let bx = 10 + CGFloat(col) * (btnW + 5)
            let by = y - CGFloat(row) * (btnH + 4)

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
        }
        y -= (btnH * 2 + 4 + 12)

        // ── Divider ──
        let div1 = NSView(frame: NSRect(x: 10, y: y, width: panelW - 20, height: 1))
        div1.wantsLayer = true
        div1.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        cv.addSubview(div1)
        y -= 8

        // ── Context Window Bar ──
        let ctxLbl = makeLabel("CONTEXT", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        ctxLbl.frame = NSRect(x: 10, y: y, width: 60, height: 12)
        cv.addSubview(ctxLbl)

        ctxLabel = makeLabel("—", size: 11, weight: .bold, color: .systemGreen)
        ctxLabel.frame = NSRect(x: panelW - 60, y: y - 1, width: 50, height: 14)
        ctxLabel.alignment = .right
        cv.addSubview(ctxLabel)
        y -= 14

        ctxBarView = NSView(frame: NSRect(x: 10, y: y, width: panelW - 20, height: 8))
        ctxBarView.wantsLayer = true
        ctxBarView.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        ctxBarView.layer?.cornerRadius = 4
        cv.addSubview(ctxBarView)

        ctxBarFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 8))
        ctxBarFill.wantsLayer = true
        ctxBarFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        ctxBarFill.layer?.cornerRadius = 4
        ctxBarView.addSubview(ctxBarFill)
        y -= 16

        // ── Rate Limits ──
        let rateLbl = makeLabel("RATE LIMITS", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        rateLbl.frame = NSRect(x: 10, y: y, width: 80, height: 12)
        cv.addSubview(rateLbl)

        rateLabel = makeLabel("5h: —  |  7d: —", size: 10, weight: .regular, color: NSColor(white: 0.6, alpha: 1))
        rateLabel.frame = NSRect(x: 90, y: y, width: panelW - 100, height: 12)
        cv.addSubview(rateLabel)
        y -= 14

        let halfW = (panelW - 25) / 2
        rate5hBar = makeBar(x: 10, y: y, width: halfW)
        cv.addSubview(rate5hBar)
        rate5hFill = rate5hBar.subviews.first!

        rate7dBar = makeBar(x: 15 + halfW, y: y, width: halfW)
        cv.addSubview(rate7dBar)
        rate7dFill = rate7dBar.subviews.first!
        y -= 14

        // ── Stats Line ──
        statsLabel = makeLabel("", size: 9, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        statsLabel.frame = NSRect(x: 10, y: y, width: panelW - 20, height: 12)
        cv.addSubview(statsLabel)
        y -= 14

        // ── Divider ──
        let div2 = NSView(frame: NSRect(x: 10, y: y, width: panelW - 20, height: 1))
        div2.wantsLayer = true
        div2.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        cv.addSubview(div2)
        y -= 4

        // ── Activity Log Header ──
        let logLbl = makeLabel("ACTIVITY", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        logLbl.frame = NSRect(x: 10, y: y, width: 80, height: 12)
        cv.addSubview(logLbl)
        y -= 4

        // ── Activity Log (scrollable) ──
        logView = NSScrollView(frame: NSRect(x: 10, y: 8, width: panelW - 20, height: y - 8))
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
        menu.addItem(withTitle: "ClaudeKey Soft v0.2", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Panel", action: #selector(hidePanel), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showPanel() { panel.orderFront(nil) }
    @objc func hidePanel() { panel.orderOut(nil) }
    @objc func quit() { NSApp.terminate(nil) }

    // ── BUTTON ACTIONS ─────────────────────────────────
    @objc func doAccept() {
        typeString("y")
        usleep(20000)
        sendKey(36)
        logActivity("Sent: y + Enter", color: .systemGreen)
        // Clear needs-attention notification
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

    @objc func doAutoYes() {
        logActivity("Auto-Yes: coming in v0.2", color: .systemYellow)
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
