import 'dart:math' as math;
import 'dart:typed_data';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';

class DaqParserService {
  static const int _recordSizeBytes = 21;
  static const int _statusFlagsOffset = 20;
  static const int _imuAccelXOffset = 8;
  static const int _imuAccelYOffset = 10;
  static const int _imuAccelZOffset = 12;
  static const int _imuGyroXOffset = 14;
  static const int _imuGyroYOffset = 16;

  static const int _imuPresentFlag = 0x01;
  static const int _imuSampleValidFlag = 0x02;
  static const double _mpu6050GyroLsbPerDegPerSecond = 131.0;
  static const double _mpu6050AccelLsbPerG = 16384.0;
  static const double _velocityIirAlpha = 0.05;

  Future<AnalysisResult> parsePositionVelocity({
    required Uint8List bytes,
    required CalibrationProfile profile,
    required List<PotentiometerChannel> channels,
  }) async {
    final Uint8List data = bytes;
    if (data.length < _recordSizeBytes) {
      throw const FormatException('File is too small to contain any DAQ records.');
    }

    final int completeRecords = data.length ~/ _recordSizeBytes;

    // Validate that every requested channel has a calibration before parsing.
    final Map<PotentiometerChannel, PotentiometerCalibration> calibrations =
        <PotentiometerChannel, PotentiometerCalibration>{};
    for (final PotentiometerChannel channel in channels) {
      final PotentiometerCalibration? calibration =
          profile.calibrationForChannel(channel);
      if (calibration == null) {
        throw FormatException(
          'The selected profile does not have a calibration for the '
          '${channel.name} channel.',
        );
      }
      calibrations[channel] = calibration;
    }

    // Per-channel state for mm position/velocity calculations.
    final Map<PotentiometerChannel, List<PositionVelocityPoint>> velocityPointsMap =
        <PotentiometerChannel, List<PositionVelocityPoint>>{
      for (final PotentiometerChannel ch in channels) ch: <PositionVelocityPoint>[],
    };
    final Map<PotentiometerChannel, List<PositionTimePoint>> positionTimePointsMap =
        <PotentiometerChannel, List<PositionTimePoint>>{
      for (final PotentiometerChannel ch in channels) ch: <PositionTimePoint>[],
    };
    final Map<PotentiometerChannel, int?> previousTimestamps =
        <PotentiometerChannel, int?>{
      for (final PotentiometerChannel ch in channels) ch: null,
    };
    final Map<PotentiometerChannel, double?> previousPositionMillimeters =
        <PotentiometerChannel, double?>{
      for (final PotentiometerChannel ch in channels) ch: null,
    };
    final Map<PotentiometerChannel, double?> previousFilteredVelocity =
        <PotentiometerChannel, double?>{
      for (final PotentiometerChannel ch in channels) ch: null,
    };

    final List<AttitudeTimePoint> attitudeTimePoints = <AttitudeTimePoint>[];
    final List<AccelerationTimePoint> accelerationTimePoints = <AccelerationTimePoint>[];
    int? firstTimestampMicroseconds;
    int? previousImuTimestampMicroseconds;
    double integratedPitchDegrees = 0.0;
    double integratedLeanDegrees = 0.0;

    for (int index = 0; index < completeRecords; index++) {
      final int offset = index * _recordSizeBytes;
      final ByteData byteData =
          ByteData.sublistView(data, offset, offset + _recordSizeBytes);

      final int timestampMicroseconds = byteData.getUint32(0, Endian.little);
        firstTimestampMicroseconds ??= timestampMicroseconds;
        final double timeSeconds =
          (timestampMicroseconds - firstTimestampMicroseconds) / 1000000.0;

      final int frontRaw = byteData.getUint16(4, Endian.little);
      final int rearRaw = byteData.getUint16(6, Endian.little);

      for (final PotentiometerChannel channel in channels) {
        final int rawAdc =
            channel == PotentiometerChannel.front ? frontRaw : rearRaw;
        final PotentiometerCalibration calibration = calibrations[channel]!;
        final double positionMillimeters =
            calibration.mapAdcToPositionMillimeters(rawAdc);
        final double normalizedTravelPercent =
            calibration.mapAdcToPositionPercent(rawAdc);

        positionTimePointsMap[channel]!.add(
          PositionTimePoint(
            timestampMicroseconds: timestampMicroseconds,
            timeSeconds: timeSeconds,
            positionMillimeters: positionMillimeters,
            normalizedTravelPercent: normalizedTravelPercent,
          ),
        );

        final int? prevTs = previousTimestamps[channel];
        final double? prevPosMm = previousPositionMillimeters[channel];

        if (prevTs != null && prevPosMm != null) {
          final double deltaTimeSeconds =
              (timestampMicroseconds - prevTs) / 1000000.0;
          if (deltaTimeSeconds > 0.0) {
            final double rawVelocity =
                (positionMillimeters - prevPosMm) / deltaTimeSeconds;
            final double? prevFiltered = previousFilteredVelocity[channel];
            final double filteredVelocity = prevFiltered == null
                ? rawVelocity
                : _velocityIirAlpha * rawVelocity +
                      (1.0 - _velocityIirAlpha) * prevFiltered;
            previousFilteredVelocity[channel] = filteredVelocity;
            velocityPointsMap[channel]!.add(
              PositionVelocityPoint(
                positionMillimeters: positionMillimeters,
                velocityMillimetersPerSecond: filteredVelocity,
                timestampMicroseconds: timestampMicroseconds,
              ),
            );
          }
        }

        previousTimestamps[channel] = timestampMicroseconds;
        previousPositionMillimeters[channel] = positionMillimeters;
      }

      final int statusFlags = byteData.getUint8(_statusFlagsOffset);
      final bool isImuPresent = (statusFlags & _imuPresentFlag) != 0;
      final bool isImuSampleValid = (statusFlags & _imuSampleValidFlag) != 0;

      if (isImuPresent && isImuSampleValid) {
        final int accelXRaw = byteData.getInt16(_imuAccelXOffset, Endian.little);
        final int accelYRaw = byteData.getInt16(_imuAccelYOffset, Endian.little);
        final int accelZRaw = byteData.getInt16(_imuAccelZOffset, Endian.little);
        final double accelXG = accelXRaw / _mpu6050AccelLsbPerG;
        final double accelYG = accelYRaw / _mpu6050AccelLsbPerG;
        final double accelZG = accelZRaw / _mpu6050AccelLsbPerG;
        final double accelAbsoluteG =
            math.sqrt(accelXG * accelXG + accelYG * accelYG + accelZG * accelZG);

        accelerationTimePoints.add(
          AccelerationTimePoint(
            timestampMicroseconds: timestampMicroseconds,
            timeSeconds: timeSeconds,
            accelXG: accelXG,
            accelYG: accelYG,
            accelZG: accelZG,
            accelAbsoluteG: accelAbsoluteG,
          ),
        );

        final int gyroXRaw = byteData.getInt16(_imuGyroXOffset, Endian.little);
        final int gyroYRaw = byteData.getInt16(_imuGyroYOffset, Endian.little);

        if (previousImuTimestampMicroseconds != null) {
          final double deltaTimeSeconds =
              (timestampMicroseconds - previousImuTimestampMicroseconds) /
                  1000000.0;
          if (deltaTimeSeconds > 0) {
            final double gyroXDegPerSecond =
                gyroXRaw / _mpu6050GyroLsbPerDegPerSecond;
            final double gyroYDegPerSecond =
                gyroYRaw / _mpu6050GyroLsbPerDegPerSecond;

            // Integrate angular rates to estimate orientation angles.
            integratedLeanDegrees += gyroXDegPerSecond * deltaTimeSeconds;
            integratedPitchDegrees += gyroYDegPerSecond * deltaTimeSeconds;
          }
        }

        attitudeTimePoints.add(
          AttitudeTimePoint(
            timestampMicroseconds: timestampMicroseconds,
            timeSeconds: timeSeconds,
            pitchDegrees: integratedPitchDegrees,
            leanDegrees: integratedLeanDegrees,
          ),
        );
        previousImuTimestampMicroseconds = timestampMicroseconds;
      }
    }

    final Map<PotentiometerChannel, ChannelResult> channelResults =
        <PotentiometerChannel, ChannelResult>{};
    for (final PotentiometerChannel channel in channels) {
      final List<PositionVelocityPoint> velocityPoints = velocityPointsMap[channel]!;
      final List<PositionTimePoint> positionTimePoints =
          positionTimePointsMap[channel]!;

      if (velocityPoints.isEmpty || positionTimePoints.isEmpty) {
        throw FormatException(
            'Not enough valid samples for the ${channel.name} channel.');
      }

      final Iterable<double> positionValues = positionTimePoints.map(
          (PositionTimePoint p) => p.positionMillimeters);
      final Iterable<double> velocityValues = velocityPoints.map(
          (PositionVelocityPoint p) => p.velocityMillimetersPerSecond);

      final PotentiometerCalibration calibration = calibrations[channel]!;
      channelResults[channel] = ChannelResult(
        velocityPoints: velocityPoints,
        positionTimePoints: positionTimePoints,
        minPositionMillimeters: positionValues
            .reduce((double a, double b) => math.min(a, b)),
        maxPositionMillimeters: positionValues
            .reduce((double a, double b) => math.max(a, b)),
        minVelocityMillimetersPerSecond: velocityValues
            .reduce((double a, double b) => math.min(a, b)),
        maxVelocityMillimetersPerSecond: velocityValues
            .reduce((double a, double b) => math.max(a, b)),
        travelMillimeters: calibration.travelMillimeters,
      );
    }

    return AnalysisResult(
      sampleCount: completeRecords,
      channelResults: channelResults,
      attitudeTimePoints: attitudeTimePoints,
      accelerationTimePoints: accelerationTimePoints,
    );
  }
}
