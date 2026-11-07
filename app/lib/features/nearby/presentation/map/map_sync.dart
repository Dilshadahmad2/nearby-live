import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';

import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/geo/geo_point.dart';
import '../../../../core/geo/geo_utils.dart';
import '../../domain/presence.dart';
import '../../scene/models_3d.dart';
import '../../scene/scene.dart';

/// Source / layer ids added on top of the base style.
abstract final class SceneLayers {
  static const rail3d = 'rail3d';
  static const flow = 'flow';
  static const flowGlow = 'flow-glow';
  static const crowd = 'crowd';
  static const movers = 'movers';
}

/// Screen positions for one frame (logical pixels).
class Projection {
  const Projection({required this.you, required this.ringRadius, required this.points});
  final Offset you;
  final double ringRadius;
  final Map<String, Offset> points;
}

/// Pushes [SceneSnapshot]s into MapLibre: smoothed camera with a slow bearing
/// sway, GeoJSON sources for moving models (~15 fps), traffic flow lines with
/// a marching dash, crowd dots, and a batched projection of every overlay
/// anchor. Calls never overlap; a frame is skipped while one is in flight.
class MapSceneSync {
  MapSceneSync(this.controller, {required this.devicePixelRatio});

  final MapLibreMapController controller;
  final double devicePixelRatio;

  bool _busy = false;
  int _staticVersion = -1;
  String _flowKey = '';
  String _crowdKey = '';
  int _dashStep = -1;
  double _animT = 0;

  // Smoothed camera.
  GeoPoint? _center;
  double _zoom = 0, _pitch = 0, _bearing = 0;

  static const _dash = [
    [0.0, 4.0, 3.0], [0.5, 4.0, 2.5], [1.0, 4.0, 2.0], [1.5, 4.0, 1.5], [2.0, 4.0, 1.0], [2.5, 4.0, 0.5], [3.0, 4.0, 0.0],
    [0.0, 0.5, 3.0, 3.5], [0.0, 1.0, 3.0, 3.0], [0.0, 1.5, 3.0, 2.5], [0.0, 2.0, 3.0, 2.0], [0.0, 2.5, 3.0, 1.5],
    [0.0, 3.0, 3.0, 1.0], [0.0, 3.5, 3.0, 0.5],
  ];

