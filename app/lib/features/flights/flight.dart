import 'dart:math' as math;

import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';

/// One aircraft state vector from OpenSky.
class FlightState {
  const FlightState({
    required this.icao24,
    required this.callsign,
    required this.position,
    required this.altitudeM,
    required this.velocityMs,
    required this.trackDeg,
    required this.onGround,
    required this.fixTime,
    this.originCountry = '',
  });

  final String icao24;
  final String callsign;
  final GeoPoint position;
  final double altitudeM;
  final double velocityMs;

  /// True track, degrees clockwise from north.
  final double trackDeg;
  final bool onGround;

  /// Time of the position fix.
  final DateTime fixTime;
  final String originCountry;
}

/// Dead-reckons [s] to [now]: position + velocity × elapsed along the track.
GeoPoint deadReckon(FlightState s, DateTime now) {
  final dt = now.difference(s.fixTime).inMilliseconds / 1000.0;
  if (dt <= 0 || s.velocityMs <= 0 || s.onGround) return s.position;
  // Never extrapolate more than 2 minutes on a stale fix.
  final t = math.min(dt, 120.0);
  return destinationPoint(s.position, s.trackDeg, s.velocityMs * t / 1000.0);
}

/// Smoothly tracked aircraft. On every new fix the visible position keeps
/// flying from where it was and blends onto the new dead-reckoned path over
/// [snapDuration], so the plane never jumps.
class FlightTrack {
  FlightTrack(this.state);

  FlightState state;
  String? route;
  Metres _offset = const Metres(0, 0);
  DateTime? _offsetAt;

  static const snapDuration = Duration(seconds: 3);

  void update(FlightState next, DateTime now) {
    final shown = positionAt(now);
    final predicted = deadReckon(next, now);
    final proj = LocalProjector(predicted);
    _offset = proj.toMetres(shown);
    _offsetAt = now;
    state = next;
  }

  GeoPoint positionAt(DateTime now) {
    final base = deadReckon(state, now);
    final at = _offsetAt;
    if (at == null) return base;
    final f = 1 - now.difference(at).inMilliseconds / snapDuration.inMilliseconds;
    if (f <= 0) return base;
    final k = f * f; // ease out
    return LocalProjector(base).toGeo(_offset.x * k, _offset.y * k);
  }
}
