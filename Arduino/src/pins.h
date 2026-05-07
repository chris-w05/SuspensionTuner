#pragma once

#include <Arduino.h>

namespace pins
{
constexpr uint8_t potentiometer_front_pin = A0;
constexpr uint8_t potentiometer_rear_pin = A0; //Same as front for now - only one sensor is attached
constexpr uint8_t acquisition_switch_pin = 3;
constexpr uint8_t calibration_switch_pin = 5;
constexpr uint8_t acquisition_indicator_light_pin = 4;

//IMU pins
constexpr uint8_t imu_SCL = 19;
constexpr uint8_t imu_SDA = 18;
constexpr uint8_t imu_INT = 2;

// Teensy 4.1 onboard SD slot chip select.
constexpr uint8_t sd_chip_select_pin = BUILTIN_SDCARD;
}
