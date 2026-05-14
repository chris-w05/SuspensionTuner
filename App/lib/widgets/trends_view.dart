import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import 'chart_utils.dart';
import 'spot_builders.dart';

class TrendsView extends StatefulWidget {
  const TrendsView({
    super.key,
    required this.result,
    required this.globalMinPosMm,
    required this.globalMaxPosMm,
    required this.globalMinVelMmPerSecond,
    required this.globalMaxVelMmPerSecond,
  });

  final AnalysisResult result;
  final double globalMinPosMm;
  final double globalMaxPosMm;
  final double globalMinVelMmPerSecond;
  final double globalMaxVelMmPerSecond;

  @override
  State<TrendsView> createState() => _TrendsViewState();
}

class _TrendsViewState extends State<TrendsView> {
  bool _isInteractingScatter = false;
  final Map<String, List<double?>> _scatterViewBounds =
      <String, List<double?>>{};
  final Map<String, List<ScatterSpot>> _scatterSpotCache =
      <String, List<ScatterSpot>>{};
  final Map<String, List<double>> _distributionCache =
      <String, List<double>>{};

  // Gesture tracking (not setState-driven)
  double _scatGestStartMinX = 0;
  double _scatGestStartMaxX = 0;
  double _scatGestStartMinY = 0;
  double _scatGestStartMaxY = 0;
  double _scatGestFocalFracX = 0.5;
  double _scatGestFocalFracY = 0.5;

  int get _scatterRenderBudget => _isInteractingScatter ? 1200 : 6500;

