# App — Flutter Application Navigation Guide

Read the root `AGENTS.md` first for project-wide context and data-format contracts.

---

## Technology Stack

- **Framework:** Flutter (Dart), Material 3, targets iOS, macOS, and Android.
- **Key dependencies:** `fl_chart` (charts), `file_picker` (file/EEPROM import), `shared_preferences` (profile persistence).
- **Build:** standard `flutter build` / `flutter run`. No code generation step is needed.

---

## Source Layout (`lib/`)

```
lib/
├── main.dart                          App entry-point, root widget, and profile state
├── models/
│   ├── calibration_profile.dart       CalibrationProfile + PotentiometerCalibration data classes
│   └── analysis_models.dart           All analysis output types (ChannelResult, AnalysisResult, …)
├── screens/
│   ├── setup_tab.dart                 "Setup Bike" tab — profile CRUD and calibration import UI
│   └── analysis_tab.dart              "Analyze Log" tab — file picker, chart rendering, and interaction
└── services/
    ├── profile_storage_service.dart   Persist/load profiles via SharedPreferences (JSON)
    ├── daq_parser_service.dart         Parse DAQ log files → AnalysisResult
    └── arduino_calibration_import_service.dart  Parse Arduino CAL.BIN or text → ADC endpoint values
```

---

## Key Classes and Their Roles

### `main.dart`

| Symbol | Role |
|---|---|
| `SuspensionTunerApp` | Root `MaterialApp`. Seed color `0xFF136A8A`. |
| `_HomePage` / `_HomePageState` | Owns the `List<CalibrationProfile>` state. Passes profiles down to both tabs and handles save/update/delete by delegating to `ProfileStorageService`. |

The two tabs are `SetupTab` (index 0) and `AnalysisTab` (index 1) inside a `DefaultTabController`.

---

### `models/calibration_profile.dart`

| Symbol | Role |
|---|---|
| `PotentiometerChannel` | Enum — `front` or `rear`. Used as a map key throughout the parser. |
| `PotentiometerCalibration` | Immutable geometry calibration for one channel. Holds sides A, B, C (mm) and the ADC counts at each endpoint. Exposes `mapAdcToPositionMillimeters(int)` and `mapAdcToPositionPercent(int)`. |
| `CalibrationProfile` | Named collection of up to two `PotentiometerCalibration` objects. Serialised to/from JSON. `configuredChannels` returns only the non-null channels. |

Default fixed side length: 145 mm. `_calculateAngleDegrees` uses the law of cosines and throws `FormatException` on degenerate triangles.

---

### `models/analysis_models.dart`

| Symbol | Role |
|---|---|
| `PositionTimePoint` | One sample: `timeSeconds`, `positionMillimeters`, `normalizedTravelPercent`. |
| `PositionVelocityPoint` | One point on the velocity–position scatter plot. |
| `AttitudeTimePoint` | Integrated pitch and lean (degrees) at one timestamp. |
| `AccelerationTimePoint` | Raw and absolute IMU acceleration (g) at one timestamp. |
| `ChannelResult` | Aggregated per-channel output: velocity points, position-time series, and min/max statistics. |
| `AnalysisResult` | Top-level parser output: `Map<PotentiometerChannel, ChannelResult>`, attitude series, acceleration series, and sample count. |

---

### `services/daq_parser_service.dart`

Single public method:

```dart
Future<AnalysisResult> parsePositionVelocity({
  required Uint8List bytes,
  required CalibrationProfile profile,
  required List<PotentiometerChannel> channels,
})
```

**Detection order:** CSV text → framed-v2 binary → legacy-float-v1 → legacy-int16-v1.

Internal constants of note (do not change without updating the Arduino firmware and this list):
- `_velocityIirAlpha = 0.05` — IIR low-pass coefficient for velocity smoothing.
- `_timestampWrapMicroseconds = 0x100000000` — handles `micros()` 32-bit wrap.
- IMU scale factors mirror the MPU-6050 defaults: `16384 LSB/g` (accelerometer), `131 LSB/°/s` (gyroscope).

---

### `services/arduino_calibration_import_service.dart`

