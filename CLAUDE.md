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

## PTT 语音识别说明

### STT 后端优先级

App 启动时自动检测可用后端，Activity Log 会显示实际使用的引擎：

```
STT: Whisper (whisper-stt)        ← 安装了 mlx-whisper（推荐）
STT: Apple STT (zh_CN)            ← 未安装 mlx-whisper，使用系统识别
```

**优先级链：**

```
scripts/whisper-stt 存在且可执行？
    ├─ Yes → mlx-whisper 转录（真正的中英混合识别）
    │           └─ 失败/未安装 → 降级到 Apple STT
    └─ No  → Apple SFSpeechRecognizer
                  Locale.current → zh-CN → en-US
```

### 方案对比

| | Apple STT | mlx-whisper |
|---|---|---|
| 中英混合 | 部分（依赖系统语言模型） | ✓ 原生支持 |
| 离线 | ✓ | ✓ |
| 延迟 | ~0.5s | ~1-2s (Apple Silicon) |
| 安装 | 零 | `pip install mlx-whisper` |
| 模型大小 | 系统内置 | ~800MB（首次下载） |

### 安装 mlx-whisper（推荐，Apple Silicon）

```bash
pip install mlx-whisper

# 验证安装
python3 -c "import mlx_whisper; print('ok')"
```

安装后重启 App 即自动切换。可通过环境变量指定模型：

```bash
# 默认：mlx-community/whisper-large-v3-turbo（最准确）
# 改用较小模型节省磁盘：
export CLAUDEKEY_WHISPER_MODEL="mlx-community/whisper-small"
./ClaudeKeyLite
```

| 模型 | 大小 | 速度 | 适合 |
|------|------|------|------|
| `whisper-small` | ~250MB | 最快 | 日常轻量 |
| `whisper-medium` | ~750MB | 快 | 平衡 |
| `whisper-large-v3-turbo` | ~800MB | 稍慢 | **默认，最准** |

### 常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 只识别英文 | 未装 mlx-whisper，系统语言是 English | `pip install mlx-whisper` 或切换系统语言为简体中文 |
| PTT 按下无反应 | 未授权麦克风/语音识别权限 | 系统设置 → 隐私与安全性 → 麦克风 / 语音识别 |
| 首次 Whisper 很慢 | 正在下载模型（~800MB） | 等待下载完成，后续正常 |
| 识别结果乱码 | Locale 不匹配 | 安装 mlx-whisper 彻底解决 |

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
