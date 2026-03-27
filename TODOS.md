# TODOS — ClaudeKey

## v0.2: Terminal foreground detection
**What:** macOS app 检查前台 app 是否是 iTerm2/Terminal.app，不是则屏蔽直发按键。
**Why:** 防止 Accept 键在错误的 app 里发送 'y'+Enter。外部用户测试前必须解决。
**Context:** v0.1 用 LED 提示缓解。复用 PTT 的 macOS app，加一个 AXUIElement 前台 app 检查（NSWorkspace.shared.frontmostApplication.bundleIdentifier）。
**Depends on:** v0.1 macOS app 完成。
**Added:** 2026-03-27 by /plan-eng-review

## v0.2: Auto-Yes reliability spike
**What:** 验证固定间隔发 'y'+Enter 是否可靠，是否需要解析终端输出中的 prompt 标记。
**Why:** 设计文档标记为最高技术风险。如果需要终端输出解析，复杂度大幅增加。
**Context:** Claude Code 的输出格式不是稳定 API。可能的替代方案：降级为"快速连按 Accept"模式（按住 Accept 键时以 500ms 间隔重复发送，松开停止）。
**Depends on:** v0.1 完成后，进入 v0.2 前做 spike。
**Added:** 2026-03-27 by /plan-eng-review

## v0.2: Local Whisper STT (whisper.cpp)
**What:** 用本地 whisper.cpp 替换 Apple SFSpeechRecognizer，提升技术术语识别准确率。
**Why:** Apple Speech 对编程术语识别差（kubectl, nginx, middleware 等）。whisper.cpp 完全离线免费，对技术语音准确率高得多。
**Context:** macOS app 录音完成后调 whisper.cpp CLI: `whisper-cli -m ggml-base.en.bin -f audio.wav`，解析 stdout 拿文字。约 200ms 延迟（base 模型）。用户需 `brew install whisper-cpp`。v0.3 可考虑 C API 直接集成减少延迟。
**Depends on:** v0.1 语音验证通过（确认语音是高价值功能后再优化）。
**Added:** 2026-03-27
