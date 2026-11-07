import '../../core/geo/geo_point.dart';

/// Scripted distances of the prototype's 40-second loop (km, null = not
/// reported). Pure, so it is unit-tested.
class DemoScenario {
  const DemoScenario({required this.jamKm, required this.eventKm});

  static const loopSeconds = 40.0;
  static const user = GeoPoint(28.6540, 77.2410);
  static const cameraCenter = GeoPoint(28.6606, 77.2436);
  static const event = GeoPoint(28.6513, 77.2468);

  /// Distance from the user to the nearest point of the jammed road.
  final double jamKm;

  /// Distance from the user to the event.
  final double eventKm;

  static double _lerp(double a, double b, double f) => a + (b - a) * f;

  /// Rises from [far] to [near] between [t0] and [t1], back to [far] by [t2].
  static double tri(double t, double t0, double t1, double t2, double far, double near) {
    if (t < t0) return far;
    if (t < t1) return _lerp(far, near, (t - t0) / (t1 - t0));
    if (t < t2) return _lerp(near, far, (t - t1) / (t2 - t1));
    return far;
  }

  Map<String, double?> distances(double t) {
    if (t > 37.5) {
      return {'train': null, 'flight': null, 'traffic': null, 'weather': t < 1.2 ? null : 0.0, 'event': null};
    }
    return {
      'train': tri(t, 0, 18, 36, 8, 1.6),
      'flight': tri(t, 3, 16, 36, 14, 2.6),
      'traffic': (t >= 4 && t < 35) ? jamKm : null,
      'weather': t >= 1.2 ? 0.0 : null,
      'event': (t >= 22 && t < 37) ? eventKm : null,
    };
  }
}
