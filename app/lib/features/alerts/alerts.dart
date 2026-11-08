import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../nearby/application/nearby_controller.dart';
import '../settings/settings_controller.dart';
import 'alert_engine.dart';

/// Alert settings, saved in shared_preferences.
final alertSettingsProvider = NotifierProvider<AlertSettingsController, AlertSettings>(AlertSettingsController.new);

class AlertSettingsController extends Notifier<AlertSettings> {
  static const _k = 'alerts.';

  @override
  AlertSettings build() {
    final p = ref.read(sharedPreferencesProvider);
    return AlertSettings(
      enabled: p.getBool('${_k}enabled') ?? false,
      trainKm: p.getDouble('${_k}train_km') ?? 2,
      flightKm: p.getDouble('${_k}flight_km') ?? 0,
      lateMin: p.getInt('${_k}late_min') ?? 30,
      watchedTrains: p.getStringList('${_k}watched') ?? const [],
      quietStart: p.getInt('${_k}quiet_start') ?? 22,
      quietEnd: p.getInt('${_k}quiet_end') ?? 7,
    );
  }

  Future<void> update(AlertSettings a) async {
    state = a;
    final p = ref.read(sharedPreferencesProvider);
    await p.setBool('${_k}enabled', a.enabled);
    await p.setDouble('${_k}train_km', a.trainKm);
    await p.setDouble('${_k}flight_km', a.flightKm);
    await p.setInt('${_k}late_min', a.lateMin);
    await p.setStringList('${_k}watched', a.watchedTrains);
    await p.setInt('${_k}quiet_start', a.quietStart);
    await p.setInt('${_k}quiet_end', a.quietEnd);
    if (a.enabled) await ref.read(notificationServiceProvider).requestPermission();
  }
}

/// Thin wrapper over flutter_local_notifications.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 0;

  static const _android = AndroidNotificationDetails(
    'nearby_alerts',
    'Nearby alerts',
    channelDescription: 'Trains nearby, flights overhead, trains running late',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  Future<void> requestPermission() async {
    await init();
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, sound: true);
  }

  Future<void> show(AlertEvent e) async {
    await init();
    if (!_ready) return;
    await _plugin.show(
      id: _id++ & 0x7fffffff,
      title: e.title,
      body: e.body,
      notificationDetails: const NotificationDetails(android: _android, iOS: DarwinNotificationDetails()),
      payload: e.key,
    );
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) => NotificationService());

/// Watches live state and shows local notifications. Works while the app
/// runs; alerts while it is closed come from the backend's push worker
/// (see `backend/README.md`, "Push alerts").
final alertsRunnerProvider = Provider<void>((ref) {
  final engine = AlertEngine();
  final notes = ref.read(notificationServiceProvider);
  DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
  ref.listen<NearbyState>(nearbyControllerProvider, (_, st) {
    final now = DateTime.now();
    if (now.difference(last) < const Duration(seconds: 10)) return; // throttle
    last = now;
    for (final e in engine.evaluate(st, ref.read(alertSettingsProvider), now)) {
      unawaited(notes.show(e));
    }
  });
});
