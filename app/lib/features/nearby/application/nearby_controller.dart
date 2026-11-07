import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config.dart';
import '../../../core/geo/geo_point.dart';
import '../../../core/geo/geo_utils.dart';
import '../../flights/flight.dart';
import '../../flights/flight_source.dart';
import '../../flights/opensky_api.dart';
import '../../location/location_repository.dart';
import '../../settings/settings_controller.dart';
import '../../traffic/traffic.dart';
import '../../traffic/traffic_source.dart';
import '../../trains/train.dart';
import '../../trains/train_data_source.dart';
import '../../weather/open_meteo_api.dart';
import '../../weather/weather.dart';
import '../scene/scene.dart';

enum NearbyMode { locating, live, demo }

/// Health of one data source, for the "Live Updates" pill.
class SourceHealth {
  const SourceHealth({this.lastSuccess, this.lastError, this.staleAfter = const Duration(minutes: 2)});

  final DateTime? lastSuccess;
  final String? lastError;
  final Duration staleAfter;

  bool isStale(DateTime now) => lastSuccess == null || now.difference(lastSuccess!) > staleAfter;
}

@immutable
class NearbyState {
  const NearbyState({
    this.mode = NearbyMode.locating,
    this.access,
    this.user,
    this.rangeKm = AppConfig.defaultRange,
    this.trains = const [],
    this.flights = const [],
    this.traffic = const [],
    this.trafficIsMock = true,
    this.weather,
    this.health = const {},
  });

  final NearbyMode mode;
  final LocationAccess? access;
  final GeoPoint? user;
  final int rangeKm;
  final List<Train> trains;
  final List<FlightTrack> flights;
  final List<TrafficSegment> traffic;
  final bool trafficIsMock;
  final Weather? weather;
  final Map<NearbyKind, SourceHealth> health;

  bool get isDemo => mode == NearbyMode.demo;

  NearbyState copyWith({
    NearbyMode? mode,
    LocationAccess? access,
    GeoPoint? user,
    int? rangeKm,
    List<Train>? trains,
    List<FlightTrack>? flights,
    List<TrafficSegment>? traffic,
    bool? trafficIsMock,
    Weather? weather,
    Map<NearbyKind, SourceHealth>? health,
  }) =>
      NearbyState(
        mode: mode ?? this.mode,
        access: access ?? this.access,
        user: user ?? this.user,
        rangeKm: rangeKm ?? this.rangeKm,
        trains: trains ?? this.trains,
        flights: flights ?? this.flights,
        traffic: traffic ?? this.traffic,
        trafficIsMock: trafficIsMock ?? this.trafficIsMock,
        weather: weather ?? this.weather,
        health: health ?? this.health,
      );

  /// Overall pill status: amber when any enabled source is stale.
  LiveStatus liveStatus(DateTime now) {
    switch (mode) {
      case NearbyMode.locating:
        return LiveStatus.locating;
      case NearbyMode.demo:
        return LiveStatus.demo;
      case NearbyMode.live:
        if (health.isEmpty) return LiveStatus.locating;
        return health.values.any((h) => h.isStale(now)) ? LiveStatus.stale : LiveStatus.live;
    }
  }

  /// Trains with their current (dead-reckoned) distance, nearest first.
  List<Ranged<Train>> trainsByDistance(DateTime now) {
    final u = user;
    if (u == null) return const [];
    final list = [for (final t in trains) Ranged(t, haversineKm(u, trainPositionAt(t, now)))];
    list.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return list;
  }

  List<Ranged<FlightTrack>> flightsByDistance(DateTime now) {
    final u = user;
    if (u == null) return const [];
    final list = [for (final f in flights) Ranged(f, haversineKm(u, f.positionAt(now)))];
    list.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return list;
  }

  List<Ranged<TrafficSegment>> trafficByDistance() {
    final u = user;
    if (u == null) return const [];
    final list = [for (final s in traffic) Ranged(s, distanceToPolylineKm(u, s.points))];
    list.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return list;
  }
}

