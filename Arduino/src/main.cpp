#include <Arduino.h>
#include <EEPROM.h>
#include <SD.h>
#include <SPI.h>
#include <Wire.h>
#include <AS5600.h>

#include "config.h"
#include "data_record.h"
#include "imu_mpu6050.h"
#include "pins.h"

static bool serial_logging_enabled = false;

#define LOG_PRINT(...)                 \
	do                                 \
	{                                  \
		if (serial_logging_enabled)    \
		{                              \
			Serial.print(__VA_ARGS__); \
		}                              \
	} while (0)
#define LOG_PRINTLN(...)                 \
	do                                   \
	{                                    \
		if (serial_logging_enabled)      \
		{                                \
			Serial.println(__VA_ARGS__); \
		}                                \
	} while (0)

namespace
{
	struct DebouncedSwitch
	{
		uint8_t pin = 0;
		bool is_stable_pressed = false;
		bool was_stable_pressed = false;
		bool was_raw_pressed = false;
		uint32_t last_change_time_ms = 0;
		uint32_t last_rising_edge_time_ms = 0;
	};

	// Calibration now stores raw 12-bit AS5600 angle counts (0–4095)
	struct EncoderCalibration
	{
		uint16_t front_extended = 0;
		uint16_t front_compressed = 0;
		uint16_t rear_extended = 0;
		uint16_t rear_compressed = 0;

		bool has_front_extended = false;
		bool has_front_compressed = false;
		bool has_rear_extended = false;
		bool has_rear_compressed = false;
	};

	struct PersistedCalibration
	{
		uint32_t magic = 0;
		uint16_t front_extended = 0;
		uint16_t front_compressed = 0;
		uint16_t rear_extended = 0;
		uint16_t rear_compressed = 0;
	};

	constexpr uint32_t calibration_magic = 0x43414C31; // "CAL1"

	Mpu6050Imu imu_sensor;

	// One AS5600 per I2C bus. Wire = front, Wire1 = rear.
	// Both share the fixed AS5600 address (0x36) without conflict.
	AS5600 front_encoder(&Wire);
	AS5600 rear_encoder(&Wire1);

	File acquisition_file;

	bool is_sd_ready = false;
	bool is_acquisition_active = false;
	bool is_calibration_mode_active = false;

	DebouncedSwitch acquisition_switch = {};
	DebouncedSwitch calibration_switch = {};
	EncoderCalibration encoder_calibration = {};

	uint32_t last_file_flush_time_ms = 0;
	uint32_t last_sample_write_time_us = 0;
	uint16_t active_file_index = 0;
	uint32_t last_debug_plot_time_ms = 0;

	// ---------------------------------------------------------------------------
	// Forward declarations
	// ---------------------------------------------------------------------------
	bool initialize_sd_card();
	bool open_next_acquisition_file();
	void close_acquisition_file();
	bool write_acquisition_csv_header();
	void start_acquisition();
	void stop_acquisition();
	void initialize_switch(DebouncedSwitch &input_switch, uint8_t pin);
	void update_switch_state(DebouncedSwitch &input_switch, uint32_t current_time_ms);
	bool did_switch_rise(const DebouncedSwitch &input_switch);
	bool did_switch_fall(const DebouncedSwitch &input_switch);
	void latch_switch_state(DebouncedSwitch &input_switch);

	bool did_simultaneous_rise();
	uint32_t absolute_time_difference(uint32_t left, uint32_t right);

	void process_user_controls();
	void update_calibration_entry_state();
	void update_acquisition_state();

	void enter_calibration_mode();
	void exit_calibration_mode();
	void handle_calibration_mode_actions();
	void capture_calibration_point(bool capture_rear, bool capture_extended);
	bool is_calibration_complete();
	bool is_calibration_valid();
	void print_calibration_summary();

	void load_calibration();
	void save_calibration();

	void print_debug_plot();
	void write_one_sample();

	// Read a raw 12-bit angle (0–4095) from the specified encoder.
	// Returns 0 and logs a warning if the encoder is not connected.
	uint16_t read_encoder_raw(bool read_rear);
} // namespace

// ===========================================================================
// setup / loop
// ===========================================================================

