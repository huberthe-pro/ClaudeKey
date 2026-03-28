/**
 ClaudeKey Pro — Simulator (Pro Edition)

 Layout matches hardware render (Image 3):
   ┌────────────────────────────────────┐
   │  OLED 2.42" 128x64  (full width)  │
   ├─────────────────────┬──────────────┤
   │ [PTT][Accept][Reject]│             │
   │                     │   KNOB      │
   │ [Up ][ Auto ][ Down ]│             │
   ├─────────────────────┴──────────────┤
   │ [Undo] [Interrupt] [Tab] [Paste]  │
   └────────────────────────────────────┘

 Build:  cd app/pro && ./build.sh
 Run:    ./ClaudeKeyPro
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech

// ── OLED DISPLAY VIEW ──────────────────────────────────
// Simulates SSD1309 2.42" 128x64 monochrome OLED (green phosphor)
class OLEDView: NSView {
    // Data fed from status updates
    var line1 = "SYSTEM STATUS:"
    var line2 = "—"
    var line3 = ""
    var line4 = ""
    var needsApproval = false
    var isIdle = false

    private let bgColor  = NSColor(red: 0.02, green: 0.04, blue: 0.02, alpha: 1)
    private let green    = NSColor(red: 0.18, green: 1.00, blue: 0.25, alpha: 1)
    private let dimGreen = NSColor(red: 0.10, green: 0.55, blue: 0.14, alpha: 1)
    private let yellow   = NSColor(red: 1.00, green: 0.85, blue: 0.00, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        // Background + bezel
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        ctx.setFillColor(bgColor.cgColor)
        let inner = bounds.insetBy(dx: 4, dy: 4)
        CGPath(roundedRect: inner, cornerWidth: 3, cornerHeight: 3, transform: nil).let { p in
            ctx.addPath(p); ctx.fillPath()
        }

        // Scanline shimmer (subtle horizontal lines)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.15).cgColor)
        var sy: CGFloat = inner.minY
        while sy < inner.maxY {
            ctx.fill(CGRect(x: inner.minX, y: sy, width: inner.width, height: 1))
            sy += 3
        }

        let pad: CGFloat = 8
        let fw = inner.width - pad * 2
        var ty = inner.maxY - pad

        if needsApproval {
            // Full yellow alert mode
            ctx.setFillColor(yellow.withAlphaComponent(0.12).cgColor)
            ctx.fill(inner)
            drawOLEDText(ctx, "NEEDS APPROVAL", x: inner.minX + pad,
                         y: ty - 22, size: 20, color: yellow, bold: true, maxW: fw)
            // Progress bar in yellow
            let barY = inner.minY + pad + 4
            drawOLEDBar(ctx, x: inner.minX + pad, y: barY, w: fw, h: 8,
                        percent: line4.isEmpty ? 0 : Int(line4) ?? 0, color: yellow)
        } else {
            // Normal 4-line display
            ty -= 13
            drawOLEDText(ctx, line1, x: inner.minX + pad, y: ty,
                         size: 11, color: dimGreen, bold: false, maxW: fw)
            ty -= 16
            drawOLEDText(ctx, line2, x: inner.minX + pad, y: ty,
                         size: 13, color: green, bold: true, maxW: fw)
            ty -= 14
            if !line3.isEmpty {
                drawOLEDText(ctx, line3, x: inner.minX + pad, y: ty,
                             size: 10, color: dimGreen, bold: false, maxW: fw)
            }
            // Progress bar at bottom
            let barY = inner.minY + pad
            let ctxPct = Int(line4) ?? 0
            drawOLEDBar(ctx, x: inner.minX + pad, y: barY, w: fw, h: 5,
                        percent: ctxPct, color: ctxPct > 75 ? yellow : green)
        }
    }

    private func drawOLEDText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat,
                               size: CGFloat, color: NSColor, bold: Bool, maxW: CGFloat) {
        let font = NSFont(name: bold ? "Menlo-Bold" : "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // Truncate if needed
        var str = text
        while str.count > 1 {
            let w = (str as NSString).size(withAttributes: attrs).width
            if w <= maxW { break }
            str = String(str.dropLast())
        }
        NSAttributedString(string: str, attributes: attrs).draw(at: NSPoint(x: x, y: y))
    }

    private func drawOLEDBar(_ ctx: CGContext, x: CGFloat, y: CGFloat,
                              w: CGFloat, h: CGFloat, percent: Int, color: NSColor) {
        // Track
        ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
        let track = CGRect(x: x, y: y, width: w, height: h)
        ctx.fill(track)
        // Fill
        let fw = w * CGFloat(min(percent, 100)) / 100
        if fw > 0 {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: fw, height: h))
        }
    }
}

// Helper to use CGPath in a closure
extension CGPath {
    func `let`(_ block: (CGPath) -> Void) { block(self) }
}

// ── KNOB VIEW ──────────────────────────────────────────
class KnobView: NSView {
    var onTurnLeft:  (() -> Void)?
    var onTurnRight: (() -> Void)?
    var onPress:     (() -> Void)?

    private var angle: CGFloat = 0
    private var isPressed = false

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let cx = bounds.midX, cy = bounds.midY
        let r = min(bounds.width, bounds.height) / 2 - 4

        // Shadow ring
        ctx.setFillColor(NSColor(white: 0.05, alpha: 0.8).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r - 2, y: cy - r - 2, width: (r+2)*2, height: (r+2)*2))

        // Knob body gradient (brushed aluminum feel)
        let knobRect = CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)
        let baseGray: CGFloat = isPressed ? 0.25 : 0.30
        ctx.setFillColor(NSColor(white: baseGray, alpha: 1).cgColor)
        ctx.fillEllipse(in: knobRect)

        // Knurling lines
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: angle)
        ctx.setStrokeColor(NSColor(white: 0.18, alpha: 0.8).cgColor)
        ctx.setLineWidth(1)
        for i in 0..<20 {
            let a = CGFloat(i) * .pi * 2 / 20
            let x1 = cos(a) * (r * 0.75), y1 = sin(a) * (r * 0.75)
            let x2 = cos(a) * r, y2 = sin(a) * r
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
        }
        ctx.strokePath()

        // Center dot indicator
        ctx.setFillColor(NSColor(white: 0.7, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: -3, y: r * 0.55 - 3, width: 6, height: 6))
        ctx.restoreGState()

        // Outer ring highlight
        ctx.setStrokeColor(NSColor(white: 0.45, alpha: 0.6).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: knobRect.insetBy(dx: 1, dy: 1))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0 { turnLeft()  }
        else if event.deltaY < 0 { turnRight() }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
        onPress?()
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false; needsDisplay = true
    }

    // Left/right arrow buttons call these
    func turnLeft()  { angle -= .pi / 10; needsDisplay = true; onTurnLeft?()  }
    func turnRight() { angle += .pi / 10; needsDisplay = true; onTurnRight?() }

    override var acceptsFirstResponder: Bool { true }
}

// ── APP DELEGATE ───────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: ControlPanel!
    var statusItem: NSStatusItem!
    let speech = SpeechEngine()

    // Major UI sections
    var statusStrip: NSView!  // top color strip synced with LED state
    var oledView: OLEDView!
    var knobView: KnobView!
    var headerLabel: NSTextField!

    // Buttons we need to reference
    var pttButton: NonActivatingButton!
    var acceptButton: NonActivatingButton!
    var alwaysAcceptButton: NonActivatingButton!

    // Activity log
    var logView: NSScrollView!
    var logText: NSTextView!
    var activityLog: [(Date, String, NSColor)] = []
    var debugLabel: NSTextField!

    // State
    var pollTimer: Timer?
    var blinkState = false
    var lastActivity = ""
    var stripMode = ""  // tracks current animation to avoid restarting every poll
    var alwaysAccept = false
    var alwaysAcceptCount = 0
    var encoderPos = 0

    // Session routing
    var sessions: [String] = []
    var sessionIndex = 0
    var sessionLabel: NSTextField!

    // Hook fix state
    var pendingHookScript: String?
    var pendingSettingsPath: String?

    // Panel dimensions
    let panelW: CGFloat = 400
    let panelH: CGFloat = 560

    // Layout constants (matching hardware proportions)
    let pad:       CGFloat = 12
    let oledH:     CGFloat = 78   // 2.42" OLED bar
    let coreKeyH:  CGFloat = 40   // per row
    let extraKeyH: CGFloat = 30   // bottom shortcut row
    let knobSize:  CGFloat = 80
    let keyGap:    CGFloat = 5

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)

        setupPanel()
        setupMenuBar()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        speech.onError  = { [weak self] m in self?.log(m, .systemRed) }
        speech.onResult = { [weak self] t in
            guard let self = self, !t.isEmpty else { return }
            self.log("Voice: \(t)", .systemPurple)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { typeString(t); sendKey(36) }
        }
        speech.requestPermission { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.log("STT: \(self.speech.backendDescription)", .systemGreen)
            } else {
                self.log("Speech permission denied", .systemRed)
            }
        }
        checkHookStatus()
        log("ClaudeKey Pro ready", .systemGreen)
    }

    // ── PANEL BUILD ────────────────────────────────────
    func setupPanel() {
        let screen = NSScreen.main!.visibleFrame
        panel = ControlPanel(
            contentRect: NSRect(x: screen.maxX - panelW - 16, y: screen.minY + 16,
                                width: panelW, height: panelH),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "ClaudeKey Pro"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(white: 0.11, alpha: 0.97)
        panel.minSize = NSSize(width: 340, height: 480)

        let cv = panel.contentView!
        let w  = panelW - pad * 2
        let ch = cv.frame.height
        var y  = ch   // top-down

        // ── Status strip (synced with LED state) ──
        let stripH: CGFloat = 4
        y -= stripH
        statusStrip = NSView(frame: NSRect(x: 0, y: y, width: panelW, height: stripH))
        statusStrip.wantsLayer = true
        statusStrip.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        cv.addSubview(statusStrip)

        // ── Section 1: Project label + session selector ──
        y -= 6
        y -= 16
        headerLabel = label("ClaudeKey Pro", 12, .bold, .white)
        headerLabel.frame = NSRect(x: pad, y: y, width: w * 0.55, height: 16)
        cv.addSubview(headerLabel)

        // Session ◀ ▶ (right side of header row)
        let arrowW: CGFloat = 20
        let prevBtn = btn("◀", #selector(prevSession), NSColor(white: 0.22, alpha: 1))
        prevBtn.frame = NSRect(x: pad + w * 0.55 + 4, y: y, width: arrowW, height: 16)
        cv.addSubview(prevBtn)

        let nextBtn = btn("▶", #selector(nextSession), NSColor(white: 0.22, alpha: 1))
        nextBtn.frame = NSRect(x: pad + w - arrowW, y: y, width: arrowW, height: 16)
        cv.addSubview(nextBtn)

        sessionLabel = label("—", 9, .regular, NSColor(white: 0.5, alpha: 1))
        sessionLabel.frame = NSRect(x: pad + w * 0.55 + arrowW + 6, y: y,
                                    width: w * 0.45 - arrowW * 2 - 10, height: 16)
        sessionLabel.alignment = .center
        cv.addSubview(sessionLabel)

        // ── Section 2: OLED bar ──
        y -= 6
        y -= oledH
        oledView = OLEDView(frame: NSRect(x: pad, y: y, width: w, height: oledH))
        oledView.wantsLayer = true
        cv.addSubview(oledView)

        // ── Section 3: Core keys (3×2) + Knob ──
        y -= 8
        let keyAreaW = w - knobSize - keyGap * 2   // space for 3 keys
        let coreKeyW = (keyAreaW - keyGap * 2) / 3

        // Row definitions: [title, action, color]
        let coreRows: [[(String, Selector, NSColor)]] = [
            [("PTT",    #selector(pttToggle),     NSColor(white: 0.28, alpha: 1)),
             ("Accept", #selector(doAccept),       NSColor(red:0.14,green:0.30,blue:0.14,alpha:1)),
             ("Reject", #selector(doReject),       NSColor(red:0.30,green:0.12,blue:0.12,alpha:1))],
            [("Up",     #selector(doUp),           NSColor(white: 0.23, alpha: 1)),
             ("Auto",   #selector(doAlwaysAccept), NSColor(white: 0.23, alpha: 1)),
             ("Down",   #selector(doDown),         NSColor(white: 0.23, alpha: 1))],
        ]

        let twoRowH = CGFloat(coreRows.count) * coreKeyH + CGFloat(coreRows.count - 1) * keyGap
        let knobY   = y - twoRowH   // knob bottom aligns with bottom of 2 key rows

        for (rowIdx, row) in coreRows.enumerated() {
            let by = y - CGFloat(rowIdx) * (coreKeyH + keyGap) - coreKeyH
            for (colIdx, (title, action, bg)) in row.enumerated() {
                let bx = pad + CGFloat(colIdx) * (coreKeyW + keyGap)
                let btn = makeKey(title, frame: NSRect(x: bx, y: by, width: coreKeyW, height: coreKeyH),
                                  bg: bg, size: 11)
                btn.onPress = { [weak self] in NSApp.sendAction(action, to: self, from: nil) }
                cv.addSubview(btn)
                if title == "PTT"    { pttButton = btn }
                if title == "Accept" { acceptButton = btn }
                if title == "Auto"   { alwaysAcceptButton = btn }
            }
        }

        // Knob — right of the 2 key rows
        let knobX = pad + keyAreaW + keyGap
        knobView = KnobView(frame: NSRect(x: knobX, y: knobY, width: knobSize, height: twoRowH))
        knobView.wantsLayer = true
        knobView.onTurnLeft  = { [weak self] in self?.encoderTurn(-1) }
        knobView.onTurnRight = { [weak self] in self?.encoderTurn(1) }
        knobView.onPress     = { [weak self] in self?.encoderPress() }
        cv.addSubview(knobView)

        // Knob arrow buttons (small, under knob)
        let arrowY = knobY - 22
        let aw: CGFloat = (knobSize - 4) / 2
        let leftArrow = makeKey("◀", frame: NSRect(x: knobX, y: arrowY, width: aw, height: 20),
                                bg: NSColor(white: 0.18, alpha: 1), size: 10)
        leftArrow.onPress = { [weak self] in self?.knobView.turnLeft() }
        cv.addSubview(leftArrow)
        let rightArrow = makeKey("▶", frame: NSRect(x: knobX + aw + 4, y: arrowY, width: aw, height: 20),
                                 bg: NSColor(white: 0.18, alpha: 1), size: 10)
        rightArrow.onPress = { [weak self] in self?.knobView.turnRight() }
        cv.addSubview(rightArrow)

        y -= twoRowH + 6

        // ── Section 4: Extra shortcut row ──
        let extraDefs: [(String, Selector, NSColor)] = [
            ("Undo",       #selector(doUndo),      NSColor(white: 0.20, alpha: 1)),
            ("Interrupt",  #selector(doInterrupt), NSColor(red:0.28,green:0.10,blue:0.10,alpha:1)),
            ("Tab",        #selector(doTab),       NSColor(white: 0.20, alpha: 1)),
            ("Paste",      #selector(doPaste),     NSColor(white: 0.20, alpha: 1)),
        ]
        let extraKeyW = (w - keyGap * 3) / 4
        y -= extraKeyH
        for (i, (title, action, bg)) in extraDefs.enumerated() {
            let bx = pad + CGFloat(i) * (extraKeyW + keyGap)
            let btn = makeKey(title, frame: NSRect(x: bx, y: y, width: extraKeyW, height: extraKeyH),
                              bg: bg, size: 10)
            btn.onPress = { [weak self] in NSApp.sendAction(action, to: self, from: nil) }
            cv.addSubview(btn)
        }
        y -= 8

        // ── Section 5: Debug + Divider + Activity ──
        addDivider(cv, y: y - 2)
        y -= 8

        y -= 24
        debugLabel = label("", 9, .regular, NSColor(white: 0.38, alpha: 1))
        debugLabel.frame = NSRect(x: pad, y: y, width: w, height: 24)
        debugLabel.maximumNumberOfLines = 2
        debugLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        cv.addSubview(debugLabel)

        y -= 4
        addDivider(cv, y: y - 2)
        y -= 8

        y -= 12
        let actLbl = label("ACTIVITY", 9, .bold, NSColor(white: 0.40, alpha: 1))
        actLbl.frame = NSRect(x: pad, y: y, width: 80, height: 12)
        cv.addSubview(actLbl)

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
        logText.textColor = NSColor(white: 0.55, alpha: 1)
        logText.autoresizingMask = [.width]
        logView.documentView = logText
        cv.addSubview(logView)

        panel.orderFront(nil)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    // ── HELPERS ────────────────────────────────────────
    func makeKey(_ title: String, frame: NSRect, bg: NSColor, size: CGFloat) -> NonActivatingButton {
        let btn = NonActivatingButton(frame: frame)
        btn.wantsLayer = true
        btn.layer?.backgroundColor = bg.cgColor
        btn.layer?.cornerRadius = 6
        btn.isBordered = false
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: size, weight: .semibold)
        ])
        return btn
    }

    func btn(_ title: String, _ action: Selector, _ bg: NSColor) -> NonActivatingButton {
        let b = NonActivatingButton()
        b.title = title; b.bezelStyle = .rounded; b.isBordered = false
        b.wantsLayer = true; b.layer?.backgroundColor = bg.cgColor; b.layer?.cornerRadius = 4
        b.font = NSFont.systemFont(ofSize: 10)
        b.contentTintColor = NSColor(white: 0.75, alpha: 1)
        b.target = self; b.action = action
        b.onPress = { [weak self] in self?.perform(action) }
        return b
    }

    func label(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.monospacedSystemFont(ofSize: size, weight: w)
        l.textColor = c; l.backgroundColor = .clear
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func addDivider(_ parent: NSView, y: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: panelW - pad*2, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        parent.addSubview(d)
    }

    func log(_ text: String, _ color: NSColor) {
        activityLog.append((Date(), text, color))
        if activityLog.count > 100 { activityLog.removeFirst() }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        let ts = fmt.string(from: Date())
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "\(ts) ", attributes: [
            .foregroundColor: NSColor(white: 0.38, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]))
        line.append(NSAttributedString(string: "\(text)\n", attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]))
        logText.textStorage?.append(line)
        logText.scrollToEndOfDocument(nil)
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
        lastActivity = ""
        stripMode = ""
    }

    func updateStatus() {
        let available = ClaudeStatus.availableSessions()
        if available != sessions { sessions = available }
        if sessions.isEmpty { sessionIndex = 0 }
        else if sessionIndex >= sessions.count { sessionIndex = 0 }

        let sid: String? = sessions.isEmpty ? nil : sessions[sessionIndex]
        guard let s = ClaudeStatus.read(session: sid) else { return }

        if sessions.isEmpty {
            sessionLabel.stringValue = "no sessions"
        } else {
            sessionLabel.stringValue = "\(sessionIndex + 1)/\(sessions.count)"
        }

        // Status strip (synced with LED: breathe/blink/solid)
        applyStripAnimation(color: statusNSColor(for: s), mode: s.ledMode())

        headerLabel.stringValue = s.project.isEmpty ? "ClaudeKey Pro" : s.project

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
        let statusAge  = fileAge("/tmp/claudekey-status.json")
        let actAge     = fileAge("/tmp/claudekey-activity.json")
        let actSnip    = fileSnippet("/tmp/claudekey-activity.json")
        let notifySnip = fileSnippet("/tmp/claudekey-notify.json")
        let state = "attn=\(s.needsAttention) work=\(s.isWorking) idle=\(s.isIdle) → \(s.ledColor())/\(s.ledMode())"
        debugLabel.stringValue = "status:\(statusAge)  act:\(actAge) \(actSnip)\nnotify:\(notifySnip)  \(state)"

        // Feed OLED
        let tokK  = (s.inputTokens + s.outputTokens) / 1000
        let ctxK  = s.contextWindowSize / 1000
        let cost  = String(format: "$%.2f", s.costUSD)
        let dur   = s.totalDurationMs / 1000
        oledView.line1 = "SYSTEM STATUS:  5h:\(s.rate5h)%  7d:\(s.rate7d)%"
        oledView.line2 = "\(s.model.isEmpty ? "—" : s.model) — CTX: \(s.contextPercent)%"
        oledView.line3 = "\(cost)  \(dur)s  +\(s.linesAdded)/-\(s.linesRemoved)  \(tokK)k/\(ctxK)k"
        oledView.line4 = "\(s.contextPercent)"
        oledView.needsApproval = s.needsAttention
        oledView.isIdle = s.isIdle
        oledView.needsDisplay = true

        // Activity
        if !s.activity.isEmpty && s.activity != lastActivity {
            lastActivity = s.activity
            let c: NSColor = s.activityTool.contains("Agent") ? .systemPurple
                : s.activityTool.contains("Bash")  ? .systemOrange
                : s.activityTool.contains("Write") || s.activityTool.contains("Edit") ? .systemYellow
                : .systemCyan
            log(s.activity, c)
        }

        if s.needsAttention {
            if alwaysAccept {
                alwaysAcceptCount += 1
                sendKey(36)
                try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
                log("Auto-accept #\(alwaysAcceptCount): Enter", .systemGreen)
                return
            }
            blinkState.toggle()
            if blinkState { log(">>> NEEDS APPROVAL <<<", .systemYellow) }
            acceptButton.layer?.backgroundColor = blinkState
                ? NSColor.systemGreen.cgColor
                : NSColor(red:0.14,green:0.30,blue:0.14,alpha:1).cgColor
            statusItem.button?.title = blinkState ? "⚠️" : "⌨"
        } else if s.isIdle {
            if lastActivity != "_idle" { lastActivity = "_idle"; log("Idle — waiting for input", .systemGreen) }
        } else {
            acceptButton.layer?.backgroundColor = NSColor(red:0.14,green:0.30,blue:0.14,alpha:1).cgColor
            if !speech.isListening {
                statusItem.button?.title = s.contextPercent > 75 ? "🔴" : "⌨"
            }
        }
    }

    // ── HOOK CHECK ─────────────────────────────────────
    func checkHookStatus() {
        let bin  = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        // Pro binary lives at <root>/app/pro/ClaudeKeyPro
        let root = bin.deletingLastPathComponent().deletingLastPathComponent()
                      .deletingLastPathComponent().path
        let hook = root + "/scripts/claude-status-hook"
        let cfg  = NSHomeDirectory() + "/.claude/settings.json"
        let fm   = FileManager.default

        guard fm.fileExists(atPath: hook) else {
            log("✗ Hook not found: \(hook)", .systemRed); return
        }
        if !fm.isExecutableFile(atPath: hook) {
            log("✗ Hook not executable — fixing…", .systemOrange)
            let _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+x", hook])
            log("  chmod +x applied", .systemGreen)
        }
        guard let d = fm.contents(atPath: cfg),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            log("✗ ~/.claude/settings.json not found", .systemRed)
            log("  Run Claude Code at least once first", .systemRed)
            return
        }
        let sl  = j["statusLine"] as? [String: Any]
        let cmd = sl?["command"] as? String ?? "(not set)"

        if cmd.contains("claude-status-hook") {
            log("✓ Hook linked: \(hook)", .systemGreen)
        } else {
            log("✗ Hook mismatch", .systemOrange)
            log("  Current:  \(cmd)", .systemOrange)
            log("  → Menu → Fix Hook to auto-configure", .systemYellow)
            pendingHookScript   = hook
            pendingSettingsPath = cfg
        }
    }

    @objc func fixHook() {
        guard let hook = pendingHookScript,
              let cfgPath = pendingSettingsPath else {
            log("Hook already configured ✓", .systemGreen); return
        }
        let fm = FileManager.default
        guard let d = fm.contents(atPath: cfgPath),
              var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            log("Cannot read settings.json", .systemRed); return
        }
        j["statusLine"] = ["type": "command", "command": hook]
        guard let out = try? JSONSerialization.data(withJSONObject: j,
                                                    options: [.prettyPrinted, .sortedKeys]) else {
            log("Cannot encode settings.json", .systemRed); return
        }
        do {
            try out.write(to: URL(fileURLWithPath: cfgPath))
            log("✓ Hook configured!", .systemGreen)
            log("  Restart Claude Code to apply", .systemGreen)
            pendingHookScript = nil; pendingSettingsPath = nil
        } catch {
            log("✗ Write failed: \(error.localizedDescription)", .systemRed)
        }
    }

    // ── MENUBAR ────────────────────────────────────────
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"
        let m = NSMenu()
        m.addItem(withTitle: "ClaudeKey Pro", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
        m.addItem(withTitle: "Hide Panel", action: #selector(hidePanel), keyEquivalent: "")
        m.addItem(.separator())
        let voiceItem = NSMenuItem(title: "Voice Engine", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        let sysItem = NSMenuItem(title: "System (Apple STT)", action: nil, keyEquivalent: "")
        sysItem.state = .on
        voiceMenu.addItem(sysItem)
        voiceMenu.addItem(.separator())
        let otherItem = NSMenuItem(title: "Other…", action: nil, keyEquivalent: "")
        otherItem.isEnabled = false
        voiceMenu.addItem(otherItem)
        voiceItem.submenu = voiceMenu
        m.addItem(voiceItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Fix Hook (configure settings.json)", action: #selector(fixHook), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc func showPanel() { panel.orderFront(nil) }
    @objc func hidePanel() { panel.orderOut(nil) }
    @objc func quit()      { NSApp.terminate(nil) }

    // ── CORE KEY ACTIONS ──────────────────────────────
    @objc func doAccept() {
        sendKey(36)
        log("Sent: Enter (accept)", .systemGreen)
        try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
    }
    @objc func doReject() {
        sendKey(53)
        log("Sent: Esc", .systemOrange)
        try? "".write(toFile: "/tmp/claudekey-notify.json", atomically: true, encoding: .utf8)
    }
    @objc func doUp()   { sendKey(126); log("Sent: Up",   .systemBlue) }
    @objc func doDown() { sendKey(125); log("Sent: Down", .systemBlue) }

    @objc func pttToggle() {
        if speech.isListening {
            speech.stopRecording()
            pttButton.layer?.backgroundColor = NSColor(white: 0.28, alpha: 1).cgColor
            pttButton.attributedTitle = NSAttributedString(string: "PTT", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            statusItem.button?.title = "⌨"
            log("PTT: recognizing...", .systemYellow)
        } else {
            if speech.startRecording() {
                pttButton.layer?.backgroundColor = NSColor.systemRed.cgColor
                pttButton.attributedTitle = NSAttributedString(string: "■ STOP", attributes: [
                    .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
                statusItem.button?.title = "🎙"
                log("PTT: recording...", .systemRed)
            }
        }
    }

    @objc func doAlwaysAccept() {
        alwaysAccept.toggle()
        if alwaysAccept {
            alwaysAcceptCount = 0
            alwaysAcceptButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            alwaysAcceptButton.attributedTitle = NSAttributedString(string: "■ Stop", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            log("Always-Accept ON", .systemRed)
        } else {
            alwaysAcceptButton.layer?.backgroundColor = NSColor(white: 0.23, alpha: 1).cgColor
            alwaysAcceptButton.attributedTitle = NSAttributedString(string: "Auto", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            log("Always-Accept OFF (×\(alwaysAcceptCount))", .systemYellow)
        }
    }

    // ── SHORTCUT ACTIONS ──────────────────────────────
    @objc func doUndo()      { sendKey(6,  flags: .maskCommand); log("Cmd+Z", .systemBlue) }
    @objc func doInterrupt() { sendKey(8,  flags: .maskControl); log("Ctrl+C (interrupt)", .systemRed) }
    @objc func doTab()       { sendKey(48);                      log("Tab",   .systemBlue) }
    @objc func doPaste()     { sendKey(9,  flags: .maskCommand); log("Cmd+V", .systemBlue) }

    // ── ENCODER ───────────────────────────────────────
    func encoderTurn(_ dir: Int) {
        encoderPos += dir
        sendKey(dir > 0 ? 125 : 126)
        log("Knob: \(dir > 0 ? "▶" : "◀")  pos=\(encoderPos)", .systemTeal)
    }
    func encoderPress() {
        sendKey(36)
        log("Knob: Press (Enter)", .systemTeal)
    }
}

// ── LED STRIP INDICATOR (bottom edge) ─────────────────
// ── MAIN ───────────────────────────────────────────────
@main
enum Main {
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
