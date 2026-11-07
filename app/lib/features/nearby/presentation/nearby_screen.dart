import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../core/geo/geo_utils.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../demo/demo_city.dart';
import '../../demo/demo_director.dart';
import '../../demo/demo_scenario.dart';
import '../../location/location_repository.dart';
import '../../settings/settings_controller.dart';
import '../../settings/settings_screen.dart';
import '../../weather/weather.dart';
import '../application/nearby_controller.dart';
import '../scene/live_director.dart';
import '../scene/scene.dart';
import 'map/map_sync.dart';
import 'map/nearby_map_view.dart';
import 'overlays/hud_painter.dart';
import 'overlays/map_fx.dart';
import 'overlays/plane_painter.dart';
import 'overlays/weather_painter.dart';
import 'widgets/chrome.dart';
import 'widgets/info_card.dart';

/// The "Nearby" tab: tilted 3D map, HUD overlays, cards and chrome.
class NearbyScreen extends ConsumerStatefulWidget {
  const NearbyScreen({super.key, required this.bottomInset, required this.onOpenCategory});

  /// Height covered by the floating bottom nav (attribution sits above it).
  final double bottomInset;
  final ValueChanged<NearbyKind> onOpenCategory;

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late final AppLifecycleListener _lifecycle;

  /// Bumped every frame; the overlay layer listens to it.
  final _frame = ValueNotifier<int>(0);
  final _hud = HudState();

  MapLibreMapController? _map;
  MapSceneSync? _sync;
  bool _styleReady = false;

  SceneDirector? _director;
  Object? _directorKey;
  SceneSnapshot? _snap;
  Projection? _proj;
  final Map<String, Offset> _smooth = {};

  Duration _last = Duration.zero;
  double _t = 0;
  double _accum = 0;
  Size _size = Size.zero;
  Offset? _planePos;

  static const _mapStep = 1 / 15;