void setup()
{
	pinMode(pins::acquisition_indicator_light_pin, OUTPUT);
	digitalWrite(pins::acquisition_indicator_light_pin, LOW);
	digitalWrite(LED_BUILTIN, LOW);
	initialize_switch(acquisition_switch, pins::acquisition_switch_pin);
	initialize_switch(calibration_switch, pins::calibration_switch_pin);

	// Analog resolution no longer needed for position sensors, but kept in
	// case other analog peripherals are present.
	analogReadResolution(config::analog_resolution_bits);

	Serial.begin(config::serial_baud_rate);
	delay(100);
	serial_logging_enabled = Serial;

	LOG_PRINTLN("Suspension DAQ startup");

	// --- I2C buses ---
	// Wire  (front encoder + IMU) – standard SDA/SCL
	// Wire1 (rear encoder)        – secondary SDA1/SCL1
	Wire.begin();
	Wire1.begin();

	// --- IMU (on Wire, same bus as front encoder) ---
	const bool imu_found = imu_sensor.begin(Wire, config::imu_i2c_address);
	LOG_PRINT("IMU present: ");
	LOG_PRINTLN(imu_found ? "yes" : "no");

	if (imu_found)
	{
		const float imu_sample_rate_hz =
			1000000.0f / static_cast<float>(config::sample_interval_microseconds);
		const ImuFilterDiagnostics filter_diagnostics =
			imu_sensor.set_low_pass_cutoff(config::imu_filter_cutoff_hz, imu_sample_rate_hz);

		LOG_PRINT("IMU low-pass: 4th-order Butterworth, ");
		LOG_PRINT(config::imu_filter_cutoff_hz, 0);
		LOG_PRINT(" Hz cutoff, phase lag at cutoff: ");
		LOG_PRINT(filter_diagnostics.phase_lag_at_cutoff_deg, 1);
		LOG_PRINT(" deg / ");
		LOG_PRINT(filter_diagnostics.phase_lag_at_cutoff_ms, 2);
		LOG_PRINTLN(" ms");
	}

	// --- AS5600 encoders ---
	front_encoder.begin();
	rear_encoder.begin();

	const bool front_connected = front_encoder.isConnected();
	const bool rear_connected = rear_encoder.isConnected();
	LOG_PRINT("Front encoder present: ");
	LOG_PRINTLN(front_connected ? "yes" : "no");
	LOG_PRINT("Rear encoder present: ");
	LOG_PRINTLN(rear_connected ? "yes" : "no");

	// --- SD card ---
	while (!is_sd_ready && millis() < 3000)
	{
		is_sd_ready = initialize_sd_card();
	}
	LOG_PRINT("SD card ready: ");
	LOG_PRINTLN(is_sd_ready ? "yes" : "no");

	load_calibration();

	digitalWrite(LED_BUILTIN, is_sd_ready ? HIGH : LOW);
}

void loop()
{
	const uint32_t current_time_ms = millis();
	update_switch_state(acquisition_switch, current_time_ms);
	update_switch_state(calibration_switch, current_time_ms);

	process_user_controls();

	latch_switch_state(acquisition_switch);
	latch_switch_state(calibration_switch);

	if (is_acquisition_active)
	{
		write_one_sample();
	}
}

// ===========================================================================
// Implementation
// ===========================================================================

namespace
{
	// ---------------------------------------------------------------------------
	// Encoder helpers
	// ---------------------------------------------------------------------------

	uint16_t read_encoder_raw(bool read_rear)
	{
		AS5600 &encoder = read_rear ? rear_encoder : front_encoder;

		if (!encoder.isConnected())
		{
			LOG_PRINTLN(read_rear ? "Rear encoder not connected" : "Front encoder not connected");
			return 0;
		}

		// getRawAngle() returns 0–4095 (12-bit), matching the range that the rest
		// of the calibration / CSV pipeline previously expected from analogRead()
		// at 12-bit resolution.
		return encoder.rawAngle();
	}

	// ---------------------------------------------------------------------------
	// SD card
	// ---------------------------------------------------------------------------

	bool initialize_sd_card()
	{
		return SD.begin(pins::sd_chip_select_pin);
	}

