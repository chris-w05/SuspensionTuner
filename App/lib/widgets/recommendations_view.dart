import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/recommendation.dart';
import '../services/suspension_recommendation_service.dart';

const Map<SuspensionAdjustment, String> _adjustmentLabels =
    <SuspensionAdjustment, String>{
  SuspensionAdjustment.airPressureOrSpringRate: 'Air pressure / Spring rate',
  SuspensionAdjustment.volumeReducers: 'Volume reducers',
  SuspensionAdjustment.negativeAirSpringVolume: 'Negative spring volume',
  SuspensionAdjustment.lowSpeedRebound: 'Low-speed rebound',
  SuspensionAdjustment.highSpeedRebound: 'High-speed rebound',
  SuspensionAdjustment.lowSpeedCompression: 'Low-speed compression',
  SuspensionAdjustment.highSpeedCompression: 'High-speed compression',
  SuspensionAdjustment.hydraulicBottomOut: 'Hydraulic bottom-out',
};

class RecommendationsView extends StatelessWidget {
  const RecommendationsView({
    super.key,
    required this.result,
    required this.profile,
  });

  final AnalysisResult result;
  final CalibrationProfile profile;

  static final SuspensionRecommendationService _service =
      SuspensionRecommendationService();

  bool get _hasAnyAdjustmentsConfigured =>
      profile.frontAdjustments.isNotEmpty ||
      profile.rearAdjustments.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_hasAnyAdjustmentsConfigured) {
      return _EmptyState(
        icon: Icons.tune_outlined,
        title: 'No adjustments configured',
        subtitle:
            'Open the Setup tab, edit this profile, and tick the adjustments '
            'that are available on this suspension. Recommendations will then '
            'be generated based on the logged data.',
      );
    }

    final List<SuspensionRecommendation> recommendations =
        _service.analyze(result: result, profile: profile);

    if (recommendations.isEmpty) {
      return _EmptyState(
        icon: Icons.check_circle_outline,
        iconColor: Colors.green.shade600,
        title: 'No issues detected',
        subtitle:
            'The suspension appears to be working within expected parameters '
            'for all configured adjustments.',
      );
    }

    // Sort by: severity (action before info), then adjustment importance,
    // then channel (front before rear).
    final List<SuspensionRecommendation> sorted =
        List<SuspensionRecommendation>.from(recommendations)
          ..sort((SuspensionRecommendation a, SuspensionRecommendation b) {
            // Higher severity first (action index > info index, so reverse).
            final int severityCompare =
                b.severity.index.compareTo(a.severity.index);
            if (severityCompare != 0) return severityCompare;
            // Within same severity, higher-importance adjustment first.
            final int importanceA =
                adjustmentImportance[a.adjustment] ?? 99;
            final int importanceB =
                adjustmentImportance[b.adjustment] ?? 99;
            final int importanceCompare = importanceA.compareTo(importanceB);
            if (importanceCompare != 0) return importanceCompare;
            // Tie-break: front before rear.
            return a.channel.index.compareTo(b.channel.index);
          });

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sorted.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int index) =>
          _RecommendationCard(recommendation: sorted[index]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 52,
              color: iconColor ?? Colors.grey.shade500,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.recommendation});

  final SuspensionRecommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final Color channelColor =
        recommendation.channel == PotentiometerChannel.front
            ? const Color(0xFFEF6C00)
            : const Color(0xFF1565C0);

    final bool isAction =
        recommendation.severity == RecommendationSeverity.action;

    final Color severityColor =
        isAction ? Colors.orange.shade800 : Colors.blue.shade700;

    final IconData severityIcon =
        isAction ? Icons.warning_amber_outlined : Icons.info_outline;

    final String channelLabel =
        recommendation.channel.name.toUpperCase();

    final String adjustmentLabel =
        _adjustmentLabels[recommendation.adjustment] ?? '';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(width: 4, color: channelColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Header row: channel chip + adjustment chip + severity icon.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        _Chip(label: channelLabel, color: channelColor),
                        const SizedBox(width: 6),
                        _Chip(
                          label: adjustmentLabel,
                          color: Colors.grey.shade600,
                          background: Colors.grey.shade100,
                        ),
                        const Spacer(),
                        Icon(severityIcon, size: 18, color: severityColor),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      recommendation.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      recommendation.explanation,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(height: 1.5),
                    ),
                    if (recommendation.dataPoints.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      ...recommendation.dataPoints
                          .map((String point) => _DataPoint(text: point)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    this.background,
  });

  final String label;
  final Color color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _DataPoint extends StatelessWidget {
  const _DataPoint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '\u2013  ',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade700,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
