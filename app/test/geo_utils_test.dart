import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/core/geo/geo_utils.dart';
import 'package:nearby_live/features/nearby/scene/live_director.dart';

void main() {
  const redFort = GeoPoint(28.6562, 77.2410);
  const indiaGate = GeoPoint(28.6129, 77.2295);

  group('haversineKm', () {
    test('is zero for the same point', () {
      expect(haversineKm(redFort, redFort), 0);
    });

    test('Red Fort → India Gate is about 4.9 km', () {
      expect(haversineKm(redFort, indiaGate), closeTo(4.94, 0.05));
    });

    test('one degree of latitude is about 111.2 km', () {
      expect(haversineKm(const GeoPoint(0, 0), const GeoPoint(1, 0)), closeTo(111.19, 0.01));
    });

    test('is symmetric', () {
      expect(haversineKm(redFort, indiaGate), closeTo(haversineKm(indiaGate, redFort), 1e-9));
    });

    test('Delhi → Mumbai airports are about 1137 km apart', () {
      expect(haversineKm(const GeoPoint(28.5562, 77.1000), const GeoPoint(19.0896, 72.8656)), closeTo(1137, 5));
    });
  });

  group('destination / bearing', () {
    test('destinationPoint round-trips with haversine and bearing', () {
      for (final b in [0.0, 45.0, 90.0, 180.0, 270.0]) {
        final p = destinationPoint(redFort, b, 5);
        expect(haversineKm(redFort, p), closeTo(5, 1e-6));
        final diff = ((bearingDeg(redFort, p) - b + 540) % 360) - 180; // wrap-around safe
        expect(diff.abs(), lessThan(0.05));
      }
    });

    test('bearing north is 0 and east is ~90', () {
      expect(bearingDeg(const GeoPoint(0, 0), const GeoPoint(1, 0)), closeTo(0, 1e-9));
      expect(bearingDeg(const GeoPoint(0, 0), const GeoPoint(0, 1)), closeTo(90, 1e-9));
    });
  });

  group('boundingBox', () {
    test('contains the full radius in every direction', () {
      final box = boundingBox(redFort, 10);
      for (final b in [0.0, 90.0, 180.0, 270.0, 33.0]) {
        expect(box.contains(destinationPoint(redFort, b, 9.99)), isTrue, reason: 'bearing $b');
      }
      expect(box.contains(destinationPoint(redFort, 0, 10.5)), isFalse);
    });
  });

  group('range filtering', () {
    final user = redFort;
    final items = [
      ('far', destinationPoint(user, 10, 12)),
      ('near', destinationPoint(user, 200, 1.2)),
      ('edge', destinationPoint(user, 90, 4.999)),
      ('mid', destinationPoint(user, 300, 3)),
    ];

    test('keeps only items within range, nearest first', () {
      final r = filterInRange(items, user, 5, (i) => i.$2);
      expect(r.map((e) => e.item.$1), ['near', 'mid', 'edge']);
      expect(r.first.distanceKm, closeTo(1.2, 1e-6));
    });

    test('range is inclusive and each preset behaves', () {
      expect(isInRange(user, destinationPoint(user, 0, 2), 2), isTrue);
      expect(filterInRange(items, user, 2, (i) => i.$2).length, 1);
      expect(filterInRange(items, user, 10, (i) => i.$2).length, 3);
      expect(filterInRange(items, user, 50, (i) => i.$2).length, 4);
    });

    test('distance to a polyline uses the nearest segment', () {
      final line = [destinationPoint(user, 270, 2), destinationPoint(user, 90, 2)];
      final p = destinationPoint(user, 0, 1);
      expect(distanceToPolylineKm(p, line), closeTo(1, 0.01));
    });
  });

  group('Polyline', () {
    final proj = LocalProjector(redFort);
    final line = Polyline.fromGeo([redFort, destinationPoint(redFort, 90, 1), destinationPoint(redFort, 90, 2)], proj);

    test('arc length matches the geodesic length', () {
      expect(line.length, closeTo(2000, 5));
    });

    test('at() interpolates and reports heading east', () {
      final p = line.at(500);
      expect(p.x, closeTo(500, 3));
      expect(p.y, closeTo(0, 3));
      expect(p.bearing, closeTo(90, .5));
    });

    test('ribbon is a closed ring', () {
      final ring = line.ribbon(100, 400, 10, 10);
      expect(ring.first, ring.last);
      expect(ring.length, greaterThan(6));
    });
  });

  group('camera framing', () {
    test('zoom decreases as the range grows and respects the caps', () {
      final z2 = zoomForRange(2, 28.65, 400);
      final z5 = zoomForRange(5, 28.65, 400);
      final z10 = zoomForRange(10, 28.65, 400);
      final z50 = zoomForRange(50, 28.65, 400);
      expect(z2, greaterThan(z5));
      expect(z5, greaterThan(z10));
      expect(z10, greaterThan(z50));
      expect(z2, lessThanOrEqualTo(14.5));
      expect(z50, lessThanOrEqualTo(9.9));
    });
  });

  test('formatKm matches the prototype', () {
    expect(formatKm(null), '–');
    expect(formatKm(2.345), '2.3 km');
    expect(formatKm(12.6), '13 km');
  });
}
