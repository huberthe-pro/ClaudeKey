/**
 * ClaudeKey Pro — Rotary Encoder Driver (EC11)
 *
 * Wiring:
 *   GPIO1 → CLK (A)
 *   GPIO2 → DT  (B)
 *   GPIO3 → SW  (button)
 *   GND   → GND
 *   (internal pull-ups used)
 */

#pragma once
#ifdef CLAUDEKEY_PRO

static const uint8_t ENC_CLK = 1;
static const uint8_t ENC_DT  = 2;
static const uint8_t ENC_SW  = 3;

static volatile int encoderPos = 0;
static int lastEncoderPos = 0;
static bool lastEncBtn = true;

void IRAM_ATTR encoderISR() {
    if (digitalRead(ENC_DT)) {
        encoderPos++;
    } else {
        encoderPos--;
    }
}

void encoderInit() {
    pinMode(ENC_CLK, INPUT_PULLUP);
    pinMode(ENC_DT, INPUT_PULLUP);
    pinMode(ENC_SW, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(ENC_CLK), encoderISR, FALLING);
}

// Returns: -1 (left), 0 (no change), +1 (right)
int encoderRead() {
    int pos = encoderPos;
    if (pos != lastEncoderPos) {
        int dir = (pos > lastEncoderPos) ? 1 : -1;
        lastEncoderPos = pos;
        return dir;
    }
    return 0;
}

// Returns true on button press (falling edge)
bool encoderButtonPressed() {
    bool current = digitalRead(ENC_SW);
    if (lastEncBtn && !current) {
        lastEncBtn = current;
        return true;
    }
    lastEncBtn = current;
    return false;
}

#endif // CLAUDEKEY_PRO
