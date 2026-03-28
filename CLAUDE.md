# ClaudeKey

Agentic Coding 控制面板 — ESP32-S3 键盘 + I2S 麦克风 + LED/OLED + macOS 模拟器。

两个版本: **Lite** (入门) 和 **Pro** (完整体验)。

## Versions

| | Lite | Pro |
|---|---|---|
| 按键 | 6 键 Cherry MX | 6 核心 + 4 扩展 |
| 显示 | WS2812B LED 灯带 | SSD1309 2.42" OLED (128x64) |
| 输入 | 按键 | 按键 + EC11 旋转编码器 |
| 麦克风 | INMP441 | INMP441 |
| 蜂鸣器 | 有 | 有 |
| BOM | ~¥100-170 | ~¥200-300 |
| 难度 | 面包板 | 需要布局设计 |

## Architecture

```
                    USB HID (direct keystrokes)
ESP32-S3 ─────────────────────────────────────────→ macOS Terminal
  keys              │
  INMP441 mic       │ F13 (PTT button)
  LED/OLED          └──────→ ClaudeKey.app ──CGEvent──→ STT (Apple)
                                  │
                                  │
Claude Code ──status hook JSON──→ scripts/claude-status-hook
                                  │
                                  └──serial──→ ESP32-S3 LED/OLED
```

## Hardware Wiring

### Lite (6 keys + LED strip)

```
  ESP32-S3          Switches (Cherry MX)        LED Strip (WS2812B)
  ────────          ────────────────────        ────────────────────
  GPIO4  ──────── [Accept ✓] ──── GND          GPIO48 ─── DIN
  GPIO5  ──────── [Reject ✗] ──── GND          3.3V ───── VCC
  GPIO6  ──────── [  Up  ↑ ] ──── GND          GND ────── GND
  GPIO7  ──────── [ Down ↓ ] ──── GND
  GPIO15 ──────── [ PTT  🎙] ──── GND          INMP441 (I2S MEMS Mic)
  GPIO16 ──────── [Spare   ] ──── GND          ────────────────────
                                                GPIO42 ─── WS  (LRCK)
  All switches: one pin to GPIO,                GPIO41 ─── SCK (BCLK)
  other pin to GND (internal pull-up)           GPIO40 ─── SD  (DOUT)
                                                3.3V ───── VDD
  Passive Buzzer                                GND ────── GND
  ────────────────────                          GND ────── L/R (left ch)
  GPIO17 ─── + (signal)
  GND ────── - (ground)
```

### Pro (adds OLED + encoder + extra keys)

```
  SSD1309 2.42" OLED (I2C)       Rotary Encoder (EC11)
  ──────────────────────          ─────────────────────
  GPIO1  ─── SDA                  GPIO38 ─── CLK (A)
  GPIO2  ─── SCL                  GPIO39 ─── DT  (B)
  3.3V ───── VCC                  GPIO3  ─── SW  (button)
  GND ────── GND                  GND ────── GND

  Extra Keys (Pro)
  ─────────────────
  GPIO8  ── [Undo]     ── GND
  GPIO9  ── [Interrupt] ── GND
  GPIO18 ── [Tab]       ── GND
  GPIO21 ── [Paste]     ── GND
```

## Key Behavior

### Core Keys (Lite + Pro)

| Key | HID Output | Sound | Notes |
|-----|-----------|-------|-------|
| Accept | Enter | Short high beep | Direct to frontmost app |
| Reject | Esc | Two low beeps | Direct to frontmost app |
| Up | Up arrow | Soft click | Direct to frontmost app |
| Down | Down arrow | Soft click | Direct to frontmost app |
| PTT | F13 → macOS app → STT | Rising/falling tone | Hold=record, release=stop |
| Always | Toggle auto-accept | Click | Sends Enter on approval |

### Pro Extra Keys

| Key | HID Output | Notes |
|-----|-----------|-------|
| Undo | Cmd+Z | Undo last edit |
| Interrupt | Ctrl+C | Stop current task |
| Tab | Tab | Switch pane |
| Paste | Cmd+V | Paste clipboard |

### Encoder (Pro)

| Action | Output | Notes |
|--------|--------|-------|
| Turn CW | Down arrow | Scroll down |
| Turn CCW | Up arrow | Scroll up |
| Press | Enter | Confirm |

