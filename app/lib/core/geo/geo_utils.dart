import 'dart:math' as math;

import 'geo_point.dart';

/// Mean Earth radius in kilometres.
const double earthRadiusKm = 6371.0;

/// Great-circle distance between [a] and [b] in kilometres (Haversine).
double haversineKm(GeoPoint a, GeoPoint b) {
  final dLat = degToRad(b.lat - a.lat);
  final dLon = degToRad(b.lon - a.lon);
  final la = degToRad(a.lat);
  final lb = degToRad(b.lat);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(la) * math.cos(lb) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h.toDouble())));
}

/// Initial bearing from [a] to [b] in degrees, 0 = north, clockwise, 0..360.
double bearingDeg(GeoPoint a, GeoPoint b) {
  final la = degToRad(a.lat);
  final lb = degToRad(b.lat);
  final dLon = degToRad(b.lon - a.lon);
  final y = math.sin(dLon) * math.cos(lb);
  final x = math.cos(la) * math.sin(lb) - math.sin(la) * math.cos(lb) * math.cos(dLon);
  return (radToDeg(math.atan2(y, x)) + 360) % 360;
}

/// Point reached from [start] travelling [distanceKm] on [bearing] degrees.
GeoPoint destinationPoint(GeoPoint start, double bearing, double distanceKm) {
  final d = distanceKm / earthRadiusKm;
  final br = degToRad(bearing);
  final la = degToRad(start.lat);
  final lo = degToRad(start.lon);
  final lat2 = math.asin(math.sin(la) * math.cos(d) + math.cos(la) * math.sin(d) * math.cos(br));
  final lon2 = lo +
      math.atan2(math.sin(br) * math.sin(d) * math.cos(la), math.cos(d) - math.sin(la) * math.sin(lat2));
  return GeoPoint(radToDeg(lat2), ((radToDeg(lon2) + 540) % 360) - 180);
}

/// Bounding box that fully contains the circle of [radiusKm] around [center].
GeoBounds boundingBox(GeoPoint center, double radiusKm) {
  final dLat = radToDeg(radiusKm / earthRadiusKm);
  final cosLat = math.cos(degToRad(center.lat)).abs().clamp(1e-6, 1.0);
  final dLon = radToDeg(radiusKm / (earthRadiusKm * cosLat));
  return GeoBounds(
    south: math.max(-90.0, center.lat - dLat),
    north: math.min(90.0, center.lat + dLat),
    west: math.max(-180.0, center.lon - dLon),
    east: math.min(180.0, center.lon + dLon),
  );
}

/// True when [p] is within [rangeKm] of [user] (inclusive).
bool isInRange(GeoPoint user, GeoPoint p, double rangeKm) => haversineKm(user, p) <= rangeKm;

/// An item paired with its distance from the user.
class Ranged<T> {
  const Ranged(this.item, this.distanceKm);
  final T item;
  final double distanceKm;
}

/// Keeps the items whose position is within [rangeKm] of [user], nearest first.
List<Ranged<T>> filterInRange<T>(
  Iterable<T> items,
  GeoPoint user,
  double rangeKm,
  GeoPoint Function(T) positionOf,
) {
  final out = <Ranged<T>>[];
  for (final it in items) {
    final d = haversineKm(user, positionOf(it));
    if (d <= rangeKm) out.add(Ranged(it, d));
  }
  out.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  return out;
}

