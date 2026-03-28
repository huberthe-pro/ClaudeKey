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

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: ControlPanel!
    var statusItem: NSStatusItem!
    let speech = SpeechEngine()

    // UI elements
    var statusStrip: NSView!  // top color strip synced with LED state
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
    var debugLabel: NSTextField!

    // Activity log
    var logView: NSScrollView!
    var logText: NSTextView!
    var activityLog: [(Date, String, NSColor)] = []
    let maxLogEntries = 100

    var pollTimer: Timer?
    var blinkState = false
    var lastActivity = ""
    var stripMode = ""  // tracks current animation to avoid restarting every poll
    var alwaysAccept = false
    var alwaysAcceptCount = 0
    var alwaysAcceptButton: NonActivatingButton!

    // Session routing
    var sessions: [String] = []   // discovered session ids
    var sessionIndex = 0          // currently tracked session
    var sessionLabel: NSTextField!

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

        // ── Status strip (synced with LED state) ──
        let stripH: CGFloat = 4
        y -= stripH
        statusStrip = NSView(frame: NSRect(x: 0, y: y, width: panelW, height: stripH))
        statusStrip.wantsLayer = true
        statusStrip.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor  // white = disconnected
        cv.addSubview(statusStrip)

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

        // ── Session selector (◀ project ▶) ──
        y -= 4
        y -= 18
        let arrowW: CGFloat = 22
        let prevBtn = makeButton("◀", #selector(prevSession), NSColor(white: 0.22, alpha: 1))
        prevBtn.frame = NSRect(x: pad, y: y, width: arrowW, height: 18)
        cv.addSubview(prevBtn)

        let nextBtn = makeButton("▶", #selector(nextSession), NSColor(white: 0.22, alpha: 1))
        nextBtn.frame = NSRect(x: pad + w - arrowW, y: y, width: arrowW, height: 18)
        cv.addSubview(nextBtn)

        sessionLabel = makeLabel("—", size: 10, weight: .medium, color: NSColor(white: 0.6, alpha: 1))
        sessionLabel.frame = NSRect(x: pad + arrowW + 4, y: y, width: w - arrowW * 2 - 8, height: 18)
        sessionLabel.alignment = .center
        cv.addSubview(sessionLabel)

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

        // ── Debug / Hook status ──
        y -= 4
        y -= 24
        debugLabel = makeLabel("", size: 9, weight: .regular, color: NSColor(white: 0.38, alpha: 1))
        debugLabel.frame = NSRect(x: pad, y: y, width: w, height: 24)
        debugLabel.maximumNumberOfLines = 2
        debugLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        cv.addSubview(debugLabel)

        // ── Divider 2 ──
        y -= 4
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
    func makeButton(_ title: String, _ action: Selector, _ bg: NSColor) -> NonActivatingButton {
        let b = NonActivatingButton()
        b.title = title
        b.bezelStyle = .rounded
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = bg.cgColor
        b.layer?.cornerRadius = 4
        b.font = NSFont.systemFont(ofSize: 11)
        b.contentTintColor = NSColor(white: 0.75, alpha: 1)
        b.target = self
        b.action = action
        b.onPress = { [weak self] in self?.perform(action) }
        return b
    }

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
    func statusNSColor(for s: ClaudeStatus) -> NSColor {
        switch s.ledColor() {
        case "red":    return .systemRed
        case "blue":   return .systemBlue
        case "yellow": return .systemYellow
        case "green":  return .systemGreen
        case "purple": return .systemPurple
        default:       return NSColor(white: 0.3, alpha: 1)
        }
    }

    func applyStripAnimation(color: NSColor, mode: String) {
        guard let layer = statusStrip.layer else { return }
        let key = "\(mode)-\(color.description)"
        guard key != stripMode else { return }
        stripMode = key
        layer.removeAllAnimations()
        layer.backgroundColor = color.cgColor
        layer.opacity = 1.0
        switch mode {
        case "b":
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0; anim.toValue = 0.12
            anim.duration = 1.8; anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "breathe")
        case "k":
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0; anim.toValue = 0.0
            anim.duration = 0.45; anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(anim, forKey: "blink")
        default: break
        }
    }

    @objc func prevSession() { switchSession(by: -1) }
    @objc func nextSession() { switchSession(by: +1) }

    func switchSession(by delta: Int) {
        let s = ClaudeStatus.availableSessions()
        guard !s.isEmpty else { return }
        sessions = s
        sessionIndex = ((sessionIndex + delta) % s.count + s.count) % s.count
        lastActivity = ""  // reset log on switch
        stripMode = ""
    }

    func updateClaudeStatus() {
        // Refresh session list and clamp index
        let available = ClaudeStatus.availableSessions()
        if available != sessions { sessions = available }
        if sessions.isEmpty { sessionIndex = 0 }
        else if sessionIndex >= sessions.count { sessionIndex = 0 }

        let sid: String? = sessions.isEmpty ? nil : sessions[sessionIndex]
        guard let s = ClaudeStatus.read(session: sid) else { return }

        // Session selector label
        if sessions.isEmpty {
            sessionLabel.stringValue = "no sessions"
        } else {
            let idx = sessionIndex + 1
            sessionLabel.stringValue = "\(s.project.isEmpty ? sid ?? "?" : s.project)  [\(idx)/\(sessions.count)]"
        }

        // Status strip (synced with LED: breathe/blink/solid)
        applyStripAnimation(color: statusNSColor(for: s), mode: s.ledMode())

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

        // Debug: hook file ages + computed state
        let now = Int(Date().timeIntervalSince1970)
        func fileAge(_ path: String) -> String {
            guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
                  let mod = attr[.modificationDate] as? Date else { return "missing" }
            let age = now - Int(mod.timeIntervalSince1970)
            return "\(age)s ago"
        }
        func fileSnippet(_ path: String) -> String {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), !d.isEmpty,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return "(empty)"
            }
            if let act = j["activity"] as? String { return "\"\(act)\"" }
            if let t = j["type"] as? String { return "type=\(t)" }
            return "(ok)"
        }
        let pfx = s.sessionId.isEmpty ? "" : "/tmp/claudekey-\(s.sessionId)"
        let statusAge  = fileAge(pfx.isEmpty ? "/tmp/claudekey-status.json"   : "\(pfx)-status.json")
        let actAge     = fileAge(pfx.isEmpty ? "/tmp/claudekey-activity.json" : "\(pfx)-activity.json")
        let actSnip    = fileSnippet(pfx.isEmpty ? "/tmp/claudekey-activity.json" : "\(pfx)-activity.json")
        let notifySnip = fileSnippet(pfx.isEmpty ? "/tmp/claudekey-notify.json"   : "\(pfx)-notify.json")
        let state = "attn=\(s.needsAttention) work=\(s.isWorking) idle=\(s.isIdle) → \(s.ledColor())/\(s.ledMode())"
        debugLabel.stringValue = "status:\(statusAge)  act:\(actAge) \(actSnip)\nnotify:\(notifySnip)  \(state)"

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
            // Clear session-specific notify file to prevent re-trigger
            let notifyPath = s.sessionId.isEmpty
                ? "/tmp/claudekey-notify.json"
                : "/tmp/claudekey-\(s.sessionId)-notify.json"
            if alwaysAccept {
                alwaysAcceptCount += 1
                sendKey(36)
                try? "".write(toFile: notifyPath, atomically: true, encoding: .utf8)
                logActivity("Auto-accept #\(alwaysAcceptCount): Enter", color: .systemGreen)
                return
            }
            blinkState.toggle()
            if blinkState {
                logActivity(">>> NEEDS APPROVAL <<<", color: .systemYellow)
            }
            // High-contrast blink: bright orange vs dark background
            acceptButton.layer?.backgroundColor = blinkState
                ? NSColor.systemOrange.cgColor
                : NSColor(white: 0.18, alpha: 1).cgColor
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
        let voiceItem = NSMenuItem(title: "Voice Engine", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        let sysItem = NSMenuItem(title: "System (Apple STT)", action: nil, keyEquivalent: "")
        sysItem.state = .on
        voiceMenu.addItem(sysItem)
        voiceMenu.addItem(NSMenuItem.separator())
        let otherItem = NSMenuItem(title: "Other…", action: nil, keyEquivalent: "")
        otherItem.isEnabled = false
        voiceMenu.addItem(otherItem)
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
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
@main
enum ClaudeKeyLiteApp {
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
