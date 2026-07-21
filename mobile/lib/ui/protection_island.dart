import 'package:flutter/material.dart';

import '../services/filter_vpn.dart';
import 'app_theme.dart';

/// Compact status pill.
class ProtectionIsland extends StatelessWidget {
  const ProtectionIsland({
    super.key,
    required this.status,
    required this.stats,
    this.onTap,
  });

  final VpnStatus status;
  final VpnStats stats;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = status == VpnStatus.active;
    final color = switch (status) {
      VpnStatus.active => AppColors.success,
      VpnStatus.connecting => AppColors.warn,
      VpnStatus.error => AppColors.danger,
      VpnStatus.idle => AppColors.inkSoft,
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: color.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: AppColors.skyDeep.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Image.asset(
              'assets/logo_square.png',
              width: 18,
              height: 18,
              filterQuality: FilterQuality.none,
            ),
            const SizedBox(width: 8),
            Text(
              status == VpnStatus.active ? 'On' : status.label,
              style: TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 10),
              Container(width: 1, height: 12, color: AppColors.skyPale),
              const SizedBox(width: 10),
              Text(
                '${stats.blocked}',
                style: const TextStyle(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
