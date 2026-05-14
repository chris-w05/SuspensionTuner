import 'calibration_profile.dart';

enum RecommendationSeverity {
  /// Something worth being aware of but not urgently wrong.
  info,

  /// A likely mis-tuning that should be corrected.
  action,
}

/// Lower number = higher importance.
/// Used to sort recommendations within the same severity tier.
const Map<SuspensionAdjustment, int> adjustmentImportance =
    <SuspensionAdjustment, int>{
  SuspensionAdjustment.airPressureOrSpringRate: 0,
  SuspensionAdjustment.hydraulicBottomOut: 1,
  SuspensionAdjustment.volumeReducers: 2,
  SuspensionAdjustment.lowSpeedRebound: 3,
  SuspensionAdjustment.highSpeedRebound: 4,
  SuspensionAdjustment.lowSpeedCompression: 5,
  SuspensionAdjustment.highSpeedCompression: 6,
  SuspensionAdjustment.negativeAirSpringVolume: 7,
};

class SuspensionRecommendation {
  const SuspensionRecommendation({
    required this.channel,
    required this.adjustment,
    required this.title,
    required this.explanation,
    required this.severity,
    required this.dataPoints,
  });

  final PotentiometerChannel channel;
  final SuspensionAdjustment adjustment;
  final String title;
  final String explanation;
  final RecommendationSeverity severity;

  /// Short data strings that support the recommendation (e.g. "Travel used: 58%").
  final List<String> dataPoints;
}
