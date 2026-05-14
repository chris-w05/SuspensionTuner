import 'dart:math' as math;

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/recommendation.dart';

class SuspensionRecommendationService {
  // Velocity split: events below this are "low-speed", above are "high-speed".
  static const double _kHsThresholdMmS = 100.0;

  // Travel utilisation thresholds.
  static const double _kTravelUsedLowPct = 65.0;
  static const double _kTravelUsedHighPct = 98.0;

  // Dynamic sag (mean ride position as % of travel).
  static const double _kSagLowPct = 10.0;
  static const double _kSagHighPct = 38.0;

  // Top-stroke sensitivity: % of time expected in first 15% of travel.
  static const double _kTopZonePct = 15.0;
  static const double _kTopZoneMinTimePct = 6.0;

  // Bottom-stroke zone: used for time-in-zone data in volume-reducer analysis.
  static const double _kBottomZonePct = 95.0;

  // Velocity balance ratios.
  // Rebound much faster than compression → suspension packing.
  static const double _kReboundPackingRatio = 2.5;
  // Rebound much slower than compression → suspension stuck / over-damped.
  static const double _kReboundSlowRatio = 0.35;

  // Minimum sample counts before velocity-based checks are trusted.
  static const int _kMinVelocityPoints = 50;
  static const int _kMinLsPoints = 20;

  // High-speed compression: flag when peak HS is this many times the mean LS.
  static const double _kHsLsRatioThreshold = 8.0;
  static const double _kHsPeakThresholdMmS = 300.0;

  // Deep-travel zone for hydraulic bottom-out analysis.
  // HBC controls velocity deep in the stroke, not just full bottom-outs.
  static const double _kDeepTravelThresholdPct = 75.0;
  static const double _kDeepZoneCompressionThresholdMmS = 150.0;
  static const int _kMinDeepZoneCompressionEvents = 3;

  List<SuspensionRecommendation> analyze({
    required AnalysisResult result,
    required CalibrationProfile profile,
  }) {
    final List<SuspensionRecommendation> recommendations =
        <SuspensionRecommendation>[];

    for (final PotentiometerChannel channel in PotentiometerChannel.values) {
      final ChannelResult? channelResult = result.channelResults[channel];
      if (channelResult == null) continue;

      final Set<SuspensionAdjustment> available =
          channel == PotentiometerChannel.front
              ? profile.frontAdjustments
              : profile.rearAdjustments;

      final double? targetSagPercent =
          channel == PotentiometerChannel.front
              ? profile.frontTargetSagPercent
              : profile.rearTargetSagPercent;

      final double? leverageRate =
          channel == PotentiometerChannel.rear ? profile.effectiveRearLeverageRate : null;

      recommendations.addAll(
          _analyzeChannel(channelResult, channel, available, targetSagPercent, leverageRate));
    }

    return recommendations;
  }

