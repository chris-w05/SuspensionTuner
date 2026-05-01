import 'calibration_profile.dart';

class PositionVelocityPoint {
  PositionVelocityPoint({
    required this.positionMillimeters,
    required this.velocityMillimetersPerSecond,
    required this.timestampMicroseconds,
  });

  final double positionMillimeters;
  final double velocityMillimetersPerSecond;
  final int timestampMicroseconds;
}

class PositionTimePoint {
  PositionTimePoint({
    required this.timestampMicroseconds,
    required this.timeSeconds,
    required this.positionMillimeters,
    required this.normalizedTravelPercent,
  });

  final int timestampMicroseconds;
  final double timeSeconds;
  final double positionMillimeters;
  final double normalizedTravelPercent;
}

class AttitudeTimePoint {
  AttitudeTimePoint({
    required this.timestampMicroseconds,
    required this.timeSeconds,
    required this.pitchDegrees,
    required this.leanDegrees,
  });

  final int timestampMicroseconds;
  final double timeSeconds;
  final double pitchDegrees;
  final double leanDegrees;
}

class ChannelResult {
  ChannelResult({
    required this.velocityPoints,
    required this.positionTimePoints,
    required this.minPositionMillimeters,
    required this.maxPositionMillimeters,
    required this.minVelocityMillimetersPerSecond,
    required this.maxVelocityMillimetersPerSecond,
    required this.travelMillimeters,
  });

  final List<PositionVelocityPoint> velocityPoints;
  final List<PositionTimePoint> positionTimePoints;
  final double minPositionMillimeters;
  final double maxPositionMillimeters;
  final double minVelocityMillimetersPerSecond;
  final double maxVelocityMillimetersPerSecond;
  final double travelMillimeters;
}

class AccelerationTimePoint {
  AccelerationTimePoint({
    required this.timestampMicroseconds,
    required this.timeSeconds,
    required this.accelXG,
    required this.accelYG,
    required this.accelZG,
    required this.accelAbsoluteG,
  });

  final int timestampMicroseconds;
  final double timeSeconds;
  final double accelXG;
  final double accelYG;
  final double accelZG;
  final double accelAbsoluteG;
}

class AnalysisResult {
  AnalysisResult({
    required this.sampleCount,
    required this.channelResults,
    required this.attitudeTimePoints,
    required this.accelerationTimePoints,
  });

  final int sampleCount;
  final Map<PotentiometerChannel, ChannelResult> channelResults;
  final List<AttitudeTimePoint> attitudeTimePoints;
  final List<AccelerationTimePoint> accelerationTimePoints;
}
