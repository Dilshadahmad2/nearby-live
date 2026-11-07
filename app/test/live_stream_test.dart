import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/features/live/live_mapping.dart';
import 'package:nearby_live/features/live/live_stream.dart';
import 'package:nearby_live/features/trains/backend_train_source.dart';

Map<String, dynamic> obj(String kind, String id, double lat, double lon, [Map<String, dynamic> more = const {}]) => {
      'kind': kind,
      'id': id,
      'label': id,
      'location': {'lat': lat, 'lon': lon},
      'heading_deg': 90.0,
      'speed_kmh': 72.0,
      ...more,
    };

void main() {
  test('snapshot then diffs keep the store in sync', () {
    final s = LiveObjectStore();
    expect(s.apply({'type': 'hello', 'protocol': 1}), ApplyResult.ignored);
    expect(
      s.apply({
        'type': 'snapshot',
        'seq': 1,
        'items': [obj('train', '12951', 28.6, 77.2), obj('flight', 'abc', 28.7, 77.3)],
      }),
      ApplyResult.changed,
    );
    expect(s.objects.keys, containsAll(['train:12951', 'flight:abc']));

    expect(
      s.apply({
        'type': 'diff',
        'seq': 2,
        'upsert': [obj('train', '12951', 28.61, 77.2, {'delay_min': 12})],
        'remove': [
          {'kind': 'flight', 'id': 'abc'},
        ],
      }),
      ApplyResult.changed,
    );
    expect(s.objects.length, 1);
    expect(s.objects['train:12951']!.position, const GeoPoint(28.61, 77.2));
    expect(s.objects['train:12951']!.delayMin, 12);
  });

  test('a sequence gap asks for a resync', () {
    final s = LiveObjectStore();
    expect(s.apply({'type': 'diff', 'seq': 5, 'upsert': []}), ApplyResult.resync); // no snapshot yet
    s.apply({'type': 'snapshot', 'seq': 1, 'items': []});
    expect(s.apply({'type': 'diff', 'seq': 3, 'upsert': []}), ApplyResult.resync);
  });

  test('stream URI from the backend URL', () {
    expect(LiveStreamClient.streamUri('http://10.0.2.2:8080').toString(), 'ws://10.0.2.2:8080/v1/live/ws');
    expect(LiveStreamClient.streamUri('https://api.example.com/base/').toString(), 'wss://api.example.com/base/v1/live/ws');
  });

  test('live objects map to flights and trains', () {
    final now = DateTime.utc(2026, 11, 7);
    final f = flightFromLive(LiveObject.fromJson(obj('flight', '800c1b', 28.6, 77.2, {'altitude_m': 3000.0, 'label': 'AIC138'}))!, now);
    expect(f.callsign, 'AIC138');
    expect(f.velocityMs, closeTo(20, 1e-9));
    expect(f.fixTime, now);

    final o = LiveObject.fromJson(obj('train', '12951', 28.6, 77.2, {
      'name': 'Mumbai Rajdhani',
      'status': 'running',
      'delay_min': 25,
      'extra': {'from': 'BCT', 'to': 'NDLS'},
    }))!;
    final t = snapToRail(trainEstimateFromLive(o), const [], now);
    expect(t.number, '12951');
    expect(t.from, 'BCT');
    expect(t.statusText, 'Moving · 25 min late');
  });
}
