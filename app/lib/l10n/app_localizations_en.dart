// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get subtitle => 'Everything around you,\nin real time';

  @override
  String get featureRealtime => 'Real-time\nUpdates';

  @override
  String get featureNearby => 'Everything\nNearby';

  @override
  String get featureGlobal => 'City to Global\nView';

  @override
  String get featureAlerts => 'Alerts &\nNotifications';

  @override
  String get pillLocating => 'Locating…';

  @override
  String get pillUpdating => 'Updating…';

  @override
  String get pillLive => 'Live Updates';

  @override
  String get pillDemo => 'Live · Demo';

  @override
  String get range => 'Range';

  @override
  String get navNearby => 'Nearby';

  @override
  String get navTrains => 'Trains';

  @override
  String get navTraffic => 'Traffic';

  @override
  String get navWeather => 'Weather';

  @override
  String get navEvents => 'Events';

  @override
  String get cardTrain => 'Train';

  @override
  String get cardFlight => 'Flight';

  @override
  String get cardTraffic => 'Road Traffic';

  @override
  String get cardWeather => 'Weather';

  @override
  String get cardEvents => 'Events';

  @override
  String humidity(int value) {
    return 'Humidity $value%';
  }

  @override
  String wind(int value) {
    return 'Wind $value km/h';
  }

  @override
  String rain(int value) {
    return 'Rain $value%';
  }

  @override
  String moreCount(int count) {
    return '+$count more';
  }

  @override
  String get you => 'You';

  @override
  String get loadingCity => 'Loading 3D city…';

  @override
  String get findingLocation => 'Finding your location…';

  @override
  String get offline => 'No connection — showing the last known data';

  @override
  String get demoNoPermission =>
      'No location permission — showing the Old Delhi demo';

  @override
  String get demoLocationOff => 'Location is off — showing the Old Delhi demo';

  @override
  String get enable => 'Enable';

  @override
  String get settings => 'Settings';

  @override
  String get settingsMap => 'Map';

  @override
  String get settingsRange => 'Range';

  @override
  String get settingsLocation => 'Location';

  @override
  String get settingsAlerts => 'Alerts';

  @override
  String get settingsAccessibility => 'Accessibility';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsDataSources => 'Data sources';

  @override
  String get languageSystem => 'System default';

  @override
  String get settingsTitle => 'Settings';

  @override
  String cardSemantics(String title, String subtitle, String distance) {
    return '$title: $subtitle$distance';
  }

  @override
  String distanceAway(String km) {
    return ', $km away';
  }
}
