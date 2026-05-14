import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/fft_result.dart';
import '../services/fft_service.dart';
import 'chart_utils.dart';
import 'fft_window_painter.dart';

class FrequencyAnalysisView extends StatefulWidget {
  const FrequencyAnalysisView({
    super.key,
    required this.result,
    required this.timeMax,
    required this.fftResults,
    required this.fftWindowStart,
    required this.fftWindowEnd,
    required this.onWindowChanged,
  });

  final AnalysisResult result;
  final double timeMax;
  final Map<PotentiometerChannel, FftResult>? fftResults;
  final double? fftWindowStart;
  final double? fftWindowEnd;

  /// Called when the user changes the FFT analysis window. The parent is
  /// responsible for recomputing the FFT and passing updated [fftResults].
  final void Function(double? windowStart, double? windowEnd) onWindowChanged;

  @override
  State<FrequencyAnalysisView> createState() => _FrequencyAnalysisViewState();
}

class _FrequencyAnalysisViewState extends State<FrequencyAnalysisView> {
  bool _isInteractingScatter = false;
  final Map<String, List<double?>> _scatterViewBounds =
      <String, List<double?>>{};

  // Gesture tracking (not setState-driven)
  double _scatGestStartMinX = 0;
  double _scatGestStartMaxX = 0;
  double _scatGestStartMinY = 0;
  double _scatGestStartMaxY = 0;
  double _scatGestFocalFracX = 0.5;
  double _scatGestFocalFracY = 0.5;
  int? _fftDragHandle;

  // Local window state — updated immediately during drag for responsive UI.
  // Parent is notified (FFT recomputed) only on gesture end / tap.
  double? _localWindowStart;
  double? _localWindowEnd;

  @override
  void initState() {
    super.initState();
    if (widget.fftResults != null) {
      _initFftScatterBounds(widget.fftResults!);
    }
  }

  @override
  void didUpdateWidget(covariant FrequencyAnalysisView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Sync local window positions whenever the parent updates them
    // (e.g. after FFT recomputation completes or on reset).
    if (oldWidget.fftWindowStart != widget.fftWindowStart) {
      _localWindowStart = widget.fftWindowStart;
    }
    if (oldWidget.fftWindowEnd != widget.fftWindowEnd) {
      _localWindowEnd = widget.fftWindowEnd;
    }

    if (oldWidget.fftResults != widget.fftResults &&
        widget.fftResults != null) {
      final bool isWindowedAnalysis =
          widget.fftWindowStart != null || widget.fftWindowEnd != null;
      if (isWindowedAnalysis) {
        // Window changed — reset scatter to show full range.
        setState(() {
          _scatterViewBounds.remove('fft_mag');
          _scatterViewBounds.remove('fft_phase');
        });
      } else {
        // New file loaded — initialize zoom to dominant frequency range.
        _initFftScatterBounds(widget.fftResults!);
      }
    }
  }

