import '../../core/geo/geo_point.dart';

/// An event at a venue (from the backend's Ticketmaster feed).
class NearbyEvent {
  const NearbyEvent({
    required this.id,
    required this.name,
    required this.position,
    this.venue,
    this.start,
    this.category,
  });

  final String id;
  final String name;
  final GeoPoint position;
  final String? venue;

  /// Local start time at the venue (date + time as published).
  final DateTime? start;
  final String? category;
}

/// A bus or metro vehicle from a GTFS-Realtime feed.
class TransitVehicle {
  const TransitVehicle({
    required this.id,
    required this.kind,
    required this.label,
    required this.position,
    required this.headingDeg,
    required this.speedKmh,
    this.route,
  });

  final String id;
  final String kind; // bus | metro
  final String label;
  final String? route;
  final GeoPoint position;
  final double headingDeg;
  final double speedKmh;
}

/// "Today, 5 PM", "Tomorrow, 9:30 AM", "Sat 8 Nov, 6 PM".
String formatEventWhen(DateTime start, DateTime now) {
  final day = DateTime(start.year, start.month, start.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  final h = start.hour % 12 == 0 ? 12 : start.hour % 12;
  final ampm = start.hour < 12 ? 'AM' : 'PM';
  final time = start.minute == 0 ? '$h $ampm' : '$h:${start.minute.toString().padLeft(2, '0')} $ampm';
  if (diff == 0) return 'Today, $time';
  if (diff == 1) return 'Tomorrow, $time';
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${wd[start.weekday - 1]} ${start.day} ${mo[start.month - 1]}, $time';
}
