import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';

enum MapStyleKind { satellite, neon }

/// How the app chooses between the user's real location and the demo scene.
enum DemoPreference {
  /// Real location; demo only if permission is denied or unavailable.
  auto,

  /// Always run the Old Delhi demo scenario.
  always,
}

class SettingsState {
  const SettingsState({
    this.rangeKm = AppConfig.defaultRange,
    this.mapStyle = MapStyleKind.satellite,
    this.demo = DemoPreference.auto,
    this.reduceMotion = false,
    this.languageCode = '',
  });

  final int rangeKm;
  final MapStyleKind mapStyle;
  final DemoPreference demo;
  final bool reduceMotion;

  /// '' = follow the device; otherwise 'en' or 'hi'.
  final String languageCode;

  SettingsState copyWith(
          {int? rangeKm, MapStyleKind? mapStyle, DemoPreference? demo, bool? reduceMotion, String? languageCode}) =>
      SettingsState(
        rangeKm: rangeKm ?? this.rangeKm,
        mapStyle: mapStyle ?? this.mapStyle,
        demo: demo ?? this.demo,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        languageCode: languageCode ?? this.languageCode,
      );
}

/// Overridden in `main()` with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);

final settingsProvider = NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

class SettingsController extends Notifier<SettingsState> {
  static const _kRange = 'range_km';
  static const _kStyle = 'map_style';
  static const _kDemo = 'demo_pref';
  static const _kMotion = 'reduce_motion';
  static const _kLanguage = 'language';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  SettingsState build() {
    final p = ref.read(sharedPreferencesProvider);
    final range = p.getInt(_kRange) ?? AppConfig.defaultRange;
    return SettingsState(
      rangeKm: AppConfig.ranges.contains(range) ? range : AppConfig.defaultRange,
      mapStyle: MapStyleKind.values.asNameMap()[p.getString(_kStyle)] ?? MapStyleKind.satellite,
      demo: DemoPreference.values.asNameMap()[p.getString(_kDemo)] ?? DemoPreference.auto,
      reduceMotion: p.getBool(_kMotion) ?? false,
      languageCode: p.getString(_kLanguage) ?? '',
    );
  }

  void setRange(int km) {
    if (!AppConfig.ranges.contains(km) || km == state.rangeKm) return;
    state = state.copyWith(rangeKm: km);
    _prefs.setInt(_kRange, km);
  }

  void setMapStyle(MapStyleKind style) {
    state = state.copyWith(mapStyle: style);
    _prefs.setString(_kStyle, style.name);
  }

  void setDemo(DemoPreference demo) {
    state = state.copyWith(demo: demo);
    _prefs.setString(_kDemo, demo.name);
  }

  void setLanguage(String code) {
    state = state.copyWith(languageCode: code);
    _prefs.setString(_kLanguage, code);
  }

  void setReduceMotion(bool v) {
    state = state.copyWith(reduceMotion: v);
    _prefs.setBool(_kMotion, v);
  }
}
