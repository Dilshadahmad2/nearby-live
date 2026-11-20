import 'dart:math' as math;
import 'dart:ui';

import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import '../nearby/domain/presence.dart';
import '../nearby/scene/models_3d.dart';
import '../nearby/scene/scene.dart';
import '../weather/weather.dart';
import 'demo_city.dart';
import 'demo_scenario.dart';

/// Replays the prototype's 40-second scripted scenario around Red Fort.
class DemoDirector implements SceneDirector {
  DemoDirector(DemoCity city, this.rangeKm) : proj = LocalProjector(DemoScenario.user) {
    train = Polyline.fromGeo(city.train.reversed.toList(), proj);
    routes = [for (final r in city.routes) Polyline.fromGeo(r, proj)].where((l) => !l.isEmpty).toList();

    // Where the train stops easing: the rail point closest to lon 77.2462.
    final tx = proj.toMetres(const GeoPoint(28.654, 77.2462)).x;
    var best = double.infinity;
    for (var s = 0.0; s <= train.length; s += 10) {
      final d = (train.at(s).x - tx).abs();
      if (d < best) {
        best = d;
        _trainTarget = s;
      }
    }

    // Nearest point of the traffic routes to the user = where the jam is shown.
    var jamD = double.infinity;
    for (var r = 0; r < routes.length; r++) {
      for (var s = 0.0; s <= routes[r].length; s += 10) {
        final p = routes[r].at(s);
        final d = math.sqrt(p.x * p.x + p.y * p.y);
        if (d < jamD) {
          jamD = d;
          _jamRoute = r;
          _jamS = s;
        }
      }
    }
    scenario = DemoScenario(
      jamKm: (jamD / 100).round() / 10,
      eventKm: (haversineKm(DemoScenario.user, DemoScenario.event) * 10).round() / 10,
    );

    trainMover = ScriptedMover(MoverConfig(
      start: 0,
      target: _trainTarget,
      ease: .75,
      eps: 3,
      crawl: 14,
      leave: 420,
      end: train.length + TrainDims.total,
    ));
    vehicles = spawnVehicles(routes);

    final ev = proj.toMetres(DemoScenario.event);
    _crowd = buildCrowd(proj, ev.x, ev.y);
    _flows = [
      for (var i = 0; i < routes.length; i++)
        (coords: [for (final p in routes[i].toGeoList()) p.toLonLat()], colour: i.isEven ? '#ff2d2d' : '#ff9a1f'),
    ];
    final viaduct = <Json>[];
    buildViaduct(train, viaduct);
    _static = viaduct;
  }

  /// Current range (read every tick so the dropdown applies immediately).
  final double Function() rangeKm;
  final LocalProjector proj;
  late final Polyline train;
  late final List<Polyline> routes;
  late final DemoScenario scenario;
  late final ScriptedMover trainMover;
  final ScriptedMover planeMover = ScriptedMover(const MoverConfig(
    start: -.04,
    target: .54,
    ease: .9,
    eps: .003,
    crawl: .004,
    leave: .16,
    end: 1.25,
  ));
  late final List<RoadVehicle> vehicles;
  late final List<Json> _crowd;
  late final List<({List<List<double>> coords, String colour})> _flows;
  late final List<Json> _static;

  double _trainTarget = 0;
  int _jamRoute = 0;
  double _jamS = 0;

  double simT = 0;
  double animT = 0;
  double _visTraffic = 0, _visWeather = 0, _visEvent = 0;

  static const _planeA = Offset(-110, 322), _planeB = Offset(640, 78);
  static const _ring = {2: 62.0, 5: 100.0, 10: 136.0, 50: 176.0};

  static final demoWeather = Weather(
    temperatureC: 28,
    humidityPct: 62,
    windKmh: 12,
    rainPct: 10,
    code: 2,
    observedAt: DateTime.utc(2025),
  );

  void restart() {
    simT = 0;
    trainMover.reset();
    planeMover.reset();
    _visTraffic = _visWeather = _visEvent = 0;
  }

