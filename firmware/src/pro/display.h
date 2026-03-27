/**
 * ClaudeKey Pro — TFT Display Driver (ST7789 1.3" 240x240)
 *
 * SPI Wiring:
 *   GPIO10 → CS
 *   GPIO11 → DC
 *   GPIO12 → RST
 *   GPIO13 → SDA (MOSI)
 *   GPIO14 → SCL (SCK)
 *   3.3V   → VCC
 *   GND    → GND
 *   3.3V   → BL (backlight)
 */

#pragma once
#ifdef CLAUDEKEY_PRO

#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>

// SPI pins for TFT
static const uint8_t TFT_CS  = 10;
static const uint8_t TFT_DC  = 11;
static const uint8_t TFT_RST = 12;
static const uint8_t TFT_SDA = 13;
static const uint8_t TFT_SCL = 14;

static Adafruit_ST7789* tft = nullptr;

struct DisplayData {
    char model[32]    = "";
    char status[16]   = "Ready";
    int  ctxPercent   = 0;
    int  rate5h       = 0;
    int  rate7d       = 0;
    char cost[12]     = "$0.00";
    char duration[12] = "0s";
    char lines[16]    = "+0/-0";
    char activity[64] = "";
    bool needsApproval = false;
    int  encoderVal   = 0;
};

static DisplayData displayData;

uint16_t barColor565(int percent) {
    if (percent < 25) return 0x07E0;  // green
    if (percent < 50) return 0x001F;  // blue
    if (percent < 75) return 0xFFE0;  // yellow
    return 0xF800;                     // red
}

void drawBar(int x, int y, int w, int h, int percent, uint16_t color) {
    tft->fillRoundRect(x, y, w, h, h/2, 0x1082);  // dark bg
    int fillW = w * min(percent, 100) / 100;
    if (fillW > 0) {
        tft->fillRoundRect(x, y, fillW, h, h/2, color);
    }
}

void displayInit() {
    SPI.begin(TFT_SCL, -1, TFT_SDA, TFT_CS);
    tft = new Adafruit_ST7789(&SPI, TFT_CS, TFT_DC, TFT_RST);
    tft->init(240, 240, SPI_MODE0);
    tft->setRotation(0);
    tft->fillScreen(ST77XX_BLACK);
    tft->setTextWrap(false);

    tft->setTextSize(1);
    tft->setTextColor(0x07E0);
    tft->setCursor(60, 110);
    tft->print("ClaudeKey Pro");
}

void displayUpdate() {
    if (!tft) return;

    tft->fillScreen(ST77XX_BLACK);

    int y = 8;
    int pad = 10;
    int w = 220;

    // Row 1: Model + Status
    tft->setTextSize(1);
    tft->setTextColor(ST77XX_WHITE);
    tft->setCursor(pad, y);
    tft->print(displayData.model);

    uint16_t statusColor = displayData.needsApproval ? ST77XX_YELLOW : 0x07E0;
    tft->setTextColor(statusColor);
    int statusX = 240 - pad - strlen(displayData.status) * 6;
    tft->setCursor(statusX, y);
    tft->print(displayData.status);
    y += 18;

    // Row 2: Context bar
    tft->setTextColor(0x7BEF);  // gray
    tft->setCursor(pad, y);
    tft->print("CTX");

    char pctBuf[8];
    snprintf(pctBuf, sizeof(pctBuf), "%d%%", displayData.ctxPercent);
    tft->setTextColor(barColor565(displayData.ctxPercent));
    tft->setCursor(240 - pad - strlen(pctBuf) * 6, y);
    tft->print(pctBuf);
    y += 12;

    drawBar(pad, y, w, 8, displayData.ctxPercent, barColor565(displayData.ctxPercent));
    y += 16;

    // Row 3: Rate limits
    char r5buf[12], r7buf[12];
    snprintf(r5buf, sizeof(r5buf), "5h:%d%%", displayData.rate5h);
    snprintf(r7buf, sizeof(r7buf), "7d:%d%%", displayData.rate7d);

    tft->setTextColor(barColor565(displayData.rate5h));
    tft->setCursor(pad, y);
    tft->print(r5buf);
    tft->setTextColor(barColor565(displayData.rate7d));
    tft->setCursor(240 - pad - strlen(r7buf) * 6, y);
    tft->print(r7buf);
    y += 12;

    int halfW = (w - 4) / 2;
    drawBar(pad, y, halfW, 6, displayData.rate5h, barColor565(displayData.rate5h));
    drawBar(pad + halfW + 4, y, halfW, 6, displayData.rate7d, barColor565(displayData.rate7d));
    y += 14;

    // Row 4: Stats
    tft->setTextColor(0x7BEF);
    tft->setCursor(pad, y);
    char statsBuf[48];
    snprintf(statsBuf, sizeof(statsBuf), "%s  %s  %s",
             displayData.cost, displayData.duration, displayData.lines);
    tft->print(statsBuf);
    y += 16;

    // Divider
    tft->drawFastHLine(pad, y, w, 0x2104);
    y += 8;

    // Row 5: Activity
    if (strlen(displayData.activity) > 0) {
        tft->setTextColor(displayData.needsApproval ? ST77XX_YELLOW : ST77XX_CYAN);
        tft->setCursor(pad, y);
        // Truncate to fit screen width
        char actBuf[38];
        strncpy(actBuf, displayData.activity, 37);
        actBuf[37] = '\0';
        tft->print(actBuf);
    }

    // Encoder value (bottom-right)
    if (displayData.encoderVal != 0) {
        char encBuf[12];
        snprintf(encBuf, sizeof(encBuf), "enc:%d", displayData.encoderVal);
        tft->setTextColor(0x4208);
        tft->setCursor(240 - pad - strlen(encBuf) * 6, 224);
        tft->print(encBuf);
    }
}

// Parse "D:ctx,5h,7d,cost,dur,status" serial command
void displayParseCommand(const char* cmd) {
    // Format: D:<ctxPct>,<rate5h>,<rate7d>,<cost>,<duration>,<status>
    char buf[128];
    strncpy(buf, cmd + 2, sizeof(buf) - 1);  // skip "D:"
    buf[sizeof(buf) - 1] = '\0';

    char* tok = strtok(buf, ",");
    if (tok) displayData.ctxPercent = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) displayData.rate5h = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) displayData.rate7d = atoi(tok);
    tok = strtok(nullptr, ",");
    if (tok) strncpy(displayData.cost, tok, sizeof(displayData.cost) - 1);
    tok = strtok(nullptr, ",");
    if (tok) strncpy(displayData.duration, tok, sizeof(displayData.duration) - 1);
    tok = strtok(nullptr, ",");
    if (tok) strncpy(displayData.status, tok, sizeof(displayData.status) - 1);
}

#endif // CLAUDEKEY_PRO