## Serial Protocol

| Prefix | Direction | Description | Example |
|--------|-----------|-------------|---------|
| `L:` | host→device | LED color[,mode] | `L:green` or `L:red,k` |
| `D:` | host→device | OLED display data (Pro) | `D:45,12,3,$1.23,340,Working,Writing tests` |
| `A:` | host→device | Buzzer alert | `A:accept` or `A:alert` |
| `K:` | device→host | Key press event | `K:accept` or `K:ptt` |
| `E:` | device→host | Encoder event (Pro) | `E:cw` or `E:press` |

Colors: green, blue, yellow, red, white, purple, off
Modes: b=breathe, s=solid, k=blink
Alerts: accept, reject, alert, ptt_start, ptt_stop
Keys: accept, reject, up, down, ptt, spare, undo, interrupt, tab, paste
Encoder: cw, ccw, press

## LED Status (via Claude Code status hook)

| Context Usage | Color | Mode |
|--------------|-------|------|
| < 25% | Green | Breathe |
| 25-50% | Blue | Breathe |
| 50-75% | Yellow | Solid |
| 75-90% | Red | Solid |
| > 90% | Red | Blink |
| PTT active | Purple | Pulse |

## Setup

### 1. Build and flash firmware (PlatformIO)

```bash
pip install platformio
cd firmware

# Lite version
pio run -e lite --target upload

# Pro version
pio run -e pro --target upload
```

### 2. Build macOS simulator app

```bash
# Lite version (6 buttons + LED status bars)
cd app/lite && ./build.sh
./ClaudeKeyLite &

# Pro version (OLED preview + encoder + extra buttons)
cd app/pro && ./build.sh
./ClaudeKeyPro &
```

### 3. Install Claude Code status hook

```bash
# Add to ~/.claude/settings.json:
# "statusline": { "type": "command", "command": "/path/to/ClaudeKey/scripts/claude-status-hook" }
```

### 4. PTT 使用本机麦克风

PTT 语音使用 macOS 本机麦克风 + Apple SFSpeechRecognizer, 不需要额外配置。
ESP32 上的 INMP441 麦克风为未来 BLE 无线版本预留。

## PTT 语音识别说明

使用 Apple `SFSpeechRecognizer`，跟随系统语言，零安装，延迟 ~0.5s。

```
Locale.current → zh-CN → en-US（依次降级）
```

### 常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 只识别英文 | 系统语言设置为 English | 系统设置 → 语言与地区 → 首选语言改为简体中文 |
| PTT 按下无反应 | 未授权麦克风/语音识别权限 | 系统设置 → 隐私与安全性 → 麦克风 / 语音识别 |

## Project Structure

```
ClaudeKey/
├── firmware/
│   ├── platformio.ini        PlatformIO (envs: lite / pro)
│   └── src/
│       ├── main.cpp          Core firmware — keys, mic, LED, serial
│       └── pro/
│           ├── display.h     SSD1309 2.42" OLED driver (Pro only)
│           └── encoder.h     EC11 rotary encoder (Pro only)
├── app/
│   ├── shared/
│   │   └── Shared.swift          Common: SpeechEngine, HID output, ClaudeStatus, Terminal detection
│   ├── lite/
│   │   ├── ClaudeKeyLite.swift   Lite simulator — 6 buttons + LED bars
│   │   └── build.sh
│   └── pro/
│       ├── ClaudeKeyPro.swift    Pro simulator — OLED + encoder + extras
│       └── build.sh
├── scripts/
│   ├── claude-status-hook    Claude Code status → LED/OLED (required)
│   ├── claude-notify-hook    Approval/idle notifications
│   ├── claude-tool-hook      Tool activity logging
│   └── claude-status-dump    Debug: dump last status JSON
└── docs/
    └── claude-code-hooks-reference.md
```

## Roadmap

### 待实现

| 优先级 | 功能 | 说明 |
|--------|------|------|
| 高 | Host Serial 写入 | macOS app 通过串口发送 L:/D: 命令到 ESP32, 硬件 LED/OLED 才能显示状态 |
| 中 | Auto-Accept 可靠性 | 验证直发 Enter 的时机准确性, 需要 Terminal 前台检测作为前置条件 |
| 中 | 会话级路由 | 区分同一 Terminal 中多个 tab/session, 绑定具体 Claude Code 会话 |