	bool open_next_acquisition_file()
	{
		char file_name[16] = {0};

		for (uint16_t file_index = 0; file_index <= config::max_file_index; ++file_index)
		{
			snprintf(file_name, sizeof(file_name), "%s%04u%s", config::data_file_prefix, file_index,
					 config::data_file_extension);

			if (!SD.exists(file_name))
			{
				acquisition_file = SD.open(file_name, FILE_WRITE);
				if (!acquisition_file)
				{
					return false;
				}

				active_file_index = file_index;
				return true;
			}
		}

		return false;
	}

	void close_acquisition_file()
	{
		if (acquisition_file)
		{
			acquisition_file.flush();
			acquisition_file.close();
		}
	}

	// ---------------------------------------------------------------------------
	// Acquisition control
	// ---------------------------------------------------------------------------

	void start_acquisition()
	{
		if (!is_sd_ready)
		{
			LOG_PRINTLN("Cannot start acquisition: SD card unavailable");
			return;
		}

		if (!open_next_acquisition_file())
		{
			LOG_PRINTLN("Cannot start acquisition: failed to create data file");
			return;
		}

		if (!write_acquisition_csv_header())
		{
			LOG_PRINTLN("Cannot start acquisition: failed to write CSV header");
			close_acquisition_file();
			return;
		}

		is_acquisition_active = true;
		last_file_flush_time_ms = millis();
		last_sample_write_time_us = micros();
		digitalWrite(pins::acquisition_indicator_light_pin, HIGH);

		LOG_PRINT("Acquisition started: file index ");
		LOG_PRINTLN(active_file_index);
	}

	bool write_acquisition_csv_header()
	{
		if (!acquisition_file)
		{
			return false;
		}

		// Column names updated: front_raw / rear_raw now hold AS5600 angle counts
		const size_t bytes_written = acquisition_file.println(
			"timestamp_us,front_raw,rear_raw,accel_x_g,accel_y_g,accel_z_g,gyro_x_dps,gyro_y_dps,gyro_z_dps,status_flags");
		return bytes_written > 0;
	}

	void stop_acquisition()
	{
		is_acquisition_active = false;
		close_acquisition_file();
		digitalWrite(pins::acquisition_indicator_light_pin, LOW);
		LOG_PRINTLN("Acquisition stopped");
	}

	// ---------------------------------------------------------------------------
	// Switch helpers
	// ---------------------------------------------------------------------------

	void initialize_switch(DebouncedSwitch &input_switch, uint8_t pin)
	{
		input_switch.pin = pin;
		pinMode(input_switch.pin, INPUT_PULLDOWN);

		const bool is_initial_pressed = digitalRead(input_switch.pin) == HIGH;
		input_switch.is_stable_pressed = is_initial_pressed;
		input_switch.was_stable_pressed = is_initial_pressed;
		input_switch.was_raw_pressed = is_initial_pressed;
		input_switch.last_change_time_ms = millis();

		if (is_initial_pressed)
		{
			input_switch.last_rising_edge_time_ms = input_switch.last_change_time_ms;
		}
	}

	void update_switch_state(DebouncedSwitch &input_switch, uint32_t current_time_ms)
	{
		const bool is_raw_pressed = digitalRead(input_switch.pin) == HIGH;

		if (is_raw_pressed != input_switch.was_raw_pressed)
		{
			input_switch.was_raw_pressed = is_raw_pressed;
			input_switch.last_change_time_ms = current_time_ms;
		}

		if (current_time_ms - input_switch.last_change_time_ms >= config::button_debounce_time_ms)
		{
			input_switch.is_stable_pressed = is_raw_pressed;
			if (did_switch_rise(input_switch))
			{
				input_switch.last_rising_edge_time_ms = current_time_ms;
			}
		}
	}

	bool did_switch_rise(const DebouncedSwitch &input_switch)
	{
		return input_switch.is_stable_pressed && !input_switch.was_stable_pressed;
	}

	bool did_switch_fall(const DebouncedSwitch &input_switch)
	{
		return !input_switch.is_stable_pressed && input_switch.was_stable_pressed;
	}

	bool did_simultaneous_rise()
	{
		if (!acquisition_switch.is_stable_pressed || !calibration_switch.is_stable_pressed)
		{
			return false;
		}

		if (!did_switch_rise(acquisition_switch) && !did_switch_rise(calibration_switch))
		{
			return false;
		}

		const uint32_t delta_ms = absolute_time_difference(
			acquisition_switch.last_rising_edge_time_ms,
			calibration_switch.last_rising_edge_time_ms);

		return delta_ms <= config::simultaneous_press_window_ms;
	}

