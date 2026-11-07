import 'dart:math' as math;
import 'dart:ui';

import '../../../core/geo/geo_point.dart';
import '../../../core/geo/geo_utils.dart';
import '../../flights/flight.dart';
import '../../traffic/traffic.dart';
import '../../trains/train.dart';
import '../application/nearby_controller.dart';
import '../domain/presence.dart';
import 'models_3d.dart';
import 'scene.dart';

/// Camera zoom that fits a [rangeKm] circle into ~44 % of the screen width at
/// the user's latitude, capped at the plan's per-range zoom.
double zoomForRange(double rangeKm, double latDeg, double screenWidth) {
  const cap = {2: 14.5, 5: 13.2, 10: 12.2, 50: 9.9};
  final mpp = rangeKm * 1000 / (0.44 * math.max(200, screenWidth));
  // MapLibre: metres per logical pixel at zoom z = 78271.517 · cos(lat) / 2^z.
  final z = math.log(78271.517 * math.cos(degToRad(latDeg)) / mpp) / math.ln2;
  final c = cap[rangeKm.round()] ?? 14.5;
  return z.clamp(3.0, c);
}

/// Camera that keeps the user in the lower-middle of a pitched view.
CameraFrame cameraForUser(GeoPoint user, double rangeKm, Size viewport, {double bearing = -8, double pitch = 60}) {
  final zoom = zoomForRange(rangeKm, user.lat, viewport.width);
  final mpp = 78271.517 * math.cos(degToRad(user.lat)) / math.pow(2, zoom).toDouble();
  // Screen-vertical ground distance per pixel is ~1/cos(pitch) near the centre.
  final shiftPx = viewport.height * .12;
  final shiftM = shiftPx * mpp / math.cos(degToRad(pitch));
  return CameraFrame(
    center: destinationPoint(user, bearing, shiftM / 1000),
    zoom: zoom,
    pitch: pitch,
    bearing: bearing,
  );
}

class _TrainAnim {
  _TrainAnim() : presence = Presence(enterDuration: const Duration(milliseconds: 1600));
  final Presence presence;
  double extra = 0;
}

class _FlightAnim {
  final presence = Presence();
}

/// Turns [NearbyState] (live data) into per-frame scenes: presence state per
/// object, dead reckoning, 3D models, overlays and cards.
class LiveDirector implements SceneDirector {
  LiveDirector({required this.read, required this.viewport});

  final NearbyState Function() read;
  final Size Function() viewport;

  final _trains = <String, _TrainAnim>{};
  final _flights = <String, _FlightAnim>{};
  final _traffic = Presence(enterDuration: const Duration(milliseconds: 1200));
  final _weather = Presence();

  LocalProjector? _proj;
  List<TrafficSegment>? _vehicleSource;
  List<RoadVehicle> _vehicles = const [];
  List<Polyline> _jamLines = const [];
  int _staticVersion = 0;
  String _staticKey = '';
  List<Json> _static = const [];

  static const _maxTrains = 3;
  static const _maxFlightPins = 5;

