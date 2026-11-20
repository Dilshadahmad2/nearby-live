import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import '../flights/flight.dart';
import '../nearby/application/nearby_controller.dart';
import '../trains/train.dart';

/// What the user wants to be alerted about (same rules as the backend's
/// push alerts, so local and push behave alike).
class AlertSettings {
  const AlertSettings({
    this.enabled = false,
    this.trainKm = 2,
    this.flightKm = 0,
    this.lateMin = 30,
    this.watchedTrains = const [],
    this.quietStart = 22,
    this.quietEnd = 7,
  });

  final bool enabled;

  /// Alert when a train is within this distance; 0 = off.
  final double trainKm;

  /// Alert when a flight is within this distance; 0 = off.
  final double flightKm;

  /// Alert when a watched train is at least this late; 0 = off.
  final int lateMin;

  /// Train numbers to watch. Empty = any train for the distance alert.
  final List<String> watchedTrains;

  /// Local quiet hours (start hour, end hour); -1 = none.
  final int quietStart;
  final int quietEnd;

  AlertSettings copyWith({
    bool? enabled,
    double? trainKm,
    double? flightKm,
    int? lateMin,
    List<String>? watchedTrains,
    int? quietStart,
    int? quietEnd,
  }) =>
      AlertSettings(
        enabled: enabled ?? this.enabled,
        trainKm: trainKm ?? this.trainKm,
        flightKm: flightKm ?? this.flightKm,
        lateMin: lateMin ?? this.lateMin,
        watchedTrains: watchedTrains ?? this.watchedTrains,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
      );

  bool isQuiet(DateTime local) {
    if (quietStart < 0 || quietEnd < 0 || quietStart == quietEnd) return false;
    final h = local.hour;
    if (quietStart < quietEnd) return h >= quietStart && h < quietEnd;
    return h >= quietStart || h < quietEnd; // wraps midnight
  }
}

/// One alert to show.
class AlertEvent {
  const AlertEvent({required this.key, required this.title, required this.body});
  final String key;
  final String title;
  final String body;

  @override
  String toString() => '$key: $body';
}

/// Turns live state into alerts, each key at most once per [cooldown].
class AlertEngine {
  AlertEngine({this.cooldown = const Duration(hours: 1)});

  final Duration cooldown;
  final _sent = <String, DateTime>{};

  /// Pure rule evaluation (no dedupe).
  static List<AlertEvent> rules(
    AlertSettings a,
    GeoPoint user,
    List<Ranged<Train>> trains,
    List<Ranged<FlightTrack>> flights,
  ) {
    final out = <AlertEvent>[];
    for (final r in trains) {
      final t = r.item;
      final watched = a.watchedTrains.contains(t.number);
      final late = t.delayMin != null && t.delayMin! > 0 ? ' · ${t.delayMin} min late' : '';
      if (a.trainKm > 0 && r.distanceKm <= a.trainKm && (a.watchedTrains.isEmpty || watched)) {
        out.add(AlertEvent(
          key: 'train-near:${t.number}',
          title: 'Train nearby',
          body: '${t.name} (${t.number}) is ${formatKm(r.distanceKm)} away$late',
        ));
      }
      if (a.lateMin > 0 && watched && (t.delayMin ?? 0) >= a.lateMin) {
        out.add(AlertEvent(
          key: 'train-late:${t.number}:${t.delayMin! ~/ 15}',
          title: 'Train running late',
          body: '${t.name} (${t.number}) is running ${t.delayMin} min late',
        ));
      }
    }
    for (final r in flights) {
      final f = r.item.state;
      if (a.flightKm > 0 && r.distanceKm <= a.flightKm && !f.onGround) {
        final cs = f.callsign.isEmpty ? f.icao24.toUpperCase() : f.callsign;
        final route = r.item.route == null ? '' : ' (${r.item.route})';
        out.add(AlertEvent(
          key: 'flight-near:${f.icao24}',
          title: 'Flight overhead',
          body: '$cs$route is ${formatKm(r.distanceKm)} away at ${(f.altitudeM / 1000).toStringAsFixed(1)} km',
        ));
      }
    }
    return out;
  }

  /// Alerts to show now for [st], deduplicated.
  List<AlertEvent> evaluate(NearbyState st, AlertSettings a, DateTime now) {
    final u = st.user;
    if (!a.enabled || u == null || st.mode != NearbyMode.live) return const [];
    _sent.removeWhere((_, t) => now.difference(t) > cooldown * 2);
    if (a.isQuiet(now.toLocal())) return const [];
    final out = <AlertEvent>[];
    for (final e in rules(a, u, st.trainsByDistance(now), st.flightsByDistance(now))) {
      final last = _sent[e.key];
      if (last != null && now.difference(last) < cooldown) continue;
      _sent[e.key] = now;
      out.add(e);
    }
    return out;
  }
}