	uint32_t absolute_time_difference(uint32_t left, uint32_t right)
	{
		return left > right ? left - right : right - left;
	}

	void latch_switch_state(DebouncedSwitch &input_switch)
	{
		input_switch.was_stable_pressed = input_switch.is_stable_pressed;
	}

	// ---------------------------------------------------------------------------
	// User control state machine
	// ---------------------------------------------------------------------------

	void process_user_controls()
	{
		if (is_calibration_mode_active)
		{
			handle_calibration_mode_actions();
			return;
		}

		update_calibration_entry_state();
		if (is_calibration_mode_active)
		{
			return;
		}

		update_acquisition_state();
	}

	void update_calibration_entry_state()
	{
		if (did_simultaneous_rise())
		{
			enter_calibration_mode();
		}
	}

	void update_acquisition_state()
	{
		if (acquisition_switch.is_stable_pressed && !is_acquisition_active)
		{
			start_acquisition();
		}
		else if (!acquisition_switch.is_stable_pressed && is_acquisition_active)
		{
			stop_acquisition();
		}
	}

	// ---------------------------------------------------------------------------
	// Calibration mode
	// ---------------------------------------------------------------------------

	void enter_calibration_mode()
	{
		if (is_acquisition_active)
		{
			stop_acquisition();
		}

		is_calibration_mode_active = true;
		encoder_calibration = {};

		LOG_PRINTLN("Calibration mode entered");
		LOG_PRINTLN("ACQ=OFF: front  ACQ=ON: rear  |  CAL rise: extended  CAL fall: compressed");
		LOG_PRINTLN("Press both switches together to exit");
	}

	void exit_calibration_mode()
	{
		is_calibration_mode_active = false;
		LOG_PRINTLN("Calibration mode exited without saving");
	}

	void handle_calibration_mode_actions()
	{
		if (did_simultaneous_rise())
		{
			exit_calibration_mode();
			return;
		}

		if (did_switch_rise(calibration_switch))
		{
			capture_calibration_point(acquisition_switch.is_stable_pressed, true);
		}
		else if (did_switch_fall(calibration_switch))
		{
			capture_calibration_point(acquisition_switch.is_stable_pressed, false);
		}

		if (!is_calibration_complete())
		{
			return;
		}

		if (!is_calibration_valid())
		{
			LOG_PRINTLN("Calibration invalid: endpoint span too small, retrying");
			encoder_calibration = {};
			return;
		}

		save_calibration();
		print_calibration_summary();
		is_calibration_mode_active = false;
		LOG_PRINTLN("Calibration complete");
	}

	void capture_calibration_point(bool capture_rear, bool capture_extended)
	{
		const uint16_t raw_value = read_encoder_raw(capture_rear);

		if (!capture_rear)
		{
			if (capture_extended)
			{
				encoder_calibration.front_extended = raw_value;
				encoder_calibration.has_front_extended = true;
				LOG_PRINT("Captured front extended: ");
				LOG_PRINTLN(raw_value);
			}
			else
			{
				encoder_calibration.front_compressed = raw_value;
				encoder_calibration.has_front_compressed = true;
				LOG_PRINT("Captured front compressed: ");
				LOG_PRINTLN(raw_value);
			}
			return;
		}

		if (capture_extended)
		{
			encoder_calibration.rear_extended = raw_value;
			encoder_calibration.has_rear_extended = true;
			LOG_PRINT("Captured rear extended: ");
			LOG_PRINTLN(raw_value);
		}
		else
		{
			encoder_calibration.rear_compressed = raw_value;
			encoder_calibration.has_rear_compressed = true;
			LOG_PRINT("Captured rear compressed: ");
			LOG_PRINTLN(raw_value);
		}
	}

	bool is_calibration_complete()
	{
		return encoder_calibration.has_front_extended &&
			   encoder_calibration.has_front_compressed &&
			   encoder_calibration.has_rear_extended &&
			   encoder_calibration.has_rear_compressed;
	}

