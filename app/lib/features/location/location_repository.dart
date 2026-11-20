import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/geo/geo_point.dart';

enum LocationAccess { granted, denied, serviceDisabled }

/// Wraps geolocator: permission flow, a position stream and the last known fix.
class LocationRepository {
  Future<LocationAccess> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return LocationAccess.denied;
    }
    return LocationAccess.granted;
  }

  Future<GeoPoint?> lastKnown() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      return p == null ? null : GeoPoint(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<GeoPoint?> current() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      return GeoPoint(p.latitude, p.longitude);
    } catch (_) {
      return lastKnown();
    }
  }

  /// Positions as the user moves (every ~25 m).
  Stream<GeoPoint> watch() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25),
      ).map((p) => GeoPoint(p.latitude, p.longitude));

  Future<void> openSettings() => Geolocator.openAppSettings();
}

final locationRepositoryProvider = Provider<LocationRepository>((ref) => LocationRepository());