/// Train head position at [now], advanced along its route by its speed.
GeoPoint trainPositionAt(Train t, DateTime now) {
  if (t.route.length < 2) return t.position;
  final proj = LocalProjector(t.position);
  final line = Polyline.fromGeo(t.route, proj);
  final dt = now.difference(t.fixTime).inMilliseconds / 1000.0;
  return line.geoAt(t.arcM + t.speedMs * dt);
}

final nearbyControllerProvider = NotifierProvider<NearbyController, NearbyState>(NearbyController.new);

/// Combines location + range + every data source into [NearbyState].
/// Each source polls on its own interval; all polling pauses while the app
/// is in the background ([pause] / [resume]).
class NearbyController extends Notifier<NearbyState> {
  final _timers = <NearbyKind, Timer>{};
  StreamSubscription<GeoPoint>? _locationSub;
  final _flightBackoff = Backoff(base: AppConfig.flightPoll);
  bool _paused = false;
  GeoPoint? _weatherAt;
  int _generation = 0;

  @override
  NearbyState build() {
    final settings = ref.read(settingsProvider);
    ref.listen<SettingsState>(settingsProvider, _onSettings);
    ref.onDispose(_stopAll);
    Future.microtask(() => _start(settings));
    return NearbyState(rangeKm: settings.rangeKm);
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _start(SettingsState settings) async {
    final gen = ++_generation;
    _stopAll();
    if (settings.demo == DemoPreference.always) {
      state = state.copyWith(mode: NearbyMode.demo);
      return;
    }
    state = state.copyWith(mode: NearbyMode.locating);
    final loc = ref.read(locationRepositoryProvider);
    final access = await loc.ensurePermission();
    if (gen != _generation) return;
    if (access != LocationAccess.granted) {
      state = state.copyWith(mode: NearbyMode.demo, access: access);
      return;
    }
    final here = await loc.current();
    if (gen != _generation) return;
    if (here == null) {
      state = state.copyWith(mode: NearbyMode.demo, access: access);
      return;
    }
    state = state.copyWith(mode: NearbyMode.live, access: access, user: here);
    _locationSub = loc.watch().listen(_onLocation, onError: (_) {});
    _startPolling();
  }

  void _onSettings(SettingsState? prev, SettingsState next) {
    if (prev?.demo != next.demo) {
      state = state.copyWith(rangeKm: next.rangeKm);
      _start(next);
      return;
    }
    if (prev?.rangeKm != next.rangeKm) {
      state = state.copyWith(rangeKm: next.rangeKm);
      if (state.mode == NearbyMode.live) {
        // The query area depends on the range: refresh now.
        _refreshFlights();
        _refreshTrains();
        _refreshTraffic();
      }
    }
  }

  void _onLocation(GeoPoint p) {
    state = state.copyWith(user: p);
    final w = _weatherAt;
    if (w == null || haversineKm(w, p) > 5) _refreshWeather();
  }

  /// Retry live mode (e.g. after the user granted permission in Settings).
  Future<void> retryLocation() => _start(ref.read(settingsProvider));

  void pause() {
    _paused = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (state.mode == NearbyMode.live) _startPolling();
  }

  void _stopAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _locationSub?.cancel();
    _locationSub = null;
  }

  void _startPolling() {
    _refreshWeather();
    _refreshFlights();
    _refreshTraffic();
    _refreshTrains();
  }

  void _schedule(NearbyKind kind, Duration after, Future<void> Function() fn) {
    _timers[kind]?.cancel();
    if (_paused || state.mode != NearbyMode.live) return;
    _timers[kind] = Timer(after, fn);
  }

  void _ok(NearbyKind k, Duration staleAfter) {
    state = state.copyWith(health: {
      ...state.health,
      k: SourceHealth(lastSuccess: DateTime.now(), staleAfter: staleAfter),
    });
  }

