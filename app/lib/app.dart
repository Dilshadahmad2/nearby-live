import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n.dart';
import 'core/theme/app_theme.dart';
import 'features/alerts/alerts.dart';
import 'features/lists/category_list_screen.dart';
import 'features/nearby/presentation/nearby_screen.dart';
import 'features/nearby/presentation/widgets/chrome.dart';
import 'features/nearby/scene/scene.dart';
import 'features/settings/settings_controller.dart';

class NearbyLiveApp extends ConsumerWidget {
  const NearbyLiveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = ref.watch(settingsProvider.select((s) => s.languageCode));
    return MaterialApp(
      title: 'Nearby Live',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: code.isEmpty ? null : Locale(code),
      home: const HomeShell(),
    );
  }
}

/// Map screen plus the floating neon bottom nav. The Nearby tab stays alive
/// while list tabs are shown so the map does not reload.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _tabKinds = [null, NearbyKind.train, NearbyKind.traffic, NearbyKind.weather, NearbyKind.event];

  void _open(NearbyKind k) {
    final i = _tabKinds.indexOf(k);
    if (i > 0) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(alertsRunnerProvider); // local alert notifications
    final w = MediaQuery.sizeOf(context).width;
    final pad = MediaQuery.paddingOf(context);
    final scale = (w / 512).clamp(.75, 1.2);
    final navH = 70 * scale;
    final inset = navH + 12 + pad.bottom;

    return Scaffold(
      extendBody: true,
      body: Stack(children: [
        Positioned.fill(
          child: IndexedStack(index: _index == 0 ? 0 : 1, children: [
            NearbyScreen(bottomInset: inset, onOpenCategory: _open),
            if (_index == 0)
              const SizedBox.shrink()
            else
              CategoryListScreen(key: ValueKey(_index), kind: _tabKinds[_index]!, bottomInset: inset),
          ]),
        ),
        Positioned(
          left: 18 * scale,
          right: 18 * scale,
          bottom: 12 + pad.bottom,
          child: NeonBottomNav(index: _index, scale: scale, onTap: (i) => setState(() => _index = i)),
        ),
      ]),
    );
  }
}