  @override
  SceneSnapshot tick(double dt, DateTime now) {
    final st = read();
    final user = st.user ?? const GeoPoint(28.6540, 77.2410);
    final range = st.rangeKm.toDouble();
    final camera = cameraForUser(user, range, viewport());
    final iconMode = range >= 10;
    final k = modelScaleForZoom(camera.zoom);

    var proj = _proj;
    if (proj == null || haversineKm(proj.origin, user) > 2) {
      proj = _proj = LocalProjector(user);
      _vehicleSource = null; // re-anchor road geometry
      _staticKey = '';
    }

    final movers = <Json>[];
    final items = <SceneItem>[];
    final cards = <NearbyKind, CardInfo>{};

    // ---------------------------------------------------------------- trains
    final trains = st.trainsByDistance(now).take(_maxTrains).toList();
    final liveIds = trains.map((t) => t.item.id).toSet();
    _trains.removeWhere((id, a) => !liveIds.contains(id) && !a.presence.isVisible);
    final shownTrains = <Ranged<Train>>[];
    final staticParts = <Json>[];
    final staticKey = StringBuffer();
    for (final r in trains) {
      final t = r.item;
      final anim = _trains.putIfAbsent(t.id, _TrainAnim.new);
      final inRange = r.distanceKm <= range;
      anim.presence.update(dt, inRange);
      if (anim.presence.phase == PresencePhase.leaving) {
        // Accelerate away along the track.
        anim.extra += (60 + anim.presence.phaseTime * 260) * dt;
      } else if (anim.presence.phase == PresencePhase.hidden) {
        anim.extra = 0;
      }
      if (!anim.presence.isVisible) continue;
      final line = Polyline.fromGeo(t.route, proj);
      final since = now.difference(t.fixTime).inMilliseconds / 1000.0;
      // Ease in: the train glides the last stretch into its real position.
      final approachLag = (1 - Curves.easeOutCubic(anim.presence.value)) * 400 * k;
      final head = t.arcM + t.speedMs * since + anim.extra - approachLag;
      if (!iconMode) {
        buildTrain(line, head, movers, k: k);
        staticKey.write('${t.id};');
        final (s0, s1) = _inRangeStretch(line, user, range);
        buildViaduct(line, staticParts, k: k, from: s0, to: s1);
      }
      final anchorArc = math.max(0.0, head - TrainDims.carLength * 1.5 * k);
      items.add(SceneItem(
        kind: NearbyKind.train,
        id: t.id,
        anchor: line.geoAt(anchorArc),
        vis: anim.presence.value,
        shown: anim.presence.isShown,
        distanceKm: r.distanceKm,
        primary: shownTrains.isEmpty,
      ));
      if (anim.presence.isShown && inRange) shownTrains.add(r);
    }
    if (shownTrains.isNotEmpty) {
      final t = shownTrains.first;
      cards[NearbyKind.train] = CardInfo(
        title: 'Train',
        subtitle: '${t.item.name}\n(${t.item.from} → ${t.item.to})',
        status: trainStatusLabel(t.item.status) + (t.item.estimated ? ' · est.' : ''),
        distanceKm: t.distanceKm,
        moreCount: shownTrains.length - 1,
      );
    }
    final key = '$staticKey|${st.rangeKm}|${k.toStringAsFixed(2)}';
    if (key != _staticKey) {
      _staticKey = key;
      _static = staticParts;
      _staticVersion++;
    }

    // --------------------------------------------------------------- flights
    final flights = st.flightsByDistance(now);
    final flightIds = flights.map((f) => f.item.state.icao24).toSet();
    _flights.removeWhere((id, a) => !flightIds.contains(id) && !a.presence.isVisible);
    final shownFlights = <Ranged<FlightTrack>>[];
    var pins = 0;
    for (final r in flights) {
      final f = r.item;
      final anim = _flights.putIfAbsent(f.state.icao24, _FlightAnim.new);
      final inRange = r.distanceKm <= range;
      anim.presence.update(dt, inRange);
      if (!anim.presence.isVisible || pins >= _maxFlightPins) continue;
      pins++;
      items.add(SceneItem(
        kind: NearbyKind.flight,
        id: f.state.icao24,
        anchor: f.positionAt(now),
        liftPx: (f.state.altitudeM / 1000 * 14).clamp(24.0, 110.0),
        headingDeg: f.state.trackDeg,
        vis: anim.presence.value,
        shown: anim.presence.isShown,
        distanceKm: r.distanceKm,
        primary: shownFlights.isEmpty && anim.presence.isShown,
      ));
      if (anim.presence.isShown && inRange) shownFlights.add(r);
    }
    if (shownFlights.isNotEmpty) {
      final f = shownFlights.first.item;
      final cs = f.state.callsign.isEmpty ? f.state.icao24.toUpperCase() : f.state.callsign;
      cards[NearbyKind.flight] = CardInfo(
        title: 'Flight',
        subtitle: f.route == null ? cs : '$cs (${f.route})',
        status: 'In Air · ${(f.state.altitudeM / 1000).toStringAsFixed(1)} km',
        distanceKm: shownFlights.first.distanceKm,
        moreCount: shownFlights.length - 1,
      );
    }

    // --------------------------------------------------------------- traffic
    final jams = st.trafficByDistance().where((r) => r.item.isCongested && r.distanceKm <= range).toList();
    _traffic.update(dt, jams.isNotEmpty);
    if (!identical(_vehicleSource, st.traffic)) {
      _vehicleSource = st.traffic;
      final congested = st.traffic.where((s) => s.isCongested).toList();
      _jamLines = [for (final s in congested) Polyline.fromGeo(s.points, proj)];
      _vehicles = [
        for (var i = 0; i < congested.length; i++)
          ...spawnVehicles(
            [_jamLines[i]],
            seed: i + 9,
            speedFactor: congested[i].currentSpeedKmh / math.max(1.0, congested[i].freeFlowSpeedKmh),
            cap: 8,
          ),
      ].take(60).toList();
    }
    final flows = <FlowLine>[];
    if (_traffic.isVisible) {
      for (final r in jams) {
        final c = r.item.congestion;
        flows.add(FlowLine(
          [for (final p in r.item.points) p.toLonLat()],
          c == Congestion.heavy || c == Congestion.closed ? '#ff2d2d' : '#ff9a1f',
          _traffic.value,
        ));
      }
      for (final v in _vehicles) {
        v.step(dt);
      }
      if (!iconMode) buildVehicles(_vehicles, _traffic.value, movers, k: k);
      if (jams.isNotEmpty) {
        final nearest = jams.first;
        items.add(SceneItem(
          kind: NearbyKind.traffic,
          id: nearest.item.id,
          anchor: nearestPointOnPolyline(user, nearest.item.points),
          vis: _traffic.value,
          shown: _traffic.isShown,
          distanceKm: nearest.distanceKm,
        ));
        if (_traffic.isShown) {
          final name = nearest.item.roadName;
          cards[NearbyKind.traffic] = CardInfo(
            title: 'Road Traffic',
            subtitle: '${congestionLabel(nearest.item.congestion)}${name == null ? '' : ' · $name'}',
            status: st.trafficIsMock ? 'Simulated' : null,
            distanceKm: nearest.distanceKm,
            moreCount: jams.length - 1,
          );
        }
      }
    }

    // --------------------------------------------------------------- weather
    final w = st.weather;
    _weather.update(dt, w != null);
    if (w != null && _weather.isShown) {
      cards[NearbyKind.weather] = CardInfo(title: 'Weather', subtitle: w.label, distanceKm: 0);
    }

    return SceneSnapshot(
      user: user,
      rangeKm: range,
      status: st.liveStatus(now),
      camera: camera,
      movers: movers,
      staticVersion: _staticVersion,
      staticFeatures: _static,
      flows: flows,
      items: items,
      cards: cards,
      weather: w,
      weatherVis: _weather.isShown ? 1.0 : 0.0,
    );
  }

  /// Arc range of [line] that lies within [rangeKm] of [user].
  static (double, double) _inRangeStretch(Polyline line, GeoPoint user, double rangeKm) {
    double? s0, s1;
    final step = math.max(25.0, line.length / 400);
    for (var s = 0.0; s <= line.length; s += step) {
      if (haversineKm(user, line.geoAt(s)) <= rangeKm) {
        s0 ??= s;
        s1 = s;
      }
    }
    return (s0 ?? 0, s1 ?? 0);
  }
}

/// Minimal easing used without importing the widgets library here.
abstract final class Curves {
  static double easeOutCubic(double t) {
    final u = 1 - t.clamp(0.0, 1.0);
    return 1 - u * u * u;
  }
}
