import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';

class AnalysisSummaryCard extends StatelessWidget {
  const AnalysisSummaryCard({super.key, required this.result});

  final AnalysisResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Samples in file: ${result.sampleCount}'),
            ...result.channelResults.entries
                .map((MapEntry<PotentiometerChannel, ChannelResult> entry) {
              final String label = entry.key.name.toUpperCase();
              final ChannelResult cr = entry.value;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 6),
                  Text('$label - ${cr.velocityPoints.length} velocity points'),
                  Text(
                    '$label position: '
                    '${cr.minPositionMillimeters.toStringAsFixed(1)} mm '
                    'to ${cr.maxPositionMillimeters.toStringAsFixed(1)} mm',
                  ),
                  Text(
                    '$label velocity: '
                    '${cr.minVelocityMillimetersPerSecond.toStringAsFixed(1)} '
                    'to ${cr.maxVelocityMillimetersPerSecond.toStringAsFixed(1)} mm/s',
                  ),
                  Text(
                      '$label configured travel: ${cr.travelMillimeters.toStringAsFixed(1)} mm'),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
