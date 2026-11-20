import 'dart:math' as math;

/// A WGS84 coordinate. Kept free of any map-plugin type so the domain and
/// data layers stay pure Dart and unit-testable.
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoPoint(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})';

  /// GeoJSON order: [lon, lat].
  List<double> toLonLat() => [lon, lat];
}

/// Axis-aligned bounding box in degrees.
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  bool contains(GeoPoint p) =>
      p.lat >= south && p.lat <= north && p.lon >= west && p.lon <= east;
}

double degToRad(double d) => d * math.pi / 180.0;
double radToDeg(double r) => r * 180.0 / math.pi;
