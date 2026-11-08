import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

export '../l10n/app_localizations.dart';

/// Strings for [context], falling back to English when no localisation
/// delegate is installed (e.g. in widget tests that build their own app).
AppLocalizations l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
