import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/core/geo/geo_utils.dart';
import 'package:nearby_live/core/osm/overpass_api.dart';
import 'package:nearby_live/features/flights/flight.dart';
import 'package:nearby_live/features/flights/opensky_api.dart';
import 'package:nearby_live/features/traffic/traffic.dart';
import 'package:nearby_live/features/traffic/traffic_source.dart';
import 'package:nearby_live/features/trains/train_data_source.dart';
import 'package:nearby_live/features/weather/open_meteo_api.dart';
import 'package:nearby_live/features/weather/weather.dart';

void main() {
  group('Open-Meteo', () {
    test('parses the current block', () {
      final w = parseOpenMeteo({
        'latitude': 28.65,
        'longitude': 77.24,
        'current_units': {'temperature_2m': '°C'},
        'current': {
          'time': '2026-11-07T10:45',
          'interval': 900,
          'temperature_2m': 27.6,
          'relative_humidity_2m': 62,
          'wind_speed_10m': 11.9,
          'precipitation_probability': 10,
          'weather_code': 2,
        },
      });
      expect(w.temperatureC, 27.6);
      expect(w.humidityPct, 62);
      expect(w.windKmh, 11.9);
      expect(w.rainPct, 10);
      expect(w.code, 2);
      expect(w.label, 'Partly Cloudy');
      expect(w.visual, WeatherVisual.partlyCloudy);
    });

    test('tolerates missing optional fields', () {
      final w = parseOpenMeteo({
        'current': {'temperature_2m': 20, 'weather_code': 61},
      });
      expect(w.temperatureC, 20);
      expect(w.rainPct, 0);
      expect(w.visual, WeatherVisual.rain);
    });

    test('throws without a current block', () {
      expect(() => parseOpenMeteo({}), throwsFormatException);
    });

    test('weather codes map to labels and visuals', () {
      expect(weatherLabel(0), 'Clear Sky');
      expect(weatherVisual(0), WeatherVisual.sun);
      expect(weatherVisual(95), WeatherVisual.storm);
      expect(weatherVisual(73), WeatherVisual.snow);
      expect(weatherVisual(45), WeatherVisual.fog);
    });
  });

  group('OpenSky', () {
    final json = {
      'time': 1762512000,
      'states': [
        ['800c1b', 'AIC138  ', 'India', 1762511995, 1762511999, 77.21, 28.62, 3200.5, false, 180.2, 245.0, -5.2, null, 3350.0, '1234', false, 0],
        // No position: skipped.
        ['800aaa', 'IGO22   ', 'India', null, 1762511999, null, null, null, false, null, null, null, null, null, null, false, 0],
        ['800bbb', '', 'India', null, 1762511990, 77.10, 28.55, null, true, 0.0, 90.0, null, null, null, null, false, 0],
      ],
    };

    test('parses state vectors and skips rows without a position', () {
      final s = parseOpenSkyStates(json);
      expect(s.length, 2);
      final a = s.first;
      expect(a.icao24, '800c1b');
      expect(a.callsign, 'AIC138');
      expect(a.position, const GeoPoint(28.62, 77.21));
      expect(a.altitudeM, 3350.0); // geo altitude preferred
      expect(a.velocityMs, 180.2);
      expect(a.trackDeg, 245.0);
      expect(a.onGround, isFalse);
      expect(a.fixTime, DateTime.fromMillisecondsSinceEpoch(1762511995 * 1000, isUtc: true));
      expect(s[1].onGround, isTrue);
      // Falls back to last_contact when time_position is null.
      expect(s[1].fixTime.millisecondsSinceEpoch, 1762511990 * 1000);
    });

    test('empty / null states', () {
      expect(parseOpenSkyStates({'time': 1, 'states': null}), isEmpty);
      expect(parseOpenSkyStates({}), isEmpty);
    });

    test('dead reckoning moves the aircraft along its track', () {
      final fix = FlightState(
        icao24: 'x',
        callsign: 'T',
        position: const GeoPoint(28.6, 77.2),
        altitudeM: 3000,
        velocityMs: 100,
        trackDeg: 0,
        onGround: false,
        fixTime: DateTime.utc(2026, 1, 1, 12),
      );
      final p = deadReckon(fix, DateTime.utc(2026, 1, 1, 12, 0, 10));
      expect(haversineKm(fix.position, p), closeTo(1.0, 1e-6));
      expect(p.lat, greaterThan(fix.position.lat));
      expect(p.lon, closeTo(fix.position.lon, 1e-9));
      // Capped at two minutes of extrapolation.
      final far = deadReckon(fix, DateTime.utc(2026, 1, 1, 13));
      expect(haversineKm(fix.position, far), closeTo(12.0, 1e-6));
    });

    test('a new fix blends in without a jump', () {
      final t0 = DateTime.utc(2026, 1, 1, 12);
      final track = FlightTrack(FlightState(
        icao24: 'x',
        callsign: 'T',
        position: const GeoPoint(28.6, 77.2),
        altitudeM: 3000,
        velocityMs: 100,
        trackDeg: 90,
        onGround: false,
        fixTime: t0,
      ));
      final now = t0.add(const Duration(seconds: 20));
      final before = track.positionAt(now);
      // The new fix is 300 m north of the dead-reckoned position.
      final corrected = destinationPoint(before, 0, .3);
      track.update(
        FlightState(
          icao24: 'x',
          callsign: 'T',
          position: corrected,
          altitudeM: 3000,
          velocityMs: 100,
          trackDeg: 90,
          onGround: false,
          fixTime: now,
        ),
        now,
      );
      expect(haversineKm(track.positionAt(now), before), lessThan(.001));
      final settled = track.positionAt(now.add(FlightTrack.snapDuration));
      final expected = deadReckon(track.state, now.add(FlightTrack.snapDuration));
      expect(haversineKm(settled, expected), lessThan(.001));
    });

    test('adsbdb route text', () {
      expect(
        parseAdsbdbRoute({
          'response': {
            'flightroute': {
              'callsign': 'AIC138',
              'origin': {'iata_code': 'DEL', 'icao_code': 'VIDP'},
              'destination': {'iata_code': 'BOM', 'icao_code': 'VABB'},
            },
          },
        }),
        'DEL → BOM',
      );
      expect(parseAdsbdbRoute({'response': 'unknown callsign'}), isNull);
    });

    test('backoff doubles on 429 and resets on success', () {
      final b = Backoff(base: const Duration(seconds: 20), max: const Duration(minutes: 2));
      expect(b.fail(), const Duration(seconds: 40));
      expect(b.fail(), const Duration(seconds: 80));
      expect(b.fail(), const Duration(minutes: 2));
      expect(b.fail(const Duration(minutes: 10)), const Duration(minutes: 2));
      expect(b.succeed(), const Duration(seconds: 20));
      expect(b.fail(const Duration(seconds: 90)), const Duration(seconds: 90));
    });
  });

  group('TomTom flow', () {
    test('parses a flow segment and derives congestion', () {
      final seg = parseTomTomFlow({
        'flowSegmentData': {
          'frc': 'FRC2',
          'currentSpeed': 12,
          'freeFlowSpeed': 45,
          'currentTravelTime': 300,
          'freeFlowTravelTime': 80,
          'confidence': 0.95,
          'roadClosure': false,
          'coordinates': {
            'coordinate': [
              {'latitude': 28.651, 'longitude': 77.240},
              {'latitude': 28.652, 'longitude': 77.242},
              {'latitude': 28.653, 'longitude': 77.244},
            ],
          },
        },
      })!;
      expect(seg.points.length, 3);
      expect(seg.currentSpeedKmh, 12);
      expect(seg.freeFlowSpeedKmh, 45);
      expect(seg.congestion, Congestion.heavy);
      expect(seg.isCongested, isTrue);
      expect(seg.roadName, 'Main Road');
    });

    test('returns null without coordinates', () {
      expect(parseTomTomFlow({'flowSegmentData': {'currentSpeed': 1}}), isNull);
      expect(parseTomTomFlow({}), isNull);
    });

    test('congestion thresholds', () {
      expect(congestionFromSpeeds(50, 50), Congestion.free);
      expect(congestionFromSpeeds(35, 50), Congestion.light);
      expect(congestionFromSpeeds(25, 50), Congestion.moderate);
      expect(congestionFromSpeeds(10, 50), Congestion.heavy);
      expect(congestionFromSpeeds(50, 50, closed: true), Congestion.closed);
    });

    test('sample points stay inside the range', () {
      const c = GeoPoint(28.654, 77.241);
      final pts = TomTomTrafficSource.samplePoints(c, 5);
      expect(pts.length, 13);
      for (final p in pts) {
        expect(haversineKm(c, p), lessThanOrEqualTo(5));
      }
    });
  });

  group('Overpass', () {
    final json = {
      'elements': [
        {
          'type': 'way',
          'id': 1,
          'tags': {'railway': 'rail', 'name': 'Delhi–Ghaziabad line'},
          'geometry': [
            {'lat': 28.650, 'lon': 77.230},
            {'lat': 28.651, 'lon': 77.240},
          ],
        },
        {
          'type': 'way',
          'id': 2,
          'tags': {'railway': 'rail'},
          'geometry': [
            {'lat': 28.651, 'lon': 77.240},
            {'lat': 28.652, 'lon': 77.250},
          ],
        },
        {'type': 'node', 'id': 3, 'lat': 1, 'lon': 2},
      ],
    };

    test('parses ways with geometry and tags', () {
      final ways = parseOverpassWays(json);
      expect(ways.length, 2);
      expect(ways.first.name, 'Delhi–Ghaziabad line');
      expect(ways.first.points.last, const GeoPoint(28.651, 77.240));
    });

    test('stitches touching ways into one route', () {
      final ways = parseOverpassWays(json);
      final routes = stitchWays([for (final w in ways) w.points]);
      expect(routes.length, 1);
      expect(routes.first.length, 3);
    });

    test('mock trains run on real routes', () {
      const origin = GeoPoint(28.651, 77.240);
      final route = [for (var i = 0; i <= 40; i++) destinationPoint(origin, 80, i * .1)];
      final trains = mockTrainsOnRoutes([route], origin, DateTime.utc(2026, 11, 7, 12));
      expect(trains.length, 1);
      final t = trains.first;
      expect(t.name, isNotEmpty);
      expect(distanceToPolylineKm(t.position, route), lessThan(.01));
    });
  });
}
