# ClaudeKey

Agentic Coding 控制面板 — ESP32-S3 六键键盘 + I2S 麦克风 + LED 状态灯带 + macOS PTT app。

## Architecture

```
                    USB HID (direct keystrokes)
ESP32-S3 ─────────────────────────────────────────→ macOS Terminal
  6 keys            │
  INMP441 mic       │ F13 (PTT button)
  LED strip         └──────→ ClaudeKey.app ──CGEvent──→ WisprFlow
                                  │                      (uses ClaudeKey mic)
                                  │
Claude Code ──status hook JSON──→ scripts/claude-status-hook
                                  │
                                  └──serial──→ ESP32-S3 LED strip
```

## Hardware Wiring (ESP32-S3-DevKitC)

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
  Adjust GPIO numbers in firmware/src/main.cpp  3.3V ───── VDD
                                                GND ────── GND
                                                GND ────── L/R (left ch)
```

## Key Behavior

| Key | HID Output | Notes |
|-----|-----------|-------|
| Accept | `y` + Enter | Direct to frontmost app |
| Reject | Esc | Direct to frontmost app |
| Up | Up arrow | Direct to frontmost app |
| Down | Down arrow | Direct to frontmost app |
| PTT | F13 → macOS app → Cmd+Shift+Space | WisprFlow PTT, mic on device |
| Spare | (unassigned) | v0.2 |

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
# Install PlatformIO CLI
pip install platformio

# Build and upload
cd firmware
pio run --target upload
# Hold BOOT button on ESP32-S3 if it doesn't enter download mode automatically
```

### 2. Build macOS app

```bash
cd app && ./build.sh
./ClaudeKey &
# Grant Accessibility permission when prompted
```

### 3. Install Claude Code status hook

```bash
# Add to ~/.claude/settings.json:
# "statusline": { "type": "command", "command": "/path/to/ClaudeKey/scripts/claude-status-hook" }
```

### 4. Configure WisprFlow mic input

In WisprFlow settings, select "ClaudeKey" (or the ESP32-S3 USB audio device) as the microphone input. The mic is mounted on the keyboard, closer to you than your laptop mic.

## Testing

```bash
# Build firmware
cd firmware && pio run

# Build macOS app
cd app && ./build.sh

# Manual test checklist:
# [ ] Accept key sends 'y' + Enter to terminal
# [ ] Reject key sends Esc
# [ ] Up/Down navigate history
# [ ] PTT activates WisprFlow (hold = talk, release = stop)
# [ ] Mic audio captured when PTT held
# [ ] LED strip shows green on startup
# [ ] LED strip changes color with Claude Code context usage
# [ ] LED turns purple pulse when PTT active
```

## Project Structure

```
firmware/
  platformio.ini    PlatformIO config (ESP32-S3 + TinyUSB)
  src/main.cpp      Keys + I2S mic + LED + serial (~250 lines)
app/
  ClaudeKey.swift   macOS menubar PTT app (~150 lines)
  build.sh          Compile with swiftc
scripts/
  claude-status-hook  Claude Code status → LED serial
```

## BOM (Bill of Materials)

| Item | Qty | Est. Price |
|------|-----|-----------|
| ESP32-S3 DevKitC (USB-C) | 1 | ¥25-40 |
| Cherry MX switches | 6 | ¥18-30 |
| Kailh hot-swap sockets | 6 | ¥6-12 |
| 1U keycaps (multi-color) | 6 | ¥12-30 |
| INMP441 I2S MEMS mic | 1 | ¥5-8 |
| WS2812B LED strip (8 LED) | 1 | ¥10-15 |
| Breadboard 400-hole | 1 | ¥5-10 |
| Dupont jumper wires | 1 pack | ¥5-10 |
| USB-C data cable | 1 | ¥10 |
| **Total** | | **¥95-165** |
