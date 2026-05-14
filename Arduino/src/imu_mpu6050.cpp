#include "imu_mpu6050.h"

#include <math.h>

namespace
{
// MPU-6050 register addresses.
constexpr uint8_t reg_pwr_mgmt_1   = 0x6B;
constexpr uint8_t reg_accel_config = 0x1C;
constexpr uint8_t reg_gyro_config  = 0x1B;
constexpr uint8_t reg_accel_xout_h = 0x3B;

// Scale factors at default full-scale ranges (±2g / ±250°/s).
constexpr float accel_lsb_per_g        = 16384.0f;
constexpr float gyro_lsb_per_deg_per_s = 131.0f;
constexpr float gravity_m_per_s2       = 9.80665f;
constexpr float deg_to_rad             = 0.01745329252f;
}

bool Mpu6050Imu::write_register(uint8_t reg, uint8_t value)
{
    wire_->beginTransmission(address_);
    wire_->write(reg);
    wire_->write(value);
    return wire_->endTransmission() == 0;
}

bool Mpu6050Imu::read_registers(uint8_t reg, uint8_t *buffer, uint8_t length)
{
    wire_->beginTransmission(address_);
    wire_->write(reg);
    if (wire_->endTransmission(false) != 0)
    {
        return false;
    }
    const uint8_t received = wire_->requestFrom(address_, length);
    if (received != length)
    {
        return false;
    }
    for (uint8_t i = 0; i < length; ++i)
    {
        buffer[i] = wire_->read();
    }
    return true;
}

