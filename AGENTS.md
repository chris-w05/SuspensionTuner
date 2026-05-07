# SuspensionTuner — Project Navigation Guide

This file is the top-level orientation document for AI agents. Read it first before exploring any sub-folder.

---

## Repository Layout

```
SuspensionTuner/
├── App/              Flutter mobile/desktop application
├── Arduino/          PlatformIO firmware for the DAQ hardware
└── SuspensionDAQ/    KiCad PCB design files (read-only for software agents)
```

Each sub-folder with active code has its own `AGENTS.md` with folder-specific rules and conventions.

---

## System Overview

The project is a **motorcycle suspension data-acquisition and analysis system** consisting of three tightly-coupled components:

1. **DAQ Hardware** (`SuspensionDAQ/`) — Custom PCB carrying a microcontroller, two potentiometer inputs, an IMU (MPU-6050), and an SD-card slot.
2. **Arduino Firmware** (`Arduino/`) — Samples the potentiometers and IMU at 2 kHz, writes CSV (or binary framed) records to SD card, and manages a two-button calibration workflow.
3. **Flutter App** (`App/`) — Imports calibration data from the Arduino, stores calibration profiles, loads DAQ log files, and renders analysis charts.

---

## Cross-Cutting Data Contracts

Understanding these formats prevents you from making changes that break the hardware–app boundary.

### DAQ Log File Format (current)

- Files are CSV text, extension `.CSV`, written to SD card as `/RUN0001.CSV`, `/RUN0002.CSV`, …
- Header row: `timestamp_us,front_raw,rear_raw,accel_x_g,accel_y_g,accel_z_g,gyro_x_dps,gyro_y_dps,gyro_z_dps,status_flags`
- `timestamp_us` — Arduino `micros()`, wraps at 2^32 (~71 min). The Flutter parser handles wrap-around.
- `front_raw` / `rear_raw` — 12-bit ADC counts (0–4095) from the suspension potentiometers.
- IMU columns are floating-point values in g and degrees/second.
- `status_flags` — bitmask: bit 0 = IMU present, bit 1 = IMU sample valid, bit 2 = button pressed, bit 3 = acquisition active.

### Legacy Binary Formats (parser still supports these; do not generate new files in these formats)

| Format | Record size | Key identifier |
|---|---|---|
| Framed v2 | 27 bytes | sync word `0xA55A`, version byte `0x02` |
| Legacy float v1 | 33 bytes | detected by file size divisibility |
| Legacy int16 v1 | 21 bytes | detected by file size divisibility |

### Arduino Calibration File (`/CAL.BIN` on SD card)

- 12-byte little-endian struct: `uint32 magic (0x43414C31 "CAL1")`, then `uint16 front_extended`, `uint16 front_compressed`, `uint16 rear_extended`, `uint16 rear_compressed`.
- The Flutter `ArduinoCalibrationImportService` accepts this binary blob **or** a text file containing the same values (useful for manually-typed inputs).

### Potentiometer Geometry Model

Calibration uses a **law-of-cosines triangle** to convert ADC counts to suspension travel in millimetres:
- Sides A and B are fixed mounting-arm lengths (default 145 mm each).
- Side C is the potentiometer rod length at the extended and compressed endpoints.
- The angle at the apex is computed from A, B, C; ADC counts are linearly interpolated between the two endpoint angles to produce a millimetre position.

---

## Coding Standards

All code-level conventions (naming, tool use, clarifying questions, etc.) are defined in `Arduino/AGENTS.md`. Those rules apply to **both** sub-projects unless a sub-project `AGENTS.md` overrides them.

Key rules to remember:
- Ask clarifying questions before writing code when requirements are ambiguous (see `Arduino/AGENTS.md` §2).
- Never use terminal commands to read source files; use file-access tools.
- No emojis anywhere in code or UI.
- Bug/code-review reports go in `Arduino/Code Review Reports/`.