  /// Adds the scene's sources and layers. Call from `onStyleLoadedCallback`
  /// (again after every style switch).
  static Future<void> installLayers(MapLibreMapController c) async {
    final empty = featureCollection(const []);
    await c.addGeoJsonSource(SceneLayers.rail3d, empty);
    await c.addGeoJsonSource(SceneLayers.flow, empty);
    await c.addGeoJsonSource(SceneLayers.crowd, empty);
    await c.addGeoJsonSource(SceneLayers.movers, empty);
    await c.addLineLayer(
      SceneLayers.flow,
      SceneLayers.flowGlow,
      const LineLayerProperties(
        lineColor: ['get', 'col'],
        lineWidth: 14.0,
        lineBlur: 7.0,
        lineOpacity: ['*', 0.75, ['get', 'o']],
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    await c.addLineLayer(
      SceneLayers.flow,
      SceneLayers.flow,
      const LineLayerProperties(
        lineColor: '#ffe3a8',
        lineWidth: 2.4,
        lineOpacity: ['*', 0.95, ['get', 'o']],
        lineDasharray: [0.0, 4.0, 3.0],
        lineCap: 'butt',
        lineJoin: 'round',
      ),
    );
    await c.addCircleLayer(
      SceneLayers.crowd,
      SceneLayers.crowd,
      const CircleLayerProperties(
        circleColor: ['get', 'c'],
        circleRadius: 2.4,
        circleOpacity: ['get', 'o'],
        circleBlur: 0.2,
      ),
    );
    const extrusion = FillExtrusionLayerProperties(
      fillExtrusionColor: ['get', 'c'],
      fillExtrusionBase: ['get', 'b'],
      fillExtrusionHeight: ['get', 'h'],
      fillExtrusionOpacity: 1.0,
      fillExtrusionVerticalGradient: true,
    );
    await c.addFillExtrusionLayer(SceneLayers.rail3d, SceneLayers.rail3d, extrusion);
    await c.addFillExtrusionLayer(SceneLayers.movers, SceneLayers.movers, extrusion);
  }

  /// Forget uploaded state (after a style reload).
  void invalidate() {
    _staticVersion = -1;
    _flowKey = '';
    _crowdKey = '';
    _dashStep = -1;
  }

  /// Pushes [s] and returns screen positions, or null when skipped.
  Future<Projection?> push(SceneSnapshot s, double dt, Size viewport, {bool sway = true}) async {
    if (_busy) return null;
    _busy = true;
    try {
      _animT += dt;
      await _camera(s.camera, dt, sway);
      await controller.setGeoJsonSource(SceneLayers.movers, featureCollection(s.movers));
      if (s.staticVersion != _staticVersion) {
        _staticVersion = s.staticVersion;
        await controller.setGeoJsonSource(SceneLayers.rail3d, featureCollection(s.staticFeatures));
      }
      await _flows(s);
      await _crowd(s);
      return await _project(s, viewport);
    } catch (_) {
      // The platform view can be torn down mid-call (style switch, dispose).
      return null;
    } finally {
      _busy = false;
    }
  }

  Future<void> _camera(CameraFrame f, double dt, bool sway) async {
    final c = _center;
    if (c == null) {
      _center = f.center;
      _zoom = f.zoom;
      _pitch = f.pitch;
      _bearing = f.bearing;
    } else {
      final k = math.min(1.0, dt * 2.5);
      _center = GeoPoint(c.lat + (f.center.lat - c.lat) * k, c.lon + (f.center.lon - c.lon) * k);
      _zoom = approach(_zoom, f.zoom, dt, 2.5);
      _pitch = approach(_pitch, f.pitch, dt, 2.5);
      _bearing = approach(_bearing, f.bearing, dt, 2.5);
    }
    final b = _bearing + (sway ? math.sin(_animT * .1) * 7 : 0);
    final ctr = _center!;
    await controller.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
      target: LatLng(ctr.lat, ctr.lon),
      zoom: _zoom,
      tilt: _pitch,
      bearing: b,
    )));
  }

  /// Current camera bearing (for rotating overlays).
  double get bearing => _bearing + math.sin(_animT * .1) * 7;

  Future<void> _flows(SceneSnapshot s) async {
    final visible = s.flows.isNotEmpty && s.flows.any((f) => f.opacity > .01);
    final key = '${s.flows.length}:${s.flows.isEmpty ? 0 : (s.flows.first.opacity * 20).round()}:'
        '${s.flows.isEmpty ? '' : s.flows.first.coords.first}';
    if (key != _flowKey) {
      _flowKey = key;
      await controller.setGeoJsonSource(
        SceneLayers.flow,
        featureCollection([
          for (final f in s.flows) lineFeature(f.coords, {'col': f.colour, 'o': f.opacity}),
        ]),
      );
    }
    if (!visible) return;
    final step = (_animT * 12).floor() % _dash.length;
    if (step != _dashStep) {
      _dashStep = step;
      await controller.setLayerProperties(SceneLayers.flow, LineLayerProperties(lineDasharray: _dash[step]));
    }
  }

  Future<void> _crowd(SceneSnapshot s) async {
    final o = (s.crowdOpacity * 20).round() / 20;
    final key = '${s.crowd.length}:$o';
    if (key == _crowdKey) return;
    _crowdKey = key;
    await controller.setGeoJsonSource(
      SceneLayers.crowd,
      featureCollection([
        if (o > 0)
          for (final f in s.crowd)
            {
              ...f,
              'properties': {...(f['properties'] as Map<String, dynamic>), 'o': o},
            },
      ]),
    );
  }

  Future<Projection> _project(SceneSnapshot s, Size viewport) async {
    // Anchor list: user, a point at the range distance to the user's right
    // (for the ring radius), then every geo-anchored item.
    final rightBearing = _bearing + 90;
    final ringPoint = destinationPoint(s.user, rightBearing, s.rangeKm);
    final anchors = <String, GeoPoint>{
      '_you': s.user,
      '_ring': ringPoint,
      for (final i in s.items)
        if (i.anchor != null) i.id: i.anchor!,
    };
    final keys = anchors.keys.toList();
    final pts = await controller.toScreenLocationBatch([for (final k in keys) LatLng(anchors[k]!.lat, anchors[k]!.lon)]);
    // Android reports physical pixels, iOS logical points.
    final div = Platform.isAndroid ? devicePixelRatio : 1.0;
    final out = <String, Offset>{};
    for (var i = 0; i < keys.length && i < pts.length; i++) {
      out[keys[i]] = Offset(pts[i].x.toDouble() / div, pts[i].y.toDouble() / div);
    }
    final you = out['_you'] ?? Offset(viewport.width / 2, viewport.height * .62);
    final ring = out['_ring'];
    final projected = ring == null ? viewport.width * .4 : (ring - you).distance;
    final r = s.ringRadiusPx != null
        ? s.ringRadiusPx! * viewport.width / 512
        : projected.clamp(40.0, viewport.width * .46);
    return Projection(you: you, ringRadius: r, points: out);
  }
}