  @override
  SceneSnapshot tick(double dt, DateTime now) {
    final range = rangeKm();
    animT += dt;
    simT += dt;
    if (simT >= DemoScenario.loopSeconds) simT -= DemoScenario.loopSeconds;

    final d = scenario.distances(simT);
    bool inR(String k) => d[k] != null && d[k]! <= range;

    trainMover.update(dt, inR('train'));
    planeMover.update(dt, inR('flight'));
    _visTraffic = approach(_visTraffic, inR('traffic') ? 1.0 : 0.0, dt, 2.5);
    _visWeather = approach(_visWeather, inR('weather') ? 1.0 : 0.0, dt, 2.5);
    _visEvent = approach(_visEvent, inR('event') ? 1.0 : 0.0, dt, 2.5);

    final movers = <Json>[];
    if (trainMover.phase != PresencePhase.hidden) buildTrain(train, trainMover.progress, movers);
    for (final v in vehicles) {
      v.step(dt);
    }
    if (_visTraffic > .01) buildVehicles(vehicles, _visTraffic, movers);
    final ev = proj.toMetres(DemoScenario.event);
    if (_visEvent > .01) buildStage(proj, ev.x, ev.y, _visEvent, movers);

    final trainShown = trainMover.isShown(_trainTarget * .6);
    final planeShown = planeMover.isShown(.35);
    final trafficOn = _visTraffic > .6 && inR('traffic');
    final weatherOn = _visWeather > .5 && inR('weather');
    final eventOn = _visEvent > .5 && inR('event');

    final items = <SceneItem>[];
    if (trainMover.phase != PresencePhase.hidden) {
      items.add(SceneItem(
        kind: NearbyKind.train,
        id: 'demo-train',
        anchor: train.geoAt(math.max(0.0, trainMover.progress - TrainDims.carLength * 1.5)),
        shown: trainShown,
        distanceKm: d['train'],
      ));
    }
    if (planeMover.phase != PresencePhase.hidden) {
      final p = planeMover.progress;
      final pos = Offset.lerp(_planeA, _planeB, p)! + Offset(0, math.sin(animT * 1.3) * 3);
      final ang = math.atan2(_planeB.dy - _planeA.dy, _planeB.dx - _planeA.dx);
      items.add(SceneItem(
        kind: NearbyKind.flight,
        id: 'demo-flight',
        stageAnchor: pos,
        headingDeg: (ang + math.pi / 2) * 180 / math.pi,
        shown: planeShown,
        distanceKm: d['flight'],
      ));
    }
    if (_visTraffic > .01 && routes.isNotEmpty) {
      items.add(SceneItem(
        kind: NearbyKind.traffic,
        id: 'demo-jam',
        anchor: routes[_jamRoute].geoAt(_jamS),
        vis: _visTraffic,
        shown: trafficOn,
        distanceKm: d['traffic'],
      ));
    }
    if (_visEvent > .01) {
      items.add(SceneItem(
        kind: NearbyKind.event,
        id: 'demo-event',
        anchor: DemoScenario.event,
        vis: _visEvent,
        shown: eventOn,
        distanceKm: d['event'],
      ));
    }

    final cards = <NearbyKind, CardInfo>{
      if (trainShown)
        NearbyKind.train: CardInfo(
          title: 'Train',
          subtitle: 'Rajdhani Express\n(NDLS → BPL)',
          status: 'Moving',
          distanceKm: d['train'],
        ),
      if (planeShown)
        NearbyKind.flight: CardInfo(title: 'Flight', subtitle: 'AI138 (DEL → BOM)', status: 'In Air', distanceKm: d['flight']),
      if (trafficOn)
        NearbyKind.traffic: CardInfo(title: 'Road Traffic', subtitle: 'Heavy · Ring Road', distanceKm: d['traffic']),
      if (weatherOn) NearbyKind.weather: const CardInfo(title: 'Weather', subtitle: 'Partly Cloudy', distanceKm: 0),
      if (eventOn)
        NearbyKind.event: CardInfo(title: 'Events', subtitle: 'Music Fest 2025', distanceKm: d['event'], extra: 'Today, 5 PM'),
    };

    return SceneSnapshot(
      user: DemoScenario.user,
      rangeKm: range,
      status: simT < 1.2 ? LiveStatus.locating : LiveStatus.demo,
      camera: const CameraFrame(center: DemoScenario.cameraCenter, zoom: 14.45, pitch: 62, bearing: -8),
      movers: movers,
      staticVersion: 1,
      staticFeatures: _static,
      flows: [
        for (final f in _flows) FlowLine(f.coords, f.colour, _visTraffic),
      ],
      crowd: _crowd,
      crowdOpacity: _visEvent,
      items: items,
      cards: cards,
      weather: weatherOn || _visWeather > .01 ? demoWeather : null,
      weatherVis: weatherOn ? 1.0 : 0.0,
      ringRadiusPx: _ring[range.round()] ?? 100,
      stageLightsOn: eventOn,
    );
  }
}
