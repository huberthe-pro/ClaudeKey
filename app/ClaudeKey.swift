/**
 ClaudeKey — macOS menubar companion app

 Responsibilities:
 1. Listen for F13 key (from ClaudeKey hardware PTT button)
 2. Simulate Cmd+Shift+Space (WisprFlow push-to-talk hotkey)
 3. Show menubar icon

 Build:  ./build.sh
 Run:    ./ClaudeKey &
 Requires: Accessibility permission (System Settings > Privacy > Accessibility)
*/

import AppKit
import CoreGraphics

// ── CONFIG ─────────────────────────────────────────────
let PTT_HOTKEY_KEYCODE: CGKeyCode = 49  // Space
let PTT_HOTKEY_FLAGS: CGEventFlags = [.maskCommand, .maskShift]  // Cmd+Shift+Space
let F13_KEYCODE: Int64 = 105

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var pttActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // hide from Dock
        setupMenuBar()

        if !checkAccessibility() {
            showAccessibilityAlert()
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

        let pttItem = NSMenuItem(title: "PTT: Cmd+Shift+Space", action: nil, keyEquivalent: "")
        pttItem.isEnabled = false
        menu.addItem(pttItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // ── ACCESSIBILITY ──────────────────────────────────
    func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "ClaudeKey needs Accessibility permission"
        alert.informativeText = "Go to System Settings > Privacy & Security > Accessibility and add ClaudeKey."
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
                guard let userInfo = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                return delegate.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("ClaudeKey: failed to create event tap — check Accessibility permission")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("ClaudeKey: event tap active")
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == F13_KEYCODE else {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            // Ignore key repeat events
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil  // consume
            }
            if !pttActive {
                pttActive = true
                simulatePTT(keyDown: true)
                DispatchQueue.main.async { self.statusItem.button?.title = "🎙" }
            }
            return nil  // consume F13
        } else if type == .keyUp {
            if pttActive {
                pttActive = false
                simulatePTT(keyDown: false)
                DispatchQueue.main.async { self.statusItem.button?.title = "⌨" }
            }
            return nil  // consume F13
        }

        return Unmanaged.passRetained(event)
    }

    func simulatePTT(keyDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: PTT_HOTKEY_KEYCODE,
            keyDown: keyDown
        ) else { return }
        event.flags = PTT_HOTKEY_FLAGS
        event.post(tap: .cgSessionEventTap)
    }
}

// ── MAIN ───────────────────────────────────────────────
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