### 已完成

| 功能 | 完成时间 |
|------|---------|
| 公共 Swift 模块提取 (app/shared/) | 2026-03-28 |
| Terminal 前台检测 (isTerminalFrontmost) | 2026-03-28 |
| GPIO 冲突修复 (编码器 → GPIO38/39) | 2026-03-28 |
| Serial 协议统一 (L:/D:/A:/K:/E:) | 2026-03-28 |
| Pro 固件集成 (OLED + 编码器 + 额外按键) | 2026-03-28 |
| 非阻塞蜂鸣器 (millis-based state machine) | 2026-03-28 |
| Hook 自动修复（Fix Hook 菜单） | 2026-03-27 |
| Lite / Pro 双版本架构 | 2026-03-27 |
| OLED 2.42" 128x64 显示方案 | 2026-03-27 |

## BOM (Bill of Materials)

### Lite — 6键 + LED底部灯带

| 物料 | 规格 | 数量 | 参考价 | 淘宝关键词 |
|------|------|------|--------|-----------|
| ESP32-S3 开发板 | DevKitC-1 USB-C | 1 | ¥25-40 | ESP32-S3-DevKitC |
| 机械轴 | Cherry MX 红轴 | 6 | ¥18-30 | Cherry MX 红轴 |
| 热插拔轴座 | Kailh PCB socket | 6 | ¥6-12 | kailh 热插拔 |
| 键帽 | 1U PBT 黑色哑光 | 6 | ¥12-30 | PBT 1U 键帽 |
| 麦克风 | INMP441 I2S MEMS | 1 | ¥5-8 | INMP441 |
| 蜂鸣器 | 无源 3.3V 5mm | 1 | ¥1-3 | 无源蜂鸣器 3.3V |
| LED 灯带 | WS2812B 8颗 | 1 | ¥10-15 | WS2812B 灯带 |
| 3D打印外壳 | PLA 黑色哑光 | 1 | ¥15-30 | 3D打印定制 |
| 面包板 | 400孔 | 1 | ¥5-10 | 面包板 400孔 |
| 杜邦线 | 公母混合 | 1包 | ¥5-10 | 杜邦线 |
| USB-C 线 | 数据线 0.5m | 1 | ¥10 | USB-C 数据线 |
| **合计** | | | **¥112-198** | |

### Pro — 10键 + 2.42" OLED + 旋钮

> 在 Lite 基础上增加以下物料

| 物料 | 规格 | 数量 | 参考价 | 淘宝关键词 |
|------|------|------|--------|-----------|
| OLED 显示屏 | SSD1309 2.42" 128x64 I2C | 1 | ¥20-35 | SSD1309 2.42寸 OLED |
| 旋转编码器 | EC11 带按压 + 金属旋钮帽 | 1 | ¥5-15 | EC11 编码器 旋钮 |
| 机械轴（加） | Cherry MX 红轴 | 4 | ¥12-20 | Cherry MX 红轴 |
| 热插拔轴座（加） | Kailh PCB socket | 4 | ¥4-8 | kailh 热插拔 |
| 键帽（加） | 1U PBT 黑色哑光 | 4 | ¥8-20 | PBT 1U 键帽 |
| 拉丝铝面板 | 1.5mm 铝板 激光切割 | 1 | ¥20-40 | 铝板 激光切割 定制 |
| 3D打印外壳（Pro） | PLA 黑色 较大尺寸 | 1 | ¥20-40 | 3D打印定制 |
| 卷线 USB-C | 弹簧卷线 数据线 | 1 | ¥15-25 | USB-C 卷线 |
| **Pro 增量** | | | **¥104-203** | |
| **Pro 合计** | | | **¥216-401** | |

### 布局参数（Pro 实物参考）

```
整体尺寸约: 165mm × 130mm × 45mm (含倾斜底座)

OLED 区: 宽 ~130mm × 高 ~35mm  (2.42" 128x64)
按键区: 3列 × 2行 核心键  +  右侧旋钮
  核心键间距: 19mm (1U标准)
  旋钮直径: 30mm 铝合金滚花
底部快捷键: 4键 × 1行 (略小于1U)
LED 灯带: 底边环绕 8颗 WS2812B
```
