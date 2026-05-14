class FftResult {
  const FftResult({
    required this.frequencies,
    required this.magnitudes,
    required this.phases,
  });

  final List<double> frequencies; // Hz, 1 Hz to FftService.kMaxFreqHz
  final List<double> magnitudes; // mm (amplitude-normalised)
  final List<double> phases; // degrees, -180 to 180
}
