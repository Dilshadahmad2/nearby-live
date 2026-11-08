import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_live/core/l10n.dart';

void main() {
  test('every English string has a Hindi translation', () {
    Map<String, dynamic> arb(String f) => jsonDecode(File('lib/l10n/$f').readAsStringSync()) as Map<String, dynamic>;
    final en = arb('app_en.arb').keys.where((k) => !k.startsWith('@')).toSet();
    final hi = arb('app_hi.arb').keys.where((k) => !k.startsWith('@')).toSet();
    expect(hi, en);
  });

  test('Hindi strings and placeholders', () {
    final hi = lookupAppLocalizations(const Locale('hi'));
    expect(hi.navTrains, 'ट्रेनें');
    expect(hi.humidity(62), 'नमी 62%');
    expect(hi.moreCount(2), '+2 और');
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.wind(12), 'Wind 12 km/h');
  });
}
