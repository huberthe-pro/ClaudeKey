/**
 ClaudeKey Pro — Agentic Coding Control Panel (Pro Edition)

 Extended panel with TFT display preview, rotary encoder simulation,
 and additional shortcut buttons. Simulates the Pro hardware:
 6 core keys + extra shortcuts + rotary encoder + ST7789 1.3" TFT.

 Build:  cd app/pro && ./build.sh
 Run:    ./ClaudeKeyPro
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
    private let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("claudekey-stt.wav")

    var isListening = false
    var onResult: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func requestPermission(completion: @escaping (Bool) -> Void) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    func startRecording() -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
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

// ── TFT DISPLAY VIEW (simulates ST7789 240x240) ───────
class TFTDisplayView: NSView {
    var contextPercent: Int = 0
    var rate5h: Int = 0
    var rate7d: Int = 0
    var model: String = "—"
    var status: String = "Ready"
    var costStr: String = "$0.00"
    var durationStr: String = "0s"
    var linesStr: String = "+0/-0"
    var activity: String = ""
    var needsAttention: Bool = false
    var encoderValue: String = ""

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let w = bounds.width
        let h = bounds.height

        // TFT background — dark with subtle border
        ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        let path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor(white: 0.2, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()

        let pad: CGFloat = 10
        let usableW = w - pad * 2
        var y = h - pad - 2

        // ── Row 1: Model + Status ──
        let statusColor = needsAttention ? NSColor.systemYellow : NSColor.systemGreen
        drawText(ctx, model, x: pad, y: y, size: 11, weight: .bold, color: .white)
        let statusW = measureText(status, size: 10)
        drawText(ctx, status, x: w - pad - statusW, y: y, size: 10, weight: .semibold, color: statusColor)
        y -= 18

        // ── Row 2: Context bar ──
        drawText(ctx, "CTX", x: pad, y: y, size: 8, weight: .bold, color: NSColor(white: 0.5, alpha: 1))
        let ctxPctStr = "\(contextPercent)%"
        let pctW = measureText(ctxPctStr, size: 9)
        drawText(ctx, ctxPctStr, x: w - pad - pctW, y: y, size: 9, weight: .bold, color: barColor(contextPercent))

        y -= 3
        let barH: CGFloat = 6
        y -= barH
        drawBar(ctx, x: pad, y: y, width: usableW, height: barH, percent: contextPercent, color: barColor(contextPercent))
        y -= 10

        // ── Row 3: Rate limits ──
        drawText(ctx, "5h:\(rate5h)%", x: pad, y: y, size: 8, weight: .regular, color: barColor(rate5h))
        let r7str = "7d:\(rate7d)%"
        let r7w = measureText(r7str, size: 8)
        drawText(ctx, r7str, x: w - pad - r7w, y: y, size: 8, weight: .regular, color: barColor(rate7d))
        y -= 3
        y -= barH
        let halfW = (usableW - 4) / 2
        drawBar(ctx, x: pad, y: y, width: halfW, height: barH, percent: rate5h, color: barColor(rate5h))
        drawBar(ctx, x: pad + halfW + 4, y: y, width: halfW, height: barH, percent: rate7d, color: barColor(rate7d))
        y -= 10

        // ── Row 4: Cost / Duration / Lines ──
        let statsStr = "\(costStr)  \(durationStr)  \(linesStr)"
        drawText(ctx, statsStr, x: pad, y: y, size: 8, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
        y -= 14

        // ── Divider ──
        ctx.setStrokeColor(NSColor(white: 0.2, alpha: 1).cgColor)
        ctx.move(to: CGPoint(x: pad, y: y))
        ctx.addLine(to: CGPoint(x: w - pad, y: y))
        ctx.strokePath()
        y -= 10

        // ── Row 5: Activity ──
        if !activity.isEmpty {
            let actColor = needsAttention ? NSColor.systemYellow : NSColor.systemCyan
            drawText(ctx, activity, x: pad, y: y, size: 9, weight: .regular, color: actColor, maxWidth: usableW)
        }

        // ── Encoder value (bottom-right) ──
        if !encoderValue.isEmpty {
            let evW = measureText(encoderValue, size: 8)
            drawText(ctx, encoderValue, x: w - pad - evW, y: pad, size: 8, weight: .regular, color: NSColor(white: 0.4, alpha: 1))
        }
    }

    func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat,
                  size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat = 0) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(at: NSPoint(x: x, y: y - size - 2))
    }

    func measureText(_ text: String, size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attrs).width
    }

    func drawBar(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                 percent: Int, color: NSColor) {
        // Background
        let bgPath = CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                            cornerWidth: height/2, cornerHeight: height/2, transform: nil)
        ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Fill
        let fillW = width * CGFloat(min(percent, 100)) / 100
        if fillW > 0 {
            let fillPath = CGPath(roundedRect: CGRect(x: x, y: y, width: fillW, height: height),
                                  cornerWidth: height/2, cornerHeight: height/2, transform: nil)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()
        }
    }

    func barColor(_ percent: Int) -> NSColor {
        if percent < 25 { return .systemGreen }
        if percent < 50 { return .systemBlue }
        if percent < 75 { return .systemYellow }
        return .systemRed
    }
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
    var alwaysAcceptButton: NonActivatingButton!

    // TFT display preview
    var tftView: TFTDisplayView!

    // Activity log
    var logView: NSScrollView!
    var logText: NSTextView!
    var activityLog: [(Date, String, NSColor)] = []
    let maxLogEntries = 100

    // Encoder simulation
    var encoderValue: Int = 0

    var pollTimer: Timer?
    var blinkState = false
    var lastActivity = ""
    var alwaysAccept = false
    var alwaysAcceptCount = 0

    let panelW: CGFloat = 420
    let panelH: CGFloat = 620

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

        checkHookStatus()
        logActivity("ClaudeKey Pro ready", color: .systemGreen)
    }

    func checkHookStatus() {
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryURL = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let projectRoot = binaryURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let hookScript = projectRoot + "/scripts/claude-status-hook"
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

        let fm = FileManager.default
        guard fm.fileExists(atPath: hookScript) else {
            logActivity("Hook script missing", color: .systemRed)
            return
        }
        guard fm.isExecutableFile(atPath: hookScript) else {
            logActivity("Hook script not executable", color: .systemRed)
            return
        }

        guard let data = fm.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            logActivity("Hook not configured in settings.json", color: .systemOrange)
            return
        }

        if command.contains("claude-status-hook") {
            logActivity("Status hook linked", color: .systemGreen)
        } else {
            logActivity("Hook mismatch: \(command)", color: .systemOrange)
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
        panel.title = "ClaudeKey Pro"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.97)
        panel.minSize = NSSize(width: 360, height: 500)

        let cv = panel.contentView!
        let pad: CGFloat = 10
        let w = panelW - pad * 2
        let contentH = cv.frame.height
        var y = contentH

        // ── Header ──
        y -= 6
        y -= 18
        headerLabel = makeLabel("ClaudeKey Pro", size: 14, weight: .bold, color: .white)
        headerLabel.frame = NSRect(x: pad, y: y, width: w, height: 18)
        cv.addSubview(headerLabel)

        y -= 14
        modelLabel = makeLabel("waiting for Claude Code...", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        modelLabel.frame = NSRect(x: pad, y: y, width: w, height: 14)
        cv.addSubview(modelLabel)

        // ── TFT Display Preview ──
        y -= 10
        let tftH: CGFloat = 140
        y -= tftH
        tftView = TFTDisplayView(frame: NSRect(x: pad, y: y, width: w, height: tftH))
        tftView.wantsLayer = true
        cv.addSubview(tftView)

        // ── Core Buttons (2 rows x 3) ──
        y -= 8
        let coreBtnDefs: [(String, Selector, NSColor)] = [
            ("🎙 PTT",     #selector(pttToggle),       NSColor(white: 0.28, alpha: 1)),
            ("✓ Accept",   #selector(doAccept),         NSColor(red: 0.15, green: 0.3, blue: 0.15, alpha: 1)),
            ("✗ Reject",   #selector(doReject),         NSColor(red: 0.3, green: 0.15, blue: 0.15, alpha: 1)),
            ("↑ Up",       #selector(doUp),             NSColor(white: 0.25, alpha: 1)),
            ("⚡ Always",  #selector(doAlwaysAccept),   NSColor(white: 0.25, alpha: 1)),
            ("↓ Down",     #selector(doDown),           NSColor(white: 0.25, alpha: 1)),
        ]
        let btnGap: CGFloat = 5
        let btnW = (w - btnGap * 2) / 3
        let btnH: CGFloat = 34

        for (i, (title, action, bgColor)) in coreBtnDefs.enumerated() {
            let col = i % 3
            let row = i / 3
            let bx = pad + CGFloat(col) * (btnW + btnGap)
            let by = y - CGFloat(row + 1) * btnH - CGFloat(row) * 4

            let btn = NonActivatingButton(frame: NSRect(x: bx, y: by, width: btnW, height: btnH))
            btn.wantsLayer = true
            btn.layer?.backgroundColor = bgColor.cgColor
            btn.layer?.cornerRadius = 6
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            btn.onPress = { [weak self] in NSApp.sendAction(action, to: self, from: btn) }
            cv.addSubview(btn)

            if title.contains("PTT") { pttButton = btn }
            if title.contains("Accept") { acceptButton = btn }
            if title.contains("Always") { alwaysAcceptButton = btn }
        }
        y -= btnH * 2 + 4 + 6

        // ── Extra Shortcut Buttons (Pro only) ──
        y -= 4
        let extraBtnDefs: [(String, Selector, NSColor)] = [
            ("⌫ Undo",      #selector(doUndo),       NSColor(white: 0.22, alpha: 1)),
            ("⏹ Interrupt",  #selector(doInterrupt),  NSColor(red: 0.25, green: 0.12, blue: 0.12, alpha: 1)),
            ("⇥ Tab",        #selector(doTab),        NSColor(white: 0.22, alpha: 1)),
            ("📋 Paste",     #selector(doPaste),      NSColor(white: 0.22, alpha: 1)),
        ]
        let extraW = (w - btnGap * 3) / 4
        let extraH: CGFloat = 28
        y -= extraH
        for (i, (title, action, bgColor)) in extraBtnDefs.enumerated() {
            let bx = pad + CGFloat(i) * (extraW + btnGap)
            let btn = NonActivatingButton(frame: NSRect(x: bx, y: y, width: extraW, height: extraH))
            btn.wantsLayer = true
            btn.layer?.backgroundColor = bgColor.cgColor
            btn.layer?.cornerRadius = 5
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title,
                attributes: [.foregroundColor: NSColor(white: 0.8, alpha: 1),
                             .font: NSFont.systemFont(ofSize: 10, weight: .medium)])
            btn.onPress = { [weak self] in NSApp.sendAction(action, to: self, from: btn) }
            cv.addSubview(btn)
        }

        // ── Rotary Encoder Simulator ──
        y -= 8
        let encoderH: CGFloat = 28
        y -= encoderH
        let encLabel = makeLabel("ENCODER", size: 8, weight: .bold, color: NSColor(white: 0.4, alpha: 1))
        encLabel.frame = NSRect(x: pad, y: y + 7, width: 55, height: 12)
        cv.addSubview(encLabel)

        let encLeft = NonActivatingButton(frame: NSRect(x: pad + 60, y: y, width: 50, height: encoderH))
        encLeft.wantsLayer = true
        encLeft.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        encLeft.layer?.cornerRadius = 14
        encLeft.isBordered = false
        encLeft.attributedTitle = NSAttributedString(string: "◀",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
        encLeft.onPress = { [weak self] in self?.encoderTurn(-1) }
        cv.addSubview(encLeft)

        let encPress = NonActivatingButton(frame: NSRect(x: pad + 115, y: y, width: 60, height: encoderH))
        encPress.wantsLayer = true
        encPress.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        encPress.layer?.cornerRadius = 14
        encPress.isBordered = false
        encPress.attributedTitle = NSAttributedString(string: "● Press",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10)])
        encPress.onPress = { [weak self] in self?.encoderPress() }
        cv.addSubview(encPress)

        let encRight = NonActivatingButton(frame: NSRect(x: pad + 180, y: y, width: 50, height: encoderH))
        encRight.wantsLayer = true
        encRight.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        encRight.layer?.cornerRadius = 14
        encRight.isBordered = false
        encRight.attributedTitle = NSAttributedString(string: "▶",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
        encRight.onPress = { [weak self] in self?.encoderTurn(1) }
        cv.addSubview(encRight)

        // ── Divider ──
        y -= 6
        addDivider(cv, y: y)
        y -= 6

        // ── ACTIVITY header ──
        y -= 12
        let logLbl = makeLabel("ACTIVITY", size: 9, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
        logLbl.frame = NSRect(x: pad, y: y, width: 80, height: 12)
        cv.addSubview(logLbl)

        // ── Activity Log ──
        y -= 4
        let logH = y - 6
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
        logText.scrollToEndOfDocument(nil)
    }

    func styledTitle(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        NSAttributedString(string: text,
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: size, weight: .semibold)])
    }

    // ── STATUS UPDATE ──────────────────────────────────
    func updateClaudeStatus() {
        guard let s = ClaudeStatus.read() else { return }

        // Header
        headerLabel.stringValue = s.project.isEmpty ? "ClaudeKey Pro" : s.project
        modelLabel.stringValue = "\(s.model)  v\(s.version)"

        // Update TFT display view
        tftView.model = s.model.isEmpty ? "—" : s.model
        tftView.contextPercent = s.contextPercent
        tftView.rate5h = s.rate5h
        tftView.rate7d = s.rate7d
        tftView.costStr = String(format: "$%.2f", s.costUSD)
        tftView.durationStr = "\(s.totalDurationMs / 1000)s"
        tftView.linesStr = "+\(s.linesAdded)/-\(s.linesRemoved)"
        tftView.needsAttention = s.needsAttention
        tftView.status = s.needsAttention ? "APPROVE" : (s.isIdle ? "Idle" : "Ready")
        if !s.activity.isEmpty {
            tftView.activity = s.activity
        }
        tftView.needsDisplay = true

        // Activity log
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
        menu.addItem(withTitle: "ClaudeKey Pro", action: nil, keyEquivalent: "")
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

    // ── CORE BUTTON ACTIONS ───────────────────────────
    @objc func doAccept() {
        sendKey(36)
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
            pttButton.attributedTitle = styledTitle("🎙 PTT", size: 11)
            statusItem.button?.title = "⌨"
            logActivity("PTT: recognizing...", color: .systemYellow)
        } else {
            let started = speech.startRecording()
            if started {
                pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
                pttButton.attributedTitle = styledTitle("⏹ STOP", size: 11)
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
            alwaysAcceptButton.attributedTitle = styledTitle("⏹ Stop", size: 11)
            logActivity("Always-Accept ON", color: .systemRed)
        } else {
            alwaysAcceptButton.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
            alwaysAcceptButton.attributedTitle = styledTitle("⚡ Always", size: 11)
            logActivity("Always-Accept OFF (auto-accepted \(alwaysAcceptCount)x)", color: .systemYellow)
        }
    }

    // ── PRO EXTRA ACTIONS ─────────────────────────────
    @objc func doUndo() {
        sendKey(6, flags: .maskCommand)  // Cmd+Z
        logActivity("Sent: Cmd+Z (undo)", color: .systemBlue)
    }

    @objc func doInterrupt() {
        sendKey(8, flags: .maskControl)  // Ctrl+C
        logActivity("Sent: Ctrl+C (interrupt)", color: .systemRed)
    }

    @objc func doTab() {
        sendKey(48)  // Tab
        logActivity("Sent: Tab", color: .systemBlue)
    }

    @objc func doPaste() {
        sendKey(9, flags: .maskCommand)  // Cmd+V
        logActivity("Sent: Cmd+V (paste)", color: .systemBlue)
    }

    // ── ENCODER ACTIONS ───────────────────────────────
    func encoderTurn(_ direction: Int) {
        encoderValue += direction
        if direction > 0 {
            sendKey(125)  // Down
            logActivity("Encoder: ▶ (Down) val=\(encoderValue)", color: .systemTeal)
        } else {
            sendKey(126)  // Up
            logActivity("Encoder: ◀ (Up) val=\(encoderValue)", color: .systemTeal)
        }
        tftView.encoderValue = "enc:\(encoderValue)"
        tftView.needsDisplay = true
    }

    func encoderPress() {
        sendKey(36)  // Enter
        logActivity("Encoder: Press (Enter)", color: .systemTeal)
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
