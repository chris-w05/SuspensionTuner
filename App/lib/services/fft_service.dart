import 'dart:math' as math;

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/fft_result.dart';

class FftService {
  FftService._();

  static const int kMaxFftSize = 1 << 15; // 32768
  static const double kMaxFreqHz = 1000.0;

  static Map<PotentiometerChannel, FftResult> computeForResult(
      AnalysisResult result) {
    final Map<PotentiometerChannel, FftResult> out =
        <PotentiometerChannel, FftResult>{};
    for (final MapEntry<PotentiometerChannel, ChannelResult> entry
        in result.channelResults.entries) {
      out[entry.key] = computeChannelFft(entry.value.positionTimePoints);
    }
    return out;
  }

  static Map<PotentiometerChannel, FftResult> computeWindowed(
      AnalysisResult result, double windowStart, double windowEnd) {
    final Map<PotentiometerChannel, FftResult> out =
        <PotentiometerChannel, FftResult>{};
    for (final MapEntry<PotentiometerChannel, ChannelResult> entry
        in result.channelResults.entries) {
      final List<PositionTimePoint> windowed = entry.value.positionTimePoints
          .where((PositionTimePoint p) =>
              p.timeSeconds >= windowStart && p.timeSeconds <= windowEnd)
          .toList();
      out[entry.key] = computeChannelFft(windowed);
    }
    return out;
  }

  static FftResult computeChannelFft(List<PositionTimePoint> points) {
    const FftResult empty = FftResult(
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

    final double detectedRate = (points.length - 1) / timeSpan;
    final double sampleRate = detectedRate.clamp(1.0, 2500.0);

    final int uniformCount =
        math.min((timeSpan * sampleRate).round(), kMaxFftSize);
    if (uniformCount < 4) {
      return empty;
    }

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

    int fftSize = 1;
    while (fftSize < uniformCount) {
      fftSize <<= 1;
    }
    if (fftSize > kMaxFftSize) {
      fftSize = kMaxFftSize;
    }

    double mean = 0.0;
    for (final double v in signal) {
      mean += v;
    }
    mean /= signal.length;

    final List<double> re = List<double>.filled(fftSize, 0.0);
    final List<double> im = List<double>.filled(fftSize, 0.0);
    double windowSum = 0.0;
    for (int i = 0; i < uniformCount; i++) {
      final double w =
          0.5 * (1.0 - math.cos(2.0 * math.pi * i / (uniformCount - 1)));
      re[i] = (signal[i] - mean) * w;
      windowSum += w;
    }

    fftInPlace(re, im);

    final int maxBin = math.min(
      (kMaxFreqHz * fftSize / sampleRate).floor(),
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

    return FftResult(frequencies: freqs, magnitudes: mags, phases: phases);
  }

  /// Returns an upper frequency bound (Hz) covering spectral content with
  /// magnitude >= 2% of the per-channel peak, rounded to a clean boundary.
  static double computeDominantFrequencyHz(
      Map<PotentiometerChannel, FftResult> fftResults) {
    double maxCutoff = 10.0;

    for (final FftResult r in fftResults.values) {
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
      for (int i = r.magnitudes.length - 1; i >= 0; i--) {
        if (r.magnitudes[i] >= threshold) {
          if (r.frequencies[i] > maxCutoff) maxCutoff = r.frequencies[i];
          break;
        }
      }
    }

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
    return ((maxCutoff / step).ceil() * step).clamp(10.0, kMaxFreqHz);
  }

  static void fftInPlace(List<double> re, List<double> im) {
    final int n = re.length;
    assert(n > 0 && (n & (n - 1)) == 0, 'FFT size must be a power of 2');

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
}