  void _fail(NearbyKind k, Object e, Duration staleAfter) {
    final prev = state.health[k];
    state = state.copyWith(health: {
      ...state.health,
      k: SourceHealth(lastSuccess: prev?.lastSuccess, lastError: '$e', staleAfter: staleAfter),
    });
  }

  // ------------------------------------------------------------------ sources

  Future<void> _refreshWeather() async {
    final u = state.user;
    if (u == null) return;
    const stale = Duration(minutes: 25);
    try {
      final w = await ref.read(openMeteoApiProvider).current(u);
      _weatherAt = u;
      state = state.copyWith(weather: w);
      _ok(NearbyKind.weather, stale);
    } catch (e) {
      _fail(NearbyKind.weather, e, stale);
    }
    _schedule(NearbyKind.weather, AppConfig.weatherPoll, _refreshWeather);
  }

  Future<void> _refreshFlights() async {
    final u = state.user;
    if (u == null) return;
    const stale = Duration(minutes: 2);
    var next = _flightBackoff.current;
    try {
      // Query a little beyond the range so planes are tracked before they enter.
      final fixes = await ref.read(flightDataSourceProvider).states(u, state.rangeKm * 1.5 + 5);
      final now = DateTime.now();
      final byId = {for (final f in state.flights) f.state.icao24: f};
      final tracks = <FlightTrack>[];
      for (final s in fixes.where((s) => !s.onGround)) {
        final track = byId[s.icao24];
        if (track == null) {
          tracks.add(FlightTrack(s));
        } else {
          track.update(s, now);
          tracks.add(track);
        }
      }
      state = state.copyWith(flights: tracks);
      next = _flightBackoff.succeed();
      _ok(NearbyKind.flight, stale);
      _lookupRoutes(tracks, u);
    } on RateLimitedException catch (e) {
      next = _flightBackoff.fail(e.retryAfter);
      _fail(NearbyKind.flight, e, stale);
    } catch (e) {
      _fail(NearbyKind.flight, e, stale);
    }
    _schedule(NearbyKind.flight, next, _refreshFlights);
  }

  /// Route text for the few nearest flights (cached per callsign).
  Future<void> _lookupRoutes(List<FlightTrack> tracks, GeoPoint u) async {
    final now = DateTime.now();
    final nearest = [...tracks]
      ..sort((a, b) => haversineKm(u, a.positionAt(now)).compareTo(haversineKm(u, b.positionAt(now))));
    final lookup = ref.read(flightRouteLookupProvider);
    var changed = false;
    for (final t in nearest.take(4)) {
      if (t.route != null) continue;
      t.route = await lookup.route(t.state.callsign);
      changed |= t.route != null;
    }
    if (changed) state = state.copyWith(flights: [...state.flights]);
  }

  Future<void> _refreshTraffic() async {
    final u = state.user;
    if (u == null) return;
    const stale = Duration(minutes: 10);
    final src = ref.read(trafficSourceProvider);
    try {
      final segs = await src.segments(u, state.rangeKm.toDouble());
      state = state.copyWith(traffic: segs, trafficIsMock: src.isMock);
      _ok(NearbyKind.traffic, stale);
    } catch (e) {
      _fail(NearbyKind.traffic, e, stale);
    }
    _schedule(NearbyKind.traffic, AppConfig.trafficPoll, _refreshTraffic);
  }

  Future<void> _refreshTrains() async {
    final u = state.user;
    if (u == null) return;
    const stale = Duration(minutes: 5);
    try {
      final trains = await ref.read(trainDataSourceProvider).nearbyTrains(u, state.rangeKm.toDouble());
      state = state.copyWith(trains: trains);
      _ok(NearbyKind.train, stale);
    } catch (e) {
      _fail(NearbyKind.train, e, stale);
    }
    _schedule(NearbyKind.train, AppConfig.trainPoll, _refreshTrains);
  }
}
