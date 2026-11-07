import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/core/geo/geo_utils.dart';
import 'package:nearby_live/features/trains/backend_train_source.dart';
import 'package:nearby_live/features/trains/train.dart';

void main() {
  // Shape of GET /v1/trains/nearby from ../backend.
  final json = {
    'count': 2,
    'items': [
      {
        'train': {'number': '54473', 'name': 'Delhi Saharanpur Passenger', 'from_code': 'DLI', 'to_code': 'SRE'},
        'position': {
          'status': 'running',
          'location': {'lat': 28.665, 'lon': 77.250},
          'bearing_deg': 45.0,
          'speed_kmh': 36.0,
          'segment_progress': 0.4,
          'prev_stop': {'code': 'DSB', 'location': {'lat': 28.660, 'lon': 77.244}},
          'next_stop': {'code': 'SHZM', 'location': {'lat': 28.672, 'lon': 77.259}},
        },
        'distance_km': 1.4,
      },
      {
        'train': {'number': '1'},
        'position': {'status': 'unknown'},
        'distance_km': 0,
      },
    ],
  };

  test('parses nearby trains and skips items without a location', () {
    final list = parseNearbyTrains(json);
    expect(list.length, 1);
    final e = list.single;
    expect(e.number, '54473');
    expect(e.status, 'running');
    expect(e.position, const GeoPoint(28.665, 77.250));
    expect(e.speedKmh, 36);
    expect(e.prevCode, 'DSB');
    expect(e.nextPoint, const GeoPoint(28.672, 77.259));
  });

  test('snaps onto a nearby rail line oriented along the bearing', () {
    final e = parseNearbyTrains(json).single;
    // A rail line running SW→NE through the estimate, listed NE→SW.
    final rail = [
      destinationPoint(e.position, 45, 3),
      destinationPoint(e.position, 45, 0.05),
      destinationPoint(e.position, 225, 3),
    ];
    final t = snapToRail(e, [rail], DateTime.utc(2026));
    expect(haversineKm(t.position, e.position), lessThan(.1));
    // Route was reversed so the head moves toward the NE end.
    expect(haversineKm(t.route.last, rail.first), lessThan(.001));
    expect(t.speedMs, closeTo(10, 1e-9));
    expect(t.status, TrainStatus.moving);
  });

  test('falls back to the station-to-station line when no rail is near', () {
    final e = parseNearbyTrains(json).single;
    final t = snapToRail(e, const [], DateTime.utc(2026));
    expect(t.route.length, 3);
    expect(haversineKm(t.position, e.position), lessThan(.05));
  });
}
