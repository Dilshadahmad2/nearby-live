import 'package:flutter/material.dart';

import '../../../../core/config.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../scene/scene.dart';

/// Rounded-square blue app icon with a white location pin.
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({super.key, this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .27),
          gradient: const LinearGradient(begin: Alignment(-.3, -1), end: Alignment(.3, 1), colors: [Color(0xFF55B4FF), Color(0xFF1352E6)]),
          boxShadow: const [
            BoxShadow(color: Color(0xCC3CA0FF), blurRadius: 26),
            BoxShadow(color: Color(0x8C0A288C), blurRadius: 22, offset: Offset(0, 8)),
          ],
        ),
        child: Stack(alignment: Alignment.center, children: [
          Icon(Icons.location_on, size: size * .6, color: Colors.white),
          Padding(
            padding: EdgeInsets.only(bottom: size * .1),
            child: Container(
              width: size * .16,
              height: size * .16,
              decoration: const BoxDecoration(color: Color(0xFF1F63EE), shape: BoxShape.circle),
            ),
          ),
        ]),
      );
}

/// "Nearby **Live**" with the cyan gradient on "Live".
class AppTitle extends StatelessWidget {
  const AppTitle({super.key, this.scale = 1});
  final double scale;

  @override
  Widget build(BuildContext context) {
    final shadows = const [
      Shadow(color: Color(0x995AC8FF), blurRadius: 22),
      Shadow(color: Color(0x73001450), blurRadius: 12, offset: Offset(0, 3)),
    ];
    final base = outfit(39 * scale, weight: FontWeight.w800, shadows: shadows, height: 1.1).copyWith(letterSpacing: -.6);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Nearby ', style: base),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => const LinearGradient(colors: [Color(0xFF5FF0FF), Color(0xFF2FB2FF)]).createShader(r),
          child: Text('Live',
              style: base.copyWith(shadows: const [Shadow(color: Color(0xD93CDCFF), blurRadius: 10)])),
        ),
      ]),
      SizedBox(height: 2 * scale),
      Text(
        'Everything around you,\nin real time',
        style: outfit(17 * scale, color: const Color(0xFFE4EDFF), height: 1.18,
            shadows: const [Shadow(color: Color(0x80001450), blurRadius: 8, offset: Offset(0, 2))]),
      ),
    ]);
  }
}

/// "Live Updates" pill with a pulsing green dot (amber when stale/locating).
class LivePill extends StatefulWidget {
  const LivePill({super.key, required this.status, this.scale = 1});
  final LiveStatus status;
  final double scale;

  @override
  State<LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<LivePill> with SingleTickerProviderStateMixin {
  late final AnimationController _ping = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final (label, colour, pulse) = switch (widget.status) {
      LiveStatus.locating => ('Locating…', AppColors.amber, false),
      LiveStatus.stale => ('Updating…', AppColors.amber, true),
      LiveStatus.live => ('Live Updates', AppColors.green, true),
      LiveStatus.demo => ('Live · Demo', AppColors.green, true),
    };
    return _ChromePill(
      scale: s,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _ping,
          builder: (_, __) {
            final p = _ping.value;
            final ring = p < .7 ? p / .7 : 1.0;
            return Container(
              width: 9 * s,
              height: 9 * s,
              decoration: BoxDecoration(
                color: colour,
                shape: BoxShape.circle,
                boxShadow: pulse
                    ? [BoxShadow(color: colour.withValues(alpha: .7 * (1 - ring)), spreadRadius: 7 * s * ring)]
                    : const [],
              ),
            );
          },
        ),
        SizedBox(width: 7 * s),
        Text(label, style: outfit(12.5 * s, weight: FontWeight.w600)),
      ]),
    );
  }
}

class _ChromePill extends StatelessWidget {
  const _ChromePill({required this.child, required this.scale});
  final Widget child;
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
        height: 28 * scale,
        padding: EdgeInsets.symmetric(horizontal: 13 * scale),
        decoration: BoxDecoration(
          color: AppColors.pill,
          borderRadius: BorderRadius.circular(14 * scale),
          border: Border.all(color: AppColors.pillBorder),
          boxShadow: const [BoxShadow(color: Color(0x733CA0FF), blurRadius: 14)],
        ),
        child: Center(widthFactor: 1, child: child),
      );
}

/// Round settings button.
class GearButton extends StatelessWidget {
  const GearButton({super.key, required this.onTap, this.scale = 1});
  final VoidCallback onTap;
  final double scale;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Settings',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 30 * scale,
            height: 30 * scale,
            decoration: BoxDecoration(
              color: AppColors.pill,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.pillBorder),
              boxShadow: const [BoxShadow(color: Color(0x733CA0FF), blurRadius: 14)],
            ),
            child: Icon(Icons.settings_rounded, size: 17 * scale, color: Colors.white),
          ),
        ),
      );
}

