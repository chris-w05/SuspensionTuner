import 'package:flutter/material.dart';

import 'models/calibration_profile.dart';
import 'screens/analysis_tab.dart';
import 'screens/setup_tab.dart';
import 'services/profile_storage_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SuspensionTunerApp());
}

class SuspensionTunerApp extends StatelessWidget {
  const SuspensionTunerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Suspension Tuner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF136A8A)),
        useMaterial3: true,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  final ProfileStorageService _storageService = ProfileStorageService();
  final List<CalibrationProfile> _profiles = <CalibrationProfile>[];

  bool _isLoadingProfiles = true;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final List<CalibrationProfile> loadedProfiles = await _storageService.loadProfiles();
    if (!mounted) {
      return;
    }

    setState(() {
      _profiles
        ..clear()
        ..addAll(loadedProfiles);
      _isLoadingProfiles = false;
    });
  }

  Future<void> _saveProfile(CalibrationProfile profile) async {
    setState(() {
      _profiles.insert(0, profile);
    });
    await _storageService.saveProfiles(_profiles);
  }

  Future<void> _updateProfile(CalibrationProfile updated) async {
    setState(() {
      final int index = _profiles.indexWhere(
        (CalibrationProfile profile) => profile.id == updated.id,
      );
      if (index != -1) {
        _profiles[index] = updated;
      }
    });
    await _storageService.saveProfiles(_profiles);
  }

  Future<void> _deleteProfile(String profileId) async {
    setState(() {
      _profiles.removeWhere((CalibrationProfile profile) => profile.id == profileId);
    });
    await _storageService.saveProfiles(_profiles);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingProfiles) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Suspension Tuner'),
          bottom: const TabBar(
            tabs: <Tab>[
              Tab(text: 'Setup Bike'),
              Tab(text: 'Analyze Log'),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            SetupTab(
              profiles: _profiles,
              onSaveProfile: _saveProfile,
              onUpdateProfile: _updateProfile,
              onDeleteProfile: _deleteProfile,
            ),
            AnalysisTab(profiles: _profiles),
          ],
        ),
      ),
    );
  }
}