  void _initFftScatterBounds(Map<PotentiometerChannel, FftResult> fftResults) {
    final double dominantFreqHz =
        FftService.computeDominantFrequencyHz(fftResults);
    if (dominantFreqHz < FftService.kMaxFreqHz) {
      setState(() {
        _scatterViewBounds['fft_mag'] = <double?>[0.0, dominantFreqHz, null, null];
        _scatterViewBounds['fft_phase'] =
            <double?>[0.0, dominantFreqHz, null, null];
      });
    }
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

  Widget _buildFftWindowSelector(double timeMax) {
    const double kHeight = 110.0;
    const double kHandleHitSlop = 16.0;

    final ChannelResult? front =
        widget.result.channelResults[PotentiometerChannel.front];
    final ChannelResult? rear =
        widget.result.channelResults[PotentiometerChannel.rear];
    if (front == null && rear == null) return const SizedBox.shrink();

    double posMin = double.infinity;
    double posMax = double.negativeInfinity;
    for (final ChannelResult? cr in <ChannelResult?>[front, rear]) {
      if (cr == null) continue;
      if (cr.minPositionMillimeters < posMin) posMin = cr.minPositionMillimeters;
      if (cr.maxPositionMillimeters > posMax) posMax = cr.maxPositionMillimeters;
    }
    final double posRange = (posMax - posMin).abs();
    if (posRange < 1) return const SizedBox.shrink();

    final Color frontColor = ChartUtils.channelColor(PotentiometerChannel.front);
    final Color rearColor = ChartUtils.channelColor(PotentiometerChannel.rear);

    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();

        double tToX(double t) => (t / timeMax * width).clamp(0.0, width);
        double xToT(double x) => (x / width * timeMax).clamp(0.0, timeMax);

        List<Offset> downsample(List<PositionTimePoint> pts) {
          if (pts.isEmpty) return const <Offset>[];
          const int kMax = 800;
          final int step =
              pts.length > kMax ? (pts.length / kMax).ceil() : 1;
          final List<Offset> out = <Offset>[];
          for (int i = 0; i < pts.length; i += step) {
            final double x = tToX(pts[i].timeSeconds);
            final double y = kHeight -
                (pts[i].positionMillimeters - posMin) / posRange * kHeight;
            out.add(Offset(x, y.clamp(0.0, kHeight)));
          }
          return out;
        }

        // Use local state for responsive rendering during drag.
        final double winStart = _localWindowStart ?? 0.0;
        final double winEnd = _localWindowEnd ?? timeMax;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // onTapUp fires only for confirmed taps (not during drags).
          onTapUp: (TapUpDetails d) {
            final double t = xToT(d.localPosition.dx);
            final double distStart = (t - winStart).abs();
            final double distEnd = (t - winEnd).abs();
            double newStart = winStart;
            double newEnd = winEnd;
            if (distStart < distEnd) {
              newStart = t.clamp(0.0, winEnd - 0.01);
            } else {
              newEnd = t.clamp(winStart + 0.01, timeMax);
            }
            setState(() {
              _localWindowStart = newStart;
              _localWindowEnd = newEnd;
            });
            widget.onWindowChanged(newStart, newEnd);
          },
          // Use horizontal-specific recognizers so the vertical SingleChildScrollView
          // can still scroll without competing with handle drags.
          onHorizontalDragStart: (DragStartDetails d) {
            final double x = d.localPosition.dx;
            if ((x - tToX(winStart)).abs() <= kHandleHitSlop) {
              _fftDragHandle = 0;
            } else if ((x - tToX(winEnd)).abs() <= kHandleHitSlop) {
              _fftDragHandle = 1;
            } else {
              _fftDragHandle = null;
            }
          },
          // Update local state only during drag — FFT recomputes on release.
          onHorizontalDragUpdate: (DragUpdateDetails d) {
            if (_fftDragHandle == null) return;
            final double t = xToT(d.localPosition.dx);
            if (_fftDragHandle == 0) {
              setState(() {
                _localWindowStart = t.clamp(0.0, (_localWindowEnd ?? timeMax) - 0.01);
              });
            } else {
              setState(() {
                _localWindowEnd = t.clamp((_localWindowStart ?? 0.0) + 0.01, timeMax);
              });
            }
          },
          onHorizontalDragEnd: (DragEndDetails d) {
            if (_fftDragHandle != null) {
              widget.onWindowChanged(_localWindowStart, _localWindowEnd);
            }
            _fftDragHandle = null;
          },
          child: SizedBox(
            width: width,
            height: kHeight,
            child: CustomPaint(
              size: Size(width, kHeight),
              painter: FftWindowPainter(
                frontPoints: front == null
                    ? const <Offset>[]
                    : downsample(front.positionTimePoints),
                rearPoints: rear == null
                    ? const <Offset>[]
                    : downsample(rear.positionTimePoints),
                frontColor: frontColor,
                rearColor: rearColor,
                windowStartX: tToX(winStart),
                windowEndX: tToX(winEnd),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<PotentiometerChannel, FftResult>? fftResults = widget.fftResults;
    final double timeMax = widget.timeMax;

    if (fftResults == null || fftResults.isEmpty) {
      return const Center(
        child: Text('Frequency analysis not available for this file.'),
      );
    }

    List<double> gaussianSmooth(List<double> values, int radius) {
      final int n = values.length;
      if (n == 0) return values;
      final List<double> out = List<double>.filled(n, 0);
      final double sigma2 = (radius * radius) / 4.0;
      for (int i = 0; i < n; i++) {
        double weightSum = 0;
        double valSum = 0;
        for (int j = -radius; j <= radius; j++) {
          final int idx = i + j;
          if (idx < 0 || idx >= n) continue;
          final double w = math.exp(-(j * j) / (2.0 * sigma2));
          valSum += values[idx] * w;
          weightSum += w;
        }
        out[i] = weightSum > 0 ? valSum / weightSum : 0;
      }
      return out;
    }

    List<FlSpot> buildSpots(
        List<double> freqs, List<double> values, int budget) {
      final int count = freqs.length;
      if (count == 0) return const <FlSpot>[];
      final int step = count > budget ? (count / budget).ceil() : 1;
      final List<FlSpot> spots = <FlSpot>[];
      for (int i = 0; i < count; i += step) {
        spots.add(FlSpot(freqs[i], values[i]));
      }
      return spots;
    }

    const int kSpectrumBudget = 4096;
    const int kSmoothRadius = 20;

    double maxMag = 0.0;
    final Map<PotentiometerChannel, List<double>> smoothedMags =
        <PotentiometerChannel, List<double>>{};
    final Map<PotentiometerChannel, List<double>> smoothedPhases =
        <PotentiometerChannel, List<double>>{};
    for (final MapEntry<PotentiometerChannel, FftResult> entry
        in fftResults.entries) {
      final List<double> sm =
          gaussianSmooth(entry.value.magnitudes, kSmoothRadius);
      final List<double> sp =
          gaussianSmooth(entry.value.phases, kSmoothRadius);
      smoothedMags[entry.key] = sm;
      smoothedPhases[entry.key] = sp;
      for (final double m in sm) {
        if (m > maxMag) maxMag = m;
      }
    }
    if (maxMag < 0.01) maxMag = 1.0;

    final List<LineChartBarData> magBars = <LineChartBarData>[];
    final List<LineChartBarData> phaseBars = <LineChartBarData>[];

    for (final MapEntry<PotentiometerChannel, FftResult> entry
        in fftResults.entries) {
      final Color color = ChartUtils.channelColor(entry.key);
      final FftResult r = entry.value;
      if (r.frequencies.isEmpty) continue;
      magBars.add(LineChartBarData(
        spots: buildSpots(
            r.frequencies, smoothedMags[entry.key]!, kSpectrumBudget),
        isCurved: true,
        curveSmoothness: 0.15,
        color: color,
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
      ));
      phaseBars.add(LineChartBarData(
        spots: buildSpots(
            r.frequencies, smoothedPhases[entry.key]!, kSpectrumBudget),
        isCurved: true,
        curveSmoothness: 0.15,
        color: color,
        barWidth: 1.0,
        dotData: const FlDotData(show: false),
      ));
    }

    FlTitlesData makeTitles({required String xLabel, required String yLabel}) {
      return FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: Text(yLabel),
          sideTitles: const SideTitles(showTitles: true, reservedSize: 54),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: Text(xLabel),
          sideTitles: const SideTitles(showTitles: true, reservedSize: 22),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      );
    }

    const double kChartHeight = 300.0;
    final double defaultMaxFreqHz =
        FftService.computeDominantFrequencyHz(fftResults);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Analysis Window',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Drag the handles to select a time window for the FFT. '
            'Tap anywhere to move the nearest handle.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.hardEdge,
            child: _buildFftWindowSelector(timeMax),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              if (widget.fftWindowStart != null || widget.fftWindowEnd != null)
                TextButton.icon(
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Reset window'),
                  onPressed: () => widget.onWindowChanged(null, null),
                ),
              const Spacer(),
              Builder(builder: (BuildContext ctx) {
                final double ws = widget.fftWindowStart ?? 0.0;
                final double we = widget.fftWindowEnd ?? timeMax;
                return Text(
                  '${ws.toStringAsFixed(2)} s \u2013 ${we.toStringAsFixed(2)} s'
                  '  (${(we - ws).toStringAsFixed(2)} s)',
                  style: const TextStyle(fontSize: 12),
                );
              }),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: <Widget>[
              ...fftResults.keys.map((PotentiometerChannel ch) => Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                            width: 12,
                            height: 12,
                            color: ChartUtils.channelColor(ch)),
                        const SizedBox(width: 6),
                        Text(ch.name.toUpperCase(),
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  )),
              const Expanded(
                child: Text(
                  'Pinch to zoom  \u2022  Double-tap to reset',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Magnitude Spectrum',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _wrapWithScatterZoom(
            chartId: 'fft_mag',
            fullMinX: 0,
            fullMaxX: defaultMaxFreqHz,
            fullMinY: 0,
            fullMaxY: maxMag * 1.1,
            chartHeight: kChartHeight,
            builder: (double minX, double maxX, double minY, double maxY) =>
                SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                lineBarsData: magBars,
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(
                    xLabel: 'Frequency (Hz)', yLabel: 'Amplitude (mm)'),
              )),
            ),
          ),
          const SizedBox(height: 24),
          Text('Phase Spectrum',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _wrapWithScatterZoom(
            chartId: 'fft_phase',
            fullMinX: 0,
            fullMaxX: defaultMaxFreqHz,
            fullMinY: -180,
            fullMaxY: 180,
            chartHeight: kChartHeight,
            builder: (double minX, double maxX, double minY, double maxY) =>
                SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: ChartUtils.highContrastLineTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                lineBarsData: phaseBars,
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true, border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(
                    xLabel: 'Frequency (Hz)', yLabel: 'Phase (deg)'),
              )),
            ),
          ),
        ],
      ),
    );
  }
}
