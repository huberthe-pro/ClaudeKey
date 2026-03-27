/**
 ClaudeKey Soft — pure software floating control panel

 A non-activating floating panel with 6 buttons that NEVER steals
 focus from iTerm/Terminal. Sends keystrokes to the frontmost app
 via CGEvent, exactly like the hardware version.

 Build:  swiftc -O -framework AppKit -framework CoreGraphics -framework AVFoundation -framework Speech -o ClaudeKeySoft ClaudeKeySoft.swift
 Run:    ./ClaudeKeySoft &

 The panel uses NSPanel + .nonActivatingPanel so clicking buttons
 does NOT move focus away from the terminal. This is the same
 technique macOS uses for the virtual keyboard and Character Viewer.
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech

// ── SPEECH ENGINE (same as hardware version) ───────────
class SpeechEngine {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentTranscript = ""
    var isAvailable = false

    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.isAvailable = (status == .authorized)
                completion(self.isAvailable)
            }
        }
    }

    func startListening() {
        _ = stopListening()
        currentTranscript = ""
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                self?.currentTranscript = result.bestTranscription.formattedString
            }
            if error != nil {
                self?.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
            }
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch { NSLog("ClaudeKey: audio error: \(error)") }
    }

    @discardableResult
    func stopListening() -> String {
        let transcript = currentTranscript
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        return transcript
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
// NSButton subclass that explicitly refuses to make the window key
class NonActivatingButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Highlight
        isHighlighted = true
        // Execute action immediately without activating window
        if let action = action, let target = target {
            NSApp.sendAction(action, to: target, from: self)
        }
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
    var pttActive = false
    var pttButton: NonActivatingButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Permissions
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        speech.requestPermission { _ in }

        setupPanel()
        setupMenuBar()

        NSLog("ClaudeKey Soft: ready")
    }

    // ── FLOATING PANEL ─────────────────────────────────
    func setupPanel() {
        let panelW: CGFloat = 240
        let panelH: CGFloat = 120

        // Position: bottom-right of screen
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

        // Button grid: 3x2
        let buttons: [(String, String, Selector)] = [
            ("🎙 PTT",    "ptt",    #selector(pttToggle)),
            ("✓ Accept",  "accept", #selector(doAccept)),
            ("✗ Reject",  "reject", #selector(doReject)),
            ("↑ Up",      "up",     #selector(doUp)),
            ("⚡ Auto",   "auto",   #selector(doAutoYes)),
            ("↓ Down",    "down",   #selector(doDown)),
        ]

        let cols = 3
        let btnW: CGFloat = 70
        let btnH: CGFloat = 40
        let padX: CGFloat = 8
        let padY: CGFloat = 8
        let startY: CGFloat = panelH - 50  // below titlebar

        for (i, (title, _, action)) in buttons.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = padX + CGFloat(col) * (btnW + padX)
            let y = startY - CGFloat(row) * (btnH + padY) - btnH

            let btn = NonActivatingButton(frame: NSRect(x: x, y: y, width: btnW, height: btnH))
            btn.title = title
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = action
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            btn.contentTintColor = .white
            // Make button opaque and visible
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            btn.layer?.cornerRadius = 6
            btn.isBordered = false

            if title.contains("PTT") {
                pttButton = btn
            }

            panel.contentView?.addSubview(btn)
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

    // ── BUTTON ACTIONS ─────────────────────────────────
    @objc func doAccept() {
        typeString("y")
        usleep(20000)
        sendKey(36)  // Enter
    }

    @objc func doReject() {
        sendKey(53)  // Escape
    }

    @objc func doUp() {
        sendKey(126)  // Up arrow
    }

    @objc func doDown() {
        sendKey(125)  // Down arrow
    }

    @objc func pttToggle() {
        if pttActive {
            pttActive = false
            let text = speech.stopListening()
            pttButton.title = "🎙 PTT"
            pttButton.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            if !text.isEmpty {
                NSLog("ClaudeKey: recognized: \(text)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    typeString(text)
                    sendKey(36)  // Enter
                }
            }
        } else {
            pttActive = true
            speech.startListening()
            pttButton.title = "⏹ Stop"
            pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }

    @objc func doAutoYes() {
        // v0.2: auto-approve loop
        NSLog("ClaudeKey: Auto-Yes not implemented yet")
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
