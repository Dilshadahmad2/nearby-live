import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_hi.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('hi')
  ];

  /// No description provided for @subtitle.
  ///
  /// In en, this message translates to:
  /// **'Everything around you,\nin real time'**
  String get subtitle;

  /// No description provided for @featureRealtime.
  ///
  /// In en, this message translates to:
  /// **'Real-time\nUpdates'**
  String get featureRealtime;

  /// No description provided for @featureNearby.
  ///
  /// In en, this message translates to:
  /// **'Everything\nNearby'**
  String get featureNearby;

  /// No description provided for @featureGlobal.
  ///
  /// In en, this message translates to:
  /// **'City to Global\nView'**
  String get featureGlobal;

  /// No description provided for @featureAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts &\nNotifications'**
  String get featureAlerts;

  /// No description provided for @pillLocating.
  ///
  /// In en, this message translates to:
  /// **'Locating…'**
  String get pillLocating;

  /// No description provided for @pillUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating…'**
  String get pillUpdating;

  /// No description provided for @pillLive.
  ///
  /// In en, this message translates to:
  /// **'Live Updates'**
  String get pillLive;

  /// No description provided for @pillDemo.
  ///
  /// In en, this message translates to:
  /// **'Live · Demo'**
  String get pillDemo;

  /// No description provided for @range.
  ///
  /// In en, this message translates to:
  /// **'Range'**
  String get range;

  /// No description provided for @navNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get navNearby;

  /// No description provided for @navTrains.
  ///
  /// In en, this message translates to:
  /// **'Trains'**
  String get navTrains;

  /// No description provided for @navTraffic.
  ///
  /// In en, this message translates to:
  /// **'Traffic'**
  String get navTraffic;

  /// No description provided for @navWeather.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get navWeather;

  /// No description provided for @navEvents.
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get navEvents;

  /// No description provided for @cardTrain.
  ///
  /// In en, this message translates to:
  /// **'Train'**
  String get cardTrain;

  /// No description provided for @cardFlight.
  ///
  /// In en, this message translates to:
  /// **'Flight'**
  String get cardFlight;

  /// No description provided for @cardTraffic.
  ///
  /// In en, this message translates to:
  /// **'Road Traffic'**
  String get cardTraffic;

  /// No description provided for @cardWeather.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get cardWeather;

  /// No description provided for @cardEvents.
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get cardEvents;

  /// No description provided for @humidity.
  ///
  /// In en, this message translates to:
  /// **'Humidity {value}%'**
  String humidity(int value);

  /// No description provided for @wind.
  ///
  /// In en, this message translates to:
  /// **'Wind {value} km/h'**
  String wind(int value);

  /// No description provided for @rain.
  ///
  /// In en, this message translates to:
  /// **'Rain {value}%'**
  String rain(int value);

  /// No description provided for @moreCount.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String moreCount(int count);

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @loadingCity.
  ///
  /// In en, this message translates to:
  /// **'Loading 3D city…'**
  String get loadingCity;

  /// No description provided for @findingLocation.
  ///
  /// In en, this message translates to:
  /// **'Finding your location…'**
  String get findingLocation;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'No connection — showing the last known data'**
  String get offline;

  /// No description provided for @demoNoPermission.
  ///
  /// In en, this message translates to:
  /// **'No location permission — showing the Old Delhi demo'**
  String get demoNoPermission;

  /// No description provided for @demoLocationOff.
  ///
  /// In en, this message translates to:
  /// **'Location is off — showing the Old Delhi demo'**
  String get demoLocationOff;

  /// No description provided for @enable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get enable;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @settingsMap.
  ///
  /// In en, this message translates to:
  /// **'Map'**
  String get settingsMap;

  /// No description provided for @settingsRange.
  ///
  /// In en, this message translates to:
  /// **'Range'**
  String get settingsRange;

  /// No description provided for @settingsLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get settingsLocation;

  /// No description provided for @settingsAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get settingsAlerts;

  /// No description provided for @settingsAccessibility.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get settingsAccessibility;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsDataSources.
  ///
  /// In en, this message translates to:
  /// **'Data sources'**
  String get settingsDataSources;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystem;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @cardSemantics.
  ///
  /// In en, this message translates to:
  /// **'{title}: {subtitle}{distance}'**
  String cardSemantics(String title, String subtitle, String distance);

  /// No description provided for @distanceAway.
  ///
  /// In en, this message translates to:
  /// **', {km} away'**
  String distanceAway(String km);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'hi'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'hi':
      return AppLocalizationsHi();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
