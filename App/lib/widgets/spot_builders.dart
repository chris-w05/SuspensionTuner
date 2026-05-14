import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import 'chart_utils.dart';

class SpotBuilders {
  SpotBuilders._();

  static List<FlSpot> sanitizeTimeSeriesSpots(List<FlSpot> spots) {
    if (spots.isEmpty) {
      return const <FlSpot>[];
    }

    final List<FlSpot> sanitized = <FlSpot>[];
    FlSpot? previous;

    for (final FlSpot spot in spots) {
      if (previous != null && spot.x < previous.x) {
        continue;
      }
      if (previous != null && spot.x == previous.x && sanitized.isNotEmpty) {
        sanitized.removeLast();
      }
      sanitized.add(spot);
      previous = spot;
    }

    return sanitized;
  }

  static List<FlSpot> scaledPositionSpots(
    ChannelResult result, {
    int maxPoints = 2500,
  }) {
    final List<PositionTimePoint> points = result.positionTimePoints;
    if (points.isEmpty) {
      return const <FlSpot>[];
    }
    final int count = points.length;
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;
    final List<FlSpot> spots = <FlSpot>[];
    for (int index = 0; index < count; index += step) {
      final PositionTimePoint point = points[index];
      spots.add(FlSpot(point.timeSeconds, point.normalizedTravelPercent));
    }
    return sanitizeTimeSeriesSpots(spots);
  }

  static List<FlSpot> positionSpotsMm(
    ChannelResult result, {
    int maxPoints = 2500,
  }) {
    final List<PositionTimePoint> points = result.positionTimePoints;
    if (points.isEmpty) return const <FlSpot>[];
    final int count = points.length;
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;
    final List<FlSpot> spots = <FlSpot>[];
    for (int i = 0; i < count; i += step) {
      spots.add(FlSpot(points[i].timeSeconds, points[i].positionMillimeters));
    }
    return sanitizeTimeSeriesSpots(spots);
  }

  static List<FlSpot> attitudeSpots(
    List<AttitudeTimePoint> points,
    double Function(AttitudeTimePoint point) selector, {
    int maxPoints = 2500,
  }) {
    if (points.isEmpty) {
      return const <FlSpot>[];
    }
    final int count = points.length;
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;
    final List<FlSpot> spots = <FlSpot>[];
    for (int index = 0; index < count; index += step) {
      final AttitudeTimePoint point = points[index];
      spots.add(FlSpot(point.timeSeconds, selector(point)));
    }
    return sanitizeTimeSeriesSpots(spots);
  }

  static List<FlSpot> accelSpots(
    List<AccelerationTimePoint> points,
    double Function(AccelerationTimePoint) selector, {
    int maxPoints = 2500,
  }) {
    if (points.isEmpty) {
      return const <FlSpot>[];
    }
    final int count = points.length;
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;
    final List<FlSpot> spots = <FlSpot>[];
    for (int i = 0; i < count; i += step) {
      spots.add(FlSpot(points[i].timeSeconds, selector(points[i])));
    }
    return sanitizeTimeSeriesSpots(spots);
  }

  static List<ScatterSpot> allVelocityPositionSpots(
    AnalysisResult result, {
    int maxPointsPerChannel = 2000,
  }) {
    final List<ScatterSpot> allSpots = <ScatterSpot>[];
    for (final MapEntry<PotentiometerChannel, ChannelResult> entry
        in result.channelResults.entries) {
      final List<PositionVelocityPoint> points = entry.value.velocityPoints;
      final int count = points.length;
      final int step =
          count > maxPointsPerChannel ? (count / maxPointsPerChannel).ceil() : 1;
      final Color color = ChartUtils.channelColor(entry.key);
      for (int i = 0; i < count; i += step) {
        allSpots.add(
          ScatterSpot(
            points[i].positionMillimeters,
            points[i].velocityMillimetersPerSecond,
            dotPainter:
                FlDotCirclePainter(radius: 2, color: color, strokeWidth: 0),
          ),
        );
      }
    }
    return allSpots;
  }

  static List<ScatterSpot> frontVsRearPositionSpots(
    AnalysisResult result, {
    int maxPoints = 2000,
  }) {
    final ChannelResult? front =
        result.channelResults[PotentiometerChannel.front];
    final ChannelResult? rear =
        result.channelResults[PotentiometerChannel.rear];
    if (front == null || rear == null) return const <ScatterSpot>[];

    final List<PositionTimePoint> fp = front.positionTimePoints;
    final List<PositionTimePoint> rp = rear.positionTimePoints;
    final int count = math.min(fp.length, rp.length);
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;

    final List<ScatterSpot> spots = <ScatterSpot>[];
    for (int i = 0; i < count; i += step) {
      spots.add(ScatterSpot(
        fp[i].positionMillimeters,
        rp[i].positionMillimeters,
        dotPainter: FlDotCirclePainter(
            radius: 2, color: const Color(0xFF7B1FA2), strokeWidth: 0),
      ));
    }
    return spots;
  }

  static List<ScatterSpot> frontVsRearVelocitySpots(
    AnalysisResult result, {
    int maxPoints = 2000,
  }) {
    final ChannelResult? front =
        result.channelResults[PotentiometerChannel.front];
    final ChannelResult? rear =
        result.channelResults[PotentiometerChannel.rear];
    if (front == null || rear == null) return const <ScatterSpot>[];

    final List<PositionVelocityPoint> fv = front.velocityPoints;
    final List<PositionVelocityPoint> rv = rear.velocityPoints;
    final int count = math.min(fv.length, rv.length);
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;

    final List<ScatterSpot> spots = <ScatterSpot>[];
    for (int i = 0; i < count; i += step) {
      spots.add(ScatterSpot(
        fv[i].velocityMillimetersPerSecond,
        rv[i].velocityMillimetersPerSecond,
        dotPainter: FlDotCirclePainter(
            radius: 2, color: const Color(0xFF00695C), strokeWidth: 0),
      ));
    }
    return spots;
  }
}
