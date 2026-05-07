import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/calibration_profile.dart';
import '../services/arduino_calibration_import_service.dart';

class SetupTab extends StatefulWidget {
  const SetupTab({
    super.key,
    required this.profiles,
    required this.onSaveProfile,
    required this.onUpdateProfile,
    required this.onDeleteProfile,
  });

  final List<CalibrationProfile> profiles;
  final ValueChanged<CalibrationProfile> onSaveProfile;
  final ValueChanged<CalibrationProfile> onUpdateProfile;
  final ValueChanged<String> onDeleteProfile;

  @override
  State<SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<SetupTab> {
  final ArduinoCalibrationImportService _calibrationImportService =
      ArduinoCalibrationImportService();

  bool _isFormOpen = false;
  String? _editingProfileId;
  bool _frontEnabled = true;
  bool _rearEnabled = true;

  final TextEditingController _nameController = TextEditingController();

  final TextEditingController _frontSideAController =
      TextEditingController(text: '145');
  final TextEditingController _frontSideBController =
      TextEditingController(text: '145');
  final TextEditingController _frontExtendedSideCController = TextEditingController();
  final TextEditingController _frontExtendedAdcController = TextEditingController();
  final TextEditingController _frontCompressedSideCController = TextEditingController();
  final TextEditingController _frontCompressedAdcController = TextEditingController();

  final TextEditingController _rearSideAController =
      TextEditingController(text: '145');
  final TextEditingController _rearSideBController =
      TextEditingController(text: '145');
  final TextEditingController _rearExtendedSideCController = TextEditingController();
  final TextEditingController _rearExtendedAdcController = TextEditingController();
  final TextEditingController _rearCompressedSideCController = TextEditingController();
  final TextEditingController _rearCompressedAdcController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _frontSideAController.dispose();
    _frontSideBController.dispose();
    _frontExtendedSideCController.dispose();
    _frontExtendedAdcController.dispose();
    _frontCompressedSideCController.dispose();
    _frontCompressedAdcController.dispose();
    _rearSideAController.dispose();
    _rearSideBController.dispose();
    _rearExtendedSideCController.dispose();
    _rearExtendedAdcController.dispose();
    _rearCompressedSideCController.dispose();
    _rearCompressedAdcController.dispose();
    super.dispose();
  }

  void _openNewProfileForm() {
    _nameController.clear();
    _frontSideAController.text = '145';
    _frontSideBController.text = '145';
    _frontExtendedSideCController.clear();
    _frontExtendedAdcController.clear();
    _frontCompressedSideCController.clear();
    _frontCompressedAdcController.clear();
    _rearSideAController.text = '145';
    _rearSideBController.text = '145';
    _rearExtendedSideCController.clear();
    _rearExtendedAdcController.clear();
    _rearCompressedSideCController.clear();
    _rearCompressedAdcController.clear();
    setState(() {
      _frontEnabled = true;
      _rearEnabled = true;
      _isFormOpen = true;
      _editingProfileId = null;
    });
  }

  void _openEditProfileForm(CalibrationProfile profile) {
    _nameController.text = profile.name;
    final bool hasFront = profile.frontCalibration != null;
    final bool hasRear = profile.rearCalibration != null;
    if (hasFront) {
      _frontSideAController.text = profile.frontCalibration!.sideA.toString();
      _frontSideBController.text = profile.frontCalibration!.sideB.toString();
      _frontExtendedSideCController.text =
          profile.frontCalibration!.extendedSideC.toString();
      _frontExtendedAdcController.text =
          profile.frontCalibration!.extendedAdc.toString();
      _frontCompressedSideCController.text =
          profile.frontCalibration!.compressedSideC.toString();
      _frontCompressedAdcController.text =
          profile.frontCalibration!.compressedAdc.toString();
    } else {
      _frontSideAController.text = '145';
      _frontSideBController.text = '145';
      _frontExtendedSideCController.clear();
      _frontExtendedAdcController.clear();
      _frontCompressedSideCController.clear();
      _frontCompressedAdcController.clear();
    }
    if (hasRear) {
      _rearSideAController.text = profile.rearCalibration!.sideA.toString();
      _rearSideBController.text = profile.rearCalibration!.sideB.toString();
      _rearExtendedSideCController.text =
          profile.rearCalibration!.extendedSideC.toString();
      _rearExtendedAdcController.text =
          profile.rearCalibration!.extendedAdc.toString();
      _rearCompressedSideCController.text =
          profile.rearCalibration!.compressedSideC.toString();
      _rearCompressedAdcController.text =
          profile.rearCalibration!.compressedAdc.toString();
    } else {
      _rearSideAController.text = '145';
      _rearSideBController.text = '145';
      _rearExtendedSideCController.clear();
      _rearExtendedAdcController.clear();
      _rearCompressedSideCController.clear();
      _rearCompressedAdcController.clear();
    }
    setState(() {
      _frontEnabled = hasFront;
      _rearEnabled = hasRear;
      _isFormOpen = true;
      _editingProfileId = profile.id;
    });
  }

