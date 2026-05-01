import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../services/daq_parser_service.dart';

class AnalysisTab extends StatefulWidget {
  const AnalysisTab({
    super.key,
    required this.profiles,
  });

  final List<CalibrationProfile> profiles;

  @override
  State<AnalysisTab> createState() => _AnalysisTabState();
}

class _AnalysisTabState extends State<AnalysisTab>
    with SingleTickerProviderStateMixin {
  final DaqParserService _parser = DaqParserService();

  CalibrationProfile? _selectedProfile;
  AnalysisResult? _analysisResult;
  String? _selectedFileName;
  bool _isParsing = false;

  late TabController _graphTabController;
  List<String> _timeChartOrder = <String>[
    'front_pos',
    'rear_pos',
    'accel',
    'pitch',
    'roll',
  ];

  // Synchronized time-axis zoom (null = full range)
  double? _timeViewMinX;
  double? _timeViewMaxX;
  // Gesture-tracking fields (not setState-driven)
  double _tcGestureStartMin = 0;
  double _tcGestureStartMax = 0;
  double _tcGestureStartFocalFraction = 0.5;
  double _tcLastChartWidth = 300;

  // Scatter chart view bounds: chartId -> [minX, maxX, minY, maxY]
  final Map<String, List<double?>> _scatterViewBounds = <String, List<double?>>{};
  // Scatter gesture tracking (shared — only one chart touched at a time)
  double _scatGestStartMinX = 0;
  double _scatGestStartMaxX = 0;
  double _scatGestStartMinY = 0;
  double _scatGestStartMaxY = 0;
  double _scatGestFocalFracX = 0.5;
  double _scatGestFocalFracY = 0.5;

  @override
  void initState() {
    super.initState();
    _graphTabController = TabController(length: 3, vsync: this);
    if (widget.profiles.isNotEmpty) {
      _selectedProfile = widget.profiles.first;
    }
  }

  @override
  void dispose() {
    _graphTabController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AnalysisTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.profiles.isEmpty) {
      _selectedProfile = null;
      return;
    }

    if (_selectedProfile == null ||
        widget.profiles.every((CalibrationProfile p) => p.id != _selectedProfile!.id)) {
      _selectedProfile = widget.profiles.first;
    }
  }


  Future<void> _pickAndAnalyzeFile() async {
    if (_selectedProfile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a calibration profile first.')),
      );
      return;
    }


    FilePickerResult? selection;
    try {
      selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['bin', 'dat', 'raw', 'daq'],
        withData: true,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $error')),
        );
      }
      return;
    }

    if (selection == null || selection.files.single.bytes == null) {
      return;
    }

    final String fileName = selection.files.single.name;
    final Uint8List fileBytes = selection.files.single.bytes!;

    setState(() {
      _isParsing = true;
      _selectedFileName = fileName;
    });

    try {
      final AnalysisResult result = await _parser.parsePositionVelocity(
        bytes: fileBytes,
        profile: _selectedProfile!,
        channels: _selectedProfile!.configuredChannels,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _analysisResult = result;
        _timeViewMinX = null;
        _timeViewMaxX = null;
        _scatterViewBounds.clear();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isParsing = false;
        });
      }
    }
  }

  static Color _channelColor(PotentiometerChannel channel) {
    return channel == PotentiometerChannel.front
        ? const Color(0xFFEF6C00)
        : const Color(0xFF1565C0);
  }

  List<ScatterSpot> _buildAllSpots(
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
      final Color color = _channelColor(entry.key);
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

  List<FlSpot> _buildScaledPositionSpots(
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
      // Internal Y domain is normalized to 0-100 so channels with different
      // travel overlay correctly; axis labels convert back to mm.
      final double scaledY = point.normalizedTravelPercent;
      spots.add(FlSpot(point.timeSeconds, scaledY));
    }
    return spots;
  }

  List<FlSpot> _buildAttitudeSpots(
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
    return spots;
  }

  double? _maxChannelTimeSeconds(AnalysisResult result) {
    double? maxTime;
    for (final ChannelResult channelResult in result.channelResults.values) {
      if (channelResult.positionTimePoints.isEmpty) {
        continue;
      }
      final double last = channelResult.positionTimePoints.last.timeSeconds;
      maxTime = maxTime == null ? last : math.max(maxTime, last);
    }
    return maxTime;
  }

  double? _maxAttitudeTimeSeconds(List<AttitudeTimePoint> points) {
    if (points.isEmpty) {
      return null;
    }
    return points.last.timeSeconds;
  }

  List<FlSpot> _buildAccelSpots(
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
    return spots;
  }

  // ── new cross-channel spot builders ────────────────────────────────────────

  /// Scatter: X = front position mm, Y = rear position mm (paired by index).
  List<ScatterSpot> _buildFrontVsRearPositionSpots(
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

  /// Scatter: X = front velocity mm/s, Y = rear velocity mm/s (paired by index).
  List<ScatterSpot> _buildFrontVsRearVelocitySpots(
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

  /// Actual mm values over time; used for individual time-correlation charts.
  List<FlSpot> _buildPositionSpotsMm(
    ChannelResult channelResult, {
    int maxPoints = 2500,
  }) {
    final List<PositionTimePoint> points = channelResult.positionTimePoints;
    if (points.isEmpty) return const <FlSpot>[];

    final int count = points.length;
    final int step = count > maxPoints ? (count / maxPoints).ceil() : 1;
    final List<FlSpot> spots = <FlSpot>[];
    for (int i = 0; i < count; i += step) {
      spots.add(FlSpot(points[i].timeSeconds, points[i].positionMillimeters));
    }
    return spots;
  }

  // ── distribution histogram panel ───────────────────────────────────────────

  Widget _buildDistributionPanel({
    required List<double> values,
    required Color color,
    required String label,
    required String unit,
    int bins = 25,
  }) {
    if (values.isEmpty) return const SizedBox.shrink();
    final double minV = values.reduce(math.min);
    final double maxV = values.reduce(math.max);
    if (maxV <= minV) return const SizedBox.shrink();

    final double binWidth = (maxV - minV) / bins;
    final List<int> counts = List<int>.filled(bins, 0);
    for (final double v in values) {
      final int bin = ((v - minV) / binWidth).floor().clamp(0, bins - 1);
      counts[bin]++;
    }
    final double maxCount = counts.reduce(math.max).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(
          height: 120,
          child: BarChart(
            BarChartData(
              barGroups: List<BarChartGroupData>.generate(
                bins,
                (int i) => BarChartGroupData(
                  x: i,
                  barRods: <BarChartRodData>[
                    BarChartRodData(
                      toY: counts[i].toDouble(),
                      color: color,
                      width: 5,
                      borderRadius: BorderRadius.zero,
                    ),
                  ],
                ),
              ),
              maxY: maxCount,
              barTouchData: BarTouchData(enabled: false),
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  axisNameWidget:
                      Text(unit, style: const TextStyle(fontSize: 10)),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 18,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final int idx = value.round();
                      if (idx != 0 && idx != bins ~/ 2 && idx != bins - 1) {
                        return const SizedBox.shrink();
                      }
                      final double val = minV + idx * binWidth;
                      return Text(
                        val.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 9),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── data-availability check ─────────────────────────────────────────────────

  bool _hasDataForId(AnalysisResult result, String id) {
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

  // ── synchronized time-axis zoom wrapper ─────────────────────────────────────

  /// Wraps [child] with synchronized time-axis zoom and pan.
  /// - Pinch/drag: zoom + pan (gesture)
  /// - Horizontal two-finger trackpad scroll: pan
  /// - Double-tap: reset to full range
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
          final double currentMin = _timeViewMinX ?? 0;
          final double currentMax = _timeViewMaxX ?? fullTimeMax;
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
            newMin = math.max(0, fullTimeMax - currentRange);
          }
          setState(() {
            _timeViewMinX = newMin;
            _timeViewMaxX = newMax;
          });
        }

        return Listener(
          onPointerSignal: (PointerSignalEvent event) {
            if (event is PointerScrollEvent) {
              final double absDx = event.scrollDelta.dx.abs();
              final double absDy = event.scrollDelta.dy.abs();
              // Claim only horizontal-dominant scroll so vertical scroll
              // still reaches the parent SingleChildScrollView.
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
              _tcGestureStartMin = _timeViewMinX ?? 0;
              _tcGestureStartMax = _timeViewMaxX ?? fullTimeMax;
              _tcLastChartWidth = bc.maxWidth;
              _tcGestureStartFocalFraction =
                  ((d.localFocalPoint.dx - kLeftReserved) / plotW).clamp(0.0, 1.0);
            },
            onScaleUpdate: (ScaleUpdateDetails d) {
              final double startRange = _tcGestureStartMax - _tcGestureStartMin;
              final double newRange =
                  (startRange / d.scale).clamp(0.2, fullTimeMax);

              // Focal data coordinate stays fixed under the finger.
              final double focalData =
                  _tcGestureStartMin + _tcGestureStartFocalFraction * startRange;

              final double currentFrac =
                  ((d.localFocalPoint.dx - kLeftReserved) / plotW).clamp(0.0, 1.0);

              double newMin = focalData - currentFrac * newRange;
              double newMax = newMin + newRange;

              if (newMin < 0) {
                newMin = 0;
                newMax = newRange;
              }
              if (newMax > fullTimeMax) {
                newMax = fullTimeMax;
                newMin = math.max(0, fullTimeMax - newRange);
              }

              setState(() {
                _timeViewMinX = newMin;
                _timeViewMaxX = newMax;
              });
            },
            onDoubleTap: () {
              setState(() {
                _timeViewMinX = null;
                _timeViewMaxX = null;
              });
            },
            child: child,
          ),
        );
      },
    );
  }

  // ── scatter chart 2-D zoom wrapper ─────────────────────────────────────────

  /// Wraps a scatter chart with pinch/drag 2-D zoom.
  /// [builder] receives the current axis bounds; [chartId] keys the zoom state.
  /// Double-tap resets to full range.
  Widget _wrapWithScatterZoom({
    required String chartId,
    required double fullMinX,
    required double fullMaxX,
    required double fullMinY,
    required double fullMaxY,
    required double chartHeight,
    double leftReserved = 54.0,
    double bottomReserved = 40.0,
    required Widget Function(
            double minX, double maxX, double minY, double maxY)
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

            // fl_chart: y=minY at bottom, y=maxY at top → screen Y inverted.
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

  // ── high-contrast tooltip helpers ───────────────────────────────────────────

  static LineTouchData _highContrastLineTouchData() => LineTouchData(
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

  static ScatterTouchData _highContrastScatterTouchData() => ScatterTouchData(
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

  // ── tab 1: Trends ───────────────────────────────────────────────────────────

  Widget _buildTrendsTab(
    AnalysisResult result, {
    required double globalMinPosMm,
    required double globalMaxPosMm,
    required double globalMinVelMmPerSecond,
    required double globalMaxVelMmPerSecond,
  }) {
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: _wrapWithScatterZoom(
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
                        scatterTouchData: _highContrastScatterTouchData(),
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        scatterSpots: _buildFrontVsRearPositionSpots(result),
                        gridData: const FlGridData(show: true),
                        borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.black54)),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                            axisNameWidget: Text('Rear (mm)'),
                            sideTitles:
                                SideTitles(showTitles: true, reservedSize: 48),
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
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: Column(
                    children: <Widget>[
                      _buildDistributionPanel(
                        values: frontResult.positionTimePoints
                            .map((PositionTimePoint p) =>
                                p.positionMillimeters)
                            .toList(),
                        color: _channelColor(PotentiometerChannel.front),
                        label: 'Front dist.',
                        unit: 'mm',
                      ),
                      const SizedBox(height: 8),
                      _buildDistributionPanel(
                        values: rearResult.positionTimePoints
                            .map((PositionTimePoint p) =>
                                p.positionMillimeters)
                            .toList(),
                        color: _channelColor(PotentiometerChannel.rear),
                        label: 'Rear dist.',
                        unit: 'mm',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Rear vs Front Velocity',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: _wrapWithScatterZoom(
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
                        scatterTouchData: _highContrastScatterTouchData(),
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        scatterSpots: _buildFrontVsRearVelocitySpots(result),
                        gridData: const FlGridData(show: true),
                        borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.black54)),
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                            axisNameWidget: Text('Rear (mm/s)'),
                            sideTitles:
                                SideTitles(showTitles: true, reservedSize: 54),
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
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: Column(
                    children: <Widget>[
                      _buildDistributionPanel(
                        values: frontResult.velocityPoints
                            .map((PositionVelocityPoint p) =>
                                p.velocityMillimetersPerSecond)
                            .toList(),
                        color: _channelColor(PotentiometerChannel.front),
                        label: 'Front vel. dist.',
                        unit: 'mm/s',
                      ),
                      const SizedBox(height: 8),
                      _buildDistributionPanel(
                        values: rearResult.velocityPoints
                            .map((PositionVelocityPoint p) =>
                                p.velocityMillimetersPerSecond)
                            .toList(),
                        color: _channelColor(PotentiometerChannel.rear),
                        label: 'Rear vel. dist.',
                        unit: 'mm/s',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          Text('Position vs Velocity (both wheels)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _wrapWithScatterZoom(
            chartId: 'pv',
            fullMinX: math.max(0, globalMinPosMm - 1),
            fullMaxX: globalMaxPosMm + 1,
            fullMinY: globalMinVelMmPerSecond - 5,
            fullMaxY: globalMaxVelMmPerSecond + 5,
            chartHeight: 360,
            builder: (double minX, double maxX, double minY, double maxY) =>
                SizedBox(
              height: 360,
              child: ScatterChart(ScatterChartData(
                        clipData: FlClipData.all(),
                        scatterTouchData: _highContrastScatterTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                scatterSpots: _buildAllSpots(result),
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(
                    axisNameWidget: Text('Velocity (mm/s)'),
                    sideTitles:
                        SideTitles(showTitles: true, reservedSize: 54),
                  ),
                  bottomTitles: const AxisTitles(
                    axisNameWidget: Text('Position (mm)'),
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
        ],
      ),
    );
  }

  // ── tab 2: Time Correlation ─────────────────────────────────────────────────

  Widget _buildTimeCorrelationTab(AnalysisResult result, double timeMax) {
    const double kLeftReserved = 54.0;
    const double kChartHeight = 200.0;

    final double viewMinX = _timeViewMinX ?? 0;
    final double viewMaxX = _timeViewMaxX ?? timeMax;

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
              lineTouchData: _highContrastLineTouchData(),
              minX: viewMinX,
              maxX: viewMaxX,
              minY: cr.minPositionMillimeters - 2,
              maxY: cr.maxPositionMillimeters + 2,
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: _buildPositionSpotsMm(cr),
                  isCurved: false,
                  color: _channelColor(PotentiometerChannel.front),
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
              lineTouchData: _highContrastLineTouchData(),
              minX: viewMinX,
              maxX: viewMaxX,
              minY: cr.minPositionMillimeters - 2,
              maxY: cr.maxPositionMillimeters + 2,
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: _buildPositionSpotsMm(cr),
                  isCurved: false,
                  color: _channelColor(PotentiometerChannel.rear),
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
            final double lo = math.min(p.accelXG,
                math.min(p.accelYG, math.min(p.accelZG, p.accelAbsoluteG)));
            final double hi = math.max(p.accelXG,
                math.max(p.accelYG, math.max(p.accelZG, p.accelAbsoluteG)));
            if (lo < accelMin) accelMin = lo;
            if (hi > accelMax) accelMax = hi;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _accelLegendDot(Colors.red.shade600, 'X'),
                  const SizedBox(width: 12),
                  _accelLegendDot(Colors.green.shade700, 'Y'),
                  const SizedBox(width: 12),
                  _accelLegendDot(Colors.blue.shade700, 'Z'),
                  const SizedBox(width: 12),
                  _accelLegendDot(Colors.grey.shade800, 'Abs'),
                ],
              ),
              const SizedBox(height: 4),
              _wrapWithTimeZoom(
                fullTimeMax: timeMax,
                child: SizedBox(
                height: kChartHeight,
                child: LineChart(LineChartData(
              clipData: FlClipData.all(),
              lineTouchData: _highContrastLineTouchData(),
                  minX: viewMinX,
                  maxX: viewMaxX,
                  minY: accelMin - 0.05,
                  maxY: accelMax + 0.05,
                  lineBarsData: <LineChartBarData>[
                    LineChartBarData(
                      spots: _buildAccelSpots(result.accelerationTimePoints,
                          (AccelerationTimePoint p) => p.accelXG),
                      isCurved: false,
                      color: Colors.red.shade600,
                      barWidth: 1.5,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _buildAccelSpots(result.accelerationTimePoints,
                          (AccelerationTimePoint p) => p.accelYG),
                      isCurved: false,
                      color: Colors.green.shade700,
                      barWidth: 1.5,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _buildAccelSpots(result.accelerationTimePoints,
                          (AccelerationTimePoint p) => p.accelZG),
                      isCurved: false,
                      color: Colors.blue.shade700,
                      barWidth: 1.5,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _buildAccelSpots(result.accelerationTimePoints,
                          (AccelerationTimePoint p) => p.accelAbsoluteG),
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
              lineTouchData: _highContrastLineTouchData(),
              minX: viewMinX,
              maxX: viewMaxX,
              minY: pitchMin - 2,
              maxY: pitchMax + 2,
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: _buildAttitudeSpots(result.attitudeTimePoints,
                      (AttitudeTimePoint p) => p.pitchDegrees),
                  isCurved: false,
                  color: Colors.teal.shade700,
                  barWidth: 1.5,
                  dotData: const FlDotData(show: false),
                ),
              ],
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(
                  show: true, border: Border.all(color: Colors.black54)),
              titlesData:
                  makeTitles(yLabel: 'deg'),
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
              lineTouchData: _highContrastLineTouchData(),
              minX: viewMinX,
              maxX: viewMaxX,
              minY: rollMin - 2,
              maxY: rollMax + 2,
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: _buildAttitudeSpots(result.attitudeTimePoints,
                      (AttitudeTimePoint p) => p.leanDegrees),
                  isCurved: false,
                  color: Colors.purple.shade700,
                  barWidth: 1.5,
                  dotData: const FlDotData(show: false),
                ),
              ],
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(
                  show: true, border: Border.all(color: Colors.black54)),
              titlesData:
                  makeTitles(yLabel: 'deg'),
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

    final List<String> visibleIds = _timeChartOrder
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
                  'Drag to reorder  •  Pinch or scroll to zoom  •  Double-tap to reset zoom',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              if (_timeViewMinX != null || _timeViewMaxX != null)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _timeViewMinX = null;
                    _timeViewMaxX = null;
                  }),
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
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final List<String> visible = _timeChartOrder
                    .where((String id) => _hasDataForId(result, id))
                    .toList();
                if (oldIndex < visible.length &&
                    newIndex < visible.length) {
                  final String moved = visible.removeAt(oldIndex);
                  visible.insert(newIndex, moved);
                  final List<String> hidden = _timeChartOrder
                      .where((String id) => !visible.contains(id))
                      .toList();
                  _timeChartOrder = <String>[...visible, ...hidden];
                }
              });
            },
            children: chartCards,
          ),
        ],
      ),
    );
  }

  // ── tab 3: Overview ─────────────────────────────────────────────────────────

  Widget _buildOverviewTab(
    AnalysisResult result, {
    required double positionTimeMaxSeconds,
    required double? frontTravelMm,
    required double? rearTravelMm,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Suspension Position Overview',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
              'Front and rear on aligned travel axes (0-100% of configured travel).'),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Pinch or scroll to zoom  •  Double-tap to reset',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              if (_timeViewMinX != null || _timeViewMaxX != null)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _timeViewMinX = null;
                    _timeViewMaxX = null;
                  }),
                  icon: const Icon(Icons.zoom_out_map, size: 16),
                  label: const Text('Reset zoom'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _wrapWithTimeZoom(
            fullTimeMax: positionTimeMaxSeconds,
            child: SizedBox(
            height: 400,
            child: LineChart(
              LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: _highContrastLineTouchData(),
                minX: _timeViewMinX ?? 0,
                maxX: _timeViewMaxX ?? positionTimeMaxSeconds + 0.01,
                minY: 0,
                maxY: 100,
                lineBarsData: result.channelResults.entries
                    .map(
                        (MapEntry<PotentiometerChannel, ChannelResult> entry) {
                  return LineChartBarData(
                    spots: _buildScaledPositionSpots(entry.value),
                    isCurved: false,
                    color: _channelColor(entry.key),
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                  );
                }).toList(),
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.black54),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      frontTravelMm != null
                          ? 'Fork travel (mm)'
                          : (rearTravelMm != null
                              ? 'Rear travel (mm)'
                              : 'Travel (mm)'),
                    ),
                    sideTitles: SideTitles(
                      showTitles:
                          frontTravelMm != null || rearTravelMm != null,
                      reservedSize: 54,
                      interval: 20,
                      getTitlesWidget: (double value, TitleMeta meta) {
                        final double? mmScale = frontTravelMm ?? rearTravelMm;
                        if (mmScale == null) return const SizedBox.shrink();
                        final double mm = (value / 100.0) * mmScale;
                        return Text(mm.toStringAsFixed(0));
                      },
                    ),
                  ),
                  bottomTitles: const AxisTitles(
                    axisNameWidget: Text('Time (s)'),
                    sideTitles: SideTitles(showTitles: true, reservedSize: 22),
                  ),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(
                    axisNameWidget: rearTravelMm != null
                        ? const Text('Rear travel (mm)')
                        : const SizedBox.shrink(),
                    sideTitles: SideTitles(
                      showTitles: rearTravelMm != null,
                      reservedSize: 54,
                      interval: 20,
                      getTitlesWidget: (double value, TitleMeta meta) {
                        if (rearTravelMm == null) return const SizedBox.shrink();
                        final double mm = (value / 100.0) * rearTravelMm;
                        return Text(mm.toStringAsFixed(0));
                      },
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<CalibrationProfile> profiles = widget.profiles;

    final AnalysisResult? result = _analysisResult;

    double? globalMinPosMm;
    double? globalMaxPosMm;
    double? globalMinVelMmPerSecond;
    double? globalMaxVelMmPerSecond;
    double? positionTimeMaxSeconds;
    double? frontTravelMm;
    double? rearTravelMm;
    if (result != null) {
      for (final ChannelResult cr in result.channelResults.values) {
        globalMinPosMm = globalMinPosMm == null
            ? cr.minPositionMillimeters
            : math.min(globalMinPosMm, cr.minPositionMillimeters);
        globalMaxPosMm = globalMaxPosMm == null
            ? cr.maxPositionMillimeters
            : math.max(globalMaxPosMm, cr.maxPositionMillimeters);
        globalMinVelMmPerSecond = globalMinVelMmPerSecond == null
            ? cr.minVelocityMillimetersPerSecond
            : math.min(
                globalMinVelMmPerSecond, cr.minVelocityMillimetersPerSecond);
        globalMaxVelMmPerSecond = globalMaxVelMmPerSecond == null
            ? cr.maxVelocityMillimetersPerSecond
            : math.max(
                globalMaxVelMmPerSecond, cr.maxVelocityMillimetersPerSecond);
      }
      positionTimeMaxSeconds = _maxChannelTimeSeconds(result);
      frontTravelMm = result
          .channelResults[PotentiometerChannel.front]?.travelMillimeters;
      rearTravelMm = result
          .channelResults[PotentiometerChannel.rear]?.travelMillimeters;
    }

    double? accelMaxSeconds;
    if (result != null && result.accelerationTimePoints.isNotEmpty) {
      accelMaxSeconds = result.accelerationTimePoints.last.timeSeconds;
    }
    double? attitudeMaxSeconds;
    if (result != null) {
      attitudeMaxSeconds =
          _maxAttitudeTimeSeconds(result.attitudeTimePoints);
    }
    final double timeMax = math.max(
      math.max(positionTimeMaxSeconds ?? 0, accelMaxSeconds ?? 0),
      attitudeMaxSeconds ?? 0,
    );

    final Widget controlsSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Log Analysis',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (profiles.isEmpty)
            const Text(
                'Create a profile in the Setup tab before analyzing logs.')
          else ...<Widget>[
            DropdownButtonFormField<CalibrationProfile>(
              value: _selectedProfile,
              decoration: const InputDecoration(
                labelText: 'Calibration profile',
                border: OutlineInputBorder(),
              ),
              items: profiles.map((CalibrationProfile profile) {
                return DropdownMenuItem<CalibrationProfile>(
                  value: profile,
                  child: Text(profile.name),
                );
              }).toList(),
              onChanged: (CalibrationProfile? value) {
                setState(() {
                  _selectedProfile = value;
                });
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isParsing ? null : _pickAndAnalyzeFile,
              icon: const Icon(Icons.folder_open),
              label: Text(_isParsing ? 'Parsing...' : 'Select log file'),
            ),
          ],
          if (_selectedFileName != null) ...<Widget>[
            const SizedBox(height: 10),
            Text('File: $_selectedFileName'),
          ],
        ],
    );

    Widget sidebar = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: controlsSection,
    );

    if (result == null ||
        globalMinPosMm == null ||
        globalMaxPosMm == null ||
        globalMinVelMmPerSecond == null ||
        globalMaxVelMmPerSecond == null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: 280, child: sidebar),
          const VerticalDivider(width: 1),
          const Expanded(
            child: Center(
              child: Text(
                'Select a log file to view analysis.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ],
      );
    }

    final Widget legendRow = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: result.channelResults.keys.map((PotentiometerChannel ch) {
        final ChannelResult channelResult = result.channelResults[ch]!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(width: 12, height: 12, color: _channelColor(ch)),
              const SizedBox(width: 6),
              Text(
                '${ch.name.toUpperCase()} '
                '(0–${channelResult.travelMillimeters.toStringAsFixed(1)} mm)',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      }).toList(),
    );

    sidebar = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          controlsSection,
          const SizedBox(height: 8),
          _SummaryCard(result: result),
          const SizedBox(height: 12),
          legendRow,
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: 280, child: sidebar),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TabBar(
                controller: _graphTabController,
                tabs: const <Tab>[
                  Tab(text: 'Trends'),
                  Tab(text: 'Time Correlation'),
                  Tab(text: 'Overview'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _graphTabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: <Widget>[
                    _buildTrendsTab(
                      result,
                      globalMinPosMm: globalMinPosMm,
                      globalMaxPosMm: globalMaxPosMm,
                      globalMinVelMmPerSecond: globalMinVelMmPerSecond,
                      globalMaxVelMmPerSecond: globalMaxVelMmPerSecond,
                    ),
                    _buildTimeCorrelationTab(result, timeMax),
                    _buildOverviewTab(
                      result,
                      positionTimeMaxSeconds: positionTimeMaxSeconds ?? timeMax,
                      frontTravelMm: frontTravelMm,
                      rearTravelMm: rearTravelMm,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Widget _accelLegendDot(Color color, String label) {
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result});

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
                  Text('$label configured travel: ${cr.travelMillimeters.toStringAsFixed(1)} mm'),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