  List<SuspensionRecommendation> _analyzeChannel(
    ChannelResult channelResult,
    PotentiometerChannel channel,
    Set<SuspensionAdjustment> available,
    double? targetSagPercent,
    double? leverageRate,
  ) {
    final List<SuspensionRecommendation> recs = <SuspensionRecommendation>[];
    final String ch = channel == PotentiometerChannel.front ? 'Front' : 'Rear';

    // Parsed data is already in wheel space when leverage is configured.
    final double travelMm = channelResult.travelMillimeters;
    if (travelMm <= 0) return recs;

    // Sag thresholds: use the profile's target +/- tolerance when set,
    // otherwise fall back to the generic acceptable range.
    const double _kSagTolerance = 5.0;
    final double sagLowPct =
        targetSagPercent != null ? targetSagPercent - _kSagTolerance : _kSagLowPct;
    final double sagHighPct =
        targetSagPercent != null ? targetSagPercent + _kSagTolerance : _kSagHighPct;
    final String sagTargetDesc = targetSagPercent != null
        ? '${targetSagPercent.toStringAsFixed(1)}% (±${_kSagTolerance.toStringAsFixed(0)}%)'
        : '${_kSagLowPct.toStringAsFixed(0)}–25%';

    final double maxPositionMm = channelResult.maxPositionMillimeters;
    final double usedTravelMm =
        channelResult.maxPositionMillimeters - channelResult.minPositionMillimeters;
    final double usedTravelPct = (usedTravelMm / travelMm * 100.0).clamp(0.0, 100.0);

    final List<PositionTimePoint> posPoints = channelResult.positionTimePoints;

    double meanPositionPct = 0;
    double timeInTopZonePct = 0;
    double timeInBottomZonePct = 0;

    if (posPoints.isNotEmpty) {
      double posSum = 0;
      int topCount = 0;
      int bottomCount = 0;
      for (final PositionTimePoint p in posPoints) {
        posSum += p.normalizedTravelPercent;
        if (p.normalizedTravelPercent < _kTopZonePct) topCount++;
        if (p.normalizedTravelPercent > _kBottomZonePct) bottomCount++;
      }
      meanPositionPct = posSum / posPoints.length;
      timeInTopZonePct = topCount / posPoints.length * 100.0;
      timeInBottomZonePct = bottomCount / posPoints.length * 100.0;
    }

    // ── Velocity metrics ─────────────────────────────────────────────────────

    final List<PositionVelocityPoint> velPoints = channelResult.velocityPoints;
    final bool hasEnoughVelocityData = velPoints.length >= _kMinVelocityPoints;

    // Positive velocity = compression; negative = rebound.
    final List<double> reboundMagnitudes = <double>[];
    final List<double> compressionMagnitudes = <double>[];
    final List<double> lsRebound = <double>[];
    final List<double> hsRebound = <double>[];
    final List<double> lsCompression = <double>[];
    final List<double> hsCompression = <double>[];

    // Data is already in wheel space; thresholds apply directly.
    final double hsThresholdMmS = _kHsThresholdMmS;
    final double deepZoneCompressionThresholdMmS = _kDeepZoneCompressionThresholdMmS;
    final String velocityUnit = leverageRate != null ? 'mm/s (wheel)' : 'mm/s';

    // Deep-travel velocity events: position > _kDeepTravelThresholdPct of travel.
    final double deepThresholdMm = travelMm * _kDeepTravelThresholdPct / 100.0;
    int deepZoneHighVelCompressionCount = 0;
    double maxDeepZoneCompressionMmS = 0;
    double maxDeepZoneReboundMmS = 0;

    for (final PositionVelocityPoint p in velPoints) {
      final double positionMm = p.positionMillimeters;
      final double v = p.velocityMillimetersPerSecond;
      if (v < 0) {
        final double mag = -v;
        reboundMagnitudes.add(mag);
        if (mag < hsThresholdMmS) {
          lsRebound.add(mag);
        } else {
          hsRebound.add(mag);
        }
        if (positionMm >= deepThresholdMm) {
          maxDeepZoneReboundMmS = math.max(maxDeepZoneReboundMmS, mag);
        }
      } else if (v > 0) {
        compressionMagnitudes.add(v);
        if (v < hsThresholdMmS) {
          lsCompression.add(v);
        } else {
          hsCompression.add(v);
        }
        if (positionMm >= deepThresholdMm &&
            v >= deepZoneCompressionThresholdMmS) {
          deepZoneHighVelCompressionCount++;
          maxDeepZoneCompressionMmS = math.max(maxDeepZoneCompressionMmS, v);
        }
      }
    }

    final double meanLsRebound = lsRebound.isEmpty
        ? 0
        : lsRebound.reduce((double a, double b) => a + b) / lsRebound.length;
    final double meanLsCompression = lsCompression.isEmpty
        ? 0
        : lsCompression.reduce((double a, double b) => a + b) /
            lsCompression.length;
    final double maxHsRebound =
        hsRebound.isEmpty ? 0 : hsRebound.reduce(math.max);
    final double maxHsCompression =
        hsCompression.isEmpty ? 0 : hsCompression.reduce(math.max);

    // ── Spring rate / Air pressure ──────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.airPressureOrSpringRate)) {
      if (usedTravelPct < _kTravelUsedLowPct) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.airPressureOrSpringRate,
          severity: RecommendationSeverity.action,
          title: '$ch: Reduce air pressure or fit a softer spring',
          explanation:
              'Only ${usedTravelPct.toStringAsFixed(1)}% of the configured travel is being '
              'reached. A well-tuned suspension typically uses 85% or more of its travel. '
              'Consider reducing air pressure or fitting a softer spring to unlock the '
              'remaining travel.',
          dataPoints: <String>[
            'Travel reached: ${_mmDisplay(usedTravelMm, leverageRate)} of ${_mmDisplay(travelMm, leverageRate)} (${usedTravelPct.toStringAsFixed(1)}%)',
            'Mean ride position: ${meanPositionPct.toStringAsFixed(1)}% of travel',
          ],
        ));
      }

      if (usedTravelPct >= _kTravelUsedHighPct) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.airPressureOrSpringRate,
          severity: RecommendationSeverity.action,
          title: '$ch: Increase air pressure or fit a stiffer spring',
          explanation:
              'The suspension is reaching ${usedTravelPct.toStringAsFixed(1)}% of its travel, '
              'indicating full compression is being reached under load. Increasing air pressure '
              'or fitting a stiffer spring will prevent the suspension from running out of travel.',
          dataPoints: <String>[
            'Max position: ${_mmDisplay(maxPositionMm, leverageRate)} '
                'of ${_mmDisplay(travelMm, leverageRate)} (${usedTravelPct.toStringAsFixed(1)}%)',
            'Time at end of travel (>${_kBottomZonePct.toStringAsFixed(0)}%): '
                '${timeInBottomZonePct.toStringAsFixed(1)}% of run',
          ],
        ));
      }

      if (posPoints.isNotEmpty && meanPositionPct < sagLowPct &&
          usedTravelPct >= _kTravelUsedLowPct) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.airPressureOrSpringRate,
          severity: RecommendationSeverity.action,
          title: '$ch: Reduce air pressure or spring preload',
          explanation:
              'The mean dynamic ride position is ${meanPositionPct.toStringAsFixed(1)}% of '
              'travel — below the target sag of $sagTargetDesc. This suggests too much '
              'spring preload or air pressure for the rider\'s weight, causing the suspension '
              'to ride too high in its travel.',
          dataPoints: <String>[
            'Mean position: ${meanPositionPct.toStringAsFixed(1)}% of travel',
            'Target sag: $sagTargetDesc',
          ],
        ));
      }

      if (posPoints.isNotEmpty && meanPositionPct > sagHighPct) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.airPressureOrSpringRate,
          severity: RecommendationSeverity.action,
          title: '$ch: Increase air pressure or spring preload',
          explanation:
              'The mean dynamic ride position is ${meanPositionPct.toStringAsFixed(1)}% of '
              'travel — above the target sag of $sagTargetDesc. This suggests insufficient '
              'spring force for the rider\'s weight. Consider increasing air pressure or '
              'fitting a stiffer spring.',
          dataPoints: <String>[
            'Mean position: ${meanPositionPct.toStringAsFixed(1)}% of travel',
            'Target sag: $sagTargetDesc',
          ],
        ));
      }
    }

    // ── Volume reducers ──────────────────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.volumeReducers)) {
      if (usedTravelPct >= _kTravelUsedHighPct &&
          hsCompression.isNotEmpty &&
          maxHsCompression > 200.0) {
        final bool hbcAvailable =
            available.contains(SuspensionAdjustment.hydraulicBottomOut);
        final String reboundNote = hbcAvailable
            ? ' Note: volume reducers increase progressive air-spring force deep in the '
              'stroke, which stores more energy and can increase rebound velocity in that '
              'zone. Pairing with a hydraulic bottom-out cartridge helps control this.'
            : '';
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.volumeReducers,
          severity: RecommendationSeverity.action,
          title: '$ch: Add volume spacers',
          explanation:
              'The suspension is reaching full travel while still experiencing high-speed '
              'compression events. Volume reducers increase end-stroke air spring progression, '
              'preventing harsh bottom-out without affecting suppleness early in the stroke. '
              'This allows correct sag to be maintained while protecting against bottom-out.$reboundNote',
          dataPoints: <String>[
            'Travel reached: ${usedTravelPct.toStringAsFixed(1)}%',
            'Peak high-speed compression: ${maxHsCompression.toStringAsFixed(0)} $velocityUnit',
            'Time at end of travel: ${timeInBottomZonePct.toStringAsFixed(1)}% of run',
          ],
        ));
      }
    }

    // ── Negative air spring volume ───────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.negativeAirSpringVolume)) {
      if (posPoints.isNotEmpty &&
          timeInTopZonePct < _kTopZoneMinTimePct) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.negativeAirSpringVolume,
          severity: RecommendationSeverity.info,
          title: '$ch: Increase negative spring volume',
          explanation:
              'Only ${timeInTopZonePct.toStringAsFixed(1)}% of the run is spent in the first '
              '${_kTopZonePct.toStringAsFixed(0)}% of travel. A small negative spring volume '
              'creates a stiff initial stroke, reducing sensitivity to small bumps. Increasing '
              'negative spring volume improves suppleness at the top of the stroke.',
          dataPoints: <String>[
            'Time in top ${_kTopZonePct.toStringAsFixed(0)}% of travel: '
                '${timeInTopZonePct.toStringAsFixed(1)}% of run',
            'Mean ride position: ${meanPositionPct.toStringAsFixed(1)}% of travel',
          ],
        ));
      }
    }

    // ── Low-speed rebound ────────────────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.lowSpeedRebound) &&
        hasEnoughVelocityData &&
        lsRebound.length >= _kMinLsPoints &&
        lsCompression.length >= _kMinLsPoints) {
      final double ratio = meanLsRebound / math.max(meanLsCompression, 1.0);

      if (ratio > _kReboundPackingRatio) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.lowSpeedRebound,
          severity: RecommendationSeverity.action,
          title: '$ch: Close the low-speed rebound adjuster',
          explanation:
              'The mean low-speed rebound velocity (${meanLsRebound.toStringAsFixed(0)} $velocityUnit) '
              'is ${ratio.toStringAsFixed(1)}x the mean low-speed compression velocity '
              '(${meanLsCompression.toStringAsFixed(0)} $velocityUnit). Fast rebound causes the '
              'suspension to pack down over successive bumps, reducing grip and control. '
              'Increase low-speed rebound damping (turn the rebound adjuster toward slower).',
          dataPoints: <String>[
            'Mean LS rebound: ${meanLsRebound.toStringAsFixed(0)} $velocityUnit',
            'Mean LS compression: ${meanLsCompression.toStringAsFixed(0)} $velocityUnit',
            'Rebound / compression ratio: ${ratio.toStringAsFixed(2)}',
          ],
        ));
      } else if (ratio < _kReboundSlowRatio) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.lowSpeedRebound,
          severity: RecommendationSeverity.info,
          title: '$ch: Open the low-speed rebound adjuster',
          explanation:
              'The mean low-speed rebound velocity (${meanLsRebound.toStringAsFixed(0)} $velocityUnit) '
              'is only ${ratio.toStringAsFixed(2)}x the mean low-speed compression velocity '
              '(${meanLsCompression.toStringAsFixed(0)} $velocityUnit). Overly slow rebound can prevent '
              'the suspension from recovering between bumps, reducing travel availability. '
              'Consider reducing low-speed rebound damping (turn adjuster toward faster).',
          dataPoints: <String>[
            'Mean LS rebound: ${meanLsRebound.toStringAsFixed(0)} $velocityUnit',
            'Mean LS compression: ${meanLsCompression.toStringAsFixed(0)} $velocityUnit',
            'Rebound / compression ratio: ${ratio.toStringAsFixed(2)}',
          ],
        ));
      }
    }

    // ── High-speed rebound ───────────────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.highSpeedRebound) &&
        hasEnoughVelocityData &&
        hsRebound.isNotEmpty &&
        hsCompression.isNotEmpty) {
      final double hsRatio = maxHsRebound / math.max(maxHsCompression, 1.0);

      if (hsRatio > _kReboundPackingRatio) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.highSpeedRebound,
          severity: RecommendationSeverity.action,
          title: '$ch: Close the high-speed rebound adjuster',
          explanation:
              'The peak high-speed rebound velocity (${maxHsRebound.toStringAsFixed(0)} $velocityUnit) '
              'is ${hsRatio.toStringAsFixed(1)}x the peak high-speed compression velocity '
              '(${maxHsCompression.toStringAsFixed(0)} $velocityUnit). Rapid high-speed rebound after '
              'large hits can cause the bike to kick and unseat the rider. Increase '
              'high-speed rebound damping.',
          dataPoints: <String>[
            'Peak HS rebound: ${maxHsRebound.toStringAsFixed(0)} $velocityUnit',
            'Peak HS compression: ${maxHsCompression.toStringAsFixed(0)} $velocityUnit',
            'HS rebound / compression ratio: ${hsRatio.toStringAsFixed(2)}',
          ],
        ));
      }
    }

    // ── Low-speed compression ────────────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.lowSpeedCompression) &&
        hasEnoughVelocityData &&
        lsCompression.length >= _kMinLsPoints &&
        lsRebound.length >= _kMinLsPoints) {
      final double ratio = meanLsCompression / math.max(meanLsRebound, 1.0);

      if (ratio > _kReboundPackingRatio) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.lowSpeedCompression,
          severity: RecommendationSeverity.info,
          title: '$ch: Close the low-speed compression adjuster',
          explanation:
              'The mean low-speed compression velocity (${meanLsCompression.toStringAsFixed(0)} $velocityUnit) '
              'is ${ratio.toStringAsFixed(1)}x the mean low-speed rebound velocity '
              '(${meanLsRebound.toStringAsFixed(0)} $velocityUnit). The suspension may be diving '
              'excessively during braking and small-bump loading. Consider increasing '
              'low-speed compression damping.',
          dataPoints: <String>[
            'Mean LS compression: ${meanLsCompression.toStringAsFixed(0)} $velocityUnit',
            'Mean LS rebound: ${meanLsRebound.toStringAsFixed(0)} $velocityUnit',
            'Compression / rebound ratio: ${ratio.toStringAsFixed(2)}',
          ],
        ));
      }
    }

    // ── High-speed compression ───────────────────────────────────────────────

    if (available.contains(SuspensionAdjustment.highSpeedCompression) &&
        hasEnoughVelocityData &&
        hsCompression.isNotEmpty) {
      final double hsLsRatio =
          maxHsCompression / math.max(meanLsCompression, 1.0);

      if (maxHsCompression > _kHsPeakThresholdMmS &&
          hsLsRatio > _kHsLsRatioThreshold) {
        recs.add(SuspensionRecommendation(
          channel: channel,
          adjustment: SuspensionAdjustment.highSpeedCompression,
          severity: RecommendationSeverity.info,
          title: '$ch: Close the high-speed compression adjuster',
          explanation:
              'Peak high-speed compression reached ${maxHsCompression.toStringAsFixed(0)} $velocityUnit '
              '— ${hsLsRatio.toStringAsFixed(0)}x the mean low-speed compression rate. Large '
              'impacts are driving the suspension rapidly, which may feel harsh. Increasing '
              'high-speed compression damping can reduce the harshness of large hits without '
              'affecting small-bump performance.',
          dataPoints: <String>[
            'Peak HS compression: ${maxHsCompression.toStringAsFixed(0)} $velocityUnit',
            'Mean LS compression: ${meanLsCompression.toStringAsFixed(0)} $velocityUnit',
            'HS / LS ratio: ${hsLsRatio.toStringAsFixed(0)}x',
          ],
        ));
      }
    }

    // ── Hydraulic bottom-out ─────────────────────────────────────────────────
    //
    // HBC controls velocity deep in the stroke — it is not limited to cases
    // where the suspension reaches the physical end of travel. The trigger is
    // high-speed compression events occurring in the deep-travel zone (>
    // _kDeepTravelThresholdPct). This is particularly meaningful when sag is
    // already near the target (spring rate is correct), yet the suspension is
    // still moving fast in that region.
    //
    // Balance consideration: volume reducers increase progressive spring force
    // deep in the stroke, storing more energy. This can accelerate rebound
    // velocity out of the same zone, making HBC even more important when both
    // are relevant.

    if (available.contains(SuspensionAdjustment.hydraulicBottomOut) &&
        hasEnoughVelocityData &&
        deepZoneHighVelCompressionCount >= _kMinDeepZoneCompressionEvents) {
      final bool sagIsOnTarget = posPoints.isNotEmpty &&
          meanPositionPct >= sagLowPct &&
          meanPositionPct <= sagHighPct;

      final bool volumeReducersRelevant =
          available.contains(SuspensionAdjustment.volumeReducers) &&
          usedTravelPct >= _kTravelUsedHighPct;

      final String sagContext = sagIsOnTarget
          ? 'Sag is on target (${meanPositionPct.toStringAsFixed(1)}%), so this is '
            'not a spring-rate issue — the damping force in this zone needs '
            'to be increased.'
          : 'Review sag alongside this: if spring rate is also wrong, correct '
            'that first before tuning hydraulic bottom-out.';

      final String volumeNote = volumeReducersRelevant
          ? ' If volume reducers are fitted, their increased spring progression '
            'stores more energy deep in the stroke. This can speed up rebound '
            'exiting the same zone, so HBC becomes especially important.'
          : '';

      recs.add(SuspensionRecommendation(
        channel: channel,
        adjustment: SuspensionAdjustment.hydraulicBottomOut,
        severity: RecommendationSeverity.action,
        title: '$ch: Fit a hydraulic bottom-out cartridge',
        explanation:
            'High-speed compression events are occurring with the suspension past '
            '${_kDeepTravelThresholdPct.toStringAsFixed(0)}% of travel. '
            'A hydraulic bottom-out cartridge adds velocity-sensitive damping specifically '
            'in this zone, absorbing energy from fast deep-stroke events without affecting '
            'the rest of the stroke. $sagContext$volumeNote',
        dataPoints: <String>[
          'Deep-travel high-velocity compressions '
              '(>${deepZoneCompressionThresholdMmS.toStringAsFixed(0)} $velocityUnit past '
              '${_kDeepTravelThresholdPct.toStringAsFixed(0)}% travel): '
              '$deepZoneHighVelCompressionCount events',
          'Peak deep-travel compression: ${maxDeepZoneCompressionMmS.toStringAsFixed(0)} $velocityUnit',
          if (maxDeepZoneReboundMmS > 0)
            'Peak deep-travel rebound: ${maxDeepZoneReboundMmS.toStringAsFixed(0)} $velocityUnit',
          'Mean ride position: ${meanPositionPct.toStringAsFixed(1)}% of travel '
              '(target: $sagTargetDesc)',
        ],
      ));
    }

    return recs;
  }

  /// Returns a display string for a position/travel distance.
  /// Values passed here are already in wheel terms when [leverageRate] is non-null.
  String _mmDisplay(double mm, double? leverageRate) {
    if (leverageRate == null) {
      return '${mm.toStringAsFixed(1)} mm';
    }
    return '${mm.toStringAsFixed(1)} mm (wheel)';
  }
}