/// Shortest distance in km from [p] to the polyline [line] (local planar approx.).
double distanceToPolylineKm(GeoPoint p, List<GeoPoint> line) {
  if (line.isEmpty) return double.infinity;
  if (line.length == 1) return haversineKm(p, line.first);
  final proj = LocalProjector(p);
  var best = double.infinity;
  for (var i = 1; i < line.length; i++) {
    final a = proj.toMetres(line[i - 1]);
    final b = proj.toMetres(line[i]);
    final abx = b.x - a.x, aby = b.y - a.y;
    final len2 = abx * abx + aby * aby;
    var t = len2 == 0 ? 0.0 : (-(a.x) * abx + -(a.y) * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t, cy = a.y + aby * t;
    final d = math.sqrt(cx * cx + cy * cy);
    if (d < best) best = d;
  }
  return best / 1000.0;
}

/// Nearest point of [line] to [p].
GeoPoint nearestPointOnPolyline(GeoPoint p, List<GeoPoint> line) {
  if (line.length < 2) return line.isEmpty ? p : line.first;
  final proj = LocalProjector(p);
  var best = double.infinity;
  var bx = 0.0, by = 0.0;
  for (var i = 1; i < line.length; i++) {
    final a = proj.toMetres(line[i - 1]);
    final b = proj.toMetres(line[i]);
    final abx = b.x - a.x, aby = b.y - a.y;
    final len2 = abx * abx + aby * aby;
    var t = len2 == 0 ? 0.0 : (-(a.x) * abx + -(a.y) * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t, cy = a.y + aby * t;
    final d = cx * cx + cy * cy;
    if (d < best) {
      best = d;
      bx = cx;
      by = cy;
    }
  }
  return proj.toGeo(bx, by);
}

/// A point in local metres: x east, y north.
class Metres {
  const Metres(this.x, this.y);
  final double x;
  final double y;
}

/// Equirectangular projection around an origin, accurate to well under 1 %
/// within the 50 km radius the app works with. Mirrors the prototype's
/// `toM` / `toLL`.
class LocalProjector {
  LocalProjector(this.origin)
      : _mLat = 111320.0,
        _mLon = 111320.0 * math.cos(degToRad(origin.lat));

  final GeoPoint origin;
  final double _mLat;
  final double _mLon;

  Metres toMetres(GeoPoint p) => Metres((p.lon - origin.lon) * _mLon, (p.lat - origin.lat) * _mLat);

  GeoPoint toGeo(double x, double y) => GeoPoint(origin.lat + y / _mLat, origin.lon + x / _mLon);
}

/// A position along a polyline plus its heading (radians, math convention:
/// 0 = east, counter-clockwise).
class PolyPos {
  const PolyPos(this.x, this.y, this.angle);
  final double x;
  final double y;
  final double angle;

  /// Heading as a compass bearing in degrees (0 = north, clockwise).
  double get bearing => (90 - radToDeg(angle) + 360) % 360;
}

class _PolyVertex {
  const _PolyVertex(this.x, this.y, this.s);
  final double x;
  final double y;
  final double s;
}

/// Polyline with arc length in local metres. Port of the prototype's
/// `line()`, `at()` and `ribbon()` helpers; all 3D models are built from it.
class Polyline {
  Polyline._(this.projector, this._pts, this.length);

  factory Polyline.fromGeo(List<GeoPoint> coords, LocalProjector projector) {
    final pts = <_PolyVertex>[];
    var s = 0.0;
    Metres? prev;
    for (final c in coords) {
      final m = projector.toMetres(c);
      if (prev != null) {
        final dx = m.x - prev.x, dy = m.y - prev.y;
        final step = math.sqrt(dx * dx + dy * dy);
        if (step < 1e-6) continue; // drop duplicate vertices
        s += step;
      }
      pts.add(_PolyVertex(m.x, m.y, s));
      prev = m;
    }
    return Polyline._(projector, pts, s);
  }

  final LocalProjector projector;
  final List<_PolyVertex> _pts;
  final double length;

  bool get isEmpty => _pts.length < 2;

  /// Position and heading at arc length [s] (clamped to the line).
  PolyPos at(double s) {
    if (_pts.isEmpty) return const PolyPos(0, 0, 0);
    if (_pts.length == 1) return PolyPos(_pts.first.x, _pts.first.y, 0);
    final sc = s.clamp(0.0, length);
    var lo = 0, hi = _pts.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) >> 1;
      if (_pts[m].s < sc) {
        lo = m;
      } else {
        hi = m;
      }
    }
    final a = _pts[lo], b = _pts[hi];
    final span = b.s - a.s;
    final f = span == 0 ? 0.0 : (sc - a.s) / span;
    return PolyPos(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, math.atan2(b.y - a.y, b.x - a.x));
  }

  GeoPoint geoAt(double s) {
    final p = at(s);
    return projector.toGeo(p.x, p.y);
  }

  /// Arc length of the vertex closest to [p].
  double nearestArc(GeoPoint p) {
    final m = projector.toMetres(p);
    var best = double.infinity;
    var bs = 0.0;
    for (final v in _pts) {
      final dx = v.x - m.x, dy = v.y - m.y;
      final d = dx * dx + dy * dy;
      if (d < best) {
        best = d;
        bs = v.s;
      }
    }
    return bs;
  }

  /// Closed polygon ring (GeoJSON [lon, lat] pairs) of a strip along the line
  /// between [s0] and [s1] with centre offset [offset] and half-width tapering
  /// from [w0] to [w1] (metres).
  List<List<double>> ribbon(double s0, double s1, double w0, double w1, [double offset = 0]) {
    final n = math.max(2, ((s1 - s0) / 14).ceil());
    final left = <List<double>>[];
    final right = <List<double>>[];
    for (var i = 0; i <= n; i++) {
      final f = i / n;
      final s = s0 + (s1 - s0) * f;
      final p = at(s);
      final w = w0 + (w1 - w0) * f;
      final nx = -math.sin(p.angle), ny = math.cos(p.angle);
      left.add(projector.toGeo(p.x + nx * (offset + w), p.y + ny * (offset + w)).toLonLat());
      right.add(projector.toGeo(p.x + nx * (offset - w), p.y + ny * (offset - w)).toLonLat());
    }
    final ring = [...left, ...right.reversed];
    ring.add(ring.first);
    return ring;
  }

  /// Polyline vertices back as geo points.
  List<GeoPoint> toGeoList() => [for (final v in _pts) projector.toGeo(v.x, v.y)];
}

/// Axis-aligned rectangle ring around a local centre (metres), as GeoJSON pairs.
List<List<double>> rectRing(LocalProjector proj, double cx, double cy, double w, double h) {
  final r = [
    [cx - w / 2, cy - h / 2],
    [cx + w / 2, cy - h / 2],
    [cx + w / 2, cy + h / 2],
    [cx - w / 2, cy + h / 2],
    [cx - w / 2, cy - h / 2],
  ];
  return [for (final p in r) proj.toGeo(p[0], p[1]).toLonLat()];
}

/// Formats a distance like the prototype: one decimal under 10 km.
String formatKm(double? d) {
  if (d == null) return '–';
  if (d < 10) return '${d.toStringAsFixed(1)} km';
  return '${d.round()} km';
}
