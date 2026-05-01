#pragma once

#include <Arduino.h>

namespace pins
{
constexpr uint8_t potentiometer_front_pin = A0;
constexpr uint8_t potentiometer_rear_pin = A1;
constexpr uint8_t acquisition_button_pin = 2;
constexpr uint8_t acquisition_indicator_light_pin = LED_BUILTIN;

// Teensy 4.1 onboard SD slot chip select.
constexpr uint8_t sd_chip_select_pin = BUILTIN_SDCARD;
}
