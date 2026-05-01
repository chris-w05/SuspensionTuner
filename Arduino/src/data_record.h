#pragma once

#include <Arduino.h>

#ifdef __cplusplus
namespace daq_flags
{
constexpr uint8_t imu_present_flag = 0x01;
constexpr uint8_t imu_sample_valid_flag = 0x02;
constexpr uint8_t button_pressed_flag = 0x04;
constexpr uint8_t acquisition_active_flag = 0x08;
}

struct __attribute__((packed)) DaqRecord
{
    uint32_t timestamp_microseconds;
    uint16_t potentiometer_front_raw;
    uint16_t potentiometer_rear_raw;

    int16_t imu_accel_x_raw;
    int16_t imu_accel_y_raw;
    int16_t imu_accel_z_raw;

    int16_t imu_gyro_x_raw;
    int16_t imu_gyro_y_raw;
    int16_t imu_gyro_z_raw;

    uint8_t status_flags;
};

static_assert(sizeof(DaqRecord) == 21, "Unexpected DaqRecord size");
#endif
