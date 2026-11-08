import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/core/geo/geo_utils.dart';
import 'package:nearby_live/features/alerts/alert_engine.dart';
import 'package:nearby_live/features/flights/flight.dart';
import 'package:nearby_live/features/nearby/application/nearby_controller.dart';
import 'package:nearby_live/features/settings/settings_screen.dart';
import 'package:nearby_live/features/trains/train.dart';

const home = GeoPoint(28.654, 77.241);

Train train(String number, double km, {int? delay}) {
  final p = destinationPoint(home, 0, km);
  return Train(
    id: 'ir-$number',
    name: 'Rajdhani',
    number: number,
    from: 'BCT',
    to: 'NDLS',
    route: [p, destinationPoint(p, 0, 1)],
    arcM: 0,
    speedMs: 0,
    position: p,
    fixTime: DateTime.utc(2026),
    delayMin: delay,
  );
}

FlightTrack flight(String id, double km) => FlightTrack(FlightState(
      icao24: id,
      callsign: 'AIC138',
      position: destinationPoint(home, 90, km),
      altitudeM: 2500,
      velocityMs: 0,
      trackDeg: 0,
      onGround: false,
      fixTime: DateTime.utc(2026),
    ));

void main() {
  const a = AlertSettings(enabled: true, trainKm: 2, flightKm: 3, lateMin: 30, watchedTrains: ['12951'], quietStart: -1, quietEnd: -1);

  test('rules: watched train near and late, flight overhead', () {
    final trains = [Ranged(train('12951', 1.5, delay: 45), 1.5), Ranged(train('11111', 1, delay: 90), 1.0)];
    final flights = [Ranged(flight('abc', 2), 2.0)];
    final got = AlertEngine.rules(a, home, trains, flights);
    expect(got.map((e) => e.key), ['train-near:12951', 'train-late:12951:3', 'flight-near:abc']);
    expect(got.first.body, 'Rajdhani (12951) is 1.5 km away · 45 min late');
    // No watch list → any nearby train.
    final any = AlertEngine.rules(a.copyWith(watchedTrains: []), home, trains, const []);
    expect(any.where((e) => e.key.startsWith('train-near')).length, 2);
  });

  test('engine dedupes within the cooldown and respects quiet hours', () {
    final st = NearbyState(mode: NearbyMode.live, user: home, trains: [train('12951', 1)]);
    final e = AlertEngine(cooldown: const Duration(hours: 1));
    final t0 = DateTime(2026, 11, 7, 12);
    expect(e.evaluate(st, a, t0).length, 1);
    expect(e.evaluate(st, a, t0.add(const Duration(minutes: 30))), isEmpty);
    expect(e.evaluate(st, a, t0.add(const Duration(minutes: 61))).length, 1);

    final quiet = a.copyWith(quietStart: 22, quietEnd: 7);
    expect(AlertEngine().evaluate(st, quiet, DateTime(2026, 11, 7, 23)), isEmpty);
    expect(AlertEngine().evaluate(st, quiet, DateTime(2026, 11, 7, 8)).length, 1);
    expect(AlertEngine().evaluate(st, a.copyWith(enabled: false), t0), isEmpty);
  });

  test('watched train numbers are parsed from free text', () {
    expect(parseTrainNumbers('12951, 12002 abc 12951'), ['12951', '12002']);
    expect(parseTrainNumbers(''), isEmpty);
  });
}
