/**
 ClaudeKey — macOS menubar companion app

 Responsibilities:
 1. Listen for F13 key (from ClaudeKey hardware PTT button)
 2. Record audio from default mic → Apple SFSpeechRecognizer → type text
 3. Fallback: if Speech framework unavailable, simulate WisprFlow hotkey
 4. Show menubar icon with PTT status

 Build:  ./build.sh
 Run:    ./ClaudeKey &
 Requires: Accessibility + Microphone + Speech Recognition permissions
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech

// ── CONFIG ─────────────────────────────────────────────
let F13_KEYCODE: Int64 = 105

// Fallback WisprFlow hotkey (used when Speech framework unavailable)
let WISPR_KEYCODE: CGKeyCode = 49  // Space
let WISPR_FLAGS: CGEventFlags = [.maskCommand, .maskShift]  // Cmd+Shift+Space

// ── SPEECH RECOGNIZER ──────────────────────────────────
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
        // Cancel any previous task
        _ = stopListening()
        currentTranscript = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            NSLog("ClaudeKey: speech recognizer not available")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
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
        do {
            try audioEngine.start()
            NSLog("ClaudeKey: listening...")
        } catch {
            NSLog("ClaudeKey: audio engine failed to start: \(error)")
        }
    }

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

// ── KEYBOARD TYPER ─────────────────────────────────────
func typeString(_ text: String) {
    // Type text into frontmost app via CGEvents
    for char in text {
        let str = String(char)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }

        // Use UniChar approach for universal character input
        var chars = Array(str.utf16)
        event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        event.post(tap: .cgAnnotatedSessionEventTap)

        // Key up
        guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
        upEvent.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        upEvent.post(tap: .cgAnnotatedSessionEventTap)

        usleep(5000)  // 5ms between chars
    }
}

func typeEnter() {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return }
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
}

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var pttActive = false
    let speech = SpeechEngine()
    var useBuiltinSTT = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()

        if !checkAccessibility() {
            showAlert(title: "Accessibility permission needed",
                      message: "System Settings > Privacy & Security > Accessibility")
        }

        // Request mic + speech permissions
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("ClaudeKey: mic permission \(granted ? "granted" : "denied")")
        }
        speech.requestPermission { available in
            self.useBuiltinSTT = available
            if !available {
                NSLog("ClaudeKey: speech recognition denied, falling back to WisprFlow mode")
                self.updateMenuMode()
            }
        }

        setupEventTap()
        NSLog("ClaudeKey: ready")
    }

    // ── MENUBAR ────────────────────────────────────────
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"

        let menu = NSMenu()
        menu.addItem(withTitle: "ClaudeKey v0.1", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Voice: Built-in STT", action: nil, keyEquivalent: "")
        modeItem.tag = 100
        modeItem.isEnabled = false
        menu.addItem(modeItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func updateMenuMode() {
        if let menu = statusItem.menu, let item = menu.item(withTag: 100) {
            item.title = useBuiltinSTT ? "Voice: Built-in STT" : "Voice: WisprFlow (fallback)"
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // ── ACCESSIBILITY ──────────────────────────────────
    func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // ── EVENT TAP (F13 → PTT) ──────────────────────────
    func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
                let d = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                return d.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("ClaudeKey: event tap failed — check Accessibility")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == F13_KEYCODE else { return Unmanaged.passRetained(event) }

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            if !pttActive {
                pttActive = true
                pttStart()
                DispatchQueue.main.async { self.statusItem.button?.title = "🎙" }
            }
            return nil
        } else if type == .keyUp {
            if pttActive {
                pttActive = false
                pttStop()
                DispatchQueue.main.async { self.statusItem.button?.title = "⌨" }
            }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // ── PTT ACTIONS ────────────────────────────────────
    func pttStart() {
        if useBuiltinSTT {
            speech.startListening()
        } else {
            simulateWisprHotkey(keyDown: true)
        }
    }

    func pttStop() {
        if useBuiltinSTT {
            let text = speech.stopListening()
            if !text.isEmpty {
                NSLog("ClaudeKey: recognized: \(text)")
                // Small delay to ensure audio cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    typeString(text)
                    typeEnter()
                }
            }
        } else {
            simulateWisprHotkey(keyDown: false)
        }
    }

    func simulateWisprHotkey(keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: WISPR_KEYCODE, keyDown: keyDown) else { return }
        event.flags = WISPR_FLAGS
        event.post(tap: .cgSessionEventTap)
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
