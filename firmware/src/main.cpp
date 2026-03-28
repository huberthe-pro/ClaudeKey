/**
 * ClaudeKey Firmware — ESP32-S3
 *
 * USB Composite Device: HID Keyboard + UAC Microphone
 * 6 mechanical keys + I2S MEMS mic (INMP441) + WS2812B LED strip + buzzer
 *
 * Serial Protocol (host → device):
 *   L:<color>[,<mode>]  LED strip color + optional mode
 *     colors: green, blue, yellow, red, white, purple, off
 *     modes:  b=breathe, s=solid, k=blink (default: unchanged)
 *   D:<csv>             OLED display data (Pro only, see display.h)
 *   A:<alert>           Buzzer alert: accept, reject, alert, ptt_start, ptt_stop
 *
 * Serial Protocol (device → host):
 *   K:<key>             Key press event: accept, reject, up, down, ptt, spare
 *   E:<event>           Encoder event (Pro only): cw, ccw, press
 *
 * Wiring (Lite):
 *   Keys: GPIO4-7,15,16 → switch → GND (internal pull-up)
 *   INMP441: WS→GPIO42, SCK→GPIO41, SD→GPIO40, L/R→GND, VDD→3.3V
 *   LED strip: DIN→GPIO48, VCC→3.3V, GND→GND
 *   Buzzer: GPIO17 → passive buzzer → GND
 *
 * Wiring (Pro adds):
 *   OLED SSD1309: SDA→GPIO1, SCL→GPIO2, VCC→3.3V, GND→GND
 *   Encoder EC11: CLK→GPIO38, DT→GPIO39, SW→GPIO3, GND→GND
 *   Extra keys: GPIO8(Undo), GPIO9(Interrupt), GPIO18(Tab), GPIO21(Paste)
 */

#include <Arduino.h>
#include <Adafruit_TinyUSB.h>
#include <Adafruit_NeoPixel.h>
#include <driver/i2s.h>
#include <math.h>

#ifdef CLAUDEKEY_PRO
#include "pro/display.h"
#include "pro/encoder.h"
#endif

// ── PIN CONFIG ─────────────────────────────────────────
static const uint8_t KEY_PINS[]  = {4, 5, 6, 7, 15, 16};
static const uint8_t NUM_KEYS    = 6;
static const uint8_t LED_PIN     = 48;
static const uint8_t NUM_PIXELS  = 8;

// I2S mic (INMP441)
static const uint8_t I2S_WS  = 42;
static const uint8_t I2S_SCK = 41;
static const uint8_t I2S_SD  = 40;

// Passive buzzer
static const uint8_t BUZZER_PIN = 17;

#ifdef CLAUDEKEY_PRO
// Pro extra keys
static const uint8_t PRO_KEY_PINS[] = {8, 9, 18, 21};
static const uint8_t NUM_PRO_KEYS   = 4;
enum ProKeyAction { UNDO = 0, INTERRUPT, TAB, PASTE };
struct KeyState proKeyState[4];
#endif

// ── USB DESCRIPTORS ────────────────────────────────────
Adafruit_USBD_HID usbHID;
uint8_t const hid_report_desc[] = {TUD_HID_REPORT_DESC_KEYBOARD()};

// USB Audio: 16kHz mono 16-bit
static const uint32_t SAMPLE_RATE = 16000;
static const size_t AUDIO_BUF_SAMPLES = 256;
int16_t audio_buf[AUDIO_BUF_SAMPLES];

// ── LED ────────────────────────────────────────────────
Adafruit_NeoPixel pixels(NUM_PIXELS, LED_PIN, NEO_GRB + NEO_KHZ800);

struct LedState {
    uint8_t r = 30, g = 30, b = 30;  // white default = "disconnected"
    char mode = 'b';                   // b=breathe (slow white = waiting for host)
    float phase = 0;
    bool hostConnected = false;        // true after first L: command received
} led;

