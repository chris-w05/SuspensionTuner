import 'dart:convert';
import 'dart:typed_data';

class ArduinoCalibrationData {
  const ArduinoCalibrationData({
    required this.frontExtended,
    required this.frontCompressed,
    required this.rearExtended,
    required this.rearCompressed,
  });

  final int frontExtended;
  final int frontCompressed;
  final int rearExtended;
  final int rearCompressed;
}

class ArduinoCalibrationImportService {
  static const int _persistedStructSizeBytes = 12;
  static const int _calibrationMagic = 0x43414C31; // "CAL1"

  ArduinoCalibrationData parse(Uint8List bytes) {
    final ArduinoCalibrationData? fromBinary = _tryParseBinary(bytes);
    if (fromBinary != null) {
      _validateCalibration(fromBinary);
      return fromBinary;
    }

    final ArduinoCalibrationData? fromText = _tryParseText(bytes);
    if (fromText != null) {
      _validateCalibration(fromText);
      return fromText;
    }

    throw const FormatException(
      'Unsupported calibration format. Expected Arduino EEPROM blob or text '
      'with front/rear extended/compressed values.',
    );
  }

  ArduinoCalibrationData? _tryParseBinary(Uint8List bytes) {
    if (bytes.length < _persistedStructSizeBytes) {
      return null;
    }

    final ByteData little = ByteData.sublistView(bytes, 0, _persistedStructSizeBytes);
    final int magicLittle = little.getUint32(0, Endian.little);
    if (magicLittle == _calibrationMagic) {
      return ArduinoCalibrationData(
        frontExtended: little.getUint16(4, Endian.little),
        frontCompressed: little.getUint16(6, Endian.little),
        rearExtended: little.getUint16(8, Endian.little),
        rearCompressed: little.getUint16(10, Endian.little),
      );
    }

    final int magicBig = little.getUint32(0, Endian.big);
    if (magicBig == _calibrationMagic) {
      return ArduinoCalibrationData(
        frontExtended: little.getUint16(4, Endian.big),
        frontCompressed: little.getUint16(6, Endian.big),
        rearExtended: little.getUint16(8, Endian.big),
        rearCompressed: little.getUint16(10, Endian.big),
      );
    }

    return null;
  }

  ArduinoCalibrationData? _tryParseText(Uint8List bytes) {
    final String text = utf8.decode(bytes, allowMalformed: true);

    int? findValue(String pattern) {
      final RegExp regex = RegExp(pattern, caseSensitive: false, multiLine: true);
      final Match? match = regex.firstMatch(text);
      if (match == null) {
        return null;
      }
      return int.tryParse(match.group(1) ?? '');
    }

    final int? frontExtended = findValue(r'front\s*extended[^0-9]*([0-9]+)');
    final int? frontCompressed =
        findValue(r'front\s*compressed[^0-9]*([0-9]+)');
    final int? rearExtended = findValue(r'rear\s*extended[^0-9]*([0-9]+)');
    final int? rearCompressed = findValue(r'rear\s*compressed[^0-9]*([0-9]+)');

    if (frontExtended != null &&
        frontCompressed != null &&
        rearExtended != null &&
        rearCompressed != null) {
      return ArduinoCalibrationData(
        frontExtended: frontExtended,
        frontCompressed: frontCompressed,
        rearExtended: rearExtended,
        rearCompressed: rearCompressed,
      );
    }

    final RegExp csvRegex = RegExp(
      r'([0-9]+)\s*[,;\s]+([0-9]+)\s*[,;\s]+([0-9]+)\s*[,;\s]+([0-9]+)',
      multiLine: true,
    );
    final Match? csvMatch = csvRegex.firstMatch(text);
    if (csvMatch != null) {
      return ArduinoCalibrationData(
        frontExtended: int.parse(csvMatch.group(1)!),
        frontCompressed: int.parse(csvMatch.group(2)!),
        rearExtended: int.parse(csvMatch.group(3)!),
        rearCompressed: int.parse(csvMatch.group(4)!),
      );
    }

    return null;
  }

  void _validateCalibration(ArduinoCalibrationData data) {
    if (data.frontExtended > 4095 ||
        data.frontCompressed > 4095 ||
        data.rearExtended > 4095 ||
        data.rearCompressed > 4095) {
      throw const FormatException(
        'Calibration ADC values are outside expected 12-bit range (0-4095).',
      );
    }

    if (data.frontExtended == data.frontCompressed ||
        data.rearExtended == data.rearCompressed) {
      throw const FormatException(
        'Calibration invalid: extended and compressed ADC cannot be equal.',
      );
    }
  }
}