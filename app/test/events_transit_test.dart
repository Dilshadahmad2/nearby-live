import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/features/live/live_mapping.dart';
import 'package:nearby_live/features/live/live_models.dart';
import 'package:nearby_live/features/live/live_stream.dart';
import 'package:nearby_live/features/nearby/application/nearby_controller.dart';
import 'package:nearby_live/features/nearby/scene/live_director.dart';
import 'package:nearby_live/features/nearby/scene/scene.dart';
import 'package:flutter/painting.dart';

void main() {
  test('event objects map with local start time', () {
    final e = eventFromLive(LiveObject.fromJson({
      'kind': 'event',
      'id': 'tm:Z1',
      'label': 'Music Fest 2026',
      'name': 'JLN Stadium',
      'location': {'lat': 28.5828, 'lon': 77.2344},
      'extra': {'local_date': '2026-11-07', 'local_time': '17:00:00', 'category': 'Music'},
    })!);
    expect(e.name, 'Music Fest 2026');
    expect(e.venue, 'JLN Stadium');
    expect(e.start, DateTime(2026, 11, 7, 17));
    expect(formatEventWhen(e.start!, DateTime(2026, 11, 7, 9)), 'Today, 5 PM');
    expect(formatEventWhen(DateTime(2026, 11, 8, 9, 30), DateTime(2026, 11, 7, 9)), 'Tomorrow, 9:30 AM');
    expect(formatEventWhen(DateTime(2026, 11, 14, 18), DateTime(2026, 11, 7, 9)), 'Sat 14 Nov, 6 PM');
  });

  test('live director shows the nearest event card and transit pins', () {
    const user = GeoPoint(28.654, 77.241);
    final st = NearbyState(
      mode: NearbyMode.live,
      user: user,
      rangeKm: 5,
      events: [NearbyEvent(id: 'tm:Z1', name: 'Music Fest', position: const GeoPoint(28.66, 77.25), start: DateTime(2026, 11, 7, 17))],
      transit: const [
        TransitVehicle(id: 'b1', kind: 'bus', label: '534', position: GeoPoint(28.655, 77.242), headingDeg: 90, speedKmh: 20),
        TransitVehicle(id: 'far', kind: 'bus', label: '9', position: GeoPoint(19.0, 72.8), headingDeg: 0, speedKmh: 0),
      ],
    );
    final d = LiveDirector(read: () => st, viewport: () => const Size(400, 800));
    SceneSnapshot snap = d.tick(.1, DateTime(2026, 11, 7, 12));
    for (var i = 0; i < 30; i++) {
      snap = d.tick(.1, DateTime(2026, 11, 7, 12));
    }
    expect(snap.cards[NearbyKind.event]?.subtitle, 'Music Fest');
    expect(snap.cards[NearbyKind.event]?.extra, 'Today, 5 PM');
    expect(snap.stageLightsOn, isTrue);
    expect(snap.items.where((i) => i.kind == NearbyKind.transit).length, 1);
    expect(snap.movers, isNotEmpty); // the stage rises
  });
}
