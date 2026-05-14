import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/calibration_profile.dart';

class ChartUtils {
  ChartUtils._();

  static Color channelColor(PotentiometerChannel channel) {
    return channel == PotentiometerChannel.front
        ? const Color(0xFFEF6C00)
        : const Color(0xFF1565C0);
  }

  static LineTouchData highContrastLineTouchData() => LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => const Color(0xDD000000),
          getTooltipItems: (List<LineBarSpot> spots) => spots
              .map((LineBarSpot s) => LineTooltipItem(
                    s.y.toStringAsFixed(2),
                    const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ))
              .toList(),
        ),
      );

  static ScatterTouchData highContrastScatterTouchData() => ScatterTouchData(
        touchTooltipData: ScatterTouchTooltipData(
          getTooltipColor: (_) => const Color(0xDD000000),
          getTooltipItems: (ScatterSpot spot) => ScatterTooltipItem(
            '(${spot.x.toStringAsFixed(1)}, ${spot.y.toStringAsFixed(1)})',
            textStyle: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
        ),
      );

  static Widget accelLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }
}
