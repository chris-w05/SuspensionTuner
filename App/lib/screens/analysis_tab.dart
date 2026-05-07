import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
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
  bool _showMobileSidebar = false;

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

    // Render-performance state/caches for large logs.
    bool _isInteractingTime = false;
    bool _isInteractingScatter = false;
    final Map<String, List<FlSpot>> _lineSpotCache = <String, List<FlSpot>>{};
    final Map<String, List<ScatterSpot>> _scatterSpotCache =
      <String, List<ScatterSpot>>{};
    final Map<String, List<double>> _distributionValuesCache =
      <String, List<double>>{};

  Map<PotentiometerChannel, _FftResult>? _fftResults;
  // Time-window for FFT analysis (null = full data)
  double? _fftWindowStart;
  double? _fftWindowEnd;
  // Which handle is being dragged: 0 = start, 1 = end
  int? _fftDragHandle;

  static const int _kMaxFftSize = 1 << 15; // 32768
  static const double _kMaxFreqHz = 1000.0;

  @override
  void initState() {
    super.initState();
    _graphTabController = TabController(length: 4, vsync: this);
    if (widget.profiles.isNotEmpty) {
      _selectedProfile = widget.profiles.first;
    }
  }

  @override
  void dispose() {
    _graphTabController.dispose();
    super.dispose();
  }

  int get _lineRenderBudget => _isInteractingTime ? 650 : 2200;

  int get _scatterRenderBudget {
    if (_isInteractingScatter) {
      return 1200;
    }
    if (_isInteractingTime) {
      return 2200;
    }
    return 6500;
  }

  String _cacheKey(String key, int budget) => '$key|$budget';

  List<FlSpot> _getOrBuildLineSpots(
    String key,
    int budget,
    List<FlSpot> Function(int maxPoints) builder,
  ) {
    return _lineSpotCache.putIfAbsent(
      _cacheKey(key, budget),
      () => builder(budget),
    );
  }

  List<ScatterSpot> _getOrBuildScatterSpots(
    String key,
    int budget,
    List<ScatterSpot> Function(int maxPoints) builder,
  ) {
    return _scatterSpotCache.putIfAbsent(
      _cacheKey(key, budget),
      () => builder(budget),
    );
  }

  List<double> _getOrBuildDistributionValues(
    String key,
    List<double> Function() builder,
  ) {
    return _distributionValuesCache.putIfAbsent(key, builder);
  }

  void _clearRenderCaches() {
    _lineSpotCache.clear();
    _scatterSpotCache.clear();
    _distributionValuesCache.clear();
  }

  // ── FFT computation ─────────────────────────────────────────────────────────

  Map<PotentiometerChannel, _FftResult> _computeFftForResult(
      AnalysisResult result) {
    final Map<PotentiometerChannel, _FftResult> out =
        <PotentiometerChannel, _FftResult>{};
    for (final MapEntry<PotentiometerChannel, ChannelResult> entry
        in result.channelResults.entries) {
      out[entry.key] =
          _computeChannelFft(entry.value.positionTimePoints);
    }
    return out;
  }

  Map<PotentiometerChannel, _FftResult> _computeWindowedFft(
      AnalysisResult result, double windowStart, double windowEnd) {
    final Map<PotentiometerChannel, _FftResult> out =
        <PotentiometerChannel, _FftResult>{};
    for (final MapEntry<PotentiometerChannel, ChannelResult> entry
        in result.channelResults.entries) {
      final List<PositionTimePoint> windowed = entry.value.positionTimePoints
          .where((PositionTimePoint p) =>
              p.timeSeconds >= windowStart && p.timeSeconds <= windowEnd)
          .toList();
      out[entry.key] = _computeChannelFft(windowed);
    }
    return out;
  }

  static _FftResult _computeChannelFft(
      List<PositionTimePoint> points) {
    const _FftResult empty = _FftResult(
      frequencies: <double>[],
      magnitudes: <double>[],
      phases: <double>[],
    );

    if (points.length < 4) {
      return empty;
    }

    final double timeSpan =
        points.last.timeSeconds - points.first.timeSeconds;
    if (timeSpan <= 0.0) {
      return empty;
    }

    // Estimate sample rate, clamped to a sensible range.
    final double detectedRate = (points.length - 1) / timeSpan;
    final double sampleRate = detectedRate.clamp(1.0, 2500.0);

    // Number of uniformly-spaced samples to feed the FFT.
    final int uniformCount =
        math.min((timeSpan * sampleRate).round(), _kMaxFftSize);
    if (uniformCount < 4) {
      return empty;
    }

    // Resample to a uniform grid via linear interpolation.
    final double dt = timeSpan / (uniformCount - 1);
    final List<double> signal = List<double>.filled(uniformCount, 0.0);
    int srcIdx = 0;
    for (int i = 0; i < uniformCount; i++) {
      final double t = points.first.timeSeconds + i * dt;
      while (srcIdx + 1 < points.length - 1 &&
          points[srcIdx + 1].timeSeconds <= t) {
        srcIdx++;
      }
      final PositionTimePoint p0 = points[srcIdx];
      if (srcIdx + 1 < points.length) {
        final PositionTimePoint p1 = points[srcIdx + 1];
        final double span = p1.timeSeconds - p0.timeSeconds;
        final double frac =
            span > 0.0 ? (t - p0.timeSeconds) / span : 0.0;
        signal[i] = p0.positionMillimeters +
            frac * (p1.positionMillimeters - p0.positionMillimeters);
      } else {
        signal[i] = p0.positionMillimeters;
      }
    }

    // Next power of 2 >= uniformCount, capped at _kMaxFftSize.
    int fftSize = 1;
    while (fftSize < uniformCount) {
      fftSize <<= 1;
    }
    if (fftSize > _kMaxFftSize) {
      fftSize = _kMaxFftSize;
    }

    // Remove DC offset.
    double mean = 0.0;
    for (final double v in signal) {
      mean += v;
    }
    mean /= signal.length;

    // Apply Hanning window and fill FFT input arrays.
    final List<double> re = List<double>.filled(fftSize, 0.0);
    final List<double> im = List<double>.filled(fftSize, 0.0);
    double windowSum = 0.0;
    for (int i = 0; i < uniformCount; i++) {
      final double w =
          0.5 * (1.0 - math.cos(2.0 * math.pi * i / (uniformCount - 1)));
      re[i] = (signal[i] - mean) * w;
      windowSum += w;
    }
    // re[uniformCount..fftSize-1] remain zero-padded.

    _fftInPlace(re, im);

    // Extract one-sided magnitude and phase up to _kMaxFreqHz.
    final int maxBin = math.min(
      (_kMaxFreqHz * fftSize / sampleRate).floor(),
      fftSize >> 1,
    );
    final double normFactor =
        windowSum > 0.0 ? 2.0 / windowSum : 2.0 / fftSize;

    final List<double> freqs = <double>[];
    final List<double> mags = <double>[];
    final List<double> phases = <double>[];
    for (int k = 1; k <= maxBin; k++) {
      freqs.add(k * sampleRate / fftSize);
      final double mag =
          math.sqrt(re[k] * re[k] + im[k] * im[k]) * normFactor;
      mags.add(mag);
      phases.add(math.atan2(im[k], re[k]) * 180.0 / math.pi);
    }

    return _FftResult(frequencies: freqs, magnitudes: mags, phases: phases);
  }

  /// Returns an upper frequency bound (Hz) that covers all spectral content
  /// with magnitude ≥ 2 % of the per-channel peak, rounded up to a clean
  /// boundary.  Used to pre-set the default X range for the FFT charts.
  static double _computeDominantFrequencyHz(
      Map<PotentiometerChannel, _FftResult> fftResults) {
    double maxCutoff = 10.0;

    for (final _FftResult r in fftResults.values) {
      if (r.magnitudes.isEmpty) {
        continue;
      }
      double peak = 0.0;
      for (final double m in r.magnitudes) {
        if (m > peak) peak = m;
      }
      if (peak <= 0.0) {
        continue;
      }
      final double threshold = peak * 0.02;
      // Walk backwards to find the last bin above the threshold.
      for (int i = r.magnitudes.length - 1; i >= 0; i--) {
        if (r.magnitudes[i] >= threshold) {
          if (r.frequencies[i] > maxCutoff) maxCutoff = r.frequencies[i];
          break;
        }
      }
    }

    // Round up to a visually clean boundary.
    final double step;
    if (maxCutoff <= 20) {
      step = 5;
    } else if (maxCutoff <= 100) {
      step = 10;
    } else if (maxCutoff <= 500) {
      step = 25;
    } else {
      step = 100;
    }
    return ((maxCutoff / step).ceil() * step).clamp(10.0, _kMaxFreqHz);
  }

  static void _fftInPlace(List<double> re, List<double> im) {
    final int n = re.length;
    assert(
        n > 0 && (n & (n - 1)) == 0, 'FFT size must be a power of 2');

    // Bit-reversal permutation.
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        double t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }

    // Cooley-Tukey iterative butterfly stages.
    for (int len = 2; len <= n; len <<= 1) {
      final double ang = -2.0 * math.pi / len;
      final double wBaseR = math.cos(ang);
      final double wBaseI = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double wR = 1.0;
        double wI = 0.0;
        final int half = len >> 1;
        for (int k = 0; k < half; k++) {
          final int u = i + k;
          final int v = i + k + half;
          final double uR = re[u];
          final double uI = im[u];
          final double vR = re[v] * wR - im[v] * wI;
          final double vI = re[v] * wI + im[v] * wR;
          re[u] = uR + vR;
          im[u] = uI + vI;
          re[v] = uR - vR;
          im[v] = uI - vI;
          final double newWR = wR * wBaseR - wI * wBaseI;
          wI = wR * wBaseI + wI * wBaseR;
          wR = newWR;
        }
      }
    }
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
    const List<String> allowedExtensions = <String>['bin', 'dat', 'raw', 'daq', 'csv', 'txt'];
    final bool useCustomExtensionFilter =
        defaultTargetPlatform != TargetPlatform.iOS;
    try {
      selection = await FilePicker.platform.pickFiles(
        type: useCustomExtensionFilter ? FileType.custom : FileType.any,
        allowedExtensions: useCustomExtensionFilter ? allowedExtensions : null,
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

    if (selection == null || selection.files.isEmpty) {
      return;
    }

    final PlatformFile file = selection.files.single;
    final String fileName = file.name;
    final String loweredName = fileName.toLowerCase();
    final bool isSupportedFile =
        allowedExtensions.any((String ext) => loweredName.endsWith('.$ext'));
    if (!isSupportedFile) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Unsupported file type. Choose one of: ${allowedExtensions.join(', ')}',
            ),
          ),
        );
      }
      return;
    }

    Uint8List? fileBytes = file.bytes;
    if (fileBytes == null && file.path != null) {
      try {
        fileBytes = await File(file.path!).readAsBytes();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not read selected file: $error')),
          );
        }
        return;
      }
    }

    if (fileBytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load file data from picker. Try moving the file to On My iPhone or Files > Downloads and try again.',
            ),
          ),
        );
      }
      return;
    }

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

      final Map<PotentiometerChannel, _FftResult> fftResults =
          _computeFftForResult(result);

      if (!mounted) {
        return;
      }

      final double dominantFreqHz = _computeDominantFrequencyHz(fftResults);

      setState(() {
        _analysisResult = result;
        _fftResults = fftResults;
        _timeViewMinX = null;
        _timeViewMaxX = null;
        _scatterViewBounds.clear();
        // Pre-set the FFT views to the dominant frequency range so the
        // interesting content fills the chart by default.  Users can pinch
        // to zoom out to the full 0–1000 Hz range, or double-tap to reset.
        if (dominantFreqHz < _kMaxFreqHz) {
          _scatterViewBounds['fft_mag'] =
              <double?>[0.0, dominantFreqHz, null, null];
          _scatterViewBounds['fft_phase'] =
              <double?>[0.0, dominantFreqHz, null, null];
        }
        _isInteractingTime = false;
        _isInteractingScatter = false;
        _clearRenderCaches();
        _showMobileSidebar = false;
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
    return _sanitizeTimeSeriesSpots(spots);
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
    return _sanitizeTimeSeriesSpots(spots);
  }

  List<FlSpot> _sanitizeTimeSeriesSpots(List<FlSpot> spots) {
    if (spots.isEmpty) {
      return const <FlSpot>[];
    }

    final List<FlSpot> sanitized = <FlSpot>[];
    FlSpot? previous;

    for (final FlSpot spot in spots) {
      if (previous != null && spot.x < previous.x) {
        // Drop out-of-order samples; parser unwrapping should prevent these,
        // but filtering here guarantees line monotonicity at render time.
        continue;
      }

      // For identical timestamps, keep only the latest sample.
      if (previous != null && spot.x == previous.x && sanitized.isNotEmpty) {
        sanitized.removeLast();
      }

      sanitized.add(spot);
      previous = spot;
    }

    return sanitized;
  }

  double? _maxChannelTimeSeconds(AnalysisResult result) {
    double? maxTime;
    for (final ChannelResult channelResult in result.channelResults.values) {
      if (channelResult.positionTimePoints.isEmpty) {
        continue;
      }
      for (final PositionTimePoint point in channelResult.positionTimePoints) {
        maxTime = maxTime == null ? point.timeSeconds : math.max(maxTime, point.timeSeconds);
      }
    }
    return maxTime;
  }

  double? _maxAttitudeTimeSeconds(List<AttitudeTimePoint> points) {
    if (points.isEmpty) {
      return null;
    }
    return points
        .map((AttitudeTimePoint p) => p.timeSeconds)
        .reduce((double a, double b) => math.max(a, b));
  }

  double? _maxAccelerationTimeSeconds(List<AccelerationTimePoint> points) {
    if (points.isEmpty) {
      return null;
    }
    return points
        .map((AccelerationTimePoint p) => p.timeSeconds)
        .reduce((double a, double b) => math.max(a, b));
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
    return _sanitizeTimeSeriesSpots(spots);
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
    return _sanitizeTimeSeriesSpots(spots);
  }

  // ── overlaid distribution line chart ───────────────────────────────────────

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
      // Gaussian-weighted smoothing using a simple box-kernel approximation.
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

    final Color frontColor = _channelColor(PotentiometerChannel.front);
    final Color rearColor = _channelColor(PotentiometerChannel.rear);

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
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            if (frontSpots.isNotEmpty) ...<Widget>[
              Container(
                  width: 16,
                  height: 2,
                  color: frontColor),
              const SizedBox(width: 4),
              const Text('Front', style: TextStyle(fontSize: 11)),
            ],
            if (frontSpots.isNotEmpty && rearSpots.isNotEmpty)
              const SizedBox(width: 12),
            if (rearSpots.isNotEmpty) ...<Widget>[
              Container(
                  width: 16,
                  height: 2,
                  color: rearColor),
              const SizedBox(width: 4),
              const Text('Rear', style: TextStyle(fontSize: 11)),
            ],
          ],
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
              if (!_isInteractingTime) {
                setState(() {
                  _isInteractingTime = true;
                });
              }
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
            onScaleEnd: (_) {
              if (_isInteractingTime) {
                setState(() {
                  _isInteractingTime = false;
                });
              }
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
                  scatterTouchData: _highContrastScatterTouchData(),
                  minX: minX,
                  maxX: maxX,
                  minY: minY,
                  maxY: maxY,
                  scatterSpots: _getOrBuildScatterSpots(
                    'trends:front_rear_pos',
                    _scatterRenderBudget,
                    (int maxPoints) =>
                        _buildFrontVsRearPositionSpots(result, maxPoints: maxPoints),
                  ),
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
                  scatterTouchData: _highContrastScatterTouchData(),
                  minX: minX,
                  maxX: maxX,
                  minY: minY,
                  maxY: maxY,
                  scatterSpots: _getOrBuildScatterSpots(
                    'trends:front_rear_vel',
                    _scatterRenderBudget,
                    (int maxPoints) =>
                        _buildFrontVsRearVelocitySpots(result, maxPoints: maxPoints),
                  ),
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
            const SizedBox(height: 24),
            _buildOverlaidDistributionChart(
              frontValues: _getOrBuildDistributionValues(
                'dist:front:vel_mms',
                () => frontResult.velocityPoints
                    .map((PositionVelocityPoint p) => p.velocityMillimetersPerSecond)
                    .toList(growable: false),
              ),
              rearValues: _getOrBuildDistributionValues(
                'dist:rear:vel_mms',
                () => rearResult.velocityPoints
                    .map((PositionVelocityPoint p) => p.velocityMillimetersPerSecond)
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
                scatterSpots: _getOrBuildScatterSpots(
                  'trends:all_pv',
                  _scatterRenderBudget,
                  (int maxPoints) =>
                      _buildAllSpots(result, maxPointsPerChannel: maxPoints),
                ),
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
                  spots: _getOrBuildLineSpots(
                    'time:front_pos',
                    _lineRenderBudget,
                    (int maxPoints) => _buildPositionSpotsMm(cr, maxPoints: maxPoints),
                  ),
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
                  spots: _getOrBuildLineSpots(
                    'time:rear_pos',
                    _lineRenderBudget,
                    (int maxPoints) => _buildPositionSpotsMm(cr, maxPoints: maxPoints),
                  ),
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
                      spots: _getOrBuildLineSpots(
                        'time:accel_x',
                        _lineRenderBudget,
                        (int maxPoints) => _buildAccelSpots(
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
                        (int maxPoints) => _buildAccelSpots(
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
                        (int maxPoints) => _buildAccelSpots(
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
                        (int maxPoints) => _buildAccelSpots(
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
              lineTouchData: _highContrastLineTouchData(),
              minX: viewMinX,
              maxX: viewMaxX,
              minY: pitchMin - 2,
              maxY: pitchMax + 2,
              lineBarsData: <LineChartBarData>[
                LineChartBarData(
                  spots: _getOrBuildLineSpots(
                    'time:pitch',
                    _lineRenderBudget,
                    (int maxPoints) => _buildAttitudeSpots(
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
                  spots: _getOrBuildLineSpots(
                    'time:roll',
                    _lineRenderBudget,
                    (int maxPoints) => _buildAttitudeSpots(
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

  // ── FFT window selector ────────────────────────────────────────────────────

  /// Interactive time-window selector. Draws front and rear position traces,
  /// a shaded selection region, and two draggable handle lines.
  Widget _buildFftWindowSelector(AnalysisResult result, double timeMax) {
    const double kHeight = 110.0;
    const double kHandleHitSlop = 16.0;

    final ChannelResult? front =
        result.channelResults[PotentiometerChannel.front];
    final ChannelResult? rear =
        result.channelResults[PotentiometerChannel.rear];
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

    final Color frontColor = _channelColor(PotentiometerChannel.front);
    final Color rearColor = _channelColor(PotentiometerChannel.rear);

    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();

        double tToX(double t) => (t / timeMax * width).clamp(0.0, width);
        double xToT(double x) => (x / width * timeMax).clamp(0.0, timeMax);

        List<Offset> downsample(List<PositionTimePoint> pts) {
          if (pts.isEmpty) return const <Offset>[];
          const int kMax = 800;
          final int step = pts.length > kMax ? (pts.length / kMax).ceil() : 1;
          final List<Offset> out = <Offset>[];
          for (int i = 0; i < pts.length; i += step) {
            final double x = tToX(pts[i].timeSeconds);
            final double y = kHeight -
                (pts[i].positionMillimeters - posMin) / posRange * kHeight;
            out.add(Offset(x, y.clamp(0.0, kHeight)));
          }
          return out;
        }

        final double winStart = _fftWindowStart ?? 0.0;
        final double winEnd = _fftWindowEnd ?? timeMax;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) {
            final double t = xToT(d.localPosition.dx);
            final double distStart = (t - winStart).abs();
            final double distEnd = (t - winEnd).abs();
            setState(() {
              if (distStart < distEnd) {
                _fftWindowStart = t.clamp(0.0, winEnd - 0.01);
              } else {
                _fftWindowEnd = t.clamp(winStart + 0.01, timeMax);
              }
            });
            _recomputeWindowedFft(result);
          },
          onPanStart: (DragStartDetails d) {
            final double x = d.localPosition.dx;
            if ((x - tToX(winStart)).abs() <= kHandleHitSlop) {
              _fftDragHandle = 0;
            } else if ((x - tToX(winEnd)).abs() <= kHandleHitSlop) {
              _fftDragHandle = 1;
            } else {
              _fftDragHandle = null;
            }
          },
          onPanUpdate: (DragUpdateDetails d) {
            if (_fftDragHandle == null) return;
            final double t = xToT(d.localPosition.dx);
            setState(() {
              if (_fftDragHandle == 0) {
                _fftWindowStart =
                    t.clamp(0.0, (_fftWindowEnd ?? timeMax) - 0.01);
              } else {
                _fftWindowEnd =
                    t.clamp((_fftWindowStart ?? 0.0) + 0.01, timeMax);
              }
            });
          },
          onPanEnd: (_) {
            _fftDragHandle = null;
            _recomputeWindowedFft(result);
          },
          child: SizedBox(
            width: width,
            height: kHeight,
            child: CustomPaint(
              size: Size(width, kHeight),
              painter: _FftWindowPainter(
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

  void _recomputeWindowedFft(AnalysisResult result) {
    final double? ws = _fftWindowStart;
    final double? we = _fftWindowEnd;
    if (ws == null || we == null || we <= ws) {
      // No valid window — fall back to full-data FFT.
      setState(() {
        _fftResults = _computeFftForResult(result);
      });
    } else {
      setState(() {
        _fftResults = _computeWindowedFft(result, ws, we);
        // Reset chart zoom to data-driven default.
        _scatterViewBounds.remove('fft_mag');
        _scatterViewBounds.remove('fft_phase');
      });
    }
  }

  // ── tab 4: Frequency Analysis ────────────────────────────────────────────────

  Widget _buildFrequencyAnalysisTab(AnalysisResult result, double timeMax) {
    final Map<PotentiometerChannel, _FftResult>? fftResults = _fftResults;
    if (fftResults == null || fftResults.isEmpty) {
      return const Center(
        child: Text('Frequency analysis not available for this file.'),
      );
    }

    // Gaussian smoothing over a raw value array.
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

    // Smoothing radius: ~0.5% of the bin count so it scales with FFT size.
    const int kSpectrumBudget = 4096;
    const int kSmoothRadius = 20;

    // Global max magnitude for Y-axis scaling (from smoothed data).
    double maxMag = 0.0;
    final Map<PotentiometerChannel, List<double>> smoothedMags =
        <PotentiometerChannel, List<double>>{};
    final Map<PotentiometerChannel, List<double>> smoothedPhases =
        <PotentiometerChannel, List<double>>{};
    for (final MapEntry<PotentiometerChannel, _FftResult> entry
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

    for (final MapEntry<PotentiometerChannel, _FftResult> entry
        in fftResults.entries) {
      final Color color = _channelColor(entry.key);
      final _FftResult r = entry.value;
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

    FlTitlesData makeTitles(
        {required String xLabel, required String yLabel}) {
      return FlTitlesData(
        leftTitles: AxisTitles(
          axisNameWidget: Text(yLabel),
          sideTitles:
              const SideTitles(showTitles: true, reservedSize: 54),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: Text(xLabel),
          sideTitles:
              const SideTitles(showTitles: true, reservedSize: 22),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      );
    }

    const double kChartHeight = 300.0;
    final double defaultMaxFreqHz =
        _computeDominantFrequencyHz(fftResults);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ── time-window selector ──────────────────────────────────────────
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
            child: _buildFftWindowSelector(result, timeMax),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              if (_fftWindowStart != null || _fftWindowEnd != null)
                TextButton.icon(
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Reset window'),
                  onPressed: () {
                    setState(() {
                      _fftWindowStart = null;
                      _fftWindowEnd = null;
                      _fftResults = _computeFftForResult(result);
                      _scatterViewBounds.remove('fft_mag');
                      _scatterViewBounds.remove('fft_phase');
                    });
                  },
                ),
              const Spacer(),
              Builder(builder: (BuildContext ctx) {
                final double ws = _fftWindowStart ?? 0.0;
                final double we = _fftWindowEnd ?? timeMax;
                return Text(
                  '${ws.toStringAsFixed(2)} s – ${we.toStringAsFixed(2)} s'
                  '  (${(we - ws).toStringAsFixed(2)} s)',
                  style: const TextStyle(fontSize: 12),
                );
              }),
            ],
          ),
          const Divider(height: 24),
          // ── channel legend ────────────────────────────────────────────────
          Row(
            children: <Widget>[
              ...fftResults.keys
                  .map((PotentiometerChannel ch) => Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(
                                width: 12,
                                height: 12,
                                color: _channelColor(ch)),
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
            builder: (double minX, double maxX, double minY,
                    double maxY) =>
                SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: _highContrastLineTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                lineBarsData: magBars,
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(
                    xLabel: 'Frequency (Hz)',
                    yLabel: 'Amplitude (mm)'),
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
            builder: (double minX, double maxX, double minY,
                    double maxY) =>
                SizedBox(
              height: kChartHeight,
              child: LineChart(LineChartData(
                clipData: FlClipData.all(),
                lineTouchData: _highContrastLineTouchData(),
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                lineBarsData: phaseBars,
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.black54)),
                titlesData: makeTitles(
                    xLabel: 'Frequency (Hz)', yLabel: 'Phase (deg)'),
              )),
            ),
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
                    spots: _getOrBuildLineSpots(
                      'overview:${entry.key.name}:scaled_pos',
                      _lineRenderBudget,
                      (int maxPoints) =>
                          _buildScaledPositionSpots(entry.value, maxPoints: maxPoints),
                    ),
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
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final bool isCompactLayout = mediaQuery.size.width < 900;
    final double textScale = isCompactLayout ? 0.9 : 1.0;

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
      accelMaxSeconds = _maxAccelerationTimeSeconds(result.accelerationTimePoints);
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
      final Widget emptyState = Center(
        child: Text(
          'Select a log file to view analysis.',
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 13,
          ),
        ),
      );

      final Widget content = isCompactLayout
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _showMobileSidebar = !_showMobileSidebar;
                        });
                      },
                      icon: Icon(
                        _showMobileSidebar
                            ? Icons.tune
                            : Icons.tune_outlined,
                        size: 18,
                      ),
                      label: Text(
                        _showMobileSidebar ? 'Hide Controls' : 'Show Controls',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 180),
                  crossFadeState: _showMobileSidebar
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  firstChild: SizedBox(height: 300, child: sidebar),
                  secondChild: const SizedBox.shrink(),
                ),
                const Divider(height: 1),
                Expanded(child: emptyState),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 280, child: sidebar),
                const VerticalDivider(width: 1),
                Expanded(child: emptyState),
              ],
            );

      return MediaQuery(
        data: mediaQuery.copyWith(textScaler: TextScaler.linear(textScale)),
        child: content,
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

    final Widget graphSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TabBar(
          controller: _graphTabController,
          tabs: const <Tab>[
            Tab(text: 'Trends'),
            Tab(text: 'Time Correlation'),
            Tab(text: 'Overview'),
            Tab(text: 'Frequency'),
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
              _buildFrequencyAnalysisTab(result, timeMax),
            ],
          ),
        ),
      ],
    );

    final Widget content = isCompactLayout
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _showMobileSidebar = !_showMobileSidebar;
                      });
                    },
                    icon: Icon(
                      _showMobileSidebar ? Icons.tune : Icons.tune_outlined,
                      size: 18,
                    ),
                    label: Text(
                      _showMobileSidebar ? 'Hide Controls' : 'Show Controls',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 180),
                crossFadeState: _showMobileSidebar
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: SizedBox(height: 320, child: sidebar),
                secondChild: const SizedBox.shrink(),
              ),
              const Divider(height: 1),
              Expanded(child: graphSection),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: 280, child: sidebar),
              const VerticalDivider(width: 1),
              Expanded(child: graphSection),
            ],
          );

    return MediaQuery(
      data: mediaQuery.copyWith(textScaler: TextScaler.linear(textScale)),
      child: content,
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

class _FftResult {
  const _FftResult({
    required this.frequencies,
    required this.magnitudes,
    required this.phases,
  });

  final List<double> frequencies; // Hz, 1 Hz to _kMaxFreqHz
  final List<double> magnitudes;  // mm (amplitude-normalised)
  final List<double> phases;      // degrees, -180 to 180
}

// ── FFT window selector painter ──────────────────────────────────────────────

class _FftWindowPainter extends CustomPainter {
  const _FftWindowPainter({
    required this.frontPoints,
    required this.rearPoints,
    required this.frontColor,
    required this.rearColor,
    required this.windowStartX,
    required this.windowEndX,
  });

  final List<Offset> frontPoints;
  final List<Offset> rearPoints;
  final Color frontColor;
  final Color rearColor;
  final double windowStartX;
  final double windowEndX;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // Dimmed overlay outside the selection window.
    final Paint dimPaint = Paint()
      ..color = Colors.black.withAlpha(40)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(0, 0, windowStartX, h), dimPaint);
    canvas.drawRect(Rect.fromLTRB(windowEndX, 0, w, h), dimPaint);

    // Selected region border.
    final Paint windowBorderPaint = Paint()
      ..color = Colors.blueAccent.withAlpha(180)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(
        Rect.fromLTRB(windowStartX, 0, windowEndX, h), windowBorderPaint);

    // Draw signal traces.
    void drawTrace(List<Offset> pts, Color color) {
      if (pts.length < 2) return;
      final Paint tracePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round;
      final Path path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, tracePaint);
    }

    drawTrace(rearPoints, rearColor);
    drawTrace(frontPoints, frontColor);

    // Handle lines.
    final Paint handlePaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawLine(
        Offset(windowStartX, 0), Offset(windowStartX, h), handlePaint);
    canvas.drawLine(
        Offset(windowEndX, 0), Offset(windowEndX, h), handlePaint);

    // Handle grip dots.
    final Paint dotPaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(windowStartX, h / 2), 5, dotPaint);
    canvas.drawCircle(Offset(windowEndX, h / 2), 5, dotPaint);
  }

  @override
  bool shouldRepaint(_FftWindowPainter old) =>
      old.windowStartX != windowStartX ||
      old.windowEndX != windowEndX ||
      old.frontPoints != frontPoints ||
      old.rearPoints != rearPoints;
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
