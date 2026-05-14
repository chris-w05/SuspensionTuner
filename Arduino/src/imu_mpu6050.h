#pragma once

#include <Arduino.h>
#include <Wire.h>

struct ImuSample
{
    float accel_x;
    float accel_y;
    float accel_z;
    float gyro_x;
    float gyro_y;
    float gyro_z;
};

// Second-order section (biquad) using Direct Form II Transposed.
// Coefficients follow the convention: H(z) = (b0 + b1*z^-1 + b2*z^-2)
//                                           / (1  + a1*z^-1 + a2*z^-2)
struct BiquadFilter
{
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
    float w1 = 0.0f, w2 = 0.0f;

    float process(float x)
    {
        const float y = b0 * x + w1;
        w1 = b1 * x - a1 * y + w2;
        w2 = b2 * x - a2 * y;
        return y;
    }

    // Seed the delay states so that a constant input x0 produces output x0
    // immediately, eliminating the cold-start transient.
    void init_steady_state(float x0)
    {
        w1 = x0 * (1.0f - b0);
        w2 = x0 * (b2 - a2);
    }
};

struct ImuFilterDiagnostics
{
    float phase_lag_at_cutoff_deg = 0.0f;
    float phase_lag_at_cutoff_ms  = 0.0f;
};

class Mpu6050Imu
{
public:
    bool begin(TwoWire &wire_interface, uint8_t device_address);
    // Configures a 4th-order Butterworth low-pass filter (two cascaded biquad
    // stages) on all six axes. Returns phase-lag diagnostics at the cutoff.
    ImuFilterDiagnostics set_low_pass_cutoff(float cutoff_hz, float sample_rate_hz);
    bool is_available() const;
    bool read_sample(ImuSample &imu_sample);

private:
    bool write_register(uint8_t reg, uint8_t value);
    bool read_registers(uint8_t reg, uint8_t *buffer, uint8_t length);

    TwoWire *wire_ = nullptr;
    uint8_t address_ = 0x68;
    bool is_available_ = false;

    // 4th-order Butterworth as two cascaded biquad stages per axis.
    // Axis index: 0=accel_x, 1=accel_y, 2=accel_z, 3=gyro_x, 4=gyro_y, 5=gyro_z
    BiquadFilter filters_[6][2];
    bool filter_initialized_ = false;
};
