import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/calibration_profile.dart';

const Map<SuspensionAdjustment, String> _adjustmentLabels = <SuspensionAdjustment, String>{
  SuspensionAdjustment.airPressureOrSpringRate: 'Air pressure / Spring rate',
  SuspensionAdjustment.volumeReducers: 'Volume reducers (positive air spring only)',
  SuspensionAdjustment.negativeAirSpringVolume: 'Negative air spring volume',
  SuspensionAdjustment.lowSpeedRebound: 'Low speed rebound',
  SuspensionAdjustment.highSpeedRebound: 'High speed rebound',
  SuspensionAdjustment.lowSpeedCompression: 'Low speed compression',
  SuspensionAdjustment.highSpeedCompression: 'High speed compression',
  SuspensionAdjustment.hydraulicBottomOut: 'Hydraulic bottom-out (bump stop)',
};

class PotentiometerCalibrationCard extends StatelessWidget {
  const PotentiometerCalibrationCard({
    super.key,
    required this.title,
    required this.enabled,
    required this.onToggled,
    required this.sideAController,
    required this.sideBController,
    required this.extendedSideCController,
    required this.extendedAdcController,
    required this.compressedSideCController,
    required this.compressedAdcController,
    required this.adjustments,
    required this.onAdjustmentToggled,
    this.targetSagController,
    this.leverageRateController,
    this.wheelTravelController,
    this.onImportLinkageCurve,
    this.leverageCurveDescription,
    this.leverageCurve,
  });