`ArduinoCalibrationImportService.parse(Uint8List bytes)` returns `ArduinoCalibrationData` (four `int` fields: `frontExtended`, `frontCompressed`, `rearExtended`, `rearCompressed`).

Accepts:
1. Arduino EEPROM binary blob (`CAL1` magic, little-endian or big-endian).
2. Plain text containing key–value pairs matched by regex (case-insensitive).

The returned ADC counts are used by `SetupTab` to pre-fill the calibration form.

---

### `services/profile_storage_service.dart`

- SharedPreferences key: `calibration_profiles_v1`
- Profiles are stored as a `List<String>` where each element is a JSON-encoded `CalibrationProfile`.
- On load, profiles are sorted newest-first by `createdAtMilliseconds`. Stale (unparseable) entries are silently dropped and the clean list is re-saved.

---

### `screens/setup_tab.dart` — `SetupTab`

Props received: `profiles`, `onSaveProfile`, `onUpdateProfile`, `onDeleteProfile`.

State machine (simplified):
- `_isFormOpen = false` → shows the profile list with an "Add profile" button.
- `_isFormOpen = true, _editingProfileId = null` → new-profile form.
- `_isFormOpen = true, _editingProfileId != null` → edit-profile form pre-filled from the existing profile.

The "Import from Arduino" button inside the form calls `ArduinoCalibrationImportService.parse` and populates the ADC text-field controllers. The user still needs to enter the physical side-C measurements manually.

12 `TextEditingController` objects cover: name, front (sideA, sideB, extendedC, extendedAdc, compressedC, compressedAdc), rear (same six). Default side A and B are `"145"`.

---

### `screens/analysis_tab.dart` — `AnalysisTab`

Props received: `profiles` (read-only reference; does not call back to `_HomePage`).

Internal state:
- `_selectedProfile` — which `CalibrationProfile` to use for parsing.
- `_analysisResult` — populated by `_pickAndAnalyzeFile()`.
- `_graphTabController` — 3-tab controller: "Time Series" | "Velocity" | "Distribution".
- `_timeChartOrder` — user-reorderable list of chart IDs for the time-series tab.
- `_timeViewMinX` / `_timeViewMaxX` — synchronized zoom across all time-axis charts (null = full range).
- `_scatterViewBounds` — per-chart scatter zoom state.

**Render-performance caches** (`_lineSpotCache`, `_scatterSpotCache`, `_distributionValuesCache`): keyed by `"chartId|budget"`. Call `_clearRenderCaches()` whenever the underlying data changes. The render budget (max points sampled) drops during active gestures to maintain frame rate:
- Line charts: 2200 points at rest → 650 while interacting.
- Scatter charts: 6500 at rest → 1200 while interacting time axis.

Supported file extensions for import: `bin`, `dat`, `raw`, `daq`, `csv`, `txt`. On iOS the extension filter is disabled (platform limitation).

---

## Platform Notes

### macOS App Sandbox
File picking requires `com.apple.security.files.user-selected.read-only` (or `read-write`) in both:
- `macos/Runner/DebugProfile.entitlements`
- `macos/Runner/Release.entitlements`

Without this entitlement the file picker silently does nothing.

---

## Typical Change Patterns

| Goal | Files to touch |
|---|---|
| Add a new chart to the Analysis tab | `analysis_tab.dart` (render + `_timeChartOrder`), `analysis_models.dart` if new data needed, `daq_parser_service.dart` to populate new fields |
| Add a new sensor field to the DAQ record | `data_record.h` (Arduino), `daq_parser_service.dart` (parser), `analysis_models.dart` (model), and any chart code in `analysis_tab.dart` |
| Change the calibration geometry model | `calibration_profile.dart` (`PotentiometerCalibration`), `setup_tab.dart` (form fields), and update `AGENTS.md` / root `AGENTS.md` data-contract tables |
| Add or rename a profile field | `calibration_profile.dart` (`toJson`/`fromJson`), bump the SharedPreferences key in `profile_storage_service.dart` if the schema is not backward-compatible |
| Support a new DAQ file format | `daq_parser_service.dart`: add a `_DaqFileFormat` variant, a decode function, and slot it into the detection order |
