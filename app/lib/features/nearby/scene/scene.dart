import 'dart:ui';

import '../../../core/geo/geo_point.dart';
import '../../weather/weather.dart';
import 'models_3d.dart';

enum NearbyKind { train, flight, traffic, weather, event }

/// Header pill state.
enum LiveStatus { locating, live, stale, demo }

/// Text for an info card.
class CardInfo {
  const CardInfo({
    required this.title,
    required this.subtitle,
    this.status,
    this.distanceKm,
    this.extra,
    this.moreCount = 0,
  });

  final String title;
  final String subtitle;
  final String? status;
  final double? distanceKm;

  /// Secondary chip ("Today, 5 PM").
  final String? extra;

  /// Further in-range objects of the same category ("+2 more").
  final int moreCount;
}

/// Something drawn as an overlay (pin, plane, beam target).
class SceneItem {
  const SceneItem({
    required this.kind,
    required this.id,
    this.anchor,
    this.stageAnchor,
    this.liftPx = 0,
    this.headingDeg = 0,
    this.vis = 1,
    this.shown = false,
    this.distanceKm,
    this.primary = true,
  });

  final NearbyKind kind;
  final String id;

  /// Geographic anchor projected with the map.
  final GeoPoint? anchor;

  /// Screen anchor in design-stage coordinates (512 × 768), used by the demo
  /// plane which flies in screen space like the prototype.
  final Offset? stageAnchor;

  /// Extra upward offset in logical px (aircraft altitude).
  final double liftPx;

  /// Compass heading for rotating overlays (plane).
  final double headingDeg;

  /// Enter/exit animation value 0..1.
  final double vis;

  /// Card, pin and beam visible.
  final bool shown;
  final double? distanceKm;

  /// The nearest of its category (gets the big overlay, card and beam).
  final bool primary;
}

/// A traffic line drawn on the map (`flow` layers).
class FlowLine {
  const FlowLine(this.coords, this.colour, this.opacity);
  final List<List<double>> coords;
  final String colour;
  final double opacity;
}

/// Camera framing requested by a director.
class CameraFrame {
  const CameraFrame({
    required this.center,
    required this.zoom,
    required this.pitch,
    required this.bearing,
  });

  final GeoPoint center;
  final double zoom;
  final double pitch;
  final double bearing;
}

/// Everything the map and the overlays need for one frame.
class SceneSnapshot {
  const SceneSnapshot({
    required this.user,
    required this.rangeKm,
    required this.status,
    required this.camera,
    required this.movers,
    required this.flows,
    required this.items,
    required this.cards,
    this.staticVersion = 0,
    this.staticFeatures = const [],
    this.crowd = const [],
    this.crowdOpacity = 0,
    this.weather,
    this.weatherVis = 0,
    this.ringRadiusPx,
    this.stageLightsOn = false,
  });

  final GeoPoint user;
  final double rangeKm;
  final LiveStatus status;
  final CameraFrame camera;

  /// Moving 3D models (fill-extrusion features).
  final List<Json> movers;

  /// Static 3D features (viaducts); re-uploaded only when [staticVersion] changes.
  final int staticVersion;
  final List<Json> staticFeatures;
  final List<FlowLine> flows;
  final List<Json> crowd;
  final double crowdOpacity;
  final List<SceneItem> items;
  final Map<NearbyKind, CardInfo> cards;
  final Weather? weather;
  final double weatherVis;

  /// Fixed HUD ring radius in stage px (demo); null = project from range.
  final double? ringRadiusPx;
  final bool stageLightsOn;

  SceneItem? primaryOf(NearbyKind k) {
    for (final i in items) {
      if (i.kind == k && i.primary) return i;
    }
    return null;
  }
}

/// Produces a [SceneSnapshot] per animation tick.
abstract interface class SceneDirector {
  /// [dt] in seconds.
  SceneSnapshot tick(double dt, DateTime now);
}
