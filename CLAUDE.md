# ClaudeKey

Agentic Coding 控制面板 — ESP32-S3 键盘 + I2S 麦克风 + LED/TFT + macOS 模拟器。

两个版本: **Lite** (入门) 和 **Pro** (完整体验)。

## Versions

| | Lite | Pro |
|---|---|---|
| 按键 | 6 键 Cherry MX | 6 核心 + 4 扩展 |
| 显示 | WS2812B LED 灯带 | ST7789 1.3" 彩色 TFT |
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
  LED/TFT           └──────→ ClaudeKey.app ──CGEvent──→ WisprFlow
                                  │                      (uses ClaudeKey mic)
                                  │
Claude Code ──status hook JSON──→ scripts/claude-status-hook
                                  │
                                  └──serial──→ ESP32-S3 LED/TFT
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

### Pro (adds TFT + encoder + extra keys)

```
  ST7789 1.3" TFT (SPI)          Rotary Encoder (EC11)
  ──────────────────────          ─────────────────────
  GPIO10 ─── CS                   GPIO1 ─── CLK (A)
  GPIO11 ─── DC                   GPIO2 ─── DT  (B)
  GPIO12 ─── RST                  GPIO3 ─── SW  (button)
  GPIO13 ─── SDA (MOSI)           GND ────── GND
  GPIO14 ─── SCL (SCK)
  3.3V ───── VCC / BL             Extra Keys (Pro)
  GND ────── GND                  ─────────────────
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

| Prefix | Direction | Description |
|--------|-----------|-------------|
| `L:` | host→device | LED strip color/mode |
| `D:` | host→device | TFT display data (Pro) |
| `A:` | host→device | Audio/buzzer command |
| `K:` | device→host | Key press report |
| `E:` | device→host | Encoder event (Pro) |

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

# Pro version (TFT preview + encoder + extra buttons)
cd app/pro && ./build.sh
./ClaudeKeyPro &

# Legacy standalone app (original PTT-only)
cd app && ./build.sh
./ClaudeKey &
```

### 3. Install Claude Code status hook

```bash
# Add to ~/.claude/settings.json:
# "statusline": { "type": "command", "command": "/path/to/ClaudeKey/scripts/claude-status-hook" }
```

### 4. Configure WisprFlow mic input

In WisprFlow settings, select "ClaudeKey" (or the ESP32-S3 USB audio device) as the microphone input.

## Project Structure

```
firmware/
  platformio.ini          PlatformIO config (lite + pro envs)
  src/
    main.cpp              Core firmware (keys, mic, LED, serial)
    pro/
      display.h           ST7789 TFT driver (Pro only)
      encoder.h           EC11 rotary encoder (Pro only)
app/
  ClaudeKey.swift         Legacy standalone PTT app
  ClaudeKeySoft.swift     Legacy soft panel (kept for compat)
  build.sh / build-soft.sh
  lite/
    ClaudeKeyLite.swift   Lite simulator (6 buttons + status bars)
    build.sh
  pro/
    ClaudeKeyPro.swift    Pro simulator (TFT preview + encoder + extras)
    build.sh
scripts/
  claude-status-hook      Claude Code status → LED/TFT serial
```

## BOM (Bill of Materials)

### Lite

| Item | Qty | Est. Price |
|------|-----|-----------|
| ESP32-S3 DevKitC (USB-C) | 1 | ¥25-40 |
| Cherry MX switches | 6 | ¥18-30 |
| Kailh hot-swap sockets | 6 | ¥6-12 |
| 1U keycaps | 6 | ¥12-30 |
| INMP441 I2S MEMS mic | 1 | ¥5-8 |
| Passive buzzer (3.3V) | 1 | ¥1-3 |
| WS2812B LED strip (8 LED) | 1 | ¥10-15 |
| Breadboard 400-hole | 1 | ¥5-10 |
| Dupont jumper wires | 1 pack | ¥5-10 |
| USB-C data cable | 1 | ¥10 |
| **Total** | | **¥96-168** |

### Pro (adds to Lite)

| Item | Qty | Est. Price |
|------|-----|-----------|
| ST7789 1.3" TFT 240x240 | 1 | ¥15-20 |
| EC11 rotary encoder + knob | 1 | ¥3-5 |
| Cherry MX switches (extra) | 4 | ¥12-20 |
| Kailh hot-swap sockets (extra) | 4 | ¥4-8 |
| 1U keycaps (extra) | 4 | ¥8-20 |
| Larger breadboard or PCB | 1 | ¥10-20 |
| **Pro Total** | | **¥148-261** |
