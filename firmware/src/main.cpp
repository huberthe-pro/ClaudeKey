/**
 * ClaudeKey Firmware — ESP32-S3
 *
 * USB Composite Device: HID Keyboard + UAC Microphone
 * 6 mechanical keys + I2S MEMS mic (INMP441) + WS2812B LED strip
 *
 * Wiring:
 *   Keys: GPIO4-7,15,16 → switch → GND (internal pull-up)
 *   INMP441: WS→GPIO42, SCK→GPIO41, SD→GPIO40, L/R→GND, VDD→3.3V
 *   LED strip: DIN→GPIO48, VCC→3.3V, GND→GND
 */

#include <Arduino.h>
#include <Adafruit_TinyUSB.h>
#include <Adafruit_NeoPixel.h>
#include <driver/i2s.h>
#include <math.h>

// ── PIN CONFIG ─────────────────────────────────────────
static const uint8_t KEY_PINS[]  = {4, 5, 6, 7, 15, 16};
static const uint8_t NUM_KEYS    = 6;
static const uint8_t LED_PIN     = 48;
static const uint8_t NUM_PIXELS  = 8;

// I2S mic (INMP441)
static const uint8_t I2S_WS  = 42;  // Word Select (LRCK)
static const uint8_t I2S_SCK = 41;  // Serial Clock (BCLK)
static const uint8_t I2S_SD  = 40;  // Serial Data (DOUT)

// ── USB DESCRIPTORS ────────────────────────────────────
Adafruit_USBD_HID usbHID;

// HID Report Descriptor: standard keyboard
uint8_t const hid_report_desc[] = {TUD_HID_REPORT_DESC_KEYBOARD()};

// USB Audio: 16kHz mono 16-bit (good for speech recognition)
static const uint32_t SAMPLE_RATE = 16000;
static const uint8_t  CHANNELS    = 1;
static const uint8_t  BIT_DEPTH   = 16;

// Audio buffer
static const size_t AUDIO_BUF_SAMPLES = 256;
int16_t audio_buf[AUDIO_BUF_SAMPLES];

// ── LED ────────────────────────────────────────────────
Adafruit_NeoPixel pixels(NUM_PIXELS, LED_PIN, NEO_GRB + NEO_KHZ800);

struct LedState {
    uint8_t r = 0, g = 30, b = 0;  // green default
    char mode = 'b';                 // b=breathe, s=solid, k=blink
    float phase = 0;
} led;

// ── KEY STATE ──────────────────────────────────────────
struct KeyState {
    bool pressed = false;
    uint32_t lastChange = 0;
} keyState[NUM_KEYS];

static const uint32_t DEBOUNCE_MS = 50;
bool pttHeld = false;

// Key actions: HID keycodes
// Accept='y'+Enter, Reject=Esc, Up, Down, PTT=F13, Spare=none
enum KeyAction { ACCEPT, REJECT, UP, DOWN, PTT, SPARE };

// ── SERIAL PROTOCOL (LED control) ──────────────────────
String serialBuf;

// ── FORWARD DECLARATIONS ───────────────────────────────
void setupI2S();
void setupKeys();
void scanKeys();
void onKeyPress(uint8_t idx);
void onKeyRelease(uint8_t idx);
void sendKey(uint8_t keycode);
void sendString(const char* str);
void checkSerial();
void updateLeds();
void readMicAndSendUSB();

// ── SETUP ──────────────────────────────────────────────
void setup() {
    Serial.begin(115200);

    // USB HID
    usbHID.setReportDescriptor(hid_report_desc, sizeof(hid_report_desc));
    usbHID.begin();

    // Wait for USB mount
    while (!TinyUSBDevice.mounted()) { delay(1); }

    setupI2S();
    setupKeys();

    pixels.begin();
    pixels.setBrightness(80);
    pixels.show();

    Serial.println("ClaudeKey ready");
}

// ── I2S MIC SETUP ──────────────────────────────────────
void setupI2S() {
    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = AUDIO_BUF_SAMPLES,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0,
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = I2S_SCK,
        .ws_io_num = I2S_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = I2S_SD,
    };

    i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
    i2s_set_pin(I2S_NUM_0, &pin_config);
    i2s_zero_dma_buffer(I2S_NUM_0);
}

// ── KEY SETUP ──────────────────────────────────────────
void setupKeys() {
    for (uint8_t i = 0; i < NUM_KEYS; i++) {
        pinMode(KEY_PINS[i], INPUT_PULLUP);
    }
}

// ── KEY SCANNING ───────────────────────────────────────
void scanKeys() {
    uint32_t now = millis();
    for (uint8_t i = 0; i < NUM_KEYS; i++) {
        bool isPressed = !digitalRead(KEY_PINS[i]);  // active LOW
        if (isPressed != keyState[i].pressed) {
            if (now - keyState[i].lastChange >= DEBOUNCE_MS) {
                keyState[i].lastChange = now;
                keyState[i].pressed = isPressed;
                if (isPressed) onKeyPress(i);
                else onKeyRelease(i);
            }
        }
    }
}