bool Mpu6050Imu::begin(TwoWire &wire_interface, uint8_t device_address)
{
    wire_    = &wire_interface;
    address_ = device_address;

    // Wake the device by clearing the sleep bit.
    if (!write_register(reg_pwr_mgmt_1, 0x00))
    {
        return false;
    }
    delay(100);

    // Set default full-scale ranges: ±2g for accel, ±250°/s for gyro.
    if (!write_register(reg_accel_config, 0x00))
    {
        return false;
    }
    if (!write_register(reg_gyro_config, 0x00))
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

// Compute bilinear-transform biquad coefficients for one stage of a
// Butterworth low-pass prototype with the given Q.
static void compute_butterworth_biquad(float cutoff_hz, float sample_rate_hz,
                                        float Q, BiquadFilter &stage)
{
    const float K    = tanf(3.14159265f * cutoff_hz / sample_rate_hz);
    const float K2   = K * K;
    const float norm = K2 + K / Q + 1.0f;
    stage.b0 = K2 / norm;
    stage.b1 = 2.0f * stage.b0;
    stage.b2 = stage.b0;
    stage.a1 = 2.0f * (K2 - 1.0f) / norm;
    stage.a2 = (K2 - K / Q + 1.0f) / norm;
    stage.w1 = 0.0f;
    stage.w2 = 0.0f;
}

// Evaluate the phase (degrees) of a biquad stage at normalised frequency omega.
static float biquad_phase_deg(float omega, const BiquadFilter &stage)
{
    const float cos_w  = cosf(omega);
    const float sin_w  = sinf(omega);
    const float cos_2w = cosf(2.0f * omega);
    const float sin_2w = sinf(2.0f * omega);
    const float num_re = stage.b0 + stage.b1 * cos_w + stage.b2 * cos_2w;
    const float num_im = -(stage.b1 * sin_w + stage.b2 * sin_2w);
    const float den_re = 1.0f + stage.a1 * cos_w + stage.a2 * cos_2w;
    const float den_im = -(stage.a1 * sin_w + stage.a2 * sin_2w);
    return (atan2f(num_im, num_re) - atan2f(den_im, den_re)) * (180.0f / 3.14159265f);
}

ImuFilterDiagnostics Mpu6050Imu::set_low_pass_cutoff(float cutoff_hz, float sample_rate_hz)
{
    // 4th-order Butterworth prototype pole pairs give these Q values:
    //   Stage 0: Q = 1 / (2*cos(π/8))  ≈ 0.5412  (poles near real axis)
    //   Stage 1: Q = 1 / (2*cos(3π/8)) ≈ 1.3066  (poles near imaginary axis)
    constexpr float q_stage_0 = 0.5412f;
    constexpr float q_stage_1 = 1.3066f;

    BiquadFilter proto_0;
    BiquadFilter proto_1;
    compute_butterworth_biquad(cutoff_hz, sample_rate_hz, q_stage_0, proto_0);
    compute_butterworth_biquad(cutoff_hz, sample_rate_hz, q_stage_1, proto_1);

    for (uint8_t axis = 0; axis < 6; ++axis)
    {
        filters_[axis][0] = proto_0;
        filters_[axis][1] = proto_1;
    }
    filter_initialized_ = false;

    // Sum the phase contributions of each stage at the cutoff frequency.
    const float omega = 2.0f * 3.14159265f * cutoff_hz / sample_rate_hz;
    const float total_phase_deg = biquad_phase_deg(omega, proto_0)
                                + biquad_phase_deg(omega, proto_1);

    ImuFilterDiagnostics diagnostics;
    diagnostics.phase_lag_at_cutoff_deg = -total_phase_deg;
    diagnostics.phase_lag_at_cutoff_ms  =
        (diagnostics.phase_lag_at_cutoff_deg / 360.0f) / cutoff_hz * 1000.0f;
    return diagnostics;
}

bool Mpu6050Imu::read_sample(ImuSample &imu_sample)
{
    if (!is_available_)
    {
        return false;
    }

    // Read 14 bytes: accel XYZ (6), temp (2), gyro XYZ (6).
    uint8_t raw[14] = {0};
    if (!read_registers(reg_accel_xout_h, raw, sizeof(raw)))
    {
        return false;
    }

    const int16_t ax = static_cast<int16_t>((raw[0]  << 8) | raw[1]);
    const int16_t ay = static_cast<int16_t>((raw[2]  << 8) | raw[3]);
    const int16_t az = static_cast<int16_t>((raw[4]  << 8) | raw[5]);
    // raw[6..7] = temperature, unused.
    const int16_t gx = static_cast<int16_t>((raw[8]  << 8) | raw[9]);
    const int16_t gy = static_cast<int16_t>((raw[10] << 8) | raw[11]);
    const int16_t gz = static_cast<int16_t>((raw[12] << 8) | raw[13]);

    imu_sample.accel_x = (ax / accel_lsb_per_g) * gravity_m_per_s2;
    imu_sample.accel_y = (ay / accel_lsb_per_g) * gravity_m_per_s2;
    imu_sample.accel_z = (az / accel_lsb_per_g) * gravity_m_per_s2;

    imu_sample.gyro_x = (gx / gyro_lsb_per_deg_per_s) * deg_to_rad;
    imu_sample.gyro_y = (gy / gyro_lsb_per_deg_per_s) * deg_to_rad;
    imu_sample.gyro_z = (gz / gyro_lsb_per_deg_per_s) * deg_to_rad;

    // Apply 4th-order Butterworth low-pass filter (two cascaded biquad stages).
    float axes[6] = {
        imu_sample.accel_x, imu_sample.accel_y, imu_sample.accel_z,
        imu_sample.gyro_x,  imu_sample.gyro_y,  imu_sample.gyro_z
    };
    if (!filter_initialized_)
    {
        for (uint8_t axis = 0; axis < 6; ++axis)
        {
            filters_[axis][0].init_steady_state(axes[axis]);
            filters_[axis][1].init_steady_state(axes[axis]);
        }
        filter_initialized_ = true;
    }
    for (uint8_t axis = 0; axis < 6; ++axis)
    {
        axes[axis] = filters_[axis][1].process(filters_[axis][0].process(axes[axis]));
    }
    imu_sample.accel_x = axes[0];
    imu_sample.accel_y = axes[1];
    imu_sample.accel_z = axes[2];
    imu_sample.gyro_x  = axes[3];
    imu_sample.gyro_y  = axes[4];
    imu_sample.gyro_z  = axes[5];

    return true;
}