/// "Range [5 km ▾]" dropdown.
class RangeDropdown extends StatelessWidget {
  const RangeDropdown({super.key, required this.value, required this.onChanged, this.scale = 1});
  final int value;
  final ValueChanged<int> onChanged;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Container(
      height: 28 * s,
      padding: EdgeInsets.only(left: 12 * s, right: 4 * s),
      decoration: BoxDecoration(
        color: const Color(0xD9081848),
        borderRadius: BorderRadius.circular(14 * s),
        border: Border.all(color: const Color(0xB335E0FF)),
        boxShadow: const [BoxShadow(color: Color(0x5935E0FF), blurRadius: 14)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Range', style: outfit(12 * s, weight: FontWeight.w600, color: const Color(0xFFBFE9FF))),
        SizedBox(width: 6 * s),
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: value,
            isDense: true,
            dropdownColor: AppColors.panel,
            borderRadius: BorderRadius.circular(12),
            icon: Icon(Icons.keyboard_arrow_down_rounded, size: 18 * s, color: Colors.white),
            style: outfit(13 * s, weight: FontWeight.w700),
            items: [
              for (final r in AppConfig.ranges)
                DropdownMenuItem(value: r, child: Text('$r km', style: outfit(13 * s, weight: FontWeight.w700))),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ]),
    );
  }
}

/// Real-time Updates · Everything Nearby · City to Global View · Alerts & Notifications.
class FeatureRow extends StatelessWidget {
  const FeatureRow({super.key, this.scale = 1});
  final double scale;

  static const _items = [
    (Icons.bolt_rounded, 'Real-time\nUpdates'),
    (Icons.location_on_outlined, 'Everything\nNearby'),
    (Icons.public_rounded, 'City to Global\nView'),
    (Icons.notifications_none_rounded, 'Alerts &\nNotifications'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < _items.length; i++)
        Container(
          width: 65 * s,
          decoration: i == 0
              ? null
              : const BoxDecoration(border: Border(left: BorderSide(color: Color(0x38FFFFFF)))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 30 * s,
              height: 30 * s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x590F3296),
                border: Border.all(color: const Color(0xBFFFFFFF), width: 1.5),
                boxShadow: const [BoxShadow(color: Color(0x8C5AC8FF), blurRadius: 12)],
              ),
              child: Icon(_items[i].$1, size: 15 * s, color: Colors.white),
            ),
            SizedBox(height: 5 * s),
            Text(
              _items[i].$2,
              textAlign: TextAlign.center,
              style: outfit(10.5 * s, height: 1.15, shadows: const [Shadow(color: Color(0xB3001450), blurRadius: 6, offset: Offset(0, 1))]),
            ),
          ]),
        ),
    ]);
  }
}

/// Bottom navigation: Nearby · Trains · Traffic · Weather · Events with a
/// glowing cyan underline under the active tab.
class NeonBottomNav extends StatelessWidget {
  const NeonBottomNav({super.key, required this.index, required this.onTap, this.scale = 1});
  final int index;
  final ValueChanged<int> onTap;
  final double scale;

  static const tabs = [
    (Icons.location_on_rounded, 'Nearby'),
    (Icons.train_outlined, 'Trains'),
    (Icons.directions_car_outlined, 'Traffic'),
    (Icons.wb_cloudy_outlined, 'Weather'),
    (Icons.event_outlined, 'Events'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = scale.clamp(.75, 1.2);
    return Container(
      height: 70 * s,
      decoration: BoxDecoration(
        color: AppColors.chrome,
        borderRadius: BorderRadius.circular(20 * s),
        border: Border.all(color: const Color(0x595A96FF)),
        boxShadow: const [
          BoxShadow(color: Color(0x592878FF), blurRadius: 30),
          BoxShadow(color: Color(0x80000A28), blurRadius: 30, offset: Offset(0, -6)),
        ],
      ),
      child: Stack(children: [
        // Cyan glow line along the top edge.
        Positioned(
          top: -1,
          left: 0,
          right: 0,
          child: FractionallySizedBox(
            widthFactor: .64,
            child: Container(
              height: 2,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0x0035E0FF), AppColors.cyan, Color(0x0035E0FF)]),
                boxShadow: [BoxShadow(color: AppColors.cyan, blurRadius: 12)],
              ),
            ),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                label: tabs[i].$2,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onTap(i),
                  child: _NavItem(icon: tabs[i].$1, label: tabs[i].$2, active: i == index, scale: s),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.active, required this.scale});
  final IconData icon;
  final String label;
  final bool active;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 32 * s,
        height: 32 * s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? AppColors.blue : Colors.transparent,
          boxShadow: active ? const [BoxShadow(color: Color(0xCC2F7DFF), blurRadius: 16)] : const [],
        ),
        child: Icon(icon, size: 22 * s, color: Colors.white),
      ),
      SizedBox(height: 4 * s),
      Text(label,
          style: outfit(12 * s, weight: active ? FontWeight.w700 : FontWeight.w500, color: active ? Colors.white : const Color(0xFFDCE6FF))),
      SizedBox(height: 4 * s),
      AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: active ? 52 * s : 0,
        height: 3,
        decoration: BoxDecoration(
          color: AppColors.cyan,
          borderRadius: BorderRadius.circular(3),
          boxShadow: active ? const [BoxShadow(color: AppColors.cyan, blurRadius: 10)] : const [],
        ),
      ),
    ]);
  }
}