void onKeyPress(uint8_t idx) {
    switch (idx) {
        case ACCEPT:
            sendString("y\n");
            break;
        case REJECT:
            sendKey(HID_KEY_ESCAPE);
            break;
        case UP:
            sendKey(HID_KEY_ARROW_UP);
            break;
        case DOWN:
            sendKey(HID_KEY_ARROW_DOWN);
            break;
        case PTT:
            if (!pttHeld) {
                pttHeld = true;
                uint8_t report[8] = {0};
                report[2] = HID_KEY_F13;
                usbHID.keyboardReport(0, 0, report+2);
            }
            break;
        case SPARE:
            break;
    }
}

void onKeyRelease(uint8_t idx) {
    if (idx == PTT && pttHeld) {
        pttHeld = false;
        usbHID.keyboardRelease(0);
    }
}

void sendKey(uint8_t keycode) {
    uint8_t keycodes[6] = {keycode, 0, 0, 0, 0, 0};
    usbHID.keyboardReport(0, 0, keycodes);
    delay(10);
    usbHID.keyboardRelease(0);
}

void sendString(const char* str) {
    while (*str) {
        uint8_t keycode = 0;
        uint8_t modifier = 0;
        char c = *str++;
        if (c == '\n') {
            keycode = HID_KEY_ENTER;
        } else if (c >= 'a' && c <= 'z') {
            keycode = HID_KEY_A + (c - 'a');
        } else if (c >= 'A' && c <= 'Z') {
            keycode = HID_KEY_A + (c - 'A');
            modifier = KEYBOARD_MODIFIER_LEFTSHIFT;
        }
        if (keycode) {
            uint8_t keycodes[6] = {keycode, 0, 0, 0, 0, 0};
            usbHID.keyboardReport(0, modifier, keycodes);
            delay(10);
            usbHID.keyboardRelease(0);
            delay(10);
        }
    }
}

// ── MIC → USB AUDIO ───────────────────────────────────
void readMicAndSendUSB() {
    size_t bytesRead = 0;
    i2s_read(I2S_NUM_0, audio_buf, sizeof(audio_buf), &bytesRead, 0);

    if (bytesRead > 0 && pttHeld) {
        // When PTT is held, stream audio over USB CDC serial
        // macOS app can capture this and feed to STT
        // Format: raw 16-bit PCM, 16kHz mono
        Serial.write((uint8_t*)audio_buf, bytesRead);
    }
}

// ── SERIAL PROTOCOL ───────────────────────────────────
void checkSerial() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n') {
            serialBuf.trim();
            if (serialBuf.startsWith("S:")) {
                String color = serialBuf.substring(2);
                color.toLowerCase();
                if      (color == "green")  { led.r=0;  led.g=30; led.b=0;  }
                else if (color == "blue")   { led.r=0;  led.g=0;  led.b=40; }
                else if (color == "yellow") { led.r=40; led.g=25; led.b=0;  }
                else if (color == "red")    { led.r=40; led.g=0;  led.b=0;  }
                else if (color == "white")  { led.r=30; led.g=30; led.b=30; }
                else if (color == "purple") { led.r=20; led.g=0;  led.b=30; }
                else if (color == "off")    { led.r=0;  led.g=0;  led.b=0;  }
            } else if (serialBuf.startsWith("M:")) {
                char m = serialBuf.charAt(2);
                if (m == 'b' || m == 's' || m == 'k') led.mode = m;
            }
            serialBuf = "";
        } else {
            serialBuf += c;
        }
    }
}

// ── LED ANIMATION ─────────────────────────────────────
void updateLeds() {
    led.phase += 0.05;
    float factor = 1.0;

    switch (led.mode) {
        case 'b':  // breathe
            factor = (sin(led.phase) + 1.0) / 2.0;
            factor = 0.15 + factor * 0.85;
            break;
        case 'k':  // blink
            factor = (int(led.phase * 2) % 2 == 0) ? 1.0 : 0.0;
            break;
        case 's':  // solid
        default:
            factor = 1.0;
            break;
    }

    uint8_t r = (uint8_t)(led.r * factor);
    uint8_t g = (uint8_t)(led.g * factor);
    uint8_t b = (uint8_t)(led.b * factor);

    // PTT active: override to purple pulse
    if (pttHeld) {
        float pulse = (sin(led.phase * 3) + 1.0) / 2.0;
        r = (uint8_t)(30 * pulse);
        g = 0;
        b = (uint8_t)(40 * pulse);
    }

    for (int i = 0; i < NUM_PIXELS; i++) {
        pixels.setPixelColor(i, pixels.Color(r, g, b));
    }
    pixels.show();
}

// ── MAIN LOOP ─────────────────────────────────────────
void loop() {
    scanKeys();
    checkSerial();
    readMicAndSendUSB();
    updateLeds();
    delay(1);  // 1ms tick
}
