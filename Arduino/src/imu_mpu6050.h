#pragma once

#include <Arduino.h>
#include <Wire.h>

struct ImuSample
{
    int16_t accel_x_raw;
    int16_t accel_y_raw;
    int16_t accel_z_raw;
    int16_t gyro_x_raw;
    int16_t gyro_y_raw;
    int16_t gyro_z_raw;
};

class Mpu6050Imu
{
public:
    bool begin(TwoWire &wire_interface, uint8_t device_address);
    bool is_available() const;
    bool read_sample(ImuSample &imu_sample);

private:
    bool write_register(uint8_t register_address, uint8_t value);
    bool read_register(uint8_t register_address, uint8_t &value);
    bool read_bytes(uint8_t start_register, uint8_t *buffer, size_t byte_count);

    TwoWire *wire_ = nullptr;
    uint8_t address_ = 0;
    bool is_available_ = false;
};
