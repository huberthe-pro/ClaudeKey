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
class SpeechEngine: NSObject {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private(set) var currentTranscript = ""
    private(set) var isListening = false
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var onTranscriptUpdate: ((String) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        // Use system locale, fallback to en-US
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authStatus = status
                let granted = (status == .authorized)
                if !granted {
                    let reason: String
                    switch status {
                    case .denied: reason = "Speech recognition denied in System Settings"
                    case .restricted: reason = "Speech recognition restricted on this device"
                    case .notDetermined: reason = "Speech permission not yet requested"
                    default: reason = "Unknown speech permission status"
                    }
                    self.onError?(reason)
                }
                completion(granted)
            }
        }
    }

    func startListening() -> Bool {
        guard authStatus == .authorized else {
            onError?("Speech not authorized (status: \(authStatus.rawValue)). Check System Settings > Privacy > Speech Recognition")
            return false
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable for locale: \(Locale.current.identifier)")
            return false
        }

        // Clean up any previous session
        if isListening { cleanupAudio() }
        currentTranscript = ""
        isListening = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            onError?("No audio input available. Check microphone permission.")
            isListening = false
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.currentTranscript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.onTranscriptUpdate?(self.currentTranscript)
                }
            }
            if let error = error {
                DispatchQueue.main.async {
                    if self.isListening {
                        self.onError?("Recognition error: \(error.localizedDescription)")
                    }
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            return true
        } catch {
            onError?("Mic failed to start: \(error.localizedDescription)")
            cleanupAudio()
            isListening = false
            return false
        }
    }

    @discardableResult
    func stopListening() -> String {
        let transcript = currentTranscript
        cleanupAudio()
        isListening = false
        return transcript
    }

    private func cleanupAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
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

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: ControlPanel!
    var statusItem: NSStatusItem!
    let speech = SpeechEngine()
    var pttButton: NonActivatingButton!
    var statusLabel: NSTextField!
    var transcriptLabel: NSTextField!

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
        }
        speech.onTranscriptUpdate = { [weak self] text in
            self?.transcriptLabel.stringValue = text.isEmpty ? "(listening...)" : text
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
        let panelH: CGFloat = 180

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

        panel.orderFront(nil)
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
            // Stop recording, get transcript, type it
            let text = speech.stopListening()
            pttButton.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            pttButton.attributedTitle = styledTitle("🎙 PTT")
            statusItem.button?.title = "⌨"

            if text.isEmpty {
                setStatus("No speech detected", color: .systemYellow)
                transcriptLabel.stringValue = ""
            } else {
                setStatus("Typing: \(text)", color: .systemGreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    typeString(text)
                    sendKey(36)  // Enter
                    self.setStatus("Ready", color: .systemGreen)
                    self.transcriptLabel.stringValue = ""
                }
            }
        } else {
            // Start recording
            transcriptLabel.stringValue = "(listening...)"
            let started = speech.startListening()
            if started {
                pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
                pttButton.attributedTitle = styledTitle("⏹ STOP")
                statusItem.button?.title = "🎙"
                setStatus("Recording... click STOP when done", color: .systemRed)
            }
            // If !started, speech.onError already called setStatus
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
