import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../../core/geo/geo_point.dart';
import '../../../settings/settings_controller.dart';

String styleAsset(MapStyleKind k) => switch (k) {
      MapStyleKind.satellite => 'assets/styles/satellite.json',
      MapStyleKind.neon => 'assets/styles/neon.json',
    };

String attributionFor(MapStyleKind k) => switch (k) {
      MapStyleKind.satellite =>
        'Imagery © Esri, Maxar, Earthstar Geographics · Map data © OpenStreetMap contributors · OpenFreeMap',
      MapStyleKind.neon => 'Map data © OpenStreetMap contributors · © OpenMapTiles · OpenFreeMap',
    };

/// Non-interactive tilted MapLibre map (the scene drives the camera).
class NearbyMapView extends StatelessWidget {
  const NearbyMapView({
    super.key,
    required this.style,
    required this.initialCenter,
    required this.onMapCreated,
    required this.onStyleLoaded,
  });

  final MapStyleKind style;
  final GeoPoint initialCenter;
  final void Function(MapLibreMapController) onMapCreated;
  final VoidCallback onStyleLoaded;

  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      // A new key per style forces a clean platform view and style load.
      key: ValueKey(style),
      styleString: styleAsset(style),
      initialCameraPosition: CameraPosition(
        target: LatLng(initialCenter.lat, initialCenter.lon),
        zoom: 13.5,
        tilt: 60,
        bearing: -8,
      ),
      onMapCreated: onMapCreated,
      onStyleLoadedCallback: onStyleLoaded,
      compassEnabled: false,
      rotateGesturesEnabled: false,
      scrollGesturesEnabled: false,
      zoomGesturesEnabled: false,
      tiltGesturesEnabled: false,
      doubleClickZoomEnabled: false,
      dragEnabled: false,
      myLocationEnabled: false,
      // Our own attribution text is drawn above the bottom nav; keep the
      // (i) button reachable at the top-left under the header.
      attributionButtonPosition: AttributionButtonPosition.topLeft,
      attributionButtonMargins: const Point(8, 196),
    );
  }
}
