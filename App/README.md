# Suspension Tuner App

Flutter application for:

- Creating bike calibration profiles from linkage geometry and ADC endpoints.
- Parsing binary Arduino DAQ files written from `DaqRecord` (21 bytes packed).
- Plotting position (x) versus velocity (y).

## Notes

- Flutter SDK is required to run this app.
- The parser expects little-endian records with this layout:
  - uint32 timestamp_microseconds
  - uint16 potentiometer_front_raw
  - uint16 potentiometer_rear_raw
  - int16 x 6 IMU fields
  - uint8 status_flags