  @override
  void didUpdateWidget(covariant TrendsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _scatterSpotCache.clear();
      _distributionCache.clear();
      _scatterViewBounds.clear();
    }
  }

  List<ScatterSpot> _getOrBuildScatterSpots(
    String key,
    int budget,
    List<ScatterSpot> Function(int maxPoints) builder,
  ) {
    final String cacheKey = '$key|$budget';
    return _scatterSpotCache.putIfAbsent(cacheKey, () => builder(budget));
  }

  List<double> _getOrBuildDistributionValues(
    String key,
    List<double> Function() builder,
  ) {
    return _distributionCache.putIfAbsent(key, builder);
  }

  Widget _wrapWithScatterZoom({
    required String chartId,
    required double fullMinX,
    required double fullMaxX,
    required double fullMinY,
    required double fullMaxY,
    required double chartHeight,
    double leftReserved = 54.0,
    double bottomReserved = 40.0,
    required Widget Function(double minX, double maxX, double minY, double maxY)
        builder,
  }) {
    final List<double?> b =
        _scatterViewBounds[chartId] ?? const <double?>[null, null, null, null];
    final double vMinX = b[0] ?? fullMinX;
    final double vMaxX = b[1] ?? fullMaxX;
    final double vMinY = b[2] ?? fullMinY;
    final double vMaxY = b[3] ?? fullMaxY;

    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints bc) {
        const double kRightPad = 10.0;
        const double kTopPad = 10.0;
        final double plotW =
            (bc.maxWidth - leftReserved - kRightPad).clamp(1.0, double.infinity);
        final double plotH =
            (chartHeight - kTopPad - bottomReserved).clamp(1.0, double.infinity);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (ScaleStartDetails d) {
            if (!_isInteractingScatter) {
              setState(() {
                _isInteractingScatter = true;
              });
            }
            final List<double?> bb = _scatterViewBounds[chartId] ??
                const <double?>[null, null, null, null];
            _scatGestStartMinX = bb[0] ?? fullMinX;
            _scatGestStartMaxX = bb[1] ?? fullMaxX;
            _scatGestStartMinY = bb[2] ?? fullMinY;
            _scatGestStartMaxY = bb[3] ?? fullMaxY;
            _scatGestFocalFracX =
                ((d.localFocalPoint.dx - leftReserved) / plotW).clamp(0.0, 1.0);
            _scatGestFocalFracY =
                ((d.localFocalPoint.dy - kTopPad) / plotH).clamp(0.0, 1.0);
          },
          onScaleUpdate: (ScaleUpdateDetails d) {
            final double xRange = _scatGestStartMaxX - _scatGestStartMinX;
            final double yRange = _scatGestStartMaxY - _scatGestStartMinY;
            final double fullXRange = fullMaxX - fullMinX;
            final double fullYRange = fullMaxY - fullMinY;
            final double newXRange =
                (xRange / d.scale).clamp(fullXRange * 0.02, fullXRange * 4);
            final double newYRange =
                (yRange / d.scale).clamp(fullYRange * 0.02, fullYRange * 4);

            final double focalDataX =
                _scatGestStartMinX + _scatGestFocalFracX * xRange;
            final double focalDataY =
                _scatGestStartMaxY - _scatGestFocalFracY * yRange;

            final double curFracX =
                ((d.localFocalPoint.dx - leftReserved) / plotW).clamp(0.0, 1.0);
            final double curFracY =
                ((d.localFocalPoint.dy - kTopPad) / plotH).clamp(0.0, 1.0);

            final double newMinX = focalDataX - curFracX * newXRange;
            final double newMaxX = newMinX + newXRange;
            final double newMaxY = focalDataY + curFracY * newYRange;
            final double newMinY = newMaxY - newYRange;

            setState(() {
              _scatterViewBounds[chartId] = <double?>[
                newMinX, newMaxX, newMinY, newMaxY,
              ];
            });
          },
          onScaleEnd: (_) {
            if (_isInteractingScatter) {
              setState(() {
                _isInteractingScatter = false;
              });
            }
          },
          onDoubleTap: () {
            setState(() {
              _scatterViewBounds.remove(chartId);
            });
          },
          child: builder(vMinX, vMaxX, vMinY, vMaxY),
        );
      },
    );
  }

  Widget _buildOverlaidDistributionChart({
    required List<double> frontValues,
    required List<double> rearValues,
    required String unit,
    required String title,
    int bins = 150,
    int smoothRadius = 5,
  }) {
    if (frontValues.isEmpty && rearValues.isEmpty) return const SizedBox.shrink();

    final List<double> allValues = <double>[...frontValues, ...rearValues];
    final double minV = allValues.reduce(math.min);
    final double maxV = allValues.reduce(math.max);
    if (maxV <= minV) return const SizedBox.shrink();

    final double binWidth = (maxV - minV) / bins;

    List<FlSpot> buildSpots(List<double> values) {
      if (values.isEmpty) return <FlSpot>[];
      final List<int> counts = List<int>.filled(bins, 0);
      for (final double v in values) {
        final int bin = ((v - minV) / binWidth).floor().clamp(0, bins - 1);
        counts[bin]++;
      }
      final double total = values.length.toDouble();
      final List<double> smoothed = List<double>.filled(bins, 0);
      for (int i = 0; i < bins; i++) {
        double weightSum = 0;
        double valSum = 0;
        for (int j = -smoothRadius; j <= smoothRadius; j++) {
          final int idx = i + j;
          if (idx < 0 || idx >= bins) continue;
          final double w = math.exp(-(j * j) / (2.0 * smoothRadius * smoothRadius / 4.0));
          valSum += counts[idx] * w;
          weightSum += w;
        }
        smoothed[i] = weightSum > 0 ? valSum / weightSum / total * 100 : 0;
      }
      return List<FlSpot>.generate(
        bins,
        (int i) => FlSpot(minV + (i + 0.5) * binWidth, smoothed[i]),
      );
    }

    final List<FlSpot> frontSpots = buildSpots(frontValues);
    final List<FlSpot> rearSpots = buildSpots(rearValues);

    final double maxY = <FlSpot>[...frontSpots, ...rearSpots]
        .map((FlSpot s) => s.y)
        .fold(0.0, math.max);

    final Color frontColor = ChartUtils.channelColor(PotentiometerChannel.front);
    final Color rearColor = ChartUtils.channelColor(PotentiometerChannel.rear);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: LineChart(
            LineChartData(
              lineBarsData: <LineChartBarData>[
                if (frontSpots.isNotEmpty)
                  LineChartBarData(
                    spots: frontSpots,
                    color: frontColor,
                    barWidth: 2,
                    isCurved: true,
                    curveSmoothness: 0.25,
                    dotData: const FlDotData(show: false),
                  ),
                if (rearSpots.isNotEmpty)
                  LineChartBarData(
                    spots: rearSpots,
                    color: rearColor,
                    barWidth: 2,
                    isCurved: true,
                    curveSmoothness: 0.25,
                    dotData: const FlDotData(show: false),
                  ),
              ],
              minX: minV,
              maxX: maxV,
              minY: 0,
              maxY: maxY * 1.15,
              lineTouchData: const LineTouchData(enabled: false),
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(
                  show: true, border: Border.all(color: Colors.black54)),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                  axisNameWidget: Text('%'),
                  sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: Text(unit),
                  sideTitles: const SideTitles(showTitles: true),
                ),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            if (frontSpots.isNotEmpty) ...<Widget>[
              Container(width: 16, height: 2, color: frontColor),
              const SizedBox(width: 4),
              const Text('Front', style: TextStyle(fontSize: 11)),
            ],
            if (frontSpots.isNotEmpty && rearSpots.isNotEmpty)
              const SizedBox(width: 12),
            if (rearSpots.isNotEmpty) ...<Widget>[
              Container(width: 16, height: 2, color: rearColor),
              const SizedBox(width: 4),
              const Text('Rear', style: TextStyle(fontSize: 11)),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AnalysisResult result = widget.result;
    final ChannelResult? frontResult =
        result.channelResults[PotentiometerChannel.front];
    final ChannelResult? rearResult =
        result.channelResults[PotentiometerChannel.rear];
    final bool hasBoth = frontResult != null && rearResult != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasBoth) ...<Widget>[
            Text('Rear vs Front Position',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _wrapWithScatterZoom(
              chartId: 'pos',
              fullMinX: frontResult.minPositionMillimeters - 1,
              fullMaxX: frontResult.maxPositionMillimeters + 1,
              fullMinY: rearResult.minPositionMillimeters - 1,
              fullMaxY: rearResult.maxPositionMillimeters + 1,
              chartHeight: 320,
              leftReserved: 48,
              builder: (double minX, double maxX, double minY, double maxY) =>
                  SizedBox(
                height: 320,
                child: ScatterChart(ScatterChartData(
                  clipData: FlClipData.all(),
                  scatterTouchData: ChartUtils.highContrastScatterTouchData(),
                  minX: minX,
                  maxX: maxX,
                  minY: minY,
                  maxY: maxY,
                  scatterSpots: _getOrBuildScatterSpots(
                    'trends:front_rear_pos',
                    _scatterRenderBudget,
                    (int maxPoints) => SpotBuilders.frontVsRearPositionSpots(
                        result, maxPoints: maxPoints),
                  ),
                  gridData: const FlGridData(show: true),
                  borderData: FlBorderData(
                      show: true, border: Border.all(color: Colors.black54)),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                      axisNameWidget: Text('Rear (mm)'),
                      sideTitles: SideTitles(showTitles: true, reservedSize: 48),
                    ),
                    bottomTitles: const AxisTitles(
                      axisNameWidget: Text('Front (mm)'),
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                )),
              ),
            ),
            const SizedBox(height: 24),
            _buildOverlaidDistributionChart(
              frontValues: _getOrBuildDistributionValues(
                'dist:front:pos_mm',
                () => frontResult.positionTimePoints
                    .map((PositionTimePoint p) => p.positionMillimeters)
                    .toList(growable: false),
              ),
              rearValues: _getOrBuildDistributionValues(
                'dist:rear:pos_mm',
                () => rearResult.positionTimePoints
                    .map((PositionTimePoint p) => p.positionMillimeters)
                    .toList(growable: false),
              ),
              unit: 'mm',
              title: 'Position Distribution',
            ),
            const SizedBox(height: 24),
            Text('Rear vs Front Velocity',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _wrapWithScatterZoom(
              chartId: 'vel',
              fullMinX: frontResult.minVelocityMillimetersPerSecond - 5,
              fullMaxX: frontResult.maxVelocityMillimetersPerSecond + 5,
              fullMinY: rearResult.minVelocityMillimetersPerSecond - 5,
              fullMaxY: rearResult.maxVelocityMillimetersPerSecond + 5,
              chartHeight: 320,
              builder: (double minX, double maxX, double minY, double maxY) =>
                  SizedBox(
                height: 320,
                child: ScatterChart(ScatterChartData(
                  clipData: FlClipData.all(),
                  scatterTouchData: ChartUtils.highContrastScatterTouchData(),
                  minX: minX,
                  maxX: maxX,
                  minY: minY,
                  maxY: maxY,
                  scatterSpots: _getOrBuildScatterSpots(
                    'trends:front_rear_vel',
                    _scatterRenderBudget,
                    (int maxPoints) => SpotBuilders.frontVsRearVelocitySpots(
                        result, maxPoints: maxPoints),
                  ),
                  gridData: const FlGridData(show: true),
                  borderData: FlBorderData(
                      show: true, border: Border.all(color: Colors.black54)),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                      axisNameWidget: Text('Rear (mm/s)'),
                      sideTitles: SideTitles(showTitles: true, reservedSize: 54),
                    ),
                    bottomTitles: const AxisTitles(
                      axisNameWidget: Text('Front (mm/s)'),
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                )),
              ),
            ),
            const SizedBox(height: 24),
            _buildOverlaidDistributionChart(
              frontValues: _getOrBuildDistributionValues(
                'dist:front:vel_mms',
                () => frontResult.velocityPoints
                    .map((PositionVelocityPoint p) =>
                        p.velocityMillimetersPerSecond)
                    .toList(growable: false),
              ),
              rearValues: _getOrBuildDistributionValues(
                'dist:rear:vel_mms',
                () => rearResult.velocityPoints
                    .map((PositionVelocityPoint p) =>
                        p.velocityMillimetersPerSecond)
                    .toList(growable: false),
              ),
              unit: 'mm/s',
              title: 'Velocity Distribution',
            ),
            const SizedBox(height: 24),
          ],
          Text('Position vs Velocity (both wheels)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _wrapWithScatterZoom(
            chartId: 'pv',
            fullMinX: math.max(0, widget.globalMinPosMm - 1),
            fullMaxX: widget.globalMaxPosMm + 1,
            fullMinY: widget.globalMinVelMmPerSecond - 5,
            fullMaxY: widget.globalMaxVelMmPerSecond + 5,
            chartHeight: 360,
            builder: (double minX, double maxX, double minY, double maxY) =>
                SizedBox(
              height: 360,
              child: ScatterChart(ScatterChartData(
                clipData: FlClipData.all(),
                scatterTouchData: ChartUtils.highContrastScatterTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                scatterSpots: _getOrBuildScatterSpots(
                  'trends:all_pv',
                  _scatterRenderBudget,
                  (int maxPoints) => SpotBuilders.allVelocityPositionSpots(
                      result, maxPointsPerChannel: maxPoints),
                ),
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(
                    axisNameWidget: Text('Velocity (mm/s)'),
                    sideTitles: SideTitles(showTitles: true, reservedSize: 54),
                  ),
                  bottomTitles: const AxisTitles(
                    axisNameWidget: Text('Position (mm)'),
                    sideTitles: SideTitles(showTitles: true),
                  ),
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
              )),
            ),
          ),
        ],
      ),
    );
  }
}
