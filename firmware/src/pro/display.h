/**
 * ClaudeKey Pro — OLED Display Driver
 * SSD1309 2.42" 128x64 I2C (address 0x3C)
 *
 * Wiring:
 *   GPIO1 → SDA
 *   GPIO2 → SCL
 *   3.3V  → VCC
 *   GND   → GND
 *
 * Library: Adafruit SSD1306 (compatible with SSD1309)
 */

#pragma once
#ifdef CLAUDEKEY_PRO

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define OLED_W    128
#define OLED_H    64
#define OLED_ADDR 0x3C
#define OLED_SDA  1
#define OLED_SCL  2

static Adafruit_SSD1306* oled = nullptr;

// Display data updated by serial parser
struct DisplayData {
    char   model[32]    = "";
    int    ctxPct       = 0;
    int    rate5h       = 0;
    int    rate7d       = 0;
    char   cost[10]     = "$0.00";
    int    durationSec  = 0;
    char   status[16]   = "Ready";   // "Ready" | "Idle" | "APPROVE"
    char   activity[42] = "";
    bool   needsApproval = false;
};

static DisplayData dispData;

// ── Init ───────────────────────────────────────────────
void displayInit() {
    Wire.begin(OLED_SDA, OLED_SCL);
    oled = new Adafruit_SSD1306(OLED_W, OLED_H, &Wire, -1);
    if (!oled->begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("OLED init failed");
        delete oled; oled = nullptr; return;
    }
    oled->clearDisplay();
    oled->setTextColor(SSD1306_WHITE);
    oled->setTextSize(1);
    oled->setCursor(20, 28);
    oled->print("ClaudeKey Pro");
    oled->display();
}

// ── Render ─────────────────────────────────────────────
void displayUpdate() {
    if (!oled) return;
    oled->clearDisplay();

    if (dispData.needsApproval) {
        // ── Alert mode: big "NEEDS APPROVAL" ──
        // Invert rectangle top half
        oled->fillRect(0, 0, 128, 32, SSD1306_WHITE);
        oled->setTextColor(SSD1306_BLACK);
        oled->setTextSize(1);
        oled->setCursor(4, 4);
        oled->print("!!! NEEDS APPROVAL !!!");
        oled->setCursor(4, 16);
        oled->print(dispData.activity);
        oled->setTextColor(SSD1306_WHITE);

        // Context bar bottom half
        oled->setCursor(0, 36);
        oled->print("CTX:");
        int barX = 28, barW = 96, barH = 6;
        oled->drawRect(barX, 36, barW, barH, SSD1306_WHITE);
        int fill = barW * min(dispData.ctxPct, 100) / 100;
        if (fill > 0) oled->fillRect(barX, 36, fill, barH, SSD1306_WHITE);

        oled->setCursor(0, 50);
        char pctBuf[8]; snprintf(pctBuf, sizeof(pctBuf), "%d%%", dispData.ctxPct);
        oled->print(pctBuf);
    } else {
        // ── Normal 4-line layout ──
        // Line 1: Model + status (right-aligned)
        oled->setTextSize(1);
        oled->setCursor(0, 0);
        // Truncate model to ~16 chars
        char modelBuf[17]; strncpy(modelBuf, dispData.model, 16); modelBuf[16] = '\0';
        oled->print(modelBuf);

        // Status right-aligned
        int statusLen = strlen(dispData.status);
        oled->setCursor(128 - statusLen * 6, 0);
        oled->print(dispData.status);

        // Line 2: Context bar
        oled->setCursor(0, 12);
        oled->print("CTX");
        int barX = 22, barW = 84, barH = 5;
        oled->drawRect(barX, 12, barW, barH, SSD1306_WHITE);
        int fill = barW * min(dispData.ctxPct, 100) / 100;
        if (fill > 0) oled->fillRect(barX, 12, fill, barH, SSD1306_WHITE);
        // Percent right of bar
        char pctBuf[6]; snprintf(pctBuf, sizeof(pctBuf), "%d%%", dispData.ctxPct);
        oled->setCursor(108, 12);
        oled->print(pctBuf);

        // Line 3: Rate limits
        oled->setCursor(0, 24);
        char rateBuf[28];
        snprintf(rateBuf, sizeof(rateBuf), "5h:%d%%  7d:%d%%", dispData.rate5h, dispData.rate7d);
        oled->print(rateBuf);

        // Line 4: Cost + duration
        oled->setCursor(0, 36);
        char statBuf[22];
        snprintf(statBuf, sizeof(statBuf), "%s  %ds", dispData.cost, dispData.durationSec);
        oled->print(statBuf);

        // Line 5: Activity (truncated to 21 chars)
        if (strlen(dispData.activity) > 0) {
            oled->setCursor(0, 52);
            char actBuf[22]; strncpy(actBuf, dispData.activity, 21); actBuf[21] = '\0';
            oled->print(actBuf);
        }
    }

    oled->display();
}

// ── Serial command parser ──────────────────────────────
// Format: "D:<ctxPct>,<rate5h>,<rate7d>,<cost>,<durSec>,<status>,<activity>"
void displayParseCommand(const char* cmd) {
    char buf[128];
    strncpy(buf, cmd + 2, sizeof(buf) - 1);  // skip "D:"
    buf[sizeof(buf) - 1] = '\0';

    char* tok = strtok(buf, ",");
    if (tok) dispData.ctxPct = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) dispData.rate5h = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) dispData.rate7d = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) strncpy(dispData.cost, tok, sizeof(dispData.cost) - 1);
    tok = strtok(nullptr, ",");
    if (tok) dispData.durationSec = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) {
        strncpy(dispData.status, tok, sizeof(dispData.status) - 1);
        dispData.needsApproval = (strcmp(tok, "APPROVE") == 0);
    }
    tok = strtok(nullptr, "\n");
    if (tok) strncpy(dispData.activity, tok, sizeof(dispData.activity) - 1);
}

#endif // CLAUDEKEY_PRO
