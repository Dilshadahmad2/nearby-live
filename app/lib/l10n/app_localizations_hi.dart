// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hindi (`hi`).
class AppLocalizationsHi extends AppLocalizations {
  AppLocalizationsHi([String locale = 'hi']) : super(locale);

  @override
  String get subtitle => 'आपके आसपास सब कुछ,\nरियल टाइम में';

  @override
  String get featureRealtime => 'रियल-टाइम\nअपडेट';

  @override
  String get featureNearby => 'आसपास\nसब कुछ';

  @override
  String get featureGlobal => 'शहर से\nदुनिया तक';

  @override
  String get featureAlerts => 'अलर्ट और\nसूचनाएँ';

  @override
  String get pillLocating => 'स्थान खोज रहे हैं…';

  @override
  String get pillUpdating => 'अपडेट हो रहा है…';

  @override
  String get pillLive => 'लाइव अपडेट';

  @override
  String get pillDemo => 'लाइव · डेमो';

  @override
  String get range => 'दायरा';

  @override
  String get navNearby => 'आसपास';

  @override
  String get navTrains => 'ट्रेनें';

  @override
  String get navTraffic => 'ट्रैफ़िक';

  @override
  String get navWeather => 'मौसम';

  @override
  String get navEvents => 'इवेंट';

  @override
  String get cardTrain => 'ट्रेन';

  @override
  String get cardFlight => 'उड़ान';

  @override
  String get cardTraffic => 'सड़क ट्रैफ़िक';

  @override
  String get cardWeather => 'मौसम';

  @override
  String get cardEvents => 'इवेंट';

  @override
  String humidity(int value) {
    return 'नमी $value%';
  }

  @override
  String wind(int value) {
    return 'हवा $value किमी/घं';
  }

  @override
  String rain(int value) {
    return 'बारिश $value%';
  }

  @override
  String moreCount(int count) {
    return '+$count और';
  }

  @override
  String get you => 'आप';

  @override
  String get loadingCity => '3D शहर लोड हो रहा है…';

  @override
  String get findingLocation => 'आपका स्थान खोजा जा रहा है…';

  @override
  String get offline => 'कनेक्शन नहीं — पिछला ज्ञात डेटा दिखाया जा रहा है';

  @override
  String get demoNoPermission =>
      'स्थान की अनुमति नहीं — पुरानी दिल्ली का डेमो दिखाया जा रहा है';

  @override
  String get demoLocationOff =>
      'स्थान बंद है — पुरानी दिल्ली का डेमो दिखाया जा रहा है';

  @override
  String get enable => 'चालू करें';

  @override
  String get settings => 'सेटिंग्स';

  @override
  String get settingsMap => 'नक्शा';

  @override
  String get settingsRange => 'दायरा';

  @override
  String get settingsLocation => 'स्थान';

  @override
  String get settingsAlerts => 'अलर्ट';

  @override
  String get settingsAccessibility => 'सुलभता';

  @override
  String get settingsLanguage => 'भाषा';

  @override
  String get settingsDataSources => 'डेटा स्रोत';

  @override
  String get languageSystem => 'सिस्टम डिफ़ॉल्ट';

  @override
  String get settingsTitle => 'सेटिंग्स';

  @override
  String cardSemantics(String title, String subtitle, String distance) {
    return '$title: $subtitle$distance';
  }

  @override
  String distanceAway(String km) {
    return ', $km दूर';
  }
}