	bool is_calibration_valid()
	{
		// AS5600 wraps at 4096, so we compute the shortest arc on the 12-bit circle
		// for each axis.  This correctly handles the case where the extended and
		// compressed positions straddle the 0/4095 boundary.
		auto angular_span = [](uint16_t a, uint16_t b) -> uint16_t
		{
			const uint16_t raw_diff = (a >= b) ? (a - b) : (b - a);
			return (raw_diff <= 2048u) ? raw_diff : static_cast<uint16_t>(4096u - raw_diff);
		};

		const uint16_t front_span =
			angular_span(encoder_calibration.front_extended, encoder_calibration.front_compressed);
		const uint16_t rear_span =
			angular_span(encoder_calibration.rear_extended, encoder_calibration.rear_compressed);

		return front_span >= config::calibration_min_span_counts &&
			   rear_span >= config::calibration_min_span_counts;
	}

	void print_calibration_summary()
	{
		LOG_PRINTLN("Calibration summary");
		LOG_PRINT("Front extended: ");
		LOG_PRINTLN(encoder_calibration.front_extended);
		LOG_PRINT("Front compressed: ");
		LOG_PRINTLN(encoder_calibration.front_compressed);
		LOG_PRINT("Rear extended: ");
		LOG_PRINTLN(encoder_calibration.rear_extended);
		LOG_PRINT("Rear compressed: ");
		LOG_PRINTLN(encoder_calibration.rear_compressed);
	}

	// ---------------------------------------------------------------------------
	// Calibration persistence (EEPROM + SD)
	// ---------------------------------------------------------------------------

	void load_calibration()
	{
		PersistedCalibration stored_calibration = {};
		EEPROM.get(0, stored_calibration);

		if (stored_calibration.magic != calibration_magic)
		{
			LOG_PRINTLN("No valid EEPROM calibration, trying SD card");

			if (is_sd_ready && SD.exists(config::calibration_file_name))
			{
				File cal_file = SD.open(config::calibration_file_name, FILE_READ);
				if (cal_file && cal_file.size() >= sizeof(PersistedCalibration))
				{
					cal_file.read(reinterpret_cast<uint8_t *>(&stored_calibration),
								  sizeof(stored_calibration));
					cal_file.close();
					LOG_PRINTLN("Calibration read from SD card");
				}
				else
				{
					if (cal_file)
					{
						cal_file.close();
					}
					LOG_PRINTLN("SD calibration file unreadable");
					return;
				}
			}
			else
			{
				LOG_PRINTLN("No stored calibration found");
				return;
			}

			if (stored_calibration.magic != calibration_magic)
			{
				LOG_PRINTLN("SD calibration file has invalid magic, ignoring");
				return;
			}
		}

		encoder_calibration.front_extended = stored_calibration.front_extended;
		encoder_calibration.front_compressed = stored_calibration.front_compressed;
		encoder_calibration.rear_extended = stored_calibration.rear_extended;
		encoder_calibration.rear_compressed = stored_calibration.rear_compressed;

		encoder_calibration.has_front_extended = true;
		encoder_calibration.has_front_compressed = true;
		encoder_calibration.has_rear_extended = true;
		encoder_calibration.has_rear_compressed = true;

		if (!is_calibration_valid())
		{
			LOG_PRINTLN("Stored calibration invalid, ignoring");
			encoder_calibration = {};
			return;
		}

		LOG_PRINTLN("Stored calibration loaded");
		print_calibration_summary();
	}

	void save_calibration()
	{
		PersistedCalibration stored_calibration = {};
		stored_calibration.magic = calibration_magic;
		stored_calibration.front_extended = encoder_calibration.front_extended;
		stored_calibration.front_compressed = encoder_calibration.front_compressed;
		stored_calibration.rear_extended = encoder_calibration.rear_extended;
		stored_calibration.rear_compressed = encoder_calibration.rear_compressed;

		EEPROM.put(0, stored_calibration);
		LOG_PRINTLN("Calibration saved to EEPROM");

		if (is_sd_ready)
		{
			if (SD.exists(config::calibration_file_name))
			{
				SD.remove(config::calibration_file_name);
			}
			File cal_file = SD.open(config::calibration_file_name, FILE_WRITE);
			if (cal_file)
			{
				cal_file.write(reinterpret_cast<const uint8_t *>(&stored_calibration),
							   sizeof(stored_calibration));
				cal_file.close();
				LOG_PRINTLN("Calibration saved to SD card");
			}
			else
			{
				LOG_PRINTLN("Failed to write calibration to SD card");
			}
		}
	}

