import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/fft_result.dart';
import 'chart_utils.dart';
import 'spot_builders.dart';

class _FreqPeak {
  _FreqPeak(this.frequencyHz, this.magnitudeMm);
  final double frequencyHz;
  final double magnitudeMm;
}

class OverviewView extends StatefulWidget {
  const OverviewView({
    super.key,
    required this.result,
    required this.positionTimeMaxSeconds,
    required this.frontTravelMm,
    required this.rearTravelMm,
    required this.viewMinX,
    required this.viewMaxX,
    required this.onZoomChanged,
    this.fftResults,
  });

  final AnalysisResult result;
  final double positionTimeMaxSeconds;
  final double? frontTravelMm;
  final double? rearTravelMm;
  final double? viewMinX;
  final double? viewMaxX;
  final void Function(double? minX, double? maxX) onZoomChanged;
  final Map<PotentiometerChannel, FftResult>? fftResults;

  @override
  State<OverviewView> createState() => _OverviewViewState();
}

class _OverviewViewState extends State<OverviewView> {
  bool _isInteractingTime = false;
  final Map<String, List<FlSpot>> _lineSpotCache = <String, List<FlSpot>>{};

  // Gesture tracking (not setState-driven)
  double _gestureStartMin = 0;
  double _gestureStartMax = 0;
  double _gestureStartFocalFraction = 0.5;

  int get _lineRenderBudget => _isInteractingTime ? 650 : 2200;

