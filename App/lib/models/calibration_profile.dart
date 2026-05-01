import 'dart:math' as math;

enum PotentiometerChannel {
  front,
  rear,
}

class PotentiometerCalibration {
  PotentiometerCalibration({
    required this.sideA,
    required this.sideB,
    required this.extendedSideC,
    required this.extendedAdc,
    required this.compressedSideC,
    required this.compressedAdc,
  });

  static const double defaultFixedSideLength = 145.0;

  final double sideA;
  final double sideB;
  final double extendedSideC;
  final int extendedAdc;
  final double compressedSideC;
  final int compressedAdc;

  double get extendedAngleDegrees =>
      _calculateAngleDegrees(sideA, sideB, extendedSideC);

  double get compressedAngleDegrees =>
      _calculateAngleDegrees(sideA, sideB, compressedSideC);

    double get travelMillimeters =>
      (compressedSideC - extendedSideC).abs();

  double mapAdcToPositionPercent(int rawAdc) {
    if (extendedAdc == compressedAdc) {
      throw const FormatException('Extended and compressed ADC values cannot be equal.');
    }

    final double adcSpan = (compressedAdc - extendedAdc).toDouble();
    final double t = (rawAdc - extendedAdc) / adcSpan;
    final double angleAtRaw =
        extendedAngleDegrees + t * (compressedAngleDegrees - extendedAngleDegrees);

    final double low = math.min(extendedAngleDegrees, compressedAngleDegrees);
    final double high = math.max(extendedAngleDegrees, compressedAngleDegrees);
    final double clampedAngle = angleAtRaw.clamp(low, high);

    final double denominator = compressedAngleDegrees - extendedAngleDegrees;
    if (denominator == 0) {
      throw const FormatException(
          'Invalid calibration: compressed and extended angles are equal.');
    }

    final double normalized = (clampedAngle - extendedAngleDegrees) / denominator;
    return (normalized * 100.0).clamp(0.0, 100.0);
  }

  double mapAdcToPositionMillimeters(int rawAdc) {
    final double normalizedPercent = mapAdcToPositionPercent(rawAdc);
    return (normalizedPercent / 100.0) * travelMillimeters;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'sideA': sideA,
      'sideB': sideB,
      'extendedSideC': extendedSideC,
      'extendedAdc': extendedAdc,
      'compressedSideC': compressedSideC,
      'compressedAdc': compressedAdc,
    };
  }

  factory PotentiometerCalibration.fromJson(Map<String, dynamic> json) {
    return PotentiometerCalibration(
      sideA: (json['sideA'] as num).toDouble(),
      sideB: (json['sideB'] as num).toDouble(),
      extendedSideC: (json['extendedSideC'] as num).toDouble(),
      extendedAdc: (json['extendedAdc'] as num).toInt(),
      compressedSideC: (json['compressedSideC'] as num).toDouble(),
      compressedAdc: (json['compressedAdc'] as num).toInt(),
    );
  }

  static double _calculateAngleDegrees(double a, double b, double c) {
    if (a <= 0 || b <= 0 || c <= 0) {
      throw const FormatException('All triangle side lengths must be greater than zero.');
    }
    if (a + b <= c || a + c <= b || b + c <= a) {
      throw const FormatException('Invalid triangle dimensions for calibration.');
    }
    final double numerator = (a * a) + (b * b) - (c * c);
    final double denominator = 2.0 * a * b;
    final double cosine = (numerator / denominator).clamp(-1.0, 1.0);
    return math.acos(cosine) * 180.0 / math.pi;
  }
}

class CalibrationProfile {
  CalibrationProfile({
    required this.id,
    required this.name,
    required this.frontCalibration,
    required this.rearCalibration,
    required this.createdAtMilliseconds,
  });

  final String id;
  final String name;
  final PotentiometerCalibration? frontCalibration;
  final PotentiometerCalibration? rearCalibration;
  final int createdAtMilliseconds;

  /// Returns null when the channel is not configured in this profile.
  PotentiometerCalibration? calibrationForChannel(PotentiometerChannel channel) {
    return channel == PotentiometerChannel.front ? frontCalibration : rearCalibration;
  }

  List<PotentiometerChannel> get configuredChannels {
    return <PotentiometerChannel>[
      if (frontCalibration != null) PotentiometerChannel.front,
      if (rearCalibration != null) PotentiometerChannel.rear,
    ];
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'frontCalibration': frontCalibration?.toJson(),
      'rearCalibration': rearCalibration?.toJson(),
      'createdAtMilliseconds': createdAtMilliseconds,
    };
  }

  factory CalibrationProfile.fromJson(Map<String, dynamic> json) {
    final Object? frontJson = json['frontCalibration'];
    final Object? rearJson = json['rearCalibration'];
    return CalibrationProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      frontCalibration: frontJson is Map<String, dynamic>
          ? PotentiometerCalibration.fromJson(frontJson)
          : null,
      rearCalibration: rearJson is Map<String, dynamic>
          ? PotentiometerCalibration.fromJson(rearJson)
          : null,
      createdAtMilliseconds: (json['createdAtMilliseconds'] as num).toInt(),
    );
  }
}