  @override
  void initState() {
    super.initState();
    _ticker.start();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _ticker.stop();
        _last = Duration.zero;
        ref.read(nearbyControllerProvider.notifier).pause();
      },
      onShow: () {
        if (!_ticker.isActive) _ticker.start();
        ref.read(nearbyControllerProvider.notifier).resume();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------- loop

  void _ensureDirector(NearbyState st) {
    if (st.mode == NearbyMode.demo) {
      final city = ref.read(demoCityProvider).valueOrNull;
      if (city == null) return;
      if (_directorKey != NearbyMode.demo) {
        _directorKey = NearbyMode.demo;
        _director = DemoDirector(city, () => ref.read(settingsProvider).rangeKm.toDouble());
        _resetOverlays();
      }
    } else if (st.mode == NearbyMode.live) {
      if (_directorKey != NearbyMode.live) {
        _directorKey = NearbyMode.live;
        _director = LiveDirector(read: () => ref.read(nearbyControllerProvider), viewport: () => _size);
        _resetOverlays();
      }
    } else {
      _director = null;
      _directorKey = null;
    }
  }

  void _resetOverlays() {
    _snap = null;
    _proj = null;
    _smooth.clear();
    _hud.contrail.clear();
    _hud.beamVis.clear();
    _sync?.invalidate();
  }

  void _onTick(Duration elapsed) {
    final raw = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final dt = raw.clamp(0.0, .05);
    _t += dt;
    _hud.reduceMotion = ref.read(settingsProvider).reduceMotion;
    _hud.advance(dt, _size);

    final director = _director;
    final sync = _sync;
    _accum += dt;
    if (director != null && sync != null && _styleReady && _accum >= _mapStep) {
      final step = _accum;
      _accum = 0;
      final snap = director.tick(step, DateTime.now());
      _snap = snap;
      final reduce = _hud.reduceMotion;
      sync.push(snap, step, _size, sway: !reduce).then((p) {
        if (p != null && mounted) _proj = p;
      });
    }

    // Ease overlay positions toward the latest projection so pins glide at
    // display rate between the ~15 fps map updates.
    final p = _proj;
    if (p != null) {
      final k = math.min(1.0, dt * 14);
      for (final e in p.points.entries) {
        final cur = _smooth[e.key];
        _smooth[e.key] = cur == null ? e.value : Offset.lerp(cur, e.value, k)!;
      }
      _smooth.removeWhere((key, _) => !p.points.containsKey(key));
      _hud.ringRadius = _hud.ringRadius == 0 ? p.ringRadius : _hud.ringRadius + (p.ringRadius - _hud.ringRadius) * math.min(1.0, dt * 4);
      _hud.you = _smooth['_you'];
    }
    _updateHud(dt);
    _frame.value++;
  }

  double get _sx => _size.width / 512;
  double get _sy => _size.height / 768;

  Offset? _stage(Offset? o) => o == null ? null : Offset(o.dx * _sx, o.dy * _sy);

  /// Screen position of the primary plane (demo: stage space; live: projected + altitude).
  Offset? _planeScreen(SceneItem? f) {
    if (f == null) return null;
    if (f.stageAnchor != null) return _stage(f.stageAnchor);
    return _smooth[f.id]?.translate(0, -f.liftPx);
  }

  Offset get _weatherPos => Offset(286 * _sx, 352 * _sy);

  void _updateHud(double dt) {
    final s = _snap;
    if (s == null) {
      _hud.beams = const [];
      return;
    }
    _hud.rangeLabel = '${s.rangeKm.round()} KM';
    final train = s.primaryOf(NearbyKind.train);
    final flight = s.primaryOf(NearbyKind.flight);
    final traffic = s.primaryOf(NearbyKind.traffic);
    final event = s.primaryOf(NearbyKind.event);
    Offset? at(SceneItem? i, double dy) {
      final p = i == null ? null : _smooth[i.id];
      return p?.translate(0, dy);
    }

    final plane = _planeScreen(flight);
    _planePos = plane;
    if (plane != null) {
      _hud.contrail.add(plane);
      if (_hud.contrail.length > 45) _hud.contrail.removeAt(0);
    } else if (_hud.contrail.isNotEmpty) {
      _hud.contrail.removeAt(0);
    }
    _hud.contrailVis = flight == null ? .6 : 1;

    _hud.beams = [
      Beam(key: 'train', target: at(train, -30), colour: AppColors.beamTrain, on: train?.shown ?? false, phase: 0),
      Beam(key: 'flight', target: plane, colour: AppColors.beamFlight, on: flight?.shown ?? false, phase: .2),
      Beam(key: 'traffic', target: at(traffic, 0), colour: AppColors.beamTraffic, on: traffic?.shown ?? false, phase: .4),
      Beam(
        key: 'weather',
        target: _weatherPos.translate(0, -40),
        colour: AppColors.beamWeather,
        on: s.cards.containsKey(NearbyKind.weather),
        phase: .6,
      ),
      Beam(key: 'event', target: at(event, -30), colour: AppColors.beamEvent, on: event?.shown ?? false, phase: .8),
    ];
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final st = ref.watch(nearbyControllerProvider);
    ref.watch(demoCityProvider);
    _ensureDirector(st);

    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final pad = MediaQuery.paddingOf(context);
      final s = _sx;
      final initial = st.mode == NearbyMode.live && st.user != null ? st.user! : DemoScenario.cameraCenter;

      return Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Color(0xFF0D2147)),
        NearbyMapView(
          style: settings.mapStyle,
          initialCenter: initial,
          onMapCreated: (c) {
            _map = c;
            _styleReady = false;
            _sync = MapSceneSync(c, devicePixelRatio: MediaQuery.devicePixelRatioOf(context));
          },
          onStyleLoaded: () async {
            final c = _map;
            if (c == null) return;
            await MapSceneSync.installLayers(c);
            _sync?.invalidate();
            if (mounted) setState(() => _styleReady = true);
          },
        ),
        Positioned(left: 0, right: 0, top: 0, child: SkyOverlay(height: 330 * _sy + pad.top * .5)),
        const Vignette(),

        // Per-frame overlay layer.
        ValueListenableBuilder<int>(
          valueListenable: _frame,
          builder: (context, _, __) => _OverlayLayer(state: this, scale: s),
        ),

        // Chrome.
        Positioned(left: 24 * s, top: pad.top + 22 * s, child: AppIconBadge(size: 64 * s)),
        Positioned(left: 100 * s, top: pad.top + 14 * s, child: AppTitle(scale: s)),
        Positioned(
          right: 16 * s,
          top: pad.top + 24 * s,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ValueListenableBuilder<int>(
                valueListenable: _frame,
                builder: (_, __, ___) => LivePill(status: _snap?.status ?? LiveStatus.locating, scale: s),
              ),
              SizedBox(width: 8 * s),
              GearButton(
                scale: s,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ]),
            SizedBox(height: 8 * s),
            RangeDropdown(
              value: settings.rangeKm,
              scale: s,
              onChanged: (v) => ref.read(settingsProvider.notifier).setRange(v),
            ),
          ]),
        ),
        Positioned(left: 15 * s, top: pad.top + 110 * s, child: FeatureRow(scale: s)),
        ValueListenableBuilder<int>(
          valueListenable: _frame,
          builder: (context, _, __) => _CardsLayer(state: this, scale: s, topPad: pad.top),
        ),

        // Status / attribution.
        if (!_styleReady)
          Center(child: Text('Loading 3D city…', style: outfit(15, weight: FontWeight.w600, color: const Color(0xFFBFE9FF)))),
        if (st.mode == NearbyMode.locating && _styleReady)
          Center(child: Text('Finding your location…', style: outfit(15, weight: FontWeight.w600, color: const Color(0xFFBFE9FF)))),
        if (st.mode == NearbyMode.demo && st.access != null && st.access != LocationAccess.granted)
          Positioned(
            left: 16,
            right: 16,
            bottom: widget.bottomInset + 26,
            child: Center(child: _DemoBanner(access: st.access!)),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: widget.bottomInset + 6,
          child: Text(
            attributionFor(settings.mapStyle),
            maxLines: 2,
            style: outfit(8.5, color: const Color(0xA6FFFFFF)),
          ),
        ),
      ]);
    });
  }
}

