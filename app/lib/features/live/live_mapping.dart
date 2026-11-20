import '../../core/geo/geo_point.dart';
import '../flights/flight.dart';
import '../traffic/traffic.dart';
import '../trains/backend_train_source.dart';
import '../weather/weather.dart';
import 'live_models.dart';
import 'live_stream.dart';

/// Hub flight → [FlightState]. The hub has already dead-reckoned the
/// position to the send time, so the fix time is when it was received.
FlightState flightFromLive(LiveObject o, DateTime received) => FlightState(
      icao24: o.id,
      callsign: o.label,
      originCountry: '${o.extra['country'] ?? ''}',
      position: o.position,
      altitudeM: o.altitudeM ?? 0,
      velocityMs: o.speedKmh / 3.6,
      trackDeg: o.headingDeg,
      onGround: o.onGround,
      fixTime: received,
    );

/// Hub train → estimate that [snapToRail] turns into a drawable [Train].
BackendTrainEstimate trainEstimateFromLive(LiveObject o) => BackendTrainEstimate(
      number: o.id,
      name: o.name ?? o.label,
      fromCode: '${o.extra['from'] ?? ''}',
      toCode: '${o.extra['to'] ?? ''}',
      status: o.status ?? 'running',
      position: o.position,
      bearingDeg: o.headingDeg,
      speedKmh: o.speedKmh,
      distanceKm: o.distanceKm ?? 0,
      prevCode: o.prevStop,
      nextCode: o.nextStop,
      delayMin: o.delayMin,
    );

/// Hub weather cell → [Weather].
Weather weatherFromLive(LiveObject o, DateTime received) {
  double d(String k) => (o.extra[k] as num?)?.toDouble() ?? 0;
  return Weather(
    temperatureC: d('temperature_c'),
    humidityPct: d('humidity_pct').round(),
    windKmh: d('wind_kmh'),
    rainPct: d('rain_pct').round(),
    code: d('code').round(),
    observedAt: received,
  );
}

/// Hub traffic segment → [TrafficSegment] (null without geometry).
TrafficSegment? trafficFromLive(LiveObject o) {
  final coords = o.extra['coordinates'];
  if (coords is! List) return null;
  final pts = <GeoPoint>[
    for (final c in coords)
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num) GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
  ];
  if (pts.length < 2) return null;
  return TrafficSegment(
    id: o.id,
    points: pts,
    currentSpeedKmh: (o.extra['current_kmh'] as num?)?.toDouble() ?? o.speedKmh,
    freeFlowSpeedKmh: (o.extra['free_flow_kmh'] as num?)?.toDouble() ?? 0,
    roadName: o.label.isEmpty ? null : o.label,
    closed: o.extra['closed'] == true,
  );
}

/// Hub event → [NearbyEvent].
NearbyEvent eventFromLive(LiveObject o) {
  DateTime? start;
  final d = o.extra['local_date'], t = o.extra['local_time'];
  if (d is String && d.isNotEmpty) start = DateTime.tryParse('${d}T${t is String && t.isNotEmpty ? t : '00:00:00'}');
  return NearbyEvent(
    id: o.id,
    name: o.label,
    position: o.position,
    venue: o.name,
    start: start,
    category: o.extra['category'] as String?,
  );
}

/// Hub bus / metro → [TransitVehicle].
TransitVehicle transitFromLive(LiveObject o) => TransitVehicle(
      id: o.id,
      kind: o.kind,
      label: o.label,
      route: o.name,
      position: o.position,
      headingDeg: o.headingDeg,
      speedKmh: o.speedKmh,
    );
