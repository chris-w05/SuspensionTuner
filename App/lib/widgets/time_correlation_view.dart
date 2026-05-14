import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import 'chart_utils.dart';
import 'spot_builders.dart';

class TimeCorrelationView extends StatefulWidget {
  const TimeCorrelationView({
    super.key,
    required this.result,
    required this.timeMax,
    required this.timeChartOrder,
    required this.viewMinX,
    required this.viewMaxX,
    required this.onZoomChanged,
    required this.onChartOrderChanged,
  });

  final AnalysisResult result;
  final double timeMax;
  final List<String> timeChartOrder;
  final double? viewMinX;
  final double? viewMaxX;
  final void Function(double? minX, double? maxX) onZoomChanged;
  final void Function(List<String> newOrder) onChartOrderChanged;

  @override
  State<TimeCorrelationView> createState() => _TimeCorrelationViewState();
}

class _TimeCorrelationViewState extends State<TimeCorrelationView> {
  bool _isInteractingTime = false;
  final Map<String, List<FlSpot>> _lineSpotCache = <String, List<FlSpot>>{};

  // Gesture tracking (not setState-driven)
  double _gestureStartMin = 0;
  double _gestureStartMax = 0;
  double _gestureStartFocalFraction = 0.5;

  int get _lineRenderBudget => _isInteractingTime ? 650 : 2200;

