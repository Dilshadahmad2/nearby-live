import 'dart:math' as math;

import '../../../core/geo/geo_utils.dart';
import '../domain/presence.dart';

/// GeoJSON helpers. Every extruded part is a polygon feature carrying its
/// colour (`c`), base (`b`) and height (`h`) in metres; the `movers`
/// fill-extrusion layer reads them with `['get', …]`.
typedef Json = Map<String, dynamic>;

Json extrusion(List<List<double>> ring, String color, double base, double height) => {
      'type': 'Feature',
      'properties': {'c': color, 'b': base, 'h': height},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [ring],
      },
    };

Json featureCollection(List<Json> features) => {'type': 'FeatureCollection', 'features': features};

Json lineFeature(List<List<double>> coords, Map<String, Object?> props) => {
      'type': 'Feature',
      'properties': props,
      'geometry': {'type': 'LineString', 'coordinates': coords},
    };

Json pointFeature(List<double> coord, Map<String, Object?> props) => {
      'type': 'Feature',
      'properties': props,
      'geometry': {'type': 'Point', 'coordinates': coord},
    };

/// Train geometry constants (metres), from the prototype.
abstract final class TrainDims {
  static const carLength = 150.0;
  static const carGap = 16.0;
  static const cars = 6;
  static const total = cars * (carLength + carGap);
}

/// Six-car train whose head is at arc length [head] along [line]: red-pink
/// end cars, blue middle cars, dark window band, white roof, neon stripe and
/// a tapered nose. [k] scales widths, heights and lengths so the model stays
/// readable when zoomed out.
void buildTrain(Polyline line, double head, List<Json> out, {double k = 1, int cars = TrainDims.cars}) {
  final carL = TrainDims.carLength * k;
  final gap = TrainDims.carGap * k;
  double w(double v) => v * k;
  for (var i = 0; i < cars; i++) {
    final s1 = head - i * (carL + gap);
    final s0 = s1 - carL;
    if (s1 <= 0 || s0 >= line.length) continue;
    final a = math.max(0.0, s0), b = math.min(line.length, s1);
    final end = i == 0 || i == cars - 1;
    final body = end ? '#ff2e63' : '#1f4fe0';
    final nose = 50 * k;
    if (i == 0 && b - a > nose * .8) {
      out.add(extrusion(line.ribbon(a, b - nose, w(15), w(15)), body, w(18), w(40)));
      out.add(extrusion(line.ribbon(b - nose, b, w(15), w(5)), body, w(18), w(37)));
      out.add(extrusion(line.ribbon(a, b - nose, w(13), w(13)), '#f7f9ff', w(46), w(54)));
      out.add(extrusion(line.ribbon(b - nose, b, w(13), w(4)), '#f7f9ff', w(37), w(45)));
      out.add(extrusion(line.ribbon(a, b - nose, w(15), w(15)), '#0d1840', w(40), w(46)));
    } else {
      out.add(extrusion(line.ribbon(a, b, w(15), w(15)), body, w(18), w(40)));
      out.add(extrusion(line.ribbon(a, b, w(15), w(15)), '#0d1840', w(40), w(46)));
      out.add(extrusion(line.ribbon(a, b, w(13), w(13)), '#f7f9ff', w(46), w(54)));
    }
    out.add(extrusion(line.ribbon(a, b, w(16.5), w(16.5)), '#38e8ff', w(35), w(38)));
  }
}

/// Elevated viaduct with neon edge rails and pillars along [line].
void buildViaduct(Polyline line, List<Json> out, {double k = 1, double? from, double? to}) {
  final s0 = from ?? 0, s1 = to ?? line.length;
  if (s1 - s0 < 20) return;
  out.add(extrusion(line.ribbon(s0, s1, 18 * k, 18 * k), '#c9d4f2', 9 * k, 16 * k));
  out.add(extrusion(line.ribbon(s0, s1, 2.2 * k, 2.2 * k, 17.5 * k), '#22e3ff', 16 * k, 18 * k));
  out.add(extrusion(line.ribbon(s0, s1, 2.2 * k, 2.2 * k, -17.5 * k), '#22e3ff', 16 * k, 18 * k));
  for (var s = s0 + 40; s < s1; s += 110 * k) {
    final p = line.at(s);
    out.add(extrusion(rectRing(line.projector, p.x, p.y, 12 * k, 12 * k), '#6b7a99', 0, 9 * k));
  }
}

const carColours = ['#ff3b4a', '#ffb020', '#ffe14d', '#2fe07a', '#2f7dff', '#a855f7', '#ff4fd8', '#f8fafc', '#18d4ff'];

/// A car or bus driving along a road polyline.
class RoadVehicle {
  RoadVehicle({
    required this.line,
    required this.s,
    required this.offset,
    required this.speed,
    required this.colour,
    required this.bus,
  });

  final Polyline line;
  double s;

  /// Lateral lane offset (signed, metres).
  final double offset;

