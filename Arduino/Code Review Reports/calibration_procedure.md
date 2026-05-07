# Calibration Procedure

This firmware uses two latching handlebar switches:

- Acquisition switch (`acquisition_switch_pin`): normal run control and front/rear selector during calibration.
- Calibration switch (`calibration_switch_pin`): capture trigger during calibration.

## Normal operation

- Acquisition switch `ON` -> acquisition starts.
- Acquisition switch `OFF` -> acquisition stops.

## Enter calibration mode

1. Press both switches to `ON`.
2. Keep both switches `ON` for 1.5 seconds.
3. Firmware enters calibration mode and stops acquisition.

The 1.5-second hold is the only entry guard. Either switch may already be ON before the gesture begins.

## Capture points in calibration mode

Use the acquisition switch to choose front/rear, then toggle the calibration switch to capture endpoint values:

- Acquisition switch `OFF` + calibration switch transition `OFF -> ON`: capture front extended.
- Acquisition switch `OFF` + calibration switch transition `ON -> OFF`: capture front compressed.
- Acquisition switch `ON` + calibration switch transition `OFF -> ON`: capture rear extended.
- Acquisition switch `ON` + calibration switch transition `ON -> OFF`: capture rear compressed.

After all four points are captured:

- Firmware validates each potentiometer span against `calibration_min_span_counts`.
- On success, values are saved to EEPROM and calibration mode exits.
- On failure, captured points are cleared and capture must be repeated.

## Persistence

Calibration endpoints are stored at EEPROM address 0 with a magic tag (`CAL1`) and loaded at startup.
