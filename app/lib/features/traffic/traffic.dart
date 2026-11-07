import '../../core/geo/geo_point.dart';

enum Congestion { free, light, moderate, heavy, closed }

/// Congestion from `currentSpeed / freeFlowSpeed`.
Congestion congestionFromSpeeds(double current, double freeFlow, {bool closed = false}) {
  if (closed) return Congestion.closed;
  if (freeFlow <= 0) return Congestion.free;
  final r = current / freeFlow;
  if (r >= 0.85) return Congestion.free;
  if (r >= 0.65) return Congestion.light;
  if (r >= 0.4) return Congestion.moderate;
  return Congestion.heavy;
}

String congestionLabel(Congestion c) => switch (c) {
      Congestion.free => 'Free flow',
      Congestion.light => 'Light',
      Congestion.moderate => 'Moderate',
      Congestion.heavy => 'Heavy',
      Congestion.closed => 'Closed',
    };

/// A road segment with its measured flow.
class TrafficSegment {
  const TrafficSegment({
    required this.id,
    required this.points,
    required this.currentSpeedKmh,
    required this.freeFlowSpeedKmh,
    this.roadName,
    this.closed = false,
  });

  final String id;
  final List<GeoPoint> points;
  final double currentSpeedKmh;
  final double freeFlowSpeedKmh;
  final String? roadName;
  final bool closed;

  Congestion get congestion => congestionFromSpeeds(currentSpeedKmh, freeFlowSpeedKmh, closed: closed);

  /// Jammed enough to show on the map.
  bool get isCongested => congestion.index >= Congestion.moderate.index;
}
