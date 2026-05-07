#pragma once

#include <Arduino.h>

#ifdef __cplusplus
namespace config
{
constexpr uint32_t serial_baud_rate = 115200;
constexpr uint16_t analog_resolution_bits = 12;

constexpr uint32_t button_debounce_time_ms = 40;
constexpr uint32_t file_flush_interval_ms = 100;
constexpr uint32_t simultaneous_press_window_ms = 250;
constexpr uint32_t sample_interval_microseconds = 100; // 2000 Hz
constexpr uint16_t calibration_min_span_counts = 32;
constexpr uint32_t debug_plot_interval_ms = 2;

constexpr uint8_t imu_i2c_address = 0x68;

constexpr const char *data_file_prefix = "/RUN";
constexpr const char *data_file_extension = ".CSV";
constexpr uint16_t max_file_index = 9999;

constexpr const char *calibration_file_name = "/CAL.BIN";
}
#endif