/// Plane, weather, pins, badges, stage lights and the HUD canvas.
class _OverlayLayer extends StatelessWidget {
  const _OverlayLayer({required this.state, required this.scale});
  final _NearbyScreenState state;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final st = state;
    final snap = st._snap;
    final t = st._t;
    final s = scale;
    final children = <Widget>[];

    final wxShown = snap?.cards.containsKey(NearbyKind.weather) ?? false;
    final wxVisual = snap?.weather?.visual ?? WeatherVisual.partlyCloudy;

    if (snap != null) {
      // Event spotlights.
      final ev = snap.primaryOf(NearbyKind.event);
      final evPos = ev == null ? null : st._smooth[ev.id];
      if (evPos != null) {
        children.add(Positioned(
          left: evPos.dx - 80,
          top: evPos.dy - 34 - 170 * s,
          child: StageLights(t: t, shown: ev!.shown, height: 170 * s),
        ));
      }

      // Plane ground shadow (live: at its real ground position).
      final f = snap.primaryOf(NearbyKind.flight);
      final plane = st._planePos;
      if (f != null && plane != null) {
        final ground = f.stageAnchor != null ? plane.translate(14 * s, 170 * s) : st._smooth[f.id];
        final rot = _planeRotation(f, st);
        if (ground != null) {
          children.add(Positioned(
            left: ground.dx - 35 * s,
            top: ground.dy - 35 * s,
            child: IgnorePointer(
              child: Opacity(
                opacity: .45 * f.vis.clamp(0.0, 1.0),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationZ(rot).multiplied(Matrix4.diagonal3Values(.6, .4, 1)),
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                    child: CustomPaint(size: Size(70 * s, 70 * s), painter: PlanePainter(t: t, shadow: true)),
                  ),
                ),
              ),
            ),
          ));
        }
      }
    }

    // HUD canvas: ring, beams, person, motes, contrail.
    children.add(Positioned.fill(
      child: IgnorePointer(child: CustomPaint(painter: HudPainter(st._hud, repaint: st._frame, scale: s))),
    ));

    // Weather overlay (fixed spot above-right of the user, as in the design).
    final wp = st._weatherPos;
    children.add(Positioned(
      left: wp.dx - 75 * s,
      top: wp.dy - 140 * s,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: wxShown ? 1 : 0,
          duration: const Duration(milliseconds: 600),
          child: AnimatedScale(
            scale: wxShown ? 1 : .4,
            alignment: const Alignment(0, .8),
            duration: const Duration(milliseconds: 900),
            curve: const Cubic(.2, 1.5, .4, 1),
            child: CustomPaint(size: Size(150 * s, 150 * s), painter: WeatherPainter(t: t, visual: wxVisual)),
          ),
        ),
      ),
    ));

    if (snap != null) {
      final f = snap.primaryOf(NearbyKind.flight);
      final plane = st._planePos;
      if (f != null && plane != null) {
        final size = 118 * s;
        children.add(Positioned(
          left: plane.dx - size / 2,
          top: plane.dy - size / 2,
          child: IgnorePointer(
            child: Opacity(
              opacity: f.stageAnchor != null ? 1.0 : f.vis.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: _planeRotation(f, st),
                child: Transform.scale(
                  scale: 1 + .06 * math.sin(t),
                  child: CustomPaint(size: Size(size, size), painter: PlanePainter(t: t)),
                ),
              ),
            ),
          ),
        ));
        children.add(Positioned(
          left: plane.dx - 72 * s,
          top: plane.dy - 18 * s,
          child: MapPin(colour: AppColors.flight, icon: Icons.flight_rounded, shown: f.shown, size: 30 * s),
        ));
        children.add(Positioned(
          left: plane.dx - 84 * s,
          top: plane.dy + 26 * s,
          child: AnimatedOpacity(
            opacity: f.shown ? 1 : 0,
            duration: const Duration(milliseconds: 400),
            child: DistanceBadge(text: formatKm(f.distanceKm), colour: AppColors.flight, scale: s),
          ),
        ));
      }

      for (final item in snap.items) {
        final p = st._smooth[item.id];
        if (p == null) continue;
        switch (item.kind) {
          case NearbyKind.train:
            children.add(Positioned(
              left: p.dx - 15 * s,
              top: p.dy - 78 * s,
              child: MapPin(colour: AppColors.train, icon: Icons.train_rounded, shown: item.shown, size: 30 * s),
            ));
          case NearbyKind.traffic:
            children.add(Positioned(
              left: p.dx - 15 * s,
              top: p.dy - 44 * s,
              child: MapPin(colour: AppColors.traffic, icon: Icons.directions_car_rounded, shown: item.shown, size: 30 * s),
            ));
          case NearbyKind.event:
            children.add(Positioned(
              left: p.dx - 15 * s,
              top: p.dy - 110 * s,
              child: MapPin(colour: AppColors.event, icon: Icons.music_note_rounded, shown: item.shown, size: 30 * s),
            ));
          case NearbyKind.flight:
            if (!item.primary) {
              // Other in-range aircraft: small pins at their real positions.
              children.add(Positioned(
                left: p.dx - 11 * s,
                top: p.dy - item.liftPx - 30 * s,
                child: MapPin(colour: AppColors.flight, icon: Icons.flight_rounded, shown: item.shown, size: 22 * s),
              ));
            }
          case NearbyKind.transit:
            // Buses / metro from GTFS-Realtime feeds: small teal pins.
            children.add(Positioned(
              left: p.dx - 9 * s,
              top: p.dy - 24 * s,
              child: MapPin(colour: const Color(0xFF14C8B4), icon: Icons.directions_bus_rounded, shown: item.shown, size: 18 * s),
            ));
          case NearbyKind.weather:
            break;
        }
      }
    }

    // The user's pin and label.
    final you = st._hud.you;
    if (you != null) {
      children.add(Positioned(
        left: you.dx - 15 * s,
        top: you.dy - 150 * s,
        child: MapPin(colour: AppColors.blue, icon: Icons.circle, shown: true, size: 30 * s),
      ));
      children.add(Positioned(left: you.dx - 28 * s, top: you.dy + 16 * s, child: YouLabel(scale: s)));
    }

    children.add(Positioned.fill(child: ScanFx(t: t, enabled: !st._hud.reduceMotion)));
    return Stack(clipBehavior: Clip.none, children: children);
  }

  static double _planeRotation(SceneItem f, _NearbyScreenState st) {
    if (f.stageAnchor != null) return f.headingDeg * math.pi / 180;
    final bearing = st._sync?.bearing ?? 0;
    return (f.headingDeg - bearing) * math.pi / 180;
  }
}

