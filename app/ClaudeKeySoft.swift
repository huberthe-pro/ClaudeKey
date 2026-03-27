/**
 ClaudeKey Soft — pure software floating control panel

 NSPanel + .nonActivatingPanel: clicks NEVER steal focus from iTerm.

 Build:  cd app && ./build-soft.sh
 Run:    ./ClaudeKeySoft
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech

// ── SPEECH ENGINE ──────────────────────────────────────
// Uses AVAudioRecorder (file-based) instead of AVAudioEngine.installTap
// which has known NSException issues on macOS.
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
                    self.onError?("Speech permission denied. System Settings > Privacy > Speech Recognition")
                }
                completion(status == .authorized)
            }
        }
    }

    func startRecording() -> Bool {
        NSLog("ClaudeKey: [PTT] start recording, auth=\(authStatus.rawValue)")

        guard authStatus == .authorized else {
            onError?("Speech not authorized. System Settings > Privacy > Speech Recognition")
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
            NSLog("ClaudeKey: [PTT] AVAudioRecorder init failed: \(error)")
            onError?("Mic init failed: \(error.localizedDescription)")
            return false
        }

        recorder?.delegate = self
        guard recorder?.record() == true else {
            NSLog("ClaudeKey: [PTT] record() returned false")
            onError?("Mic failed to start recording")
            return false
        }

        isListening = true
        startTime = Date()
        NSLog("ClaudeKey: [PTT] RECORDING to \(tempFileURL.lastPathComponent)")
        return true
    }

    func stopRecording() {
        guard isListening else { return }
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        NSLog("ClaudeKey: [PTT] stop recording, duration=%.1fs", duration)

        recorder?.stop()
        recorder = nil
        isListening = false

        guard duration > 0.3 else {
            NSLog("ClaudeKey: [PTT] too short (< 0.3s), skipping recognition")
            onError?("Recording too short")
            return
        }

        // Recognize the recorded file
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: tempFileURL)
        NSLog("ClaudeKey: [PTT] recognizing...")

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("ClaudeKey: [PTT] recognition error: \(error.localizedDescription)")
                    self?.onError?("Recognition failed: \(error.localizedDescription)")
                    return
                }
                guard let result = result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                NSLog("ClaudeKey: [PTT] recognized: \"\(text)\"")
                self?.onResult?(text)
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

// ── NON-ACTIVATING BUTTON ──────────────────────────────
class NonActivatingButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    var onPress: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        onPress?()
    }
    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
    }
}

// ── NON-ACTIVATING PANEL ───────────────────────────────
class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ── CLAUDE STATUS READER ───────────────────────────────
struct ClaudeStatus {
    var contextPercent: Int = 0
    var model: String = ""
    var costUSD: Double = 0
    var rate5h: Int = 0
    var rate7d: Int = 0
    var project: String = ""

    static func read() -> ClaudeStatus? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/claudekey-status.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var s = ClaudeStatus()
        if let cw = json["context_window"] as? [String: Any] {
            s.contextPercent = cw["used_percentage"] as? Int ?? 0
        }
        if let m = json["model"] as? [String: Any] {
            s.model = m["display_name"] as? String ?? ""
        }
        if let c = json["cost"] as? [String: Any] {
            s.costUSD = c["total_cost_usd"] as? Double ?? 0
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
        return s
    }
}

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: ControlPanel!
    var statusItem: NSStatusItem!
    let speech = SpeechEngine()
    var pttButton: NonActivatingButton!
    var statusLabel: NSTextField!
    var transcriptLabel: NSTextField!
    var ctxBarView: NSView!
    var ctxBarFill: NSView!
    var ctxLabel: NSTextField!
    var infoLabel: NSTextField!
    var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Accessibility
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let axOk = AXIsProcessTrustedWithOptions(opts)

        setupPanel()
        setupMenuBar()

        // Show initial status
        if !axOk {
            setStatus("Need Accessibility permission", color: .systemOrange)
        }

        // Request mic permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.setStatus("Microphone permission denied", color: .systemRed)
                }
            }
        }

        // Request speech permission
        speech.onError = { [weak self] msg in
            self?.setStatus(msg, color: .systemRed)
            self?.transcriptLabel.stringValue = ""
        }
        speech.onResult = { [weak self] text in
            guard let self = self, !text.isEmpty else { return }
            self.setStatus("Typing: \(text)", color: .systemGreen)
            self.transcriptLabel.stringValue = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                typeString(text)
                sendKey(36) // Enter
                self.setStatus("Ready", color: .systemGreen)
            }
        }
        speech.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.setStatus("Ready", color: .systemGreen)
            } else {
                self.setStatus("Speech permission denied", color: .systemRed)
            }
        }

        NSLog("ClaudeKey Soft: ready")
    }

    // ── STATUS ─────────────────────────────────────────
    func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        NSLog("ClaudeKey: \(text)")
    }

    // ── FLOATING PANEL ─────────────────────────────────
    func setupPanel() {
        let panelW: CGFloat = 260
        let panelH: CGFloat = 240

        let screen = NSScreen.main!.visibleFrame
        let x = screen.maxX - panelW - 20
        let y = screen.minY + 20

        panel = ControlPanel(
            contentRect: NSRect(x: x, y: y, width: panelW, height: panelH),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "ClaudeKey"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(white: 0.15, alpha: 0.95)

        let contentView = panel.contentView!

        // ── Status bar at top ──
        statusLabel = NSTextField(labelWithString: "Starting...")
        statusLabel.frame = NSRect(x: 8, y: panelH - 36, width: panelW - 16, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .systemYellow
        statusLabel.backgroundColor = .clear
        contentView.addSubview(statusLabel)

        // ── Transcript display ──
        transcriptLabel = NSTextField(labelWithString: "")
        transcriptLabel.frame = NSRect(x: 8, y: panelH - 56, width: panelW - 16, height: 18)
        transcriptLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        transcriptLabel.textColor = .white
        transcriptLabel.backgroundColor = .clear
        transcriptLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(transcriptLabel)

        // ── Button grid: 3x2 ──
        let btnDefs: [(String, Selector)] = [
            ("🎙 PTT",    #selector(pttToggle)),
            ("✓ Accept",  #selector(doAccept)),
            ("✗ Reject",  #selector(doReject)),
            ("↑ Up",      #selector(doUp)),
            ("⚡ Auto",   #selector(doAutoYes)),
            ("↓ Down",    #selector(doDown)),
        ]

        let cols = 3
        let btnW: CGFloat = 76
        let btnH: CGFloat = 40
        let padX: CGFloat = 8
        let padY: CGFloat = 6
        let gridTop: CGFloat = panelH - 68

        for (i, (title, action)) in btnDefs.enumerated() {
            let col = i % cols
            let row = i / cols
            let bx = padX + CGFloat(col) * (btnW + padX)
            let by = gridTop - CGFloat(row) * (btnH + padY) - btnH

            let btn = NonActivatingButton(frame: NSRect(x: bx, y: by, width: btnW, height: btnH))
            btn.title = title
            btn.target = self
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            btn.layer?.cornerRadius = 6
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            )

            btn.onPress = { [weak self] in
                NSApp.sendAction(action, to: self, from: btn)
            }

            if title.contains("PTT") { pttButton = btn }
            contentView.addSubview(btn)
        }

        // ── Claude Code Status Area ──
        let statusY: CGFloat = 8

        // Context bar background
        ctxBarView = NSView(frame: NSRect(x: 8, y: statusY + 28, width: panelW - 60, height: 10))
        ctxBarView.wantsLayer = true
        ctxBarView.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        ctxBarView.layer?.cornerRadius = 3
        contentView.addSubview(ctxBarView)

        // Context bar fill
        ctxBarFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 10))
        ctxBarFill.wantsLayer = true
        ctxBarFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        ctxBarFill.layer?.cornerRadius = 3
        ctxBarView.addSubview(ctxBarFill)

        // Context percentage label
        ctxLabel = NSTextField(labelWithString: "—")
        ctxLabel.frame = NSRect(x: panelW - 48, y: statusY + 26, width: 44, height: 14)
        ctxLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        ctxLabel.textColor = .systemGreen
        ctxLabel.alignment = .right
        ctxLabel.backgroundColor = .clear
        contentView.addSubview(ctxLabel)

        // Info line: model | cost | rate limits
        infoLabel = NSTextField(labelWithString: "Claude Code status: waiting...")
        infoLabel.frame = NSRect(x: 8, y: statusY + 4, width: panelW - 16, height: 20)
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        infoLabel.textColor = NSColor(white: 0.6, alpha: 1)
        infoLabel.backgroundColor = .clear
        infoLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(infoLabel)

        panel.orderFront(nil)

        // ── Poll Claude Code status every 1s ──
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateClaudeStatus()
        }
    }

    // ── CLAUDE STATUS UPDATE ──────────────────────────
    func updateClaudeStatus() {
        guard let s = ClaudeStatus.read() else { return }

        // Context bar fill width
        let barW = ctxBarView.frame.width
        let fillW = barW * CGFloat(min(s.contextPercent, 100)) / 100.0
        ctxBarFill.frame.size.width = fillW

        // Color based on usage
        let barColor: NSColor
        if s.contextPercent < 25 {
            barColor = .systemGreen
        } else if s.contextPercent < 50 {
            barColor = .systemBlue
        } else if s.contextPercent < 75 {
            barColor = .systemYellow
        } else {
            barColor = .systemRed
        }
        ctxBarFill.layer?.backgroundColor = barColor.cgColor
        ctxLabel.textColor = barColor
        ctxLabel.stringValue = "\(s.contextPercent)%"

        // Info line
        let cost = String(format: "$%.2f", s.costUSD)
        infoLabel.stringValue = "\(s.project) | \(cost) | 5h:\(s.rate5h)% 7d:\(s.rate7d)%"
    }

    // ── MENUBAR ────────────────────────────────────────
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"

        let menu = NSMenu()
        menu.addItem(withTitle: "ClaudeKey Soft v0.1", action: nil, keyEquivalent: "")
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

    // ── ACTIONS ────────────────────────────────────────
    @objc func doAccept() {
        typeString("y")
        usleep(20000)
        sendKey(36)  // Enter
        flashButton(statusLabel, text: "Sent: y + Enter", color: .systemGreen)
    }

    @objc func doReject() {
        sendKey(53)  // Escape
        flashButton(statusLabel, text: "Sent: Esc", color: .systemOrange)
    }

    @objc func doUp() {
        sendKey(126)  // Up
        flashButton(statusLabel, text: "Sent: Up", color: .systemBlue)
    }

    @objc func doDown() {
        sendKey(125)  // Down
        flashButton(statusLabel, text: "Sent: Down", color: .systemBlue)
    }

    @objc func pttToggle() {
        if speech.isListening {
            // Stop recording → triggers recognition → onResult types text
            speech.stopRecording()
            pttButton.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            pttButton.attributedTitle = styledTitle("🎙 PTT")
            statusItem.button?.title = "⌨"
            setStatus("Recognizing...", color: .systemYellow)
            transcriptLabel.stringValue = "(processing...)"
        } else {
            // Start recording
            let started = speech.startRecording()
            if started {
                pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
                pttButton.attributedTitle = styledTitle("⏹ STOP")
                statusItem.button?.title = "🎙"
                setStatus("Recording... click STOP when done", color: .systemRed)
                transcriptLabel.stringValue = "(recording...)"
            }
        }
    }

    @objc func doAutoYes() {
        setStatus("Auto-Yes: not implemented (v0.2)", color: .systemYellow)
    }

    // ── HELPERS ────────────────────────────────────────
    func styledTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        )
    }

    func flashButton(_ label: NSTextField, text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if label.stringValue == text {
                label.stringValue = "Ready"
                label.textColor = .systemGreen
            }
        }
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
