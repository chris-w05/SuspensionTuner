import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/calibration_profile.dart';

class ProfileStorageService {
  static const String _profilesKey = 'calibration_profiles_v1';

  Future<List<CalibrationProfile>> loadProfiles() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final List<String> profileJsonList =
        preferences.getStringList(_profilesKey) ?? <String>[];

    final List<CalibrationProfile> profiles = <CalibrationProfile>[];
    bool hasStaleEntries = false;

    for (final String jsonText in profileJsonList) {
      try {
        profiles.add(
          CalibrationProfile.fromJson(
            jsonDecode(jsonText) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        hasStaleEntries = true;
      }
    }

    profiles.sort((CalibrationProfile a, CalibrationProfile b) {
      return b.createdAtMilliseconds.compareTo(a.createdAtMilliseconds);
    });

    if (hasStaleEntries) {
      await saveProfiles(profiles);
    }

    return profiles;
  }

  Future<void> saveProfiles(List<CalibrationProfile> profiles) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final List<String> profileJsonList = profiles
        .map((CalibrationProfile profile) => jsonEncode(profile.toJson()))
        .toList();

    await preferences.setStringList(_profilesKey, profileJsonList);
  }
}
