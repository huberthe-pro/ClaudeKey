# ClaudeKey

Agentic Coding 控制面板 — ESP32-S3 六键键盘 + LED 状态灯带 + macOS PTT app。

## Architecture

```
                    USB HID (direct keystrokes)
ESP32-S3 ─────────────────────────────────────────→ macOS Terminal
  6 keys            │                                    │
  LED strip         │ F13 only                           │
                    └──────→ ClaudeKey.app ──CGEvent──→ WisprFlow
                                  ↑
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
  GPIO15 ──────── [ PTT  🎙] ──── GND
  GPIO16 ──────── [Spare   ] ──── GND

  All switches: one pin to GPIO, other pin to GND (internal pull-up enabled)
  Adjust GPIO numbers in firmware/code.py for your board
```

## Key Behavior

| Key | HID Output | Notes |
|-----|-----------|-------|
| Accept | `y` + Enter | Direct to frontmost app |
| Reject | Esc | Direct to frontmost app |
| Up | ↑ arrow | Direct to frontmost app |
| Down | ↓ arrow | Direct to frontmost app |
| PTT | F13 → macOS app → Cmd+Shift+Space | WisprFlow push-to-talk |
| Spare | (unassigned) | v0.2 |

## LED Status (via Claude Code status hook)

| Context Usage | Color | Mode |
|--------------|-------|------|
| < 25% | Green | Breathe |
| 25-50% | Blue | Breathe |
| 50-75% | Yellow | Solid |
| 75-90% | Red | Solid |
| > 90% | Red | Blink |

## Setup

### 1. Flash firmware to ESP32-S3

```bash
pip install esptool
# Download CircuitPython for your ESP32-S3 board from circuitpython.org
# Hold BOOT button, plug USB, flash:
esptool.py --chip esp32s3 erase_flash
esptool.py --chip esp32s3 write_flash -z 0x0 adafruit-circuitpython-*.bin

# Copy libraries to CIRCUITPY drive:
#   lib/adafruit_hid/        (from Adafruit CircuitPython Bundle)
#   lib/neopixel.mpy
# Copy firmware/boot.py and firmware/code.py to CIRCUITPY root
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

## Testing

```bash
# Build macOS app
cd app && swiftc -O -framework AppKit -framework CoreGraphics -o ClaudeKey ClaudeKey.swift

# Manual test checklist:
# [ ] Accept key sends 'y' + Enter to terminal
# [ ] Reject key sends Esc
# [ ] Up/Down navigate history
# [ ] PTT activates WisprFlow (hold = talk, release = stop)
# [ ] LED strip shows green on startup
# [ ] LED changes color when Claude Code is running (with hook installed)
```

## Project Structure

```
firmware/
  boot.py         USB HID + serial config
  code.py         Keys + LED + serial listener (~120 lines)
app/
  ClaudeKey.swift  macOS menubar PTT app (~150 lines)
  build.sh         Compile with swiftc
scripts/
  claude-status-hook   Claude Code status → LED serial
```