/// The five info cards at their design positions.
class _CardsLayer extends StatelessWidget {
  const _CardsLayer({required this.state, required this.scale, required this.topPad});
  final _NearbyScreenState state;
  final double scale;
  final double topPad;

  @override
  Widget build(BuildContext context) {
    final snap = state._snap;
    final cards = snap?.cards ?? const <NearbyKind, CardInfo>{};
    final t = state._t;
    final s = scale;
    final open = state.widget.onOpenCategory;
    // Cards keep the design's x positions; y is offset by the status bar.
    double y(double v) => topPad * .6 + v * s;

    return Stack(children: [
      Positioned(
        left: 36 * s,
        top: y(194),
        width: 184 * s,
        child: ObjectCard(
          info: cards[NearbyKind.train],
          style: CardStyle.train,
          icon: Icons.train_rounded,
          shown: cards.containsKey(NearbyKind.train),
          t: t,
          scale: s,
          onTap: () => open(NearbyKind.train),
        ),
      ),
      Positioned(
        left: 358 * s,
        top: y(140),
        width: 142 * s,
        child: ObjectCard(
          info: cards[NearbyKind.flight],
          style: CardStyle.flight,
          icon: Icons.flight_rounded,
          showIcon: false,
          shown: cards.containsKey(NearbyKind.flight),
          t: t,
          scale: s,
        ),
      ),
      Positioned(
        left: 348 * s,
        top: y(266),
        width: 154 * s,
        child: WeatherCard(
          weather: snap?.weather,
          shown: cards.containsKey(NearbyKind.weather),
          t: t,
          scale: s,
          onTap: () => open(NearbyKind.weather),
        ),
      ),
      Positioned(
        left: 33 * s,
        top: y(386),
        width: 172 * s,
        child: ObjectCard(
          info: cards[NearbyKind.traffic],
          style: CardStyle.traffic,
          icon: Icons.directions_car_rounded,
          shown: cards.containsKey(NearbyKind.traffic),
          t: t,
          scale: s,
          onTap: () => open(NearbyKind.traffic),
        ),
      ),
      Positioned(
        left: 330 * s,
        top: y(438),
        width: 176 * s,
        child: ObjectCard(
          info: cards[NearbyKind.event],
          style: CardStyle.event,
          icon: Icons.calendar_month_rounded,
          shown: cards.containsKey(NearbyKind.event),
          t: t,
          scale: s,
          onTap: () => open(NearbyKind.event),
        ),
      ),
    ]);
  }
}

class _DemoBanner extends ConsumerWidget {
  const _DemoBanner({required this.access});
  final LocationAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = access == LocationAccess.serviceDisabled ? 'Location is off — showing the Old Delhi demo' : 'No location permission — showing the Old Delhi demo';
    return Material(
      color: const Color(0xE6081437),
      shape: StadiumBorder(side: BorderSide(color: AppColors.amber.withValues(alpha: .6))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () async {
          await ref.read(locationRepositoryProvider).openSettings();
          await ref.read(nearbyControllerProvider.notifier).retryLocation();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.location_off_rounded, size: 15, color: AppColors.amber),
            const SizedBox(width: 6),
            Flexible(child: Text(text, style: outfit(11.5, weight: FontWeight.w600))),
            const SizedBox(width: 6),
            Text('Enable', style: outfit(11.5, weight: FontWeight.w700, color: AppColors.cyan)),
          ]),
        ),
      ),
    );
  }
}
