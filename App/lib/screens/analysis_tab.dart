import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/analysis_models.dart';
import '../models/calibration_profile.dart';
import '../models/fft_result.dart';
import '../services/daq_parser_service.dart';
import '../services/fft_service.dart';
import '../widgets/frequency_analysis_view.dart';
import '../widgets/overview_view.dart';
import '../widgets/recommendations_view.dart';
import '../widgets/summary_card.dart';
import '../widgets/time_correlation_view.dart';
import '../widgets/trends_view.dart';

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

  // Synchronized time-axis zoom shared between Time Correlation and Overview.
  double? _timeViewMinX;
  double? _timeViewMaxX;

  // FFT analysis state
  Map<PotentiometerChannel, FftResult>? _fftResults;
  double? _fftWindowStart;
  double? _fftWindowEnd;

  @override
  void initState() {
    super.initState();
    _graphTabController = TabController(length: 5, vsync: this);
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
        widget.profiles
            .every((CalibrationProfile p) => p.id != _selectedProfile!.id)) {
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
    const List<String> allowedExtensions = <String>[
      'bin', 'dat', 'raw', 'daq', 'csv', 'txt',
    ];
    final bool useCustomExtensionFilter =
        defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS;
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
              'Could not load file data from picker. Try moving the file to '
              'On My iPhone or Files > Downloads and try again.',
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

      final Map<PotentiometerChannel, FftResult> fftResults =
          FftService.computeForResult(result);

      if (!mounted) {
        return;
      }

      setState(() {
        _analysisResult = result;
        _fftResults = fftResults;
        _fftWindowStart = null;
        _fftWindowEnd = null;
        _timeViewMinX = null;
        _timeViewMaxX = null;
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

  void _handleFftWindowChanged(double? windowStart, double? windowEnd) {
    final AnalysisResult? result = _analysisResult;
    if (result == null) return;

    if (windowStart == null || windowEnd == null || windowEnd <= windowStart) {
      setState(() {
        _fftWindowStart = null;
        _fftWindowEnd = null;
        _fftResults = FftService.computeForResult(result);
      });
    } else {
      setState(() {
        _fftWindowStart = windowStart;
        _fftWindowEnd = windowEnd;
        _fftResults = FftService.computeWindowed(result, windowStart, windowEnd);
      });
    }
  }

  static double? _maxChannelTimeSeconds(AnalysisResult result) {
    double? maxTime;
    for (final ChannelResult channelResult in result.channelResults.values) {
      for (final PositionTimePoint point in channelResult.positionTimePoints) {
        maxTime = maxTime == null
            ? point.timeSeconds
            : math.max(maxTime, point.timeSeconds);
      }
    }
    return maxTime;
  }

  static double? _maxAttitudeTimeSeconds(List<AttitudeTimePoint> points) {
    if (points.isEmpty) return null;
    return points
        .map((AttitudeTimePoint p) => p.timeSeconds)
        .reduce((double a, double b) => math.max(a, b));
  }

  static double? _maxAccelerationTimeSeconds(
      List<AccelerationTimePoint> points) {
    if (points.isEmpty) return null;
    return points
        .map((AccelerationTimePoint p) => p.timeSeconds)
        .reduce((double a, double b) => math.max(a, b));
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
      frontTravelMm =
          result.channelResults[PotentiometerChannel.front]?.travelMillimeters;
      rearTravelMm =
          result.channelResults[PotentiometerChannel.rear]?.travelMillimeters;
    }

    double? accelMaxSeconds;
    if (result != null && result.accelerationTimePoints.isNotEmpty) {
      accelMaxSeconds =
          _maxAccelerationTimeSeconds(result.accelerationTimePoints);
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
        final Color color = ch == PotentiometerChannel.front
            ? const Color(0xFFEF6C00)
            : const Color(0xFF1565C0);
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(width: 12, height: 12, color: color),
              const SizedBox(width: 6),
              Text(
                '${ch.name.toUpperCase()} '
                '(0\u2013${channelResult.travelMillimeters.toStringAsFixed(1)} mm)',
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
          AnalysisSummaryCard(result: result),
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
            Tab(text: 'Recommendations'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _graphTabController,
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[
              TrendsView(
                result: result,
                globalMinPosMm: globalMinPosMm,
                globalMaxPosMm: globalMaxPosMm,
                globalMinVelMmPerSecond: globalMinVelMmPerSecond,
                globalMaxVelMmPerSecond: globalMaxVelMmPerSecond,
              ),
              TimeCorrelationView(
                result: result,
                timeMax: timeMax,
                timeChartOrder: _timeChartOrder,
                viewMinX: _timeViewMinX,
                viewMaxX: _timeViewMaxX,
                onZoomChanged: (double? minX, double? maxX) {
                  setState(() {
                    _timeViewMinX = minX;
                    _timeViewMaxX = maxX;
                  });
                },
                onChartOrderChanged: (List<String> newOrder) {
                  setState(() {
                    _timeChartOrder = newOrder;
                  });
                },
              ),
              OverviewView(
                result: result,
                positionTimeMaxSeconds: positionTimeMaxSeconds ?? timeMax,
                frontTravelMm: frontTravelMm,
                rearTravelMm: rearTravelMm,
                viewMinX: _timeViewMinX,
                viewMaxX: _timeViewMaxX,
                fftResults: _fftResults,
                onZoomChanged: (double? minX, double? maxX) {
                  setState(() {
                    _timeViewMinX = minX;
                    _timeViewMaxX = maxX;
                  });
                },
              ),
              FrequencyAnalysisView(
                result: result,
                timeMax: timeMax,
                fftResults: _fftResults,
                fftWindowStart: _fftWindowStart,
                fftWindowEnd: _fftWindowEnd,
                onWindowChanged: _handleFftWindowChanged,
              ),
              RecommendationsView(
                result: result,
                profile: _selectedProfile!,
              ),
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
}
