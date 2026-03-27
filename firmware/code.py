"""
ClaudeKey firmware — ESP32-S3 + CircuitPython
6 mechanical keys + WS2812B LED status strip

Wiring (adjust GPIO numbers for your board):
  Key 1 (Accept)  → GPIO4  → GND
  Key 2 (Reject)  → GPIO5  → GND
  Key 3 (Up)      → GPIO6  → GND
  Key 4 (Down)    → GPIO7  → GND
  Key 5 (PTT)     → GPIO15 → GND
  Key 6 (Spare)   → GPIO16 → GND
  LED strip DIN   → GPIO48 (or board.NEOPIXEL)
  LED strip VCC   → 3.3V
  LED strip GND   → GND
"""

import board
import digitalio
import usb_hid
import usb_cdc
import time
import math
import neopixel
from adafruit_hid.keyboard import Keyboard
from adafruit_hid.keycode import Keycode
from adafruit_hid.keyboard_layout_us import KeyboardLayoutUS

# ── CONFIG ──────────────────────────────────────────────
# Adjust these pins for your ESP32-S3 board
KEY_PINS = [board.IO4, board.IO5, board.IO6, board.IO7, board.IO15, board.IO16]
KEY_NAMES = ["accept", "reject", "up", "down", "ptt", "spare"]

NUM_PIXELS = 8           # LED count on your strip
LED_BRIGHTNESS = 0.3
DEBOUNCE_MS = 50

# LED pin: try built-in NeoPixel first, fallback to GPIO48
try:
    LED_PIN = board.NEOPIXEL
except AttributeError:
    LED_PIN = board.IO48

# ── INIT ────────────────────────────────────────────────
kbd = Keyboard(usb_hid.devices)
layout = KeyboardLayoutUS(kbd)
pixels = neopixel.NeoPixel(LED_PIN, NUM_PIXELS, brightness=LED_BRIGHTNESS, auto_write=False)
serial = usb_cdc.data

# Setup key GPIOs (active LOW, internal pull-up)
keys = []
for pin in KEY_PINS:
    dio = digitalio.DigitalInOut(pin)
    dio.direction = digitalio.Direction.INPUT
    dio.pull = digitalio.Pull.UP
    keys.append(dio)

# ── STATE ───────────────────────────────────────────────
was_pressed = [False] * 6
last_press_ms = [0] * 6
ptt_held = False

# LED state (updated via serial from Claude Code status hook)
led_color = (0, 30, 0)   # default: green = idle
led_mode = "breathe"      # breathe | solid | blink
led_phase = 0.0

COLORS = {
    "green":  (0, 30, 0),
    "blue":   (0, 0, 40),
    "yellow": (40, 25, 0),
    "red":    (40, 0, 0),
    "white":  (30, 30, 30),
    "purple": (20, 0, 30),
    "off":    (0, 0, 0),
}

# ── KEY HANDLERS ────────────────────────────────────────
def on_press(idx):
    global ptt_held
    name = KEY_NAMES[idx]
    if name == "accept":
        layout.write("y\n")
    elif name == "reject":
        kbd.send(Keycode.ESCAPE)
    elif name == "up":
        kbd.send(Keycode.UP_ARROW)
    elif name == "down":
        kbd.send(Keycode.DOWN_ARROW)
    elif name == "ptt" and not ptt_held:
        ptt_held = True
        kbd.press(Keycode.F13)
    elif name == "spare":
        pass  # v0.2: assign via serial config

def on_release(idx):
    global ptt_held
    if KEY_NAMES[idx] == "ptt" and ptt_held:
        ptt_held = False
        kbd.release(Keycode.F13)

# ── SERIAL PROTOCOL ────────────────────────────────────
# Receives single-line commands from macOS:
#   S:green    → set LED color
#   M:breathe  → set LED mode (breathe/solid/blink)
serial_buf = ""

def check_serial():
    global serial_buf, led_color, led_mode
    if serial is None:
        return
    if serial.in_waiting > 0:
        raw = serial.read(serial.in_waiting)
        if raw:
            serial_buf += raw.decode("utf-8", errors="ignore")
    while "\n" in serial_buf:
        line, serial_buf = serial_buf.split("\n", 1)
        cmd = line.strip()
        if cmd.startswith("S:"):
            c = cmd[2:].lower()
            if c in COLORS:
                led_color = COLORS[c]
        elif cmd.startswith("M:"):
            m = cmd[2:].lower()
            if m in ("breathe", "solid", "blink"):
                led_mode = m

# ── LED ANIMATION ──────────────────────────────────────
def update_leds():
    global led_phase
    led_phase += 0.05
    r, g, b = led_color

    if led_mode == "solid":
        pixels.fill((r, g, b))
    elif led_mode == "breathe":
        factor = (math.sin(led_phase) + 1) / 2  # 0..1
        factor = 0.15 + factor * 0.85            # keep min 15% brightness
        pixels.fill((int(r * factor), int(g * factor), int(b * factor)))
    elif led_mode == "blink":
        on = int(led_phase * 2) % 2 == 0
        pixels.fill((r, g, b) if on else (0, 0, 0))

    pixels.show()

# ── MAIN LOOP ──────────────────────────────────────────
print("ClaudeKey ready")

while True:
    now_ms = time.monotonic_ns() // 1_000_000

    # Scan keys
    for i, key in enumerate(keys):
        is_pressed = not key.value  # active LOW
        if is_pressed != was_pressed[i]:
            if now_ms - last_press_ms[i] >= DEBOUNCE_MS:
                last_press_ms[i] = now_ms
                was_pressed[i] = is_pressed
                if is_pressed:
                    on_press(i)
                else:
                    on_release(i)

    # Check serial for LED updates
    check_serial()

    # Update LED strip
    update_leds()

    time.sleep(0.01)  # 100Hz scan rate