	// ---------------------------------------------------------------------------
	// Debug
	// ---------------------------------------------------------------------------

	void print_debug_plot()
	{
		LOG_PRINT(">acq_switch:");
		LOG_PRINT(acquisition_switch.is_stable_pressed ? 1 : 0);
		LOG_PRINT(",cal_switch:");
		LOG_PRINT(calibration_switch.is_stable_pressed ? 1 : 0);
		LOG_PRINT(",acquiring:");
		LOG_PRINT(is_acquisition_active ? 1 : 0);
		LOG_PRINT(",calibrating:");
		LOG_PRINTLN(is_calibration_mode_active ? 1 : 0);
	}

	// ---------------------------------------------------------------------------
	// Sample writing
	// ---------------------------------------------------------------------------

	void write_one_sample()
	{
		if (!acquisition_file)
		{
			stop_acquisition();
			return;
		}

		const uint32_t timestamp_microseconds = micros();
		if (timestamp_microseconds - last_sample_write_time_us < config::sample_interval_microseconds)
		{
			return;
		}
		last_sample_write_time_us = timestamp_microseconds;

		// Read 12-bit angle counts from each AS5600 (0–4095)
		const uint16_t front_raw = read_encoder_raw(false);
		const uint16_t rear_raw = read_encoder_raw(true);


		Serial.print( front_raw);
		Serial.print(" ");
		Serial.println(rear_raw);
		float accel_x_g = 0.0f;
		float accel_y_g = 0.0f;
		float accel_z_g = 0.0f;
		float gyro_x_dps = 0.0f;
		float gyro_y_dps = 0.0f;
		float gyro_z_dps = 0.0f;
		uint8_t status_flags = 0;

		if (imu_sensor.is_available())
		{
			status_flags |= daq_flags::imu_present_flag;

			ImuSample imu_sample = {};
			if (imu_sensor.read_sample(imu_sample))
			{
				accel_x_g = imu_sample.accel_x /
							daq_format::standard_gravity_meters_per_second_squared;
				accel_y_g = imu_sample.accel_y /
							daq_format::standard_gravity_meters_per_second_squared;
				accel_z_g = imu_sample.accel_z /
							daq_format::standard_gravity_meters_per_second_squared;

				constexpr float radians_to_degrees = 57.2957795f;
				gyro_x_dps = imu_sample.gyro_x * radians_to_degrees;
				gyro_y_dps = imu_sample.gyro_y * radians_to_degrees;
				gyro_z_dps = imu_sample.gyro_z * radians_to_degrees;
				status_flags |= daq_flags::imu_sample_valid_flag;
			}
		}

		if (acquisition_switch.is_stable_pressed)
		{
			status_flags |= daq_flags::button_pressed_flag;
		}

		status_flags |= daq_flags::acquisition_active_flag;

		acquisition_file.print(timestamp_microseconds);
		acquisition_file.print(',');
		acquisition_file.print(front_raw);
		acquisition_file.print(',');
		acquisition_file.print(rear_raw);
		acquisition_file.print(',');
		acquisition_file.print(accel_x_g, 3);
		acquisition_file.print(',');
		acquisition_file.print(accel_y_g, 3);
		acquisition_file.print(',');
		acquisition_file.print(accel_z_g, 3);
		acquisition_file.print(',');
		acquisition_file.print(gyro_x_dps, 1);
		acquisition_file.print(',');
		acquisition_file.print(gyro_y_dps, 1);
		acquisition_file.print(',');
		acquisition_file.print(gyro_z_dps, 1);
		acquisition_file.print(',');
		const size_t bytes_written = acquisition_file.println(status_flags);
		if (bytes_written == 0)
		{
			LOG_PRINTLN("Write error: stopping acquisition");
			stop_acquisition();
			return;
		}

		const uint32_t current_time_ms = millis();
		if (current_time_ms - last_file_flush_time_ms >= config::file_flush_interval_ms)
		{
			acquisition_file.flush();
			last_file_flush_time_ms = current_time_ms;
		}
	}
} // namespace