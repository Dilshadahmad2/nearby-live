// Layout smoke test of the Nearby screen at real phone sizes, with the
// demo scenario running. The native MapLibre view cannot run in tests, so a
// MapPreview supplies a background and a flat projection; everything else
// (chrome, cards, HUD, plane, weather, pins, nav) is the real UI.
//
// Fails on any layout overflow. With SCREENSHOT_DIR set it also writes PNGs:
//   SCREENSHOT_DIR=build/screenshots flutter test test/layout_screenshot_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nearby_live/core/geo/geo_point.dart';
import 'package:nearby_live/core/theme/app_theme.dart';
import 'package:nearby_live/features/demo/demo_city.dart';
import 'package:nearby_live/features/nearby/presentation/map/map_sync.dart';
import 'package:nearby_live/features/nearby/presentation/nearby_screen.dart';
import 'package:nearby_live/features/nearby/presentation/widgets/chrome.dart';
import 'package:nearby_live/features/nearby/scene/scene.dart';
import 'package:nearby_live/features/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Flat Web-Mercator projection around the camera centre, with the pitch
/// approximated by compressing the vertical axis.
Projection flatProjection(SceneSnapshot s, Size v) {
  final scale = 512 * math.pow(2, s.camera.zoom).toDouble();
  Offset world(GeoPoint p) {
    final x = (p.lon + 180) / 360 * scale;
    final sinLat = math.sin(p.lat * math.pi / 180);
    final y = (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale;
    return Offset(x, y);
  }

  final c = world(s.camera.center);
  final tilt = math.cos(s.camera.pitch * math.pi / 180);
  Offset screen(GeoPoint p) {
    final w = world(p) - c;
    return Offset(v.width / 2 + w.dx, v.height / 2 + w.dy * tilt);
  }

  final you = screen(s.user);
  return Projection(
    you: you,
    ringRadius: s.ringRadiusPx != null ? s.ringRadiusPx! * v.width / 512 : v.width * .4,
    points: {
      '_you': you,
      for (final i in s.items)
        if (i.anchor != null) i.id: screen(i.anchor!),
    },
  );
}

/// Stand-in for the satellite map: dusk-coloured ground with a street grid.
class _FakeMap extends StatelessWidget {
  const _FakeMap();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GridPainter(), size: Size.infinite);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(
        r,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2B4A63), Color(0xFF3E5A3E), Color(0xFF4A4A3A)],
          ).createShader(r));
    final road = Paint()
      ..color = const Color(0x55FFD166)
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width + size.height; x += 46) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height * .35, 0), road);
    }
    for (var y = size.height * .3; y < size.height; y += 38) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 20), road);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const _sizes = <String, Size>{
  'small-android-360x780': Size(360, 780),
  'pixel-412x915': Size(412, 915),
  'iphone-390x844': Size(390, 844),
  'iphone-pro-max-430x932': Size(430, 932),
};

void main() {
  late DemoCity city;
  setUpAll(() async {
    // Load the demo city once, outside the fake-async test zone.
    city = DemoCity.fromJson(jsonDecode(File('assets/demo/city-old-delhi.json').readAsStringSync()) as Map<String, dynamic>);
    GoogleFonts.config.allowRuntimeFetching = false;
    // Tests don't load the Material icon font; load it from the Flutter SDK
    // so screenshots show real icons instead of boxes.
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (flutterRoot != null && icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  for (final entry in _sizes.entries) {
    testWidgets('Nearby screen lays out on ${entry.key}', (tester) async {
      const dpr = 2.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = entry.value * dpr;
      tester.view.padding = const FakeViewPadding(top: 32 * dpr, bottom: 16 * dpr);
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({'demo_pref': 'always', 'range_km': 10});
      final prefs = await SharedPreferences.getInstance();
      final shot = GlobalKey();

      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          demoCityProvider.overrideWith((ref) async => city),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: RepaintBoundary(
            key: shot,
            child: Scaffold(
              body: LayoutBuilder(builder: (context, box) {
                final scale = (box.maxWidth / 512).clamp(.75, 1.2);
                final pad = MediaQuery.paddingOf(context);
                return Stack(children: [
                  Positioned.fill(
                    child: NearbyScreen(
                      bottomInset: 70 * scale + 12 + pad.bottom,
                      onOpenCategory: (_) {},
                      preview: const MapPreview(background: _FakeMap(), project: flatProjection),
                    ),
                  ),
                  Positioned(
                    left: 18 * scale,
                    right: 18 * scale,
                    bottom: 12 + pad.bottom,
                    child: NeonBottomNav(index: 0, scale: scale, onTap: (_) {}),
                  ),
                ]);
              }),
            ),
          ),
        ),
      ));

      // Let real async work finish: the demo city asset and the bundled fonts.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await GoogleFonts.pendingFonts();
      });

      // Run the 40 s demo script to t ≈ 25 s, when all five cards are on screen at 10 km.
      for (var i = 0; i < 520; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final dir = Platform.environment['SCREENSHOT_DIR'];
      if (dir != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shot));
        await tester.runAsync(() async {
          final ui.Image img = await boundary.toImage(pixelRatio: dpr);
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          Directory(dir).createSync(recursive: true);
          File('$dir/nearby-${entry.key}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }

      expect(find.text('Train'), findsOneWidget);
      expect(find.text('Weather'), findsWidgets);
      expect(find.text('Road Traffic'), findsOneWidget);
      expect(find.text('Music Fest 2025'), findsOneWidget);

      // Stop the ticker before the test ends.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