// ── KEY STATE ──────────────────────────────────────────
struct KeyState {
    bool pressed = false;
    uint32_t lastChange = 0;
} keyState[6];

static const uint32_t DEBOUNCE_MS = 50;
bool pttHeld = false;

enum KeyAction { ACCEPT, REJECT, UP, DOWN, PTT, SPARE };

// ── NON-BLOCKING BUZZER ────────────────────────────────
// Plays tone sequences without blocking the main loop.
// Each sequence is an array of {freq, duration_ms} pairs, terminated by {0,0}.
struct BuzzerNote { uint16_t freq; uint16_t ms; };

static const BuzzerNote SEQ_ACCEPT[]   = {{1200,40}, {0,0}};
static const BuzzerNote SEQ_REJECT[]   = {{400,60}, {0,40}, {300,80}, {0,0}};
static const BuzzerNote SEQ_PTT_START[]= {{600,30}, {900,30}, {1200,30}, {0,0}};
static const BuzzerNote SEQ_PTT_STOP[] = {{1200,30}, {900,30}, {600,30}, {0,0}};
static const BuzzerNote SEQ_ALERT[]    = {{2000,80}, {0,60}, {2000,80}, {0,60}, {2000,80}, {0,0}};
static const BuzzerNote SEQ_CLICK[]    = {{800,20}, {0,0}};
static const BuzzerNote SEQ_CLICK_LO[] = {{600,20}, {0,0}};
static const BuzzerNote SEQ_SPARE[]    = {{440,30}, {0,0}};

struct BuzzerState {
    const BuzzerNote* seq = nullptr;
    uint8_t idx = 0;
    uint32_t noteStart = 0;
    bool playing = false;
} buzzer;

void buzzerPlay(const BuzzerNote* sequence) {
    buzzer.seq = sequence;
    buzzer.idx = 0;
    buzzer.noteStart = millis();
    buzzer.playing = true;
    // Start first note immediately
    if (sequence[0].freq > 0) {
        ledcWriteTone(BUZZER_PIN, sequence[0].freq);
    } else {
        ledcWriteTone(BUZZER_PIN, 0);  // silence gap
    }
}

void buzzerUpdate() {
    if (!buzzer.playing) return;
    uint32_t now = millis();
    const BuzzerNote& note = buzzer.seq[buzzer.idx];
    if (now - buzzer.noteStart >= note.ms) {
        buzzer.idx++;
        if (buzzer.seq[buzzer.idx].freq == 0 && buzzer.seq[buzzer.idx].ms == 0) {
            // End of sequence
            ledcWriteTone(BUZZER_PIN, 0);
            buzzer.playing = false;
            return;
        }
        buzzer.noteStart = now;
        if (buzzer.seq[buzzer.idx].freq > 0) {
            ledcWriteTone(BUZZER_PIN, buzzer.seq[buzzer.idx].freq);
        } else {
            ledcWriteTone(BUZZER_PIN, 0);  // silence gap
        }
    }
}

// ── SERIAL PROTOCOL ────────────────────────────────────
String serialBuf;

// ── FORWARD DECLARATIONS ───────────────────────────────
void setupI2S();
void setupKeys();
void scanKeys();
void onKeyPress(uint8_t idx);
void onKeyRelease(uint8_t idx);
void hidSendKey(uint8_t keycode);
void hidSendString(const char* str);
void checkSerial();
void updateLeds();
void readMicAndSendUSB();
#ifdef CLAUDEKEY_PRO
void setupProKeys();
void scanProKeys();
void onProKeyPress(uint8_t idx);
#endif