  @override
  void didUpdateWidget(covariant TimeCorrelationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _lineSpotCache.clear();
    }
  }

  List<FlSpot> _getOrBuildLineSpots(
    String key,
    int budget,
    List<FlSpot> Function(int maxPoints) builder,
  ) {
    final String cacheKey = '$key|$budget';
    return _lineSpotCache.putIfAbsent(cacheKey, () => builder(budget));
  }

  static bool _hasDataForId(AnalysisResult result, String id) {
    switch (id) {
      case 'front_pos':
        return result.channelResults[PotentiometerChannel.front]
                ?.positionTimePoints.isNotEmpty ??
            false;
      case 'rear_pos':
        return result.channelResults[PotentiometerChannel.rear]
                ?.positionTimePoints.isNotEmpty ??
            false;
      case 'accel':
        return result.accelerationTimePoints.isNotEmpty;
      case 'pitch':
      case 'roll':
        return result.attitudeTimePoints.isNotEmpty;
      default:
        return false;
    }
  }

  Widget _wrapWithTimeZoom({
    required Widget child,
    required double fullTimeMax,
  }) {
    const double kLeftReserved = 54.0;
    const double kRightPad = 10.0;

    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints bc) {
        final double plotW =
            (bc.maxWidth - kLeftReserved - kRightPad).clamp(1.0, double.infinity);

        void applyPan(double pixelDx) {
          final double currentMin = widget.viewMinX ?? 0;
          final double currentMax = widget.viewMaxX ?? fullTimeMax;
          final double currentRange = currentMax - currentMin;
          final double dataDelta = (pixelDx / plotW) * currentRange;
          double newMin = currentMin + dataDelta;
          double newMax = newMin + currentRange;
          if (newMin < 0) {
            newMin = 0;
            newMax = currentRange;
          }
          if (newMax > fullTimeMax) {
            newMax = fullTimeMax;
            newMin = newMax - currentRange > 0 ? newMax - currentRange : 0;
          }
          widget.onZoomChanged(newMin, newMax);
        }

        return Listener(
          onPointerSignal: (PointerSignalEvent event) {
            if (event is PointerScrollEvent) {
              final double absDx = event.scrollDelta.dx.abs();
              final double absDy = event.scrollDelta.dy.abs();
              if (absDx > absDy + 1.0) {
                GestureBinding.instance.pointerSignalResolver
                    .register(event, (PointerSignalEvent e) {
                  if (e is PointerScrollEvent) applyPan(e.scrollDelta.dx);
                });
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (ScaleStartDetails d) {
              if (!_isInteractingTime) {
                setState(() {
                  _isInteractingTime = true;
                });
              }
              _gestureStartMin = widget.viewMinX ?? 0;
              _gestureStartMax = widget.viewMaxX ?? fullTimeMax;
              _gestureStartFocalFraction =
                  ((d.localFocalPoint.dx - kLeftReserved) / plotW)
                      .clamp(0.0, 1.0);
            },
            onScaleUpdate: (ScaleUpdateDetails d) {
              final double startRange = _gestureStartMax - _gestureStartMin;
              final double newRange =
                  (startRange / d.scale).clamp(0.2, fullTimeMax);

              final double focalData =
                  _gestureStartMin + _gestureStartFocalFraction * startRange;

              final double currentFrac =
                  ((d.localFocalPoint.dx - kLeftReserved) / plotW)
                      .clamp(0.0, 1.0);

              double newMin = focalData - currentFrac * newRange;
              double newMax = newMin + newRange;

              if (newMin < 0) {
                newMin = 0;
                newMax = newRange;
              }
              if (newMax > fullTimeMax) {
                newMax = fullTimeMax;
                newMin = (fullTimeMax - newRange).clamp(0.0, double.infinity);
              }

              widget.onZoomChanged(newMin, newMax);
            },
            onScaleEnd: (_) {
              if (_isInteractingTime) {
                setState(() {
                  _isInteractingTime = false;
                });
              }
            },
            onDoubleTap: () {
              widget.onZoomChanged(null, null);
            },
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AnalysisResult result = widget.result;
    final double timeMax = widget.timeMax;
    const double kLeftReserved = 54.0;
    const double kChartHeight = 200.0;

    final double viewMinX = widget.viewMinX ?? 0;
    final double viewMaxX = widget.viewMaxX ?? timeMax;

    FlTitlesData makeTitles({required String yLabel}) {
      return FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: Text(yLabel),
          sideTitles:
              const SideTitles(showTitles: true, reservedSize: kLeftReserved),
        ),
        bottomTitles: const AxisTitles(
          axisNameWidget: Text('s'),
          sideTitles: SideTitles(showTitles: true, reservedSize: 22),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      );
    }

    Widget? buildContent(String id) {
      switch (id) {
        case 'front_pos':
          final ChannelResult? cr =
              result.channelResults[PotentiometerChannel.front];
          if (cr == null || cr.positionTimePoints.isEmpty) return null;
          return _wrapWithTimeZoom(
            fullTimeMax: timeMax,
            child: SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: viewMinX,
                maxX: viewMaxX,
                minY: cr.minPositionMillimeters - 2,
                maxY: cr.maxPositionMillimeters + 2,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(
                    spots: _getOrBuildLineSpots(
                      'time:front_pos',
                      _lineRenderBudget,
                      (int maxPoints) =>
                          SpotBuilders.positionSpotsMm(cr, maxPoints: maxPoints),
                    ),
                    isCurved: false,
                    color: ChartUtils.channelColor(PotentiometerChannel.front),
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(yLabel: 'mm'),
              )),
            ),
          );

        case 'rear_pos':
          final ChannelResult? cr =
              result.channelResults[PotentiometerChannel.rear];
          if (cr == null || cr.positionTimePoints.isEmpty) return null;
          return _wrapWithTimeZoom(
            fullTimeMax: timeMax,
            child: SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: viewMinX,
                maxX: viewMaxX,
                minY: cr.minPositionMillimeters - 2,
                maxY: cr.maxPositionMillimeters + 2,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(
                    spots: _getOrBuildLineSpots(
                      'time:rear_pos',
                      _lineRenderBudget,
                      (int maxPoints) =>
                          SpotBuilders.positionSpotsMm(cr, maxPoints: maxPoints),
                    ),
                    isCurved: false,
                    color: ChartUtils.channelColor(PotentiometerChannel.rear),
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(yLabel: 'mm'),
              )),
            ),
          );

        case 'accel':
          if (result.accelerationTimePoints.isEmpty) return null;
          double accelMin = double.infinity;
          double accelMax = double.negativeInfinity;
          for (final AccelerationTimePoint p in result.accelerationTimePoints) {
            final double lo = p.accelXG < p.accelYG
                ? (p.accelXG < p.accelZG
                    ? (p.accelXG < p.accelAbsoluteG ? p.accelXG : p.accelAbsoluteG)
                    : (p.accelZG < p.accelAbsoluteG ? p.accelZG : p.accelAbsoluteG))
                : (p.accelYG < p.accelZG
                    ? (p.accelYG < p.accelAbsoluteG ? p.accelYG : p.accelAbsoluteG)
                    : (p.accelZG < p.accelAbsoluteG ? p.accelZG : p.accelAbsoluteG));
            final double hi = p.accelXG > p.accelYG
                ? (p.accelXG > p.accelZG
                    ? (p.accelXG > p.accelAbsoluteG ? p.accelXG : p.accelAbsoluteG)
                    : (p.accelZG > p.accelAbsoluteG ? p.accelZG : p.accelAbsoluteG))
                : (p.accelYG > p.accelZG
                    ? (p.accelYG > p.accelAbsoluteG ? p.accelYG : p.accelAbsoluteG)
                    : (p.accelZG > p.accelAbsoluteG ? p.accelZG : p.accelAbsoluteG));
            if (lo < accelMin) accelMin = lo;
            if (hi > accelMax) accelMax = hi;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ChartUtils.accelLegendDot(Colors.red.shade600, 'X'),
                  const SizedBox(width: 12),
                  ChartUtils.accelLegendDot(Colors.green.shade700, 'Y'),
                  const SizedBox(width: 12),
                  ChartUtils.accelLegendDot(Colors.blue.shade700, 'Z'),
                  const SizedBox(width: 12),
                  ChartUtils.accelLegendDot(Colors.grey.shade800, 'Abs'),
                ],
              ),
              const SizedBox(height: 4),
              _wrapWithTimeZoom(
                fullTimeMax: timeMax,
                child: SizedBox(
                  height: kChartHeight,
                  child: LineChart(LineChartData(
                    clipData: FlClipData.all(),
                    lineTouchData: ChartUtils.highContrastLineTouchData(),
                    minX: viewMinX,
                    maxX: viewMaxX,
                    minY: accelMin - 0.05,
                    maxY: accelMax + 0.05,
                    lineBarsData: <LineChartBarData>[
                      LineChartBarData(
                        spots: _getOrBuildLineSpots(
                          'time:accel_x',
                          _lineRenderBudget,
                          (int maxPoints) => SpotBuilders.accelSpots(
                            result.accelerationTimePoints,
                            (AccelerationTimePoint p) => p.accelXG,
                            maxPoints: maxPoints,
                          ),
                        ),
                        isCurved: false,
                        color: Colors.red.shade600,
                        barWidth: 1.5,
                        dotData: const FlDotData(show: false),
                      ),
                      LineChartBarData(
                        spots: _getOrBuildLineSpots(
                          'time:accel_y',
                          _lineRenderBudget,
                          (int maxPoints) => SpotBuilders.accelSpots(
                            result.accelerationTimePoints,
                            (AccelerationTimePoint p) => p.accelYG,
                            maxPoints: maxPoints,
                          ),
                        ),
                        isCurved: false,
                        color: Colors.green.shade700,
                        barWidth: 1.5,
                        dotData: const FlDotData(show: false),
                      ),
                      LineChartBarData(
                        spots: _getOrBuildLineSpots(
                          'time:accel_z',
                          _lineRenderBudget,
                          (int maxPoints) => SpotBuilders.accelSpots(
                            result.accelerationTimePoints,
                            (AccelerationTimePoint p) => p.accelZG,
                            maxPoints: maxPoints,
                          ),
                        ),
                        isCurved: false,
                        color: Colors.blue.shade700,
                        barWidth: 1.5,
                        dotData: const FlDotData(show: false),
                      ),
                      LineChartBarData(
                        spots: _getOrBuildLineSpots(
                          'time:accel_abs',
                          _lineRenderBudget,
                          (int maxPoints) => SpotBuilders.accelSpots(
                            result.accelerationTimePoints,
                            (AccelerationTimePoint p) => p.accelAbsoluteG,
                            maxPoints: maxPoints,
                          ),
                        ),
                        isCurved: false,
                        color: Colors.grey.shade800,
                        barWidth: 2,
                        dotData: const FlDotData(show: false),
                        dashArray: <int>[6, 3],
                      ),
                    ],
                    gridData: const FlGridData(show: true),
                    borderData: FlBorderData(
                        show: true, border: Border.all(color: Colors.black54)),
                    titlesData: makeTitles(yLabel: 'g'),
                  )),
                ),
              ),
            ],
          );

        case 'pitch':
          if (result.attitudeTimePoints.isEmpty) return null;
          double pitchMin = double.infinity;
          double pitchMax = double.negativeInfinity;
          for (final AttitudeTimePoint p in result.attitudeTimePoints) {
            if (p.pitchDegrees < pitchMin) pitchMin = p.pitchDegrees;
            if (p.pitchDegrees > pitchMax) pitchMax = p.pitchDegrees;
          }
          return _wrapWithTimeZoom(
            fullTimeMax: timeMax,
            child: SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: viewMinX,
                maxX: viewMaxX,
                minY: pitchMin - 2,
                maxY: pitchMax + 2,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(
                    spots: _getOrBuildLineSpots(
                      'time:pitch',
                      _lineRenderBudget,
                      (int maxPoints) => SpotBuilders.attitudeSpots(
                        result.attitudeTimePoints,
                        (AttitudeTimePoint p) => p.pitchDegrees,
                        maxPoints: maxPoints,
                      ),
                    ),
                    isCurved: false,
                    color: Colors.teal.shade700,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(yLabel: 'deg'),
              )),
            ),
          );

        case 'roll':
          if (result.attitudeTimePoints.isEmpty) return null;
          double rollMin = double.infinity;
          double rollMax = double.negativeInfinity;
          for (final AttitudeTimePoint p in result.attitudeTimePoints) {
            if (p.leanDegrees < rollMin) rollMin = p.leanDegrees;
            if (p.leanDegrees > rollMax) rollMax = p.leanDegrees;
          }
          return _wrapWithTimeZoom(
            fullTimeMax: timeMax,
            child: SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: viewMinX,
                maxX: viewMaxX,
                minY: rollMin - 2,
                maxY: rollMax + 2,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(
                    spots: _getOrBuildLineSpots(
                      'time:roll',
                      _lineRenderBudget,
                      (int maxPoints) => SpotBuilders.attitudeSpots(
                        result.attitudeTimePoints,
                        (AttitudeTimePoint p) => p.leanDegrees,
                        maxPoints: maxPoints,
                      ),
                    ),
                    isCurved: false,
                    color: Colors.purple.shade700,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(yLabel: 'deg'),
              )),
            ),
          );

        default:
          return null;
      }
    }

    const Map<String, String> kTitles = <String, String>{
      'front_pos': 'Front Position',
      'rear_pos': 'Rear Position',
      'accel': 'Acceleration',
      'pitch': 'Bike Pitch',
      'roll': 'Bike Roll',
    };

    final List<String> visibleIds = widget.timeChartOrder
        .where((String id) => _hasDataForId(result, id))
        .toList();

    final List<Widget> chartCards = <Widget>[];
    for (int i = 0; i < visibleIds.length; i++) {
      final String id = visibleIds[i];
      final Widget? content = buildContent(id);
      if (content == null) continue;
      chartCards.add(Card(
        key: ValueKey<String>(id),
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.only(top: 4, right: 6, left: 4),
                  child: Icon(Icons.drag_handle, color: Colors.grey),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      kTitles[id] ?? id,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    content,
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Drag to reorder  \u2022  Pinch or scroll to zoom  \u2022  Double-tap to reset zoom',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              if (widget.viewMinX != null || widget.viewMaxX != null)
                TextButton.icon(
                  onPressed: () => widget.onZoomChanged(null, null),
                  icon: const Icon(Icons.zoom_out_map, size: 16),
                  label: const Text('Reset zoom'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: (int oldIndex, int newIndex) {
              if (newIndex > oldIndex) newIndex--;
              final List<String> visible = widget.timeChartOrder
                  .where((String id) => _hasDataForId(result, id))
                  .toList();
              if (oldIndex < visible.length && newIndex < visible.length) {
                final String moved = visible.removeAt(oldIndex);
                visible.insert(newIndex, moved);
                final List<String> hidden = widget.timeChartOrder
                    .where((String id) => !visible.contains(id))
                    .toList();
                widget.onChartOrderChanged(<String>[...visible, ...hidden]);
              }
            },
            children: chartCards,
          ),
        ],
      ),
    );
  }
}
