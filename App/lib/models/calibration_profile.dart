import 'dart:math' as math;

/// One point on an imported leverage curve.
///
/// [wheelTravelMm] is the wheel travel at this point in mm.
/// [leverageRatio] is the instantaneous leverage ratio (wheel speed / shock speed)
/// at that point — identical to how Linkage X3 reports it.
class LeverageCurvePoint {
  const LeverageCurvePoint({
    required this.wheelTravelMm,
    required this.leverageRatio,
  });

  final double wheelTravelMm;
  final double leverageRatio;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'wheelTravelMm': wheelTravelMm,
        'leverageRatio': leverageRatio,
      };

  factory LeverageCurvePoint.fromJson(Map<String, dynamic> json) {
    return LeverageCurvePoint(
      wheelTravelMm: (json['wheelTravelMm'] as num).toDouble(),
      leverageRatio: (json['leverageRatio'] as num).toDouble(),
    );
  }
}

enum PotentiometerChannel {
  front,
  rear,
}

enum SuspensionAdjustment {
  airPressureOrSpringRate,
  volumeReducers,
  negativeAirSpringVolume,
  lowSpeedRebound,
  highSpeedRebound,
  lowSpeedCompression,
  highSpeedCompression,
  hydraulicBottomOut,
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
    Set<SuspensionAdjustment>? frontAdjustments,
    Set<SuspensionAdjustment>? rearAdjustments,
    this.frontTargetSagPercent,
    this.rearTargetSagPercent,
    this.rearLeverageRate,
    this.rearLeverageCurve,
  })  : frontAdjustments = frontAdjustments ?? <SuspensionAdjustment>{},
        rearAdjustments = rearAdjustments ?? <SuspensionAdjustment>{};

  final String id;
  final String name;
  final PotentiometerCalibration? frontCalibration;
  final PotentiometerCalibration? rearCalibration;
  final int createdAtMilliseconds;
  final Set<SuspensionAdjustment> frontAdjustments;
  final Set<SuspensionAdjustment> rearAdjustments;

  /// Desired sag as a percentage of total travel (0–100), or null if not set.
  final double? frontTargetSagPercent;
  final double? rearTargetSagPercent;

  /// Average leverage rate for the rear suspension: wheel travel divided by
  /// shock travel. Used to convert shock measurements to wheel-travel
  /// equivalents. Null when not configured.
  final double? rearLeverageRate;

  /// Full leverage curve imported from Linkage X3. Each point maps a wheel
  /// travel position (mm) to the instantaneous leverage ratio at that point.
  final List<LeverageCurvePoint>? rearLeverageCurve;

  /// Resolved leverage rate, applying priority: direct scalar > average of
  /// imported curve > null.
  double? get effectiveRearLeverageRate {
    if (rearLeverageRate != null) return rearLeverageRate;
    final List<LeverageCurvePoint>? curve = rearLeverageCurve;
    if (curve != null && curve.isNotEmpty) {
      return curve.fold(0.0, (double sum, LeverageCurvePoint p) => sum + p.leverageRatio) /
          curve.length;
    }
    return null;
  }

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
      'frontAdjustments': frontAdjustments.map((SuspensionAdjustment a) => a.name).toList(),
      'rearAdjustments': rearAdjustments.map((SuspensionAdjustment a) => a.name).toList(),
      'frontTargetSagPercent': frontTargetSagPercent,
      'rearTargetSagPercent': rearTargetSagPercent,
      'rearLeverageRate': rearLeverageRate,
      'rearLeverageCurve': rearLeverageCurve
          ?.map((LeverageCurvePoint p) => p.toJson())
          .toList(),
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
      frontAdjustments: _parseAdjustments(json['frontAdjustments']),
      rearAdjustments: _parseAdjustments(json['rearAdjustments']),
      frontTargetSagPercent: (json['frontTargetSagPercent'] as num?)?.toDouble(),
      rearTargetSagPercent: (json['rearTargetSagPercent'] as num?)?.toDouble(),
      rearLeverageRate: (json['rearLeverageRate'] as num?)?.toDouble(),
      rearLeverageCurve: (json['rearLeverageCurve'] as List<dynamic>?)
          ?.map((Object? e) =>
              LeverageCurvePoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static Set<SuspensionAdjustment> _parseAdjustments(Object? value) {
    if (value is! List<dynamic>) {
      return <SuspensionAdjustment>{};
    }
    final Set<SuspensionAdjustment> result = <SuspensionAdjustment>{};
    for (final Object? item in value) {
      if (item is! String) {
        continue;
      }
      for (final SuspensionAdjustment adjustment in SuspensionAdjustment.values) {
        if (adjustment.name == item) {
          result.add(adjustment);
          break;
        }
      }
    }
    return result;
  }
}