  final String title;
  final bool enabled;
  final ValueChanged<bool> onToggled;
  final TextEditingController sideAController;
  final TextEditingController sideBController;
  final TextEditingController extendedSideCController;
  final TextEditingController extendedAdcController;
  final TextEditingController compressedSideCController;
  final TextEditingController compressedAdcController;
  final Set<SuspensionAdjustment> adjustments;
  final void Function(SuspensionAdjustment adjustment, bool selected) onAdjustmentToggled;
  final TextEditingController? targetSagController;
  /// When set, shows a direct leverage rate entry field (wheel travel / shock travel).
  final TextEditingController? leverageRateController;
  /// When set, shows a wheel travel entry field used to derive leverage rate.
  final TextEditingController? wheelTravelController;
  /// When set, a "Import Linkage X3" button is shown in the leverage section.
  final VoidCallback? onImportLinkageCurve;
  /// When non-null, a summary of the imported leverage curve is shown.
  final String? leverageCurveDescription;
  /// When non-null, a small preview chart of the leverage curve is shown.
  final List<LeverageCurvePoint>? leverageCurve;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Switch(value: enabled, onChanged: onToggled),
              ],
            ),
            if (enabled) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Potentiometer reads the angle at B, between Side A and Side C. '
                'Side B is opposite that measured angle and is used to compute the geometry.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              const SizedBox(
                height: 120,
                child: _PotentiometerGeometryDiagram(),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(child: _mmField(sideAController, 'Side A (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _mmField(sideBController, 'Side B (mm)')),
                ],
              ),
              const SizedBox(height: 12),
              Text('Extended', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: _mmField(extendedSideCController, 'Side C (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _intField(extendedAdcController, 'ADC')),
                ],
              ),
              const SizedBox(height: 12),
              Text('Compressed', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: _mmField(compressedSideCController, 'Side C (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _intField(compressedAdcController, 'ADC')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: targetSagController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Target sag (% of travel)',
                  hintText: 'e.g. 25',
                  border: OutlineInputBorder(),
                ),
              ),
              if (leverageRateController != null ||
                  wheelTravelController != null ||
                  onImportLinkageCurve != null) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Text('Leverage Rate',
                        style: Theme.of(context).textTheme.labelLarge),
                    const Spacer(),
                    if (onImportLinkageCurve != null)
                      OutlinedButton.icon(
                        onPressed: onImportLinkageCurve,
                        icon: const Icon(Icons.upload_file_outlined, size: 16),
                        label: const Text('Import Linkage X3'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
                if (leverageCurveDescription != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    leverageCurveDescription!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (leverageCurve != null && leverageCurve!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  _LeverageCurveChart(points: leverageCurve!),
                ],
                const SizedBox(height: 4),
                Text(
                  leverageCurveDescription != null
                      ? 'Direct entry below overrides the imported curve if filled.'
                      : 'Specify either value. If both are entered, the direct leverage rate takes priority.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    if (leverageRateController != null)
                      Expanded(
                        child: TextField(
                          controller: leverageRateController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Average leverage rate',
                            hintText: 'e.g. 2.5',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    if (leverageRateController != null && wheelTravelController != null)
                      const SizedBox(width: 12),
                    if (wheelTravelController != null)
                      Expanded(
                        child: TextField(
                          controller: wheelTravelController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Wheel travel (mm)',
                            hintText: 'e.g. 150',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text('Available Adjustments', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ..._adjustmentLabels.entries.map((MapEntry<SuspensionAdjustment, String> entry) {
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(entry.value),
                  value: adjustments.contains(entry.key),
                  onChanged: (bool? selected) =>
                      onAdjustmentToggled(entry.key, selected ?? false),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mmField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _intField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _LeverageCurveChart extends StatelessWidget {
  const _LeverageCurveChart({required this.points});

  final List<LeverageCurvePoint> points;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    final List<FlSpot> spots = points
        .map((LeverageCurvePoint p) =>
            FlSpot(p.wheelTravelMm, p.leverageRatio))
        .toList();

    double minX = spots.first.x;
    double maxX = spots.last.x;
    double minY = spots.map((FlSpot s) => s.y).reduce((double a, double b) => a < b ? a : b);
    double maxY = spots.map((FlSpot s) => s.y).reduce((double a, double b) => a > b ? a : b);

    // Add 5 % padding on the Y axis so the line never touches the border.
    final double yPad = (maxY - minY).clamp(0.1, double.infinity) * 0.1;
    minY = minY - yPad;
    maxY = maxY + yPad;

    final double xInterval = ((maxX - minX) / 4).clamp(1.0, double.infinity);
    final double yInterval = ((maxY - minY) / 3).clamp(0.01, double.infinity);

    return SizedBox(
      height: 140,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          lineTouchData: const LineTouchData(enabled: false),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: yInterval,
            verticalInterval: xInterval,
            getDrawingHorizontalLine: (_) => FlLine(
              color: colors.outlineVariant,
              strokeWidth: 0.5,
            ),
            getDrawingVerticalLine: (_) => FlLine(
              color: colors.outlineVariant,
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: colors.outlineVariant),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              axisNameWidget: Text(
                'LR',
                style: TextStyle(fontSize: 9, color: colors.onSurfaceVariant),
              ),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: yInterval,
                getTitlesWidget: (double value, TitleMeta meta) {
                  if (value == meta.min || value == meta.max) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    value.toStringAsFixed(1),
                    style: TextStyle(
                        fontSize: 9, color: colors.onSurfaceVariant),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              axisNameWidget: Text(
                'Wheel travel (mm)',
                style: TextStyle(fontSize: 9, color: colors.onSurfaceVariant),
              ),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 18,
                interval: xInterval,
                getTitlesWidget: (double value, TitleMeta meta) {
                  if (value == meta.min || value == meta.max) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    value.toStringAsFixed(0),
                    style: TextStyle(
                        fontSize: 9, color: colors.onSurfaceVariant),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: <LineChartBarData>[
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.25,
              color: colors.primary,
              barWidth: 2,
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _PotentiometerGeometryDiagram extends StatelessWidget {
  const _PotentiometerGeometryDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PotentiometerGeometryPainter(Theme.of(context).colorScheme),
      child: const SizedBox.expand(),
    );
  }
}

class _PotentiometerGeometryPainter extends CustomPainter {
  const _PotentiometerGeometryPainter(this.colors);

  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint linePaint = Paint()
      ..color = colors.onSurfaceVariant
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final Paint accentPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final Paint dotPaint = Paint()..color = colors.primary;

    final Offset vertexA = Offset(size.width * 0.15, size.height * 0.2);
    final Offset vertexC = Offset(size.width * 0.85, size.height * 0.2);
    final Offset vertexB = Offset(size.width * 0.5, size.height * 0.85);

    canvas.drawLine(vertexA, vertexB, linePaint);
    canvas.drawLine(vertexB, vertexC, linePaint);
    canvas.drawLine(vertexA, vertexC, linePaint);

    final Offset sideAMid = Offset.lerp(vertexA, vertexB, 0.55)!;
    final Offset sideCMid = Offset.lerp(vertexB, vertexC, 0.55)!;
    final Offset sideBMid = Offset.lerp(vertexA, vertexC, 0.5)!;

    const double arcRadius = 30;
    final Rect arcRect = Rect.fromCircle(center: vertexB, radius: arcRadius);
    canvas.drawArc(arcRect, -2.3, 1.3, false, accentPaint);
    canvas.drawCircle(vertexB, 4, dotPaint);

    final TextStyle labelStyle = TextStyle(fontSize: 12, color: colors.onSurface);
    _drawText(canvas, 'Side A', sideAMid + const Offset(-24, 0), labelStyle);
    _drawText(canvas, 'Side C', sideCMid + const Offset(8, 0), labelStyle);
    _drawText(canvas, 'Side B', sideBMid + const Offset(-20, -18), labelStyle);
    _drawText(canvas, 'Angle B', vertexB + const Offset(-24, 20), labelStyle);
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final TextSpan span = TextSpan(text: text, style: style);
    final TextPainter tp = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
