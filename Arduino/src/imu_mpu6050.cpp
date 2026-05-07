#include "imu_mpu6050.h"

bool Mpu6050Imu::begin(TwoWire &wire_interface, uint8_t device_address)
{
    is_available_ = mpu_device_.begin(device_address, &wire_interface);
    return is_available_;
}

bool Mpu6050Imu::is_available() const
{
    return is_available_;
}

bool Mpu6050Imu::read_sample(ImuSample &imu_sample)
{
    if (!is_available_)
    {
        return false;
    }

    sensors_event_t accel_event;
    sensors_event_t gyro_event;
    sensors_event_t temp_event;
    mpu_device_.getEvent(&accel_event, &gyro_event, &temp_event);

    imu_sample.accel_x = accel_event.acceleration.x;
    imu_sample.accel_y = accel_event.acceleration.y;
    imu_sample.accel_z = accel_event.acceleration.z;

    imu_sample.gyro_x = gyro_event.gyro.x;
    imu_sample.gyro_y = gyro_event.gyro.y;
    imu_sample.gyro_z = gyro_event.gyro.z;

    return true;
}