  void _closeForm() {
    setState(() {
      _isFormOpen = false;
      _editingProfileId = null;
    });
  }

  void _saveProfile() {
    try {
      final String profileName = _nameController.text.trim();
      if (profileName.isEmpty) {
        throw const FormatException('Profile name is required.');
      }

      final PotentiometerCalibration? frontCalibration = _frontEnabled
          ? _buildCalibration(
              sideAText: _frontSideAController.text,
              sideBText: _frontSideBController.text,
              extendedSideCText: _frontExtendedSideCController.text,
              extendedAdcText: _frontExtendedAdcController.text,
              compressedSideCText: _frontCompressedSideCController.text,
              compressedAdcText: _frontCompressedAdcController.text,
              prefix: 'Front',
            )
          : null;

      final PotentiometerCalibration? rearCalibration = _rearEnabled
          ? _buildCalibration(
              sideAText: _rearSideAController.text,
              sideBText: _rearSideBController.text,
              extendedSideCText: _rearExtendedSideCController.text,
              extendedAdcText: _rearExtendedAdcController.text,
              compressedSideCText: _rearCompressedSideCController.text,
              compressedAdcText: _rearCompressedAdcController.text,
              prefix: 'Rear',
            )
          : null;

      if (frontCalibration == null && rearCalibration == null) {
        throw const FormatException('At least one potentiometer must be enabled.');
      }

      // Validate geometry — throws FormatException on invalid dimensions.
      frontCalibration?.extendedAngleDegrees;
      frontCalibration?.compressedAngleDegrees;
      rearCalibration?.extendedAngleDegrees;
      rearCalibration?.compressedAngleDegrees;

      if (_editingProfileId != null) {
        final CalibrationProfile existing = widget.profiles.firstWhere(
          (CalibrationProfile profile) => profile.id == _editingProfileId,
        );
        widget.onUpdateProfile(
          CalibrationProfile(
            id: existing.id,
            name: profileName,
            frontCalibration: frontCalibration,
            rearCalibration: rearCalibration,
            createdAtMilliseconds: existing.createdAtMilliseconds,
          ),
        );
      } else {
        widget.onSaveProfile(
          CalibrationProfile(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: profileName,
            frontCalibration: frontCalibration,
            rearCalibration: rearCalibration,
            createdAtMilliseconds: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      _closeForm();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved.')),
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
  }

  Future<void> _importArduinoCalibration() async {
    FilePickerResult? selection;
    const List<String> allowedExtensions = <String>[
      'bin',
      'dat',
      'cal',
      'eeprom',
      'txt',
      'log',
    ];
    final bool useCustomExtensionFilter =
        defaultTargetPlatform != TargetPlatform.iOS;

    try {
      selection = await FilePicker.platform.pickFiles(
        type: useCustomExtensionFilter ? FileType.custom : FileType.any,
        allowedExtensions: useCustomExtensionFilter ? allowedExtensions : null,
        withData: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file picker: $error')),
      );
      return;
    }

    if (selection == null || selection.files.isEmpty) {
      return;
    }

    final PlatformFile file = selection.files.single;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read selected file: $error')),
        );
        return;
      }
    }

    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load selected file data.')),
        );
      }
      return;
    }

    try {
      final ArduinoCalibrationData calibration =
          _calibrationImportService.parse(bytes);

      if (!_isFormOpen || _editingProfileId != null) {
        _openNewProfileForm();
      }

      setState(() {
        _frontEnabled = true;
        _rearEnabled = true;
        _frontExtendedAdcController.text = calibration.frontExtended.toString();
        _frontCompressedAdcController.text = calibration.frontCompressed.toString();
        _rearExtendedAdcController.text = calibration.rearExtended.toString();
        _rearCompressedAdcController.text = calibration.rearCompressed.toString();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Arduino calibration imported. Review side lengths and side C values before saving.',
            ),
          ),
        );
      }
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  PotentiometerCalibration _buildCalibration({
    required String sideAText,
    required String sideBText,
    required String extendedSideCText,
    required String extendedAdcText,
    required String compressedSideCText,
    required String compressedAdcText,
    required String prefix,
  }) {
    return PotentiometerCalibration(
      sideA: _parseDouble(sideAText, '$prefix side A'),
      sideB: _parseDouble(sideBText, '$prefix side B'),
      extendedSideC: _parseDouble(extendedSideCText, '$prefix extended side C'),
      extendedAdc: _parseInt(extendedAdcText, '$prefix extended ADC'),
      compressedSideC: _parseDouble(compressedSideCText, '$prefix compressed side C'),
      compressedAdc: _parseInt(compressedAdcText, '$prefix compressed ADC'),
    );
  }

  double _parseDouble(String value, String fieldName) {
    final double? parsed = double.tryParse(value.trim());
    if (parsed == null) {
      throw FormatException('$fieldName must be a number.');
    }
    return parsed;
  }

  int _parseInt(String value, String fieldName) {
    final int? parsed = int.tryParse(value.trim());
    if (parsed == null) {
      throw FormatException('$fieldName must be an integer.');
    }
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Saved Profiles',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _importArduinoCalibration,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Import CAL.BIN'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _openNewProfileForm,
                icon: const Icon(Icons.add),
                label: const Text('New Profile'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.profiles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No profiles saved yet.'),
            )
          else
            ...widget.profiles.map((CalibrationProfile profile) {
              return Card(
                child: ListTile(
                  title: Text(profile.name),
                  subtitle: Text(
                    profile.configuredChannels
                        .map((PotentiometerChannel ch) => ch.name.toUpperCase())
                        .join(' + '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openEditProfileForm(profile),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => widget.onDeleteProfile(profile.id),
                      ),
                    ],
                  ),
                ),
              );
            }),
          if (_isFormOpen) ...<Widget>[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Text(
                  _editingProfileId != null ? 'Edit Profile' : 'New Profile',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                TextButton(
                  onPressed: _closeForm,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Profile name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _PotentiometerCalibrationCard(
              title: 'Front Potentiometer',
              enabled: _frontEnabled,
              onToggled: (bool value) => setState(() => _frontEnabled = value),
              sideAController: _frontSideAController,
              sideBController: _frontSideBController,
              extendedSideCController: _frontExtendedSideCController,
              extendedAdcController: _frontExtendedAdcController,
              compressedSideCController: _frontCompressedSideCController,
              compressedAdcController: _frontCompressedAdcController,
            ),
            const SizedBox(height: 12),
            _PotentiometerCalibrationCard(
              title: 'Rear Potentiometer',
              enabled: _rearEnabled,
              onToggled: (bool value) => setState(() => _rearEnabled = value),
              sideAController: _rearSideAController,
              sideBController: _rearSideBController,
              extendedSideCController: _rearExtendedSideCController,
              extendedAdcController: _rearExtendedAdcController,
              compressedSideCController: _rearCompressedSideCController,
              compressedAdcController: _rearCompressedAdcController,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saveProfile,
                icon: const Icon(Icons.save),
                label: const Text('Save Profile'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PotentiometerCalibrationCard extends StatelessWidget {
  const _PotentiometerCalibrationCard({
    required this.title,
    required this.enabled,
    required this.onToggled,
    required this.sideAController,
    required this.sideBController,
    required this.extendedSideCController,
    required this.extendedAdcController,
    required this.compressedSideCController,
    required this.compressedAdcController,
  });

  final String title;
  final bool enabled;
  final ValueChanged<bool> onToggled;
  final TextEditingController sideAController;
  final TextEditingController sideBController;
  final TextEditingController extendedSideCController;
  final TextEditingController extendedAdcController;
  final TextEditingController compressedSideCController;
  final TextEditingController compressedAdcController;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Switch(value: enabled, onChanged: onToggled),
              ],
            ),
            if (enabled) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(child: _mmField(sideAController, 'Side A (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _mmField(sideBController, 'Side B (mm)')),
                ],
              ),
              const SizedBox(height: 12),
              Text('Extended', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: _mmField(extendedSideCController, 'Side C (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _intField(extendedAdcController, 'ADC')),
                ],
              ),
              const SizedBox(height: 12),
              Text('Compressed', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                      child: _mmField(compressedSideCController, 'Side C (mm)')),
                  const SizedBox(width: 12),
                  Expanded(child: _intField(compressedAdcController, 'ADC')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mmField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _intField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
