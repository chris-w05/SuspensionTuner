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

namespace daq_format
{
constexpr uint16_t frame_sync_word = 0xA55A;
constexpr uint8_t frame_version = 2;
constexpr float standard_gravity_meters_per_second_squared = 9.80665f;
constexpr float accel_milli_g_per_g = 1000.0f;
constexpr float gyro_deci_degrees_per_second_scale = 10.0f;
}

struct __attribute__((packed)) DaqRecordPayload
{
    uint32_t timestamp_microseconds = 0;
    uint16_t potentiometer_front_raw = 0;
    uint16_t potentiometer_rear_raw = 0;

    int16_t imu_accel_x_milli_g = 0;
    int16_t imu_accel_y_milli_g = 0;
    int16_t imu_accel_z_milli_g = 0;

    int16_t imu_gyro_x_deci_degrees_per_second = 0;
    int16_t imu_gyro_y_deci_degrees_per_second = 0;
    int16_t imu_gyro_z_deci_degrees_per_second = 0;

    uint8_t status_flags = 0;
};

struct __attribute__((packed)) DaqRecordFrame
{
    uint16_t sync_word = daq_format::frame_sync_word;
    uint8_t version = daq_format::frame_version;
    uint8_t payload_size = sizeof(DaqRecordPayload);
    DaqRecordPayload payload = {};
    uint16_t crc16_ccitt = 0;
};

static_assert(sizeof(DaqRecordPayload) == 21, "Unexpected DaqRecordPayload size");
static_assert(sizeof(DaqRecordFrame) == 27, "Unexpected DaqRecordFrame size");
#endif
