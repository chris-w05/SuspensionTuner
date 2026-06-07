import 'dart:convert';
import 'dart:io';

import 'package:suspension_tuner_app/models/calibration_profile.dart';

void main() {
  // Sample calibration - adjusted based on data
  final frontCalibration = PotentiometerCalibration(
    sideA: 145.0,
    sideB: 145.0,
    extendedSideC: 140.0,
    extendedAdc: 817, // Higher ADC = extended
    compressedSideC: 150.0,
    compressedAdc: 810, // Lower ADC = compressed
  );

  final rearCalibration = PotentiometerCalibration(
    sideA: 145.0,
    sideB: 145.0,
    extendedSideC: 140.0,
    extendedAdc: 2140, // Higher ADC = extended
    compressedSideC: 150.0,
    compressedAdc: 2091, // Lower ADC = compressed
  );

  // Sample data from CSV
  final samples = [
    [810, 2140],
    [810, 2136],
    [813, 2136],
    [812, 2133],
    [813, 2130],
  ];

  print('Front and Rear Compression Percentages:');
  for (final sample in samples) {
    final frontAdc = sample[0];
    final rearAdc = sample[1];

    final frontPercent = frontCalibration.mapAdcToPositionPercent(frontAdc);
    final rearPercent = rearCalibration.mapAdcToPositionPercent(rearAdc);

    print('Front ADC: $frontAdc -> ${frontPercent.toStringAsFixed(2)}%, Rear ADC: $rearAdc -> ${rearPercent.toStringAsFixed(2)}%');
  }
}