import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';

enum _DaqFileFormat {
  csvTextV3,
  framedV2,
  legacyFloatV1,
  legacyInt16V1,
}

class _DecodedRecord {
  const _DecodedRecord({
    required this.timestampMicroseconds,
    required this.frontRaw,
    required this.rearRaw,
    required this.statusFlags,
    required this.accelXG,
    required this.accelYG,
    required this.accelZG,
    required this.gyroXDegPerSecond,
    required this.gyroYDegPerSecond,
  });

  final int timestampMicroseconds;
  final int frontRaw;
  final int rearRaw;
  final int statusFlags;
  final double accelXG;
  final double accelYG;
  final double accelZG;
  final double gyroXDegPerSecond;
  final double gyroYDegPerSecond;
}

class DaqParserService {
  static const int _legacyInt16RecordSizeBytes = 21;
  static const int _legacyFloatRecordSizeBytes = 33;
  static const int _frameSizeBytes = 27;
  static const int _framePayloadSizeBytes = 21;
  static const int _timestampWrapMicroseconds = 0x100000000;
  static const int _frameSyncWord = 0xA55A;
  static const int _frameVersion = 2;
  static const int _frameHeaderSizeBytes = 4;

  static const int _timestampOffset = 0;
  static const int _frontOffset = 4;
  static const int _rearOffset = 6;
  static const int _imuAccelXOffset = 8;
  static const int _imuAccelYOffset = 10;
  static const int _imuAccelZOffset = 12;
  static const int _imuGyroXOffset = 14;
  static const int _imuGyroYOffset = 16;
  static const int _statusFlagsOffset = 20;

  static const int _legacyFloatImuAccelXOffset = 8;
  static const int _legacyFloatImuAccelYOffset = 12;
  static const int _legacyFloatImuAccelZOffset = 16;
  static const int _legacyFloatImuGyroXOffset = 20;
  static const int _legacyFloatImuGyroYOffset = 24;
  static const int _legacyFloatStatusFlagsOffset = 32;

  static const int _imuPresentFlag = 0x01;
  static const int _imuSampleValidFlag = 0x02;
  static const double _standardGravityMetersPerSecondSquared = 9.80665;
  static const double _milliGScale = 1000.0;
  static const double _deciDegreesPerSecondScale = 10.0;
  static const double _radiansToDegrees = 57.29577951308232;
  static const double _mpu6050GyroLsbPerDegPerSecond = 131.0;
  static const double _mpu6050AccelLsbPerG = 16384.0;
  static const double _velocityIirAlpha = 0.05;

