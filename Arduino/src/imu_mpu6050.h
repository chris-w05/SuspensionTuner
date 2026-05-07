#pragma once

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>

struct ImuSample
{
    float accel_x;
    float accel_y;
    float accel_z;
    float gyro_x;
    float gyro_y;
    float gyro_z;
};

class Mpu6050Imu
{
public:
    bool begin(TwoWire &wire_interface, uint8_t device_address);
    bool is_available() const;
    bool read_sample(ImuSample &imu_sample);

private:
    Adafruit_MPU6050 mpu_device_;
    bool is_available_ = false;
};
