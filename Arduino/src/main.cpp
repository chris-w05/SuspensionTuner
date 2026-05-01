
#include <Arduino.h>
#include <SD.h>
#include <SPI.h>
#include <Wire.h>

#include "config.h"
#include "data_record.h"
#include "imu_mpu6050.h"
#include "pins.h"

namespace
{
Mpu6050Imu imu_sensor;
File acquisition_file;

bool is_sd_ready = false;
bool is_acquisition_active = false;

bool is_button_state_stable_pressed = false;
bool is_last_button_state_stable_pressed = false;
bool is_last_button_state_raw_pressed = false;
uint32_t button_last_change_time_ms = 0;

uint32_t last_file_flush_time_ms = 0;
uint16_t active_file_index = 0;

bool initialize_sd_card();
bool open_next_acquisition_file();
void close_acquisition_file();
void start_acquisition();
void stop_acquisition();
void update_button_state();
void write_one_sample();
}

void setup()
{
	pinMode(pins::acquisition_indicator_light_pin, OUTPUT);
	digitalWrite(pins::acquisition_indicator_light_pin, LOW);

	pinMode(pins::acquisition_button_pin, INPUT_PULLUP);
	analogReadResolution(config::analog_resolution_bits);

	Serial.begin(config::serial_baud_rate);
	while (!Serial && millis() < 4000)
	{
		;
	}

	Serial.println("Suspension DAQ startup");

	Wire.begin();
	const bool imu_found = imu_sensor.begin(Wire, config::imu_i2c_address);
	Serial.print("IMU present: ");
	Serial.println(imu_found ? "yes" : "no");

	is_sd_ready = initialize_sd_card();
	Serial.print("SD card ready: ");
	Serial.println(is_sd_ready ? "yes" : "no");
}

void loop()
{
	update_button_state();

	if (is_button_state_stable_pressed && !is_last_button_state_stable_pressed)
	{
		if (is_acquisition_active)
		{
			stop_acquisition();
		}
		else
		{
			start_acquisition();
		}
	}

	is_last_button_state_stable_pressed = is_button_state_stable_pressed;

	if (is_acquisition_active)
	{
		write_one_sample();
	}
}

namespace
{
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

void start_acquisition()
{
	if (!is_sd_ready)
	{
		Serial.println("Cannot start acquisition: SD card unavailable");
		return;
	}

	if (!open_next_acquisition_file())
	{
		Serial.println("Cannot start acquisition: failed to create data file");
		return;
	}

	is_acquisition_active = true;
	last_file_flush_time_ms = millis();
	digitalWrite(pins::acquisition_indicator_light_pin, HIGH);

	Serial.print("Acquisition started: file index ");
	Serial.println(active_file_index);
}

void stop_acquisition()
{
	is_acquisition_active = false;
	close_acquisition_file();
	digitalWrite(pins::acquisition_indicator_light_pin, LOW);
	Serial.println("Acquisition stopped");
}

void update_button_state()
{
	const bool is_button_raw_pressed = digitalRead(pins::acquisition_button_pin) == LOW;
	const uint32_t current_time_ms = millis();

	if (is_button_raw_pressed != is_last_button_state_raw_pressed)
	{
		is_last_button_state_raw_pressed = is_button_raw_pressed;
		button_last_change_time_ms = current_time_ms;
	}

	if (current_time_ms - button_last_change_time_ms >= config::button_debounce_time_ms)
	{
		is_button_state_stable_pressed = is_button_raw_pressed;
	}
}

void write_one_sample()
{
	if (!acquisition_file)
	{
		stop_acquisition();
		return;
	}

	DaqRecord data_record = {};
	data_record.timestamp_microseconds = micros();
	data_record.potentiometer_front_raw = analogRead(pins::potentiometer_front_pin);
	data_record.potentiometer_rear_raw = analogRead(pins::potentiometer_rear_pin);

	if (imu_sensor.is_available())
	{
		data_record.status_flags |= daq_flags::imu_present_flag;

		ImuSample imu_sample = {};
		if (imu_sensor.read_sample(imu_sample))
		{
			data_record.imu_accel_x_raw = imu_sample.accel_x_raw;
			data_record.imu_accel_y_raw = imu_sample.accel_y_raw;
			data_record.imu_accel_z_raw = imu_sample.accel_z_raw;

			data_record.imu_gyro_x_raw = imu_sample.gyro_x_raw;
			data_record.imu_gyro_y_raw = imu_sample.gyro_y_raw;
			data_record.imu_gyro_z_raw = imu_sample.gyro_z_raw;
			data_record.status_flags |= daq_flags::imu_sample_valid_flag;
		}
	}

	if (digitalRead(pins::acquisition_button_pin) == LOW)
	{
		data_record.status_flags |= daq_flags::button_pressed_flag;
	}

	data_record.status_flags |= daq_flags::acquisition_active_flag;

	const size_t bytes_written = acquisition_file.write(
		reinterpret_cast<const uint8_t *>(&data_record), sizeof(data_record));
	if (bytes_written != sizeof(data_record))
	{
		Serial.println("Write error: stopping acquisition");
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
}
