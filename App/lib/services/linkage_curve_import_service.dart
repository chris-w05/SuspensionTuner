import '../models/calibration_profile.dart';

/// Parses a Linkage X3 CSV leverage-curve export into a list of
/// [LeverageCurvePoint] values.
///
/// The parser is deliberately lenient:
/// - The delimiter must be a comma.
/// - The first row whose cells contain the substrings "travel" and "leverage"
///   (case-insensitive) is treated as the header.  Rows before that are
///   ignored (they may be title/comment lines).
/// - The column that contains "travel" supplies [LeverageCurvePoint.wheelTravelMm];
///   the column that contains "leverage" supplies [LeverageCurvePoint.leverageRatio].
/// - Empty rows and rows where either target cell is non-numeric are skipped.
/// - Windows (CRLF) and Unix (LF) line endings are both accepted.
/// - A leading UTF-8 BOM is stripped automatically.
class LinkageCurveImportService {
  /// Parse [csvText] and return the ordered leverage curve.
  ///
  /// Throws [FormatException] when no recognisable header row is found, or
  /// when fewer than two data points are present.
  List<LeverageCurvePoint> parse(String csvText) {
    // Strip BOM if present.
    final String text =
        csvText.startsWith('\uFEFF') ? csvText.substring(1) : csvText;

    final List<String> lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    int travelIndex = -1;
    int leverageIndex = -1;
    int headerLineIndex = -1;

    // Find the header row.
    for (int i = 0; i < lines.length; i++) {
      final List<String> cells =
          lines[i].split(',').map((String c) => c.trim()).toList();
      int foundTravel = -1;
      int foundLeverage = -1;
      for (int j = 0; j < cells.length; j++) {
        final String lower = cells[j].toLowerCase();
        if (lower.contains('travel') && foundTravel == -1) foundTravel = j;
        if (lower.contains('leverage') && foundLeverage == -1) foundLeverage = j;
      }
      if (foundTravel != -1 && foundLeverage != -1) {
        travelIndex = foundTravel;
        leverageIndex = foundLeverage;
        headerLineIndex = i;
        break;
      }
    }

    if (headerLineIndex == -1) {
      throw const FormatException(
          'No header row found. Expected columns containing "travel" and "leverage".');
    }

    final List<LeverageCurvePoint> points = <LeverageCurvePoint>[];

    for (int i = headerLineIndex + 1; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line.isEmpty) continue;

      final List<String> cells =
          line.split(',').map((String c) => c.trim()).toList();

      if (cells.length <= travelIndex || cells.length <= leverageIndex) {
        continue;
      }

      final double? travel = double.tryParse(cells[travelIndex]);
      final double? leverage = double.tryParse(cells[leverageIndex]);

      if (travel == null || leverage == null) continue;
      if (leverage <= 0) continue;

      points.add(LeverageCurvePoint(
        wheelTravelMm: travel,
        leverageRatio: leverage,
      ));
    }

    if (points.length < 2) {
      throw const FormatException(
          'Leverage curve must contain at least two data points.');
    }

    // Sort ascending by wheel travel in case the file is not ordered.
    points.sort(
        (LeverageCurvePoint a, LeverageCurvePoint b) =>
            a.wheelTravelMm.compareTo(b.wheelTravelMm));

    return points;
  }
}