  @override
  void didUpdateWidget(covariant OverviewView oldWidget) {
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
            newMin = (newMax - currentRange).clamp(0.0, double.infinity);
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

  // ─── Metric computation ────────────────────────────────────────────────────

  static double? _dynamicSagPercent(ChannelResult cr) {
    if (cr.positionTimePoints.isEmpty) return null;
    double sum = 0;
    for (final PositionTimePoint p in cr.positionTimePoints) {
      sum += p.normalizedTravelPercent;
    }
    return sum / cr.positionTimePoints.length;
  }

  static double? _maxCompressionMmS(ChannelResult cr) {
    double maxV = 0;
    for (final PositionVelocityPoint p in cr.velocityPoints) {
      if (p.velocityMillimetersPerSecond > maxV) {
        maxV = p.velocityMillimetersPerSecond;
      }
    }
    return maxV > 0 ? maxV : null;
  }

  static double? _maxReboundMmS(ChannelResult cr) {
    double minV = 0;
    for (final PositionVelocityPoint p in cr.velocityPoints) {
      if (p.velocityMillimetersPerSecond < minV) {
        minV = p.velocityMillimetersPerSecond;
      }
    }
    return minV < 0 ? -minV : null;
  }

  static double? _comprReboundRatio(ChannelResult cr) {
    double comprSum = 0;
    int comprCount = 0;
    double rebSum = 0;
    int rebCount = 0;
    for (final PositionVelocityPoint p in cr.velocityPoints) {
      final double v = p.velocityMillimetersPerSecond;
      if (v > 0) {
        comprSum += v;
        comprCount++;
      } else if (v < 0) {
        rebSum -= v;
        rebCount++;
      }
    }
    if (comprCount == 0 || rebCount == 0) return null;
    final double meanReb = rebSum / rebCount;
    if (meanReb <= 0) return null;
    return (comprSum / comprCount) / meanReb;
  }

  /// Returns the top [n] spectral peaks from [fft], ordered by frequency
  /// ascending (lowest first). Only peaks with magnitude >= 4 % of the
  /// global maximum are considered.
  static List<_FreqPeak> _topPeaks(FftResult fft, int n) {
    if (fft.magnitudes.length < 3) return const <_FreqPeak>[];
    double maxMag = 0;
    for (final double m in fft.magnitudes) {
      if (m > maxMag) maxMag = m;
    }
    if (maxMag <= 0) return const <_FreqPeak>[];
    final double threshold = maxMag * 0.04;
    final List<_FreqPeak> peaks = <_FreqPeak>[];
    for (int i = 1; i < fft.magnitudes.length - 1; i++) {
      if (fft.magnitudes[i] > fft.magnitudes[i - 1] &&
          fft.magnitudes[i] > fft.magnitudes[i + 1] &&
          fft.magnitudes[i] >= threshold) {
        peaks.add(_FreqPeak(fft.frequencies[i], fft.magnitudes[i]));
      }
    }
    // Keep top-N by amplitude, then re-sort by frequency so the display reads
    // lowest → highest.
    peaks.sort(
        (_FreqPeak a, _FreqPeak b) => b.magnitudeMm.compareTo(a.magnitudeMm));
    final List<_FreqPeak> top = peaks.take(n).toList();
    top.sort(
        (_FreqPeak a, _FreqPeak b) => a.frequencyHz.compareTo(b.frequencyHz));
    return top;
  }

  /// Estimates the damping ratio using the half-power (-3 dB) bandwidth
  /// method applied to the dominant FFT peak:
  ///   ζ ≈ Δf / (2 · fd)
  /// where Δf is the bandwidth between the two frequencies at which the
  /// magnitude equals peak / √2, and fd is the dominant frequency.
  static double? _estimateDampingRatio(FftResult fft) {
    if (fft.magnitudes.length < 5) return null;

    int peakIdx = 0;
    for (int i = 1; i < fft.magnitudes.length; i++) {
      if (fft.magnitudes[i] > fft.magnitudes[peakIdx]) peakIdx = i;
    }
    final double peakMag = fft.magnitudes[peakIdx];
    final double peakFreq = fft.frequencies[peakIdx];
    if (peakMag <= 0 || peakFreq <= 0) return null;

    final double halfPower = peakMag / math.sqrt(2.0);

    // Lower -3 dB crossing (search left from peak).
    double? f1;
    for (int i = peakIdx - 1; i >= 0; i--) {
      if (fft.magnitudes[i] <= halfPower) {
        final double m0 = fft.magnitudes[i];
        final double m1 = fft.magnitudes[i + 1];
        final double span = m1 - m0;
        if (span > 0) {
          f1 = fft.frequencies[i] +
              (halfPower - m0) / span *
                  (fft.frequencies[i + 1] - fft.frequencies[i]);
        }
        break;
      }
    }

    // Upper -3 dB crossing (search right from peak).
    double? f2;
    for (int i = peakIdx + 1; i < fft.magnitudes.length; i++) {
      if (fft.magnitudes[i] <= halfPower) {
        final double m0 = fft.magnitudes[i - 1];
        final double m1 = fft.magnitudes[i];
        final double span = m1 - m0;
        if (span < 0) {
          f2 = fft.frequencies[i - 1] +
              (halfPower - m0) / span *
                  (fft.frequencies[i] - fft.frequencies[i - 1]);
        }
        break;
      }
    }

    if (f1 == null || f2 == null || f2 <= f1) return null;
    return ((f2 - f1) / (2.0 * peakFreq)).clamp(0.0, 1.5);
  }

  // ─── Formatting helpers ────────────────────────────────────────────────────

  static String? _fmtMmS(double? v) =>
      v != null ? '${v.toStringAsFixed(0)} mm/s' : null;

  static String? _fmtPct(double? v) =>
      v != null ? '${v.toStringAsFixed(1)} %' : null;

  static String? _fmtHz(double? v) =>
      v != null ? '${v.toStringAsFixed(2)} Hz' : null;

  static String? _fmtRatio(double? v) =>
      v != null ? v.toStringAsFixed(2) : null;

  // ─── Metrics card ──────────────────────────────────────────────────────────

  Widget _buildMetricsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<PotentiometerChannel, ChannelResult> channels =
        widget.result.channelResults;
    final ChannelResult? frontCr = channels[PotentiometerChannel.front];
    final ChannelResult? rearCr = channels[PotentiometerChannel.rear];
    if (frontCr == null && rearCr == null) return const SizedBox.shrink();

    final FftResult? frontFft =
        widget.fftResults?[PotentiometerChannel.front];
    final FftResult? rearFft =
        widget.fftResults?[PotentiometerChannel.rear];

    // — Travel used
    String? frontTravelUsed;
    String? rearTravelUsed;
    if (frontCr != null && frontCr.travelMillimeters > 0) {
      final double usedMm =
          frontCr.maxPositionMillimeters - frontCr.minPositionMillimeters;
      final double pct =
          (usedMm / frontCr.travelMillimeters * 100).clamp(0.0, 100.0);
      frontTravelUsed =
          '${pct.toStringAsFixed(1)} %  (${usedMm.toStringAsFixed(0)} mm)';
    }
    if (rearCr != null && rearCr.travelMillimeters > 0) {
      final double usedMm =
          rearCr.maxPositionMillimeters - rearCr.minPositionMillimeters;
      final double pct =
          (usedMm / rearCr.travelMillimeters * 100).clamp(0.0, 100.0);
      rearTravelUsed =
          '${pct.toStringAsFixed(1)} %  (${usedMm.toStringAsFixed(0)} mm)';
    }

    // — Dynamic sag (mean ride height as % of configured travel)
    final String? frontSag =
        _fmtPct(frontCr != null ? _dynamicSagPercent(frontCr) : null);
    final String? rearSag =
        _fmtPct(rearCr != null ? _dynamicSagPercent(rearCr) : null);

    // — Velocity
    final String? frontMaxComp =
        _fmtMmS(frontCr != null ? _maxCompressionMmS(frontCr) : null);
    final String? rearMaxComp =
        _fmtMmS(rearCr != null ? _maxCompressionMmS(rearCr) : null);
    final String? frontMaxReb =
        _fmtMmS(frontCr != null ? _maxReboundMmS(frontCr) : null);
    final String? rearMaxReb =
        _fmtMmS(rearCr != null ? _maxReboundMmS(rearCr) : null);
    final String? frontRatio =
        _fmtRatio(frontCr != null ? _comprReboundRatio(frontCr) : null);
    final String? rearRatio =
        _fmtRatio(rearCr != null ? _comprReboundRatio(rearCr) : null);

    // — Spectral peaks (top 3, ordered lowest → highest frequency)
    final List<_FreqPeak> frontPeaks =
        frontFft != null ? _topPeaks(frontFft, 3) : const <_FreqPeak>[];
    final List<_FreqPeak> rearPeaks =
        rearFft != null ? _topPeaks(rearFft, 3) : const <_FreqPeak>[];

    String? peakHz(List<_FreqPeak> peaks, int idx) =>
        _fmtHz(idx < peaks.length ? peaks[idx].frequencyHz : null);

    // — Estimated damping ratio (half-power bandwidth method)
    final String? frontZeta =
        _fmtRatio(frontFft != null ? _estimateDampingRatio(frontFft) : null);
    final String? rearZeta =
        _fmtRatio(rearFft != null ? _estimateDampingRatio(rearFft) : null);

    final bool hasFront = frontCr != null;
    final bool hasRear = rearCr != null;

    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Session Summary', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            _metricsHeader(theme, hasFront, hasRear),
            const Divider(height: 10, thickness: 0.5),
            _sectionLabel(context, 'TRAVEL'),
            _metricRow('Travel used', frontTravelUsed, rearTravelUsed,
                hasFront, hasRear, alt: false),
            _metricRow('Dynamic sag (mean ride height)', frontSag, rearSag,
                hasFront, hasRear, alt: true),
            const SizedBox(height: 8),
            _sectionLabel(context, 'VELOCITY'),
            _metricRow('Max compression', frontMaxComp, rearMaxComp, hasFront,
                hasRear, alt: false),
            _metricRow(
                'Max rebound', frontMaxReb, rearMaxReb, hasFront, hasRear,
                alt: true),
            _metricRow('Mean compr. / rebound ratio', frontRatio, rearRatio,
                hasFront, hasRear, alt: false),
            const SizedBox(height: 8),
            _sectionLabel(context, 'FREQUENCY  (estimated from spectral analysis)'),
            _metricRow('Primary', peakHz(frontPeaks, 0), peakHz(rearPeaks, 0),
                hasFront, hasRear, alt: false),
            _metricRow('Secondary', peakHz(frontPeaks, 1),
                peakHz(rearPeaks, 1), hasFront, hasRear, alt: true),
            _metricRow('Tertiary', peakHz(frontPeaks, 2),
                peakHz(rearPeaks, 2), hasFront, hasRear, alt: false),
            _metricRow('Damping ratio (ζ)', frontZeta, rearZeta, hasFront,
                hasRear, alt: true),
            const SizedBox(height: 6),
            Text(
              'Damping ratio estimated from the \u22123 dB spectral bandwidth '
              'around the dominant frequency (ζ \u2248 \u0394f / 2f\u2099).',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricsHeader(ThemeData theme, bool hasFront, bool hasRear) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Row(
        children: <Widget>[
          const Expanded(flex: 5, child: SizedBox.shrink()),
          if (hasFront)
            Expanded(
              flex: 3,
              child: Text(
                'Front',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: ChartUtils.channelColor(PotentiometerChannel.front),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (hasRear)
            Expanded(
              flex: 3,
              child: Text(
                'Rear',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: ChartUtils.channelColor(PotentiometerChannel.rear),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.grey.shade600,
              letterSpacing: 0.8,
            ),
      ),
    );
  }

  Widget _metricRow(
    String label,
    String? frontValue,
    String? rearValue,
    bool hasFront,
    bool hasRear, {
    required bool alt,
  }) {
    return Container(
      decoration: alt
          ? BoxDecoration(
              color: Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 5,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          if (hasFront)
            Expanded(
              flex: 3,
              child: Text(
                frontValue ?? '\u2014',
                style: TextStyle(
                  fontSize: 13,
                  color: frontValue == null ? Colors.grey : null,
                ),
              ),
            ),
          if (hasRear)
            Expanded(
              flex: 3,
              child: Text(
                rearValue ?? '\u2014',
                style: TextStyle(
                  fontSize: 13,
                  color: rearValue == null ? Colors.grey : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AnalysisResult result = widget.result;
    final double positionTimeMaxSeconds = widget.positionTimeMaxSeconds;
    final double? frontTravelMm = widget.frontTravelMm;
    final double? rearTravelMm = widget.rearTravelMm;

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
                  'Pinch or scroll to zoom  \u2022  Double-tap to reset',
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
          const SizedBox(height: 4),
          _wrapWithTimeZoom(
            fullTimeMax: positionTimeMaxSeconds,
            child: SizedBox(
              height: 400,
              child: LineChart(
                LineChartData(
                  clipData: FlClipData.all(),
                  lineTouchData: ChartUtils.highContrastLineTouchData(),
                  minX: widget.viewMinX ?? 0,
                  maxX: widget.viewMaxX ?? positionTimeMaxSeconds + 0.01,
                  minY: 0,
                  maxY: 100,
                  lineBarsData: result.channelResults.entries
                      .map((MapEntry<PotentiometerChannel, ChannelResult> entry) {
                    return LineChartBarData(
                      spots: _getOrBuildLineSpots(
                        'overview:${entry.key.name}:scaled_pos',
                        _lineRenderBudget,
                        (int maxPoints) => SpotBuilders.scaledPositionSpots(
                            entry.value, maxPoints: maxPoints),
                      ),
                      isCurved: false,
                      color: ChartUtils.channelColor(entry.key),
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
                      sideTitles:
                          SideTitles(showTitles: true, reservedSize: 22),
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
                          if (rearTravelMm == null) {
                            return const SizedBox.shrink();
                          }
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
          _buildMetricsSection(context),
        ],
      ),
    );
  }
}