  /// Signed speed along the line, m/s.
  double speed;
  final String colour;
  final bool bus;

  void step(double dt) {
    s += speed * dt;
    if (s > line.length) s -= line.length;
    if (s < 0) s += line.length;
  }
}

/// Seeded vehicle population for [lines], about one per 160 m.
/// [speedFactor] (0..1) slows traffic on jammed roads.
List<RoadVehicle> spawnVehicles(List<Polyline> lines, {int seed = 9, double speedFactor = 1, int cap = 60}) {
  final r = math.Random(seed);
  final cars = <RoadVehicle>[];
  for (final l in lines) {
    final n = (l.length / 160).round();
    for (var i = 0; i < n && cars.length < cap; i++) {
      final dir = r.nextBool() ? 1.0 : -1.0;
      cars.add(RoadVehicle(
        line: l,
        s: r.nextDouble() * l.length,
        offset: dir * (r.nextBool() ? 9 : 20),
        // Exaggerated "visual" speed like the prototype (45–85 m/s).
        speed: (45 + r.nextDouble() * 40) * dir * speedFactor.clamp(0.15, 1.0),
        colour: carColours[r.nextInt(carColours.length)],
        bus: r.nextDouble() < .1,
      ));
    }
  }
  return cars;
}

/// Car and bus extrusions rising out of the ground with [vis] (0..1).
void buildVehicles(List<RoadVehicle> cars, double vis, List<Json> out, {double k = 1}) {
  final e = easeBack(vis);
  for (final c in cars) {
    final len = (c.bus ? 95 : 56) * k;
    final s0 = c.s - len / 2, s1 = c.s + len / 2;
    if (s0 < 0 || s1 > c.line.length) continue;
    out.add(extrusion(c.line.ribbon(s0, s1, 9 * k, 9 * k, c.offset * k), c.bus ? '#ffc21a' : c.colour, 1, 1 + 16 * k * e));
    out.add(extrusion(c.line.ribbon(s0 + len * .22, s1 - len * .18, 6.6 * k, 6.6 * k, c.offset * k), '#bfe9ff',
        1 + 16 * k * e, 1 + 25 * k * e));
  }
}

/// Event stage (stage deck, LED screen, truss towers, tents) at local metres
/// ([x], [y]) rising with [vis].
void buildStage(LocalProjector proj, double x, double y, double vis, List<Json> out) {
  final k = easeBack(vis);
  out.add(extrusion(rectRing(proj, x, y, 170, 110), '#2b2470', 0, 8 * k));
  out.add(extrusion(rectRing(proj, x, y + 40, 150, 14), '#ff2bd6', 8 * k, 62 * k));
  out.add(extrusion(rectRing(proj, x, y + 49, 150, 4), '#170f3a', 8 * k, 64 * k));
  for (final d in const [
    [-80.0, -50.0],
    [80.0, -50.0],
    [-80.0, 50.0],
    [80.0, 50.0],
  ]) {
    out.add(extrusion(rectRing(proj, x + d[0], y + d[1], 12, 12), '#9a7bff', 0, 78 * k));
  }
  out.add(extrusion(rectRing(proj, x, y + 50, 172, 8), '#c4b5ff', 72 * k, 78 * k));
  out.add(extrusion(rectRing(proj, x, y - 50, 172, 8), '#c4b5ff', 72 * k, 78 * k));
  const tents = [
    (-140.0, -60.0, '#ff4d5e'),
    (140.0, -80.0, '#ffd23f'),
    (-150.0, 40.0, '#35e0ff'),
    (150.0, 30.0, '#2fe07a'),
  ];
  for (final (dx, dy, c) in tents) {
    out.add(extrusion(rectRing(proj, x + dx, y + dy, 34, 34), c, 0, 16 * k));
    out.add(extrusion(rectRing(proj, x + dx, y + dy, 20, 20), '#ffffff', 16 * k, 22 * k));
  }
}

/// Crowd dots around a stage at local metres ([x], [y]).
List<Json> buildCrowd(LocalProjector proj, double x, double y, {int count = 190, int seed = 5}) {
  final r = math.Random(seed);
  const cols = ['#ffffff', '#ffe14d', '#ff4fd8', '#35e0ff', '#9b7bff', '#ff6b6b'];
  return [
    for (var i = 0; i < count; i++)
      () {
        final a = r.nextDouble() * math.pi * 2;
        final rad = math.sqrt(r.nextDouble());
        return pointFeature(
          proj.toGeo(x + math.cos(a) * rad * 85, y - 45 + math.sin(a) * rad * 40).toLonLat(),
          {'c': cols[r.nextInt(cols.length)]},
        );
      }(),
  ];
}

/// Model exaggeration factor for zoom (prototype models are sized for z14.5).
double modelScaleForZoom(double zoom) => math.pow(2, (14.5 - zoom).clamp(0.0, 2.0)).toDouble();
