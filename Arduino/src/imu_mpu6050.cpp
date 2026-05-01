#include "imu_mpu6050.h"

namespace
{
constexpr uint8_t power_management_1_register = 0x6B;
constexpr uint8_t who_am_i_register = 0x75;
constexpr uint8_t sensor_data_start_register = 0x3B;
constexpr uint8_t expected_who_am_i_value_primary = 0x68;
constexpr uint8_t expected_who_am_i_value_secondary = 0x69;
}

bool Mpu6050Imu::begin(TwoWire &wire_interface, uint8_t device_address)
{
    wire_ = &wire_interface;
    address_ = device_address;
    is_available_ = false;

    uint8_t who_am_i_value = 0;
    if (!read_register(who_am_i_register, who_am_i_value))
    {
        return false;
    }

    if (who_am_i_value != expected_who_am_i_value_primary &&
        who_am_i_value != expected_who_am_i_value_secondary)
    {
        return false;
    }

    if (!write_register(power_management_1_register, 0x00))
    {
        return false;
    }

    is_available_ = true;
    return true;
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

    uint8_t raw_sensor_data[14] = {0};
    if (!read_bytes(sensor_data_start_register, raw_sensor_data, sizeof(raw_sensor_data)))
    {
        return false;
    }

    imu_sample.accel_x_raw = static_cast<int16_t>((raw_sensor_data[0] << 8) | raw_sensor_data[1]);
    imu_sample.accel_y_raw = static_cast<int16_t>((raw_sensor_data[2] << 8) | raw_sensor_data[3]);
    imu_sample.accel_z_raw = static_cast<int16_t>((raw_sensor_data[4] << 8) | raw_sensor_data[5]);

    imu_sample.gyro_x_raw = static_cast<int16_t>((raw_sensor_data[8] << 8) | raw_sensor_data[9]);
    imu_sample.gyro_y_raw = static_cast<int16_t>((raw_sensor_data[10] << 8) | raw_sensor_data[11]);
    imu_sample.gyro_z_raw = static_cast<int16_t>((raw_sensor_data[12] << 8) | raw_sensor_data[13]);

    return true;
}

bool Mpu6050Imu::write_register(uint8_t register_address, uint8_t value)
{
    if (wire_ == nullptr)
    {
        return false;
    }

    wire_->beginTransmission(address_);
    wire_->write(register_address);
    wire_->write(value);

    return wire_->endTransmission() == 0;
}

bool Mpu6050Imu::read_register(uint8_t register_address, uint8_t &value)
{
    if (!read_bytes(register_address, &value, 1))
    {
        return false;
    }

    return true;
}

bool Mpu6050Imu::read_bytes(uint8_t start_register, uint8_t *buffer, size_t byte_count)
{
    if (wire_ == nullptr || buffer == nullptr || byte_count == 0)
    {
        return false;
    }

    wire_->beginTransmission(address_);
    wire_->write(start_register);
    if (wire_->endTransmission(false) != 0)
    {
        return false;
    }

    const size_t bytes_received = wire_->requestFrom(address_, static_cast<uint8_t>(byte_count));
    if (bytes_received != byte_count)
    {
        return false;
    }

    for (size_t byte_index = 0; byte_index < byte_count; ++byte_index)
    {
        if (wire_->available() <= 0)
        {
            return false;
        }

        buffer[byte_index] = static_cast<uint8_t>(wire_->read());
    }

    return true;
}
