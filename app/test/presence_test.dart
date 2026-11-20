import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/features/demo/demo_scenario.dart';
import 'package:nearby_live/features/nearby/domain/presence.dart';

void main() {
  group('Presence state machine', () {
    Presence make() => Presence(
          enterDuration: const Duration(seconds: 1),
          leaveDuration: const Duration(milliseconds: 500),
        );

    test('starts hidden and stays hidden while out of range', () {
      final p = make();
      p.update(.1, false);
      expect(p.phase, PresencePhase.hidden);
      expect(p.value, 0);
      expect(p.isVisible, isFalse);
    });

    test('hidden → entering → present → leaving → hidden', () {
      final p = make();
      p.update(.1, true);
      expect(p.phase, PresencePhase.entering);

      for (var i = 0; i < 12; i++) {
        p.update(.1, true);
      }
      expect(p.phase, PresencePhase.present);
      expect(p.value, 1);
      expect(p.isShown, isTrue);

      p.update(.1, false);
      expect(p.phase, PresencePhase.leaving);
      for (var i = 0; i < 6; i++) {
        p.update(.1, false);
      }
      expect(p.phase, PresencePhase.hidden);
      expect(p.value, 0);
    });

    test('entering is shown only past 60 %', () {
      final p = make();
      p.update(.01, true); // → entering
      p.update(.5, true);
      expect(p.phase, PresencePhase.entering);
      expect(p.isShown, isFalse);
      p.update(.2, true);
      expect(p.isShown, isTrue);
    });

    test('reverses continuously when range flips mid-animation', () {
      final p = make();
      p.update(.01, true);
      p.update(.5, true); // value ≈ .5
      final mid = p.value;
      p.update(.01, false); // → leaving, value unchanged
      expect(p.phase, PresencePhase.leaving);
      expect(p.value, closeTo(mid, 1e-9));
      p.update(.1, false);
      expect(p.value, lessThan(mid));
      p.update(.01, true); // back to entering from where it was
      expect(p.phase, PresencePhase.entering);
      expect(p.value, greaterThan(0));
    });
  });

  group('ScriptedMover (prototype step())', () {
    const cfg = MoverConfig(start: 0, target: 100, ease: 1, eps: 1, crawl: 10, leave: 200, end: 500);

    test('eases toward the target, crawls, then accelerates away', () {
      final m = ScriptedMover(cfg);
      m.update(.05, true);
      expect(m.phase, PresencePhase.entering);
      var last = m.progress;
      for (var i = 0; i < 200 && m.phase == PresencePhase.entering; i++) {
        m.update(.05, true);
        expect(m.progress, greaterThanOrEqualTo(last));
        last = m.progress;
      }
      expect(m.phase, PresencePhase.present);
      final before = m.progress;
      m.update(1, true);
      expect(m.progress, closeTo(before + 10, 1e-9));

      m.update(.1, false);
      expect(m.phase, PresencePhase.leaving);
      while (m.phase == PresencePhase.leaving) {
        m.update(.1, false);
      }
      expect(m.phase, PresencePhase.hidden);
      expect(m.progress, greaterThan(cfg.end));
    });

    test('isShown uses the approach threshold', () {
      final m = ScriptedMover(cfg);
      m.update(.01, true);
      expect(m.isShown(60), isFalse);
      for (var i = 0; i < 20; i++) {
        m.update(.1, true);
      }
      expect(m.isShown(60), isTrue);
    });
  });

  test('easeBack overshoots then settles at 1', () {
    expect(easeBack(0), closeTo(0, 1e-9));
    expect(easeBack(1), closeTo(1, 1e-9));
    expect(easeBack(.7), greaterThan(1));
  });

  group('DemoScenario', () {
    const s = DemoScenario(jamKm: 1.2, eventKm: 0.9);

    test('train approaches to 1.6 km at 18 s and leaves', () {
      expect(s.distances(0)['train'], 8);
      expect(s.distances(18)['train'], closeTo(1.6, 1e-9));
      expect(s.distances(36)['train'], closeTo(8, 1e-9));
      expect(s.distances(38)['train'], isNull);
    });

    test('weather appears after locating and is always 0 km', () {
      expect(s.distances(1)['weather'], isNull);
      expect(s.distances(2)['weather'], 0);
    });

    test('with a 5 km range, the train enters around 8.4 s', () {
      double? enteredAt;
      for (var t = 0.0; t < 18; t += .1) {
        if (s.distances(t)['train']! <= 5) {
          enteredAt = t;
          break;
        }
      }
      expect(enteredAt, closeTo(8.44, .11));
    });

    test('traffic and event windows', () {
      expect(s.distances(3)['traffic'], isNull);
      expect(s.distances(10)['traffic'], 1.2);
      expect(s.distances(21)['event'], isNull);
      expect(s.distances(25)['event'], .9);
    });
  });
}
