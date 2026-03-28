/**
 ClaudeKey — Shared Module

 Common code used by both Lite and Pro macOS apps:
 - SpeechEngine: Apple SFSpeechRecognizer PTT
 - Keyboard output: typeString, sendKey
 - NonActivatingButton / ControlPanel: floating panel controls
 - ClaudeStatus: reads Claude Code hook JSON from /tmp/
 - SerialBridge: connects to ESP32 via USB serial, sends L:/D: commands
*/

import AppKit
import CoreGraphics
import AVFoundation
import Speech
import Darwin

// ── SPEECH ENGINE ──────────────────────────────────────
class SpeechEngine: NSObject, AVAudioRecorderDelegate {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recorder: AVAudioRecorder?
    private var startTime: Date?
    private(set) var isListening = false
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var onError:  ((String) -> Void)?
    var onResult: ((String) -> Void)?

    private var tempFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claudekey_ptt.wav")
    }

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

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
        "Apple STT (\(Locale.current.identifier))"
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
        transcribe(fileURL: tempFileURL)
    }

    private func transcribe(fileURL: URL) {
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
    var sessionId: String = ""
    var contextPercent: Int = 0
    var contextWindowSize: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var model: String = ""
    var version: String = ""
    var costUSD: Double = 0
    var totalDurationMs: Int = 0
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var rate5h: Int = 0
    var rate7d: Int = 0
    var project: String = ""
    var activity: String = ""
    var activityTool: String = ""
    var needsAttention: Bool = false
    var isIdle: Bool = false

    /// Scan /tmp/ for all active Claude Code sessions (those with a status file < 5 min old).
    /// Falls back to legacy /tmp/claudekey-status.json if no session-specific files exist.
    static func availableSessions() -> [String] {
        let fm = FileManager.default
        let now = Date()
        var results: [(String, Date)] = []

        var seenSids = Set<String>()

        if let items = try? fm.contentsOfDirectory(atPath: "/tmp") {
            // 1. Session-specific status files (< 30 min)
            for name in items where name.hasPrefix("claudekey-") && name.hasSuffix("-status.json") {
                let path = "/tmp/\(name)"
                guard let attr = try? fm.attributesOfItem(atPath: path),
                      let mod = attr[.modificationDate] as? Date,
                      now.timeIntervalSince(mod) < 1800 else { continue }
                let sid = String(name.dropFirst("claudekey-".count).dropLast("-status.json".count))
                if seenSids.insert(sid).inserted { results.append((sid, mod)) }
            }
            // 2. Sessions with recent activity (< 10 min) but no status file yet
            for name in items where name.hasPrefix("claudekey-") && name.hasSuffix("-activity.json") {
                let path = "/tmp/\(name)"
                guard let attr = try? fm.attributesOfItem(atPath: path),
                      let mod = attr[.modificationDate] as? Date,
                      now.timeIntervalSince(mod) < 600 else { continue }
                let sid = String(name.dropFirst("claudekey-".count).dropLast("-activity.json".count))
                if seenSids.insert(sid).inserted { results.append((sid, mod)) }
            }
        }

        // 3. Legacy fallback: extract session_id from claudekey-status.json
        if results.isEmpty {
            let legacyPath = "/tmp/claudekey-status.json"
            if let attr = try? fm.attributesOfItem(atPath: legacyPath),
               let mod = attr[.modificationDate] as? Date,
               now.timeIntervalSince(mod) < 1800,
               let data = try? Data(contentsOf: URL(fileURLWithPath: legacyPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fullSid = json["session_id"] as? String {
                let sid = String(fullSid.prefix(8))
                try? data.write(to: URL(fileURLWithPath: "/tmp/claudekey-\(sid)-status.json"))
                results.append((sid, mod))
            }
        }

        return results.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    static func read(session: String? = nil) -> ClaudeStatus? {
        let statusPath: String
        if let sid = session {
            statusPath = "/tmp/claudekey-\(sid)-status.json"
        } else {
            statusPath = "/tmp/claudekey-status.json"
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var s = ClaudeStatus()
        // Derive session id from filename or JSON
        s.sessionId = session ?? (json["session_id"] as? String).map { String($0.prefix(8)) } ?? ""

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
        let sid = s.sessionId
        // Try session-specific activity file first, fall back to legacy
        let actPaths = sid.isEmpty
            ? ["/tmp/claudekey-activity.json"]
            : ["/tmp/claudekey-\(sid)-activity.json", "/tmp/claudekey-activity.json"]
        for actPath in actPaths {
            if let actData = try? Data(contentsOf: URL(fileURLWithPath: actPath)),
               let actJson = try? JSONSerialization.jsonObject(with: actData) as? [String: Any] {
                let ts = actJson["ts"] as? Int ?? 0
                if now - ts < 10 {
                    s.activity = actJson["activity"] as? String ?? ""
                    s.activityTool = actJson["tool"] as? String ?? ""
                }
                break
            }
        }
        let notifyPaths = sid.isEmpty
            ? ["/tmp/claudekey-notify.json"]
            : ["/tmp/claudekey-\(sid)-notify.json", "/tmp/claudekey-notify.json"]
        for notifyPath in notifyPaths {
            if let notifData = try? Data(contentsOf: URL(fileURLWithPath: notifyPath)),
               let notifJson = try? JSONSerialization.jsonObject(with: notifData) as? [String: Any] {
                let ts = notifJson["ts"] as? Int ?? 0
                if now - ts < 30 {
                    let type = notifJson["type"] as? String ?? ""
                    s.needsAttention = (type == "permission")
                    s.isIdle = (type == "idle")
                }
                break
            }
        }
        return s
    }

    /// Is Claude actively working? (tool activity within last 10 seconds)
    var isWorking: Bool { !isIdle && !needsAttention && !activity.isEmpty }

    /// Convert status to LED color name for Serial protocol
    ///
    /// Priority: approval > working > context level > idle
    ///   - Red blink:    needs approval (action required)
    ///   - Blue breathe: Claude is working (thinking/running tools)
    ///   - Green solid:  idle, waiting for input
    ///   - Yellow solid: context > 50% (caution)
    ///   - Red solid:    context > 75% (warning)
    ///   - Red blink:    context > 90% (critical)
    func ledColor() -> String {
        if needsAttention { return "red" }
        if isWorking { return "blue" }
        if isIdle { return "green" }
        // No activity signal, fall back to context usage
        if contextPercent < 50 { return "green" }
        if contextPercent < 75 { return "yellow" }
        return "red"
    }

    /// Convert status to LED mode for Serial protocol
    func ledMode() -> String {
        if needsAttention { return "k" }  // blink for approval needed
        if isWorking { return "b" }       // breathe while working
        if isIdle { return "s" }          // solid when idle
        if contextPercent > 90 { return "k" }  // blink for critical
        if contextPercent > 50 { return "s" }  // solid for caution+
        return "s"  // solid default
    }

    /// Format as D: command for OLED (Pro)
    func oledCommand() -> String {
        let cost = String(format: "$%.2f", costUSD)
        let dur = totalDurationMs / 1000
        let status = needsAttention ? "APPROVE" : (isIdle ? "Idle" : "Working")
        let act = String(activity.prefix(40))
        return "D:\(contextPercent),\(rate5h),\(rate7d),\(cost),\(dur),\(status),\(act)"
    }
}

// ── SERIAL BRIDGE ──────────────────────────────────────
/// Manages USB serial connection to ESP32-S3 ClaudeKey hardware.
/// Discovers the device at /dev/cu.usbmodem*, opens the port,
/// and sends L:/D: commands based on ClaudeStatus.
class SerialBridge {
    private var fd: Int32 = -1
    private var devicePath: String?
    var onLog: ((String) -> Void)?

    /// Scan for ESP32-S3 USB serial device
    func discover() -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
        // ESP32-S3 with TinyUSB typically shows as cu.usbmodemXXXX
        let candidates = items.filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()  // deterministic order
        return candidates.first.map { "/dev/\($0)" }
    }

    /// Open the serial port at 115200 baud
    func connect() -> Bool {
        guard let path = discover() else {
            onLog?("Serial: no ESP32 found at /dev/cu.usbmodem*")
            return false
        }
        devicePath = path

        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            onLog?("Serial: failed to open \(path)")
            return false
        }

        // Configure 115200 8N1
        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, speed_t(B115200))
        cfsetospeed(&options, speed_t(B115200))
        options.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~UInt(PARENB | CSTOPB)
        options.c_iflag = 0
        options.c_oflag = 0
        options.c_lflag = 0
        tcsetattr(fd, TCSANOW, &options)

        // Clear O_NONBLOCK after setup
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        onLog?("Serial: connected to \(path)")
        return true
    }

    /// Send a raw command string (with newline)
    func send(_ command: String) {
        guard fd >= 0 else { return }
        let line = command + "\n"
        line.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }

    /// Send LED + OLED commands from ClaudeStatus
    func sendStatus(_ status: ClaudeStatus, isPro: Bool = false) {
        send("L:\(status.ledColor()),\(status.ledMode())")
        if isPro {
            send(status.oledCommand())
        }
    }

    /// Close the serial port
    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
            onLog?("Serial: disconnected")
        }
    }

    var isConnected: Bool { fd >= 0 }

    deinit { disconnect() }
}