// ── SETUP ──────────────────────────────────────────────
void setup() {
    Serial.begin(115200);

    // USB HID
    usbHID.setReportDescriptor(hid_report_desc, sizeof(hid_report_desc));
    usbHID.begin();
    while (!TinyUSBDevice.mounted()) { delay(1); }

    setupI2S();
    setupKeys();
    ledcAttach(BUZZER_PIN, 1000, 8);  // buzzer PWM

    pixels.begin();
    pixels.setBrightness(80);
    pixels.show();

#ifdef CLAUDEKEY_PRO
    displayInit();
    encoderInit();
    setupProKeys();
#endif

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

// ── KEY SETUP & SCANNING ───────────────────────────────
void setupKeys() {
    for (uint8_t i = 0; i < NUM_KEYS; i++) {
        pinMode(KEY_PINS[i], INPUT_PULLUP);
    }
}

void scanKeys() {
    uint32_t now = millis();
    for (uint8_t i = 0; i < NUM_KEYS; i++) {
        bool isPressed = !digitalRead(KEY_PINS[i]);
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
            hidSendKey(HID_KEY_ENTER);
            buzzerPlay(SEQ_ACCEPT);
            Serial.println("K:accept");
            break;
        case REJECT:
            hidSendKey(HID_KEY_ESCAPE);
            buzzerPlay(SEQ_REJECT);
            Serial.println("K:reject");
            break;
        case UP:
            hidSendKey(HID_KEY_ARROW_UP);
            buzzerPlay(SEQ_CLICK);
            Serial.println("K:up");
            break;
        case DOWN:
            hidSendKey(HID_KEY_ARROW_DOWN);
            buzzerPlay(SEQ_CLICK_LO);
            Serial.println("K:down");
            break;
        case PTT:
            if (!pttHeld) {
                pttHeld = true;
                uint8_t report[8] = {0};
                report[2] = HID_KEY_F13;
                usbHID.keyboardReport(0, 0, report+2);
                buzzerPlay(SEQ_PTT_START);
                Serial.println("K:ptt");
            }
            break;
        case SPARE:
            buzzerPlay(SEQ_SPARE);
            Serial.println("K:spare");
            break;
    }
}

void onKeyRelease(uint8_t idx) {
    if (idx == PTT && pttHeld) {
        pttHeld = false;
        usbHID.keyboardRelease(0);
        buzzerPlay(SEQ_PTT_STOP);
    }
}

void hidSendKey(uint8_t keycode) {
    uint8_t keycodes[6] = {keycode, 0, 0, 0, 0, 0};
    usbHID.keyboardReport(0, 0, keycodes);
    delay(10);
    usbHID.keyboardRelease(0);
}

void hidSendString(const char* str) {
    while (*str) {
        uint8_t keycode = 0;
        uint8_t modifier = 0;
        char c = *str++;
        if (c == '\n') keycode = HID_KEY_ENTER;
        else if (c >= 'a' && c <= 'z') keycode = HID_KEY_A + (c - 'a');
        else if (c >= 'A' && c <= 'Z') {
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

// ── PRO EXTRA KEYS ─────────────────────────────────────
#ifdef CLAUDEKEY_PRO
void setupProKeys() {
    for (uint8_t i = 0; i < NUM_PRO_KEYS; i++) {
        pinMode(PRO_KEY_PINS[i], INPUT_PULLUP);
    }
}

void scanProKeys() {
    uint32_t now = millis();
    for (uint8_t i = 0; i < NUM_PRO_KEYS; i++) {
        bool isPressed = !digitalRead(PRO_KEY_PINS[i]);
        if (isPressed != proKeyState[i].pressed) {
            if (now - proKeyState[i].lastChange >= DEBOUNCE_MS) {
                proKeyState[i].lastChange = now;
                proKeyState[i].pressed = isPressed;
                if (isPressed) onProKeyPress(i);
            }
        }
    }
}

void onProKeyPress(uint8_t idx) {
    switch (idx) {
        case UNDO:
            hidSendKey(HID_KEY_Z);  // TODO: need modifier Cmd+Z
            buzzerPlay(SEQ_CLICK);
            Serial.println("K:undo");
            break;
        case INTERRUPT:
            hidSendKey(HID_KEY_C);  // TODO: need modifier Ctrl+C
            buzzerPlay(SEQ_CLICK);
            Serial.println("K:interrupt");
            break;
        case TAB:
            hidSendKey(HID_KEY_TAB);
            buzzerPlay(SEQ_CLICK);
            Serial.println("K:tab");
            break;
        case PASTE:
            hidSendKey(HID_KEY_V);  // TODO: need modifier Cmd+V
            buzzerPlay(SEQ_CLICK);
            Serial.println("K:paste");
            break;
    }
}
#endif

// ── MIC → USB AUDIO ───────────────────────────────────
void readMicAndSendUSB() {
    size_t bytesRead = 0;
    i2s_read(I2S_NUM_0, audio_buf, sizeof(audio_buf), &bytesRead, 0);
    if (bytesRead > 0 && pttHeld) {
        Serial.write((uint8_t*)audio_buf, bytesRead);
    }
}

// ── SERIAL PROTOCOL ───────────────────────────────────
void checkSerial() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n') {
            serialBuf.trim();
            if (serialBuf.startsWith("L:")) {
                // LED color[,mode]  e.g. "L:green" or "L:red,k"
                led.hostConnected = true;
                String payload = serialBuf.substring(2);
                int comma = payload.indexOf(',');
                String color = (comma >= 0) ? payload.substring(0, comma) : payload;
                color.toLowerCase();
                if      (color == "green")  { led.r=0;  led.g=30; led.b=0;  }
                else if (color == "blue")   { led.r=0;  led.g=0;  led.b=40; }
                else if (color == "yellow") { led.r=40; led.g=25; led.b=0;  }
                else if (color == "red")    { led.r=40; led.g=0;  led.b=0;  }
                else if (color == "white")  { led.r=30; led.g=30; led.b=30; }
                else if (color == "purple") { led.r=20; led.g=0;  led.b=30; }
                else if (color == "off")    { led.r=0;  led.g=0;  led.b=0;  }
                // Optional mode after comma
                if (comma >= 0) {
                    char m = payload.charAt(comma + 1);
                    if (m == 'b' || m == 's' || m == 'k') led.mode = m;
                }
#ifdef CLAUDEKEY_PRO
            } else if (serialBuf.startsWith("D:")) {
                led.hostConnected = true;
                displayParseCommand(serialBuf.c_str());
#endif
            } else if (serialBuf.startsWith("A:")) {
                led.hostConnected = true;
                String alert = serialBuf.substring(2);
                if      (alert == "accept")    buzzerPlay(SEQ_ACCEPT);
                else if (alert == "reject")    buzzerPlay(SEQ_REJECT);
                else if (alert == "alert")     buzzerPlay(SEQ_ALERT);
                else if (alert == "ptt_start") buzzerPlay(SEQ_PTT_START);
                else if (alert == "ptt_stop")  buzzerPlay(SEQ_PTT_STOP);
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
            // Slower breathe when disconnected (white), normal when connected
            if (!led.hostConnected) {
                factor = (sin(led.phase * 0.3) + 1.0) / 2.0;  // ~3x slower
            }
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
#ifdef CLAUDEKEY_PRO
    scanProKeys();
    // Encoder: CW=down, CCW=up, press=enter
    int enc = encoderRead();
    if (enc > 0) { hidSendKey(HID_KEY_ARROW_DOWN); Serial.println("E:cw"); }
    if (enc < 0) { hidSendKey(HID_KEY_ARROW_UP);   Serial.println("E:ccw"); }
    if (encoderButtonPressed()) { hidSendKey(HID_KEY_ENTER); Serial.println("E:press"); }
    displayUpdate();
#endif
    checkSerial();
    readMicAndSendUSB();
    buzzerUpdate();
    updateLeds();
    delay(1);
}