  Future<AnalysisResult> parsePositionVelocity({
    required Uint8List bytes,
    required CalibrationProfile profile,
    required List<PotentiometerChannel> channels,
  }) async {
    final Uint8List data = bytes;
    final List<_DecodedRecord>? csvRecords = _tryDecodeCsvRecords(data);
    final List<_DecodedRecord> records = csvRecords ?? _decodeBinaryRecords(data);
    if (records.isEmpty) {
      throw const FormatException('No valid DAQ records were found in the file.');
    }

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
    int? previousRawTimestampMicroseconds;
    int timestampWrapOffsetMicroseconds = 0;
    int? previousImuTimestampMicroseconds;
    double integratedPitchDegrees = 0.0;
    double integratedLeanDegrees = 0.0;

    // Pre-compute leverage conversion for the rear channel (if configured).
    // All position and velocity values for the rear are stored in wheel space
    // so every downstream consumer (charts, recommendations) gets wheel data.
    final bool rearHasCurve;
    final double rearScalarLr;
    final double? rearWheelTravelMm;
    final List<double> rearShockTable;
    final List<double> rearWheelTable;
    {
      final List<LeverageCurvePoint>? curve = profile.rearLeverageCurve;
      final PotentiometerCalibration? rearCal =
          calibrations[PotentiometerChannel.rear];
      if (rearCal != null && curve != null && curve.length >= 2) {
        rearHasCurve = true;
        final (List<double> s, List<double> w) = _buildShockToWheelMap(curve);
        rearShockTable = s;
        rearWheelTable = w;
        rearWheelTravelMm = curve.last.wheelTravelMm;
        rearScalarLr = 1.0;
      } else if (rearCal != null && profile.rearLeverageRate != null) {
        rearHasCurve = false;
        rearScalarLr = profile.rearLeverageRate!;
        rearShockTable = <double>[];
        rearWheelTable = <double>[];
        rearWheelTravelMm = rearCal.travelMillimeters * rearScalarLr;
      } else {
        rearHasCurve = false;
        rearScalarLr = 1.0;
        rearShockTable = <double>[];
        rearWheelTable = <double>[];
        rearWheelTravelMm = null;
      }
    }

    for (final _DecodedRecord record in records) {
      final int rawTimestampMicroseconds = record.timestampMicroseconds;
      if (previousRawTimestampMicroseconds != null &&
          rawTimestampMicroseconds < previousRawTimestampMicroseconds) {
        timestampWrapOffsetMicroseconds += _timestampWrapMicroseconds;
      }
      previousRawTimestampMicroseconds = rawTimestampMicroseconds;

      final int timestampMicroseconds =
          rawTimestampMicroseconds + timestampWrapOffsetMicroseconds;
      firstTimestampMicroseconds ??= timestampMicroseconds;
      final double timeSeconds =
          (timestampMicroseconds - firstTimestampMicroseconds) / 1000000.0;

        final int frontRaw = record.frontRaw;
        final int rearRaw = record.rearRaw;

      for (final PotentiometerChannel channel in channels) {
        final int rawAdc =
            channel == PotentiometerChannel.front ? frontRaw : rearRaw;
        final PotentiometerCalibration calibration = calibrations[channel]!;
        double positionMillimeters =
            calibration.mapAdcToPositionMillimeters(rawAdc);
        final double normalizedTravelPercent;
        if (channel == PotentiometerChannel.rear && rearWheelTravelMm != null) {
          positionMillimeters = rearHasCurve
              ? _interpolate(rearShockTable, rearWheelTable, positionMillimeters)
              : positionMillimeters * rearScalarLr;
          normalizedTravelPercent =
              (positionMillimeters / rearWheelTravelMm * 100.0).clamp(0.0, 100.0);
        } else {
          normalizedTravelPercent = calibration.mapAdcToPositionPercent(rawAdc);
        }

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

      final int statusFlags = record.statusFlags;
      final bool isImuPresent = (statusFlags & _imuPresentFlag) != 0;
      final bool isImuSampleValid = (statusFlags & _imuSampleValidFlag) != 0;

      if (isImuPresent && isImuSampleValid) {
        final double accelXG = record.accelXG;
        final double accelYG = record.accelYG;
        final double accelZG = record.accelZG;
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

        if (previousImuTimestampMicroseconds != null) {
          final double deltaTimeSeconds =
              (timestampMicroseconds - previousImuTimestampMicroseconds) /
                  1000000.0;
          if (deltaTimeSeconds > 0) {
              final double gyroXDegPerSecond = record.gyroXDegPerSecond;
              final double gyroYDegPerSecond = record.gyroYDegPerSecond;

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
        travelMillimeters: (channel == PotentiometerChannel.rear &&
                rearWheelTravelMm != null)
            ? rearWheelTravelMm
            : calibration.travelMillimeters,
      );
    }

    return AnalysisResult(
      sampleCount: records.length,
      channelResults: channelResults,
      attitudeTimePoints: attitudeTimePoints,
      accelerationTimePoints: accelerationTimePoints,
    );
  }

  List<_DecodedRecord> _decodeBinaryRecords(Uint8List data) {
    if (data.length < _legacyInt16RecordSizeBytes) {
      throw const FormatException('File is too small to contain any DAQ records.');
    }

    final _DaqFileFormat format = _detectBinaryFormat(data);
    return _decodeRecords(data, format);
  }

  _DaqFileFormat _detectBinaryFormat(Uint8List data) {
    if (_hasValidFrameHeader(data)) {
      return _DaqFileFormat.framedV2;
    }

    if (_looksLikeLegacyFloat(data)) {
      return _DaqFileFormat.legacyFloatV1;
    }

    return _DaqFileFormat.legacyInt16V1;
  }

  List<_DecodedRecord>? _tryDecodeCsvRecords(Uint8List data) {
    final String text = utf8.decode(data, allowMalformed: true);
    if (!text.contains(',') || !text.contains('\n')) {
      return null;
    }

    final List<String> lines = text
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    if (lines.length < 2) {
      return null;
    }

    final List<String> headers =
        lines.first.split(',').map((String h) => h.trim().toLowerCase()).toList();
    final int timestampIndex = headers.indexOf('timestamp_us');
    final int frontIndex = headers.indexOf('front_raw');
    final int rearIndex = headers.indexOf('rear_raw');
    final int statusIndex = headers.indexOf('status_flags');
    if (timestampIndex < 0 || frontIndex < 0 || rearIndex < 0 || statusIndex < 0) {
      return null;
    }

    final int accelXIndex = headers.indexOf('accel_x_g');
    final int accelYIndex = headers.indexOf('accel_y_g');
    final int accelZIndex = headers.indexOf('accel_z_g');
    final int gyroXIndex = headers.indexOf('gyro_x_dps');
    final int gyroYIndex = headers.indexOf('gyro_y_dps');

    final List<_DecodedRecord> records = <_DecodedRecord>[];
    for (final String line in lines.skip(1)) {
      final List<String> cells = line.split(',').map((String c) => c.trim()).toList();
      if (cells.length <= statusIndex ||
          cells.length <= timestampIndex ||
          cells.length <= frontIndex ||
          cells.length <= rearIndex) {
        continue;
      }

      final int? timestamp = int.tryParse(cells[timestampIndex]);
      final int? front = int.tryParse(cells[frontIndex]);
      final int? rear = int.tryParse(cells[rearIndex]);
      final int? status = _tryParseStatusFlags(cells[statusIndex]);
      if (timestamp == null || front == null || rear == null || status == null) {
        continue;
      }

      final double accelXG = _tryParseCellDouble(cells, accelXIndex) ?? 0.0;
      final double accelYG = _tryParseCellDouble(cells, accelYIndex) ?? 0.0;
      final double accelZG = _tryParseCellDouble(cells, accelZIndex) ?? 0.0;
      final double gyroXDegPerSecond = _tryParseCellDouble(cells, gyroXIndex) ?? 0.0;
      final double gyroYDegPerSecond = _tryParseCellDouble(cells, gyroYIndex) ?? 0.0;

      records.add(
        _DecodedRecord(
          timestampMicroseconds: timestamp,
          frontRaw: front,
          rearRaw: rear,
          statusFlags: status,
          accelXG: accelXG,
          accelYG: accelYG,
          accelZG: accelZG,
          gyroXDegPerSecond: gyroXDegPerSecond,
          gyroYDegPerSecond: gyroYDegPerSecond,
        ),
      );
    }

    if (records.isEmpty) {
      throw const FormatException('CSV file does not contain valid DAQ rows.');
    }
    return records;
  }

  int? _tryParseStatusFlags(String raw) {
    final String normalized = raw.trim().toLowerCase();
    if (normalized.startsWith('0x')) {
      return int.tryParse(normalized.substring(2), radix: 16);
    }
    return int.tryParse(normalized);
  }

  double? _tryParseCellDouble(List<String> cells, int index) {
    if (index < 0 || index >= cells.length) {
      return null;
    }
    return double.tryParse(cells[index]);
  }

  List<_DecodedRecord> _decodeRecords(Uint8List data, _DaqFileFormat format) {
    switch (format) {
      case _DaqFileFormat.csvTextV3:
        throw const FormatException('CSV format should be decoded directly.');
      case _DaqFileFormat.framedV2:
        return _decodeFramedV2(data);
      case _DaqFileFormat.legacyFloatV1:
        return _decodeLegacyFloat(data);
      case _DaqFileFormat.legacyInt16V1:
        return _decodeLegacyInt16(data);
    }
  }

  bool _hasValidFrameHeader(Uint8List data) {
    if (data.length < _frameSizeBytes) {
      return false;
    }

    final ByteData firstFrame = ByteData.sublistView(data, 0, _frameSizeBytes);
    final int syncWord = firstFrame.getUint16(0, Endian.little);
    final int version = firstFrame.getUint8(2);
    final int payloadSize = firstFrame.getUint8(3);
    if (syncWord != _frameSyncWord ||
        version != _frameVersion ||
        payloadSize != _framePayloadSizeBytes) {
      return false;
    }

    final int expectedCrc = firstFrame.getUint16(_frameSizeBytes - 2, Endian.little);
    final int actualCrc = _crc16Ccitt(data, 0, _frameSizeBytes - 2);
    return expectedCrc == actualCrc;
  }

  bool _looksLikeLegacyFloat(Uint8List data) {
    if (data.length < _legacyFloatRecordSizeBytes ||
        data.length % _legacyFloatRecordSizeBytes != 0) {
      return false;
    }

    final int recordCount = data.length ~/ _legacyFloatRecordSizeBytes;
    final int probeCount = math.min(5, recordCount);
    for (int index = 0; index < probeCount; index++) {
      final int offset = index * _legacyFloatRecordSizeBytes;
      final ByteData byteData = ByteData.sublistView(
        data,
        offset,
        offset + _legacyFloatRecordSizeBytes,
      );

      final int frontRaw = byteData.getUint16(_frontOffset, Endian.little);
      final int rearRaw = byteData.getUint16(_rearOffset, Endian.little);
      final int status = byteData.getUint8(_legacyFloatStatusFlagsOffset);
      if (frontRaw > 5000 || rearRaw > 5000 || (status & 0xF0) != 0) {
        return false;
      }
    }

    return true;
  }

  List<_DecodedRecord> _decodeFramedV2(Uint8List data) {
    final List<_DecodedRecord> records = <_DecodedRecord>[];
    int offset = 0;

    while (offset <= data.length - _frameSizeBytes) {
      final ByteData frame = ByteData.sublistView(data, offset, offset + _frameSizeBytes);
      final int syncWord = frame.getUint16(0, Endian.little);
      final int version = frame.getUint8(2);
      final int payloadSize = frame.getUint8(3);

      if (syncWord != _frameSyncWord ||
          version != _frameVersion ||
          payloadSize != _framePayloadSizeBytes) {
        offset += 1;
        continue;
      }

      final int expectedCrc = frame.getUint16(_frameSizeBytes - 2, Endian.little);
      final int actualCrc = _crc16Ccitt(data, offset, _frameSizeBytes - 2);
      if (expectedCrc != actualCrc) {
        offset += 1;
        continue;
      }

      records.add(_decodeInt16Payload(frame, _frameHeaderSizeBytes, _milliGScale, _deciDegreesPerSecondScale));
      offset += _frameSizeBytes;
    }

    if (records.isEmpty) {
      throw const FormatException(
        'No valid framed DAQ records were found. The file may be corrupted.',
      );
    }
    return records;
  }

  List<_DecodedRecord> _decodeLegacyInt16(Uint8List data) {
    final int completeRecords = data.length ~/ _legacyInt16RecordSizeBytes;
    if (completeRecords <= 0) {
      throw const FormatException('File is too small to contain any DAQ records.');
    }

    final List<_DecodedRecord> records = <_DecodedRecord>[];
    for (int index = 0; index < completeRecords; index++) {
      final int offset = index * _legacyInt16RecordSizeBytes;
      final ByteData payload = ByteData.sublistView(
        data,
        offset,
        offset + _legacyInt16RecordSizeBytes,
      );
      records.add(_decodeInt16Payload(payload, 0, _mpu6050AccelLsbPerG, _mpu6050GyroLsbPerDegPerSecond));
    }
    return records;
  }

  List<_DecodedRecord> _decodeLegacyFloat(Uint8List data) {
    final int completeRecords = data.length ~/ _legacyFloatRecordSizeBytes;
    if (completeRecords <= 0) {
      throw const FormatException('File is too small to contain any DAQ records.');
    }

    final List<_DecodedRecord> records = <_DecodedRecord>[];
    for (int index = 0; index < completeRecords; index++) {
      final int offset = index * _legacyFloatRecordSizeBytes;
      final ByteData byteData = ByteData.sublistView(
        data,
        offset,
        offset + _legacyFloatRecordSizeBytes,
      );

      final double accelXG =
          byteData.getFloat32(_legacyFloatImuAccelXOffset, Endian.little) /
          _standardGravityMetersPerSecondSquared;
      final double accelYG =
          byteData.getFloat32(_legacyFloatImuAccelYOffset, Endian.little) /
          _standardGravityMetersPerSecondSquared;
      final double accelZG =
          byteData.getFloat32(_legacyFloatImuAccelZOffset, Endian.little) /
          _standardGravityMetersPerSecondSquared;

      final double gyroXDegPerSecond =
          byteData.getFloat32(_legacyFloatImuGyroXOffset, Endian.little) *
          _radiansToDegrees;
      final double gyroYDegPerSecond =
          byteData.getFloat32(_legacyFloatImuGyroYOffset, Endian.little) *
          _radiansToDegrees;

      records.add(
        _DecodedRecord(
          timestampMicroseconds: byteData.getUint32(_timestampOffset, Endian.little),
          frontRaw: byteData.getUint16(_frontOffset, Endian.little),
          rearRaw: byteData.getUint16(_rearOffset, Endian.little),
          statusFlags: byteData.getUint8(_legacyFloatStatusFlagsOffset),
          accelXG: accelXG,
          accelYG: accelYG,
          accelZG: accelZG,
          gyroXDegPerSecond: gyroXDegPerSecond,
          gyroYDegPerSecond: gyroYDegPerSecond,
        ),
      );
    }
    return records;
  }

  _DecodedRecord _decodeInt16Payload(
    ByteData byteData,
    int baseOffset,
    double accelDivisor,
    double gyroDivisor,
  ) {
    final double accelXG = byteData.getInt16(baseOffset + _imuAccelXOffset, Endian.little) /
        accelDivisor;
    final double accelYG = byteData.getInt16(baseOffset + _imuAccelYOffset, Endian.little) /
        accelDivisor;
    final double accelZG = byteData.getInt16(baseOffset + _imuAccelZOffset, Endian.little) /
        accelDivisor;
    final double gyroXDegPerSecond =
        byteData.getInt16(baseOffset + _imuGyroXOffset, Endian.little) / gyroDivisor;
    final double gyroYDegPerSecond =
        byteData.getInt16(baseOffset + _imuGyroYOffset, Endian.little) / gyroDivisor;

    return _DecodedRecord(
      timestampMicroseconds: byteData.getUint32(baseOffset + _timestampOffset, Endian.little),
      frontRaw: byteData.getUint16(baseOffset + _frontOffset, Endian.little),
      rearRaw: byteData.getUint16(baseOffset + _rearOffset, Endian.little),
      statusFlags: byteData.getUint8(baseOffset + _statusFlagsOffset),
      accelXG: accelXG,
      accelYG: accelYG,
      accelZG: accelZG,
      gyroXDegPerSecond: gyroXDegPerSecond,
      gyroYDegPerSecond: gyroYDegPerSecond,
    );
  }

  (List<double>, List<double>) _buildShockToWheelMap(List<LeverageCurvePoint> curve) {
    final List<double> shockMm = <double>[0.0];
    final List<double> wheelMm = <double>[curve.first.wheelTravelMm];
    for (int i = 1; i < curve.length; i++) {
      final double dw = curve[i].wheelTravelMm - curve[i - 1].wheelTravelMm;
      final double avgLr =
          (curve[i].leverageRatio + curve[i - 1].leverageRatio) / 2.0;
      shockMm.add(shockMm.last + dw / avgLr);
      wheelMm.add(curve[i].wheelTravelMm);
    }
    return (shockMm, wheelMm);
  }

  double _interpolate(List<double> xTable, List<double> yTable, double x) {
    if (x <= xTable.first) return yTable.first;
    if (x >= xTable.last) return yTable.last;
    int lo = 0;
    int hi = xTable.length - 1;
    while (hi - lo > 1) {
      final int mid = (lo + hi) ~/ 2;
      if (xTable[mid] <= x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final double t = (x - xTable[lo]) / (xTable[hi] - xTable[lo]);
    return yTable[lo] + t * (yTable[hi] - yTable[lo]);
  }

  int _crc16Ccitt(Uint8List data, int start, int length) {
    int crc = 0xFFFF;
    for (int i = 0; i < length; i++) {
      crc ^= data[start + i] << 8;
      for (int bit = 0; bit < 8; bit++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }
}
