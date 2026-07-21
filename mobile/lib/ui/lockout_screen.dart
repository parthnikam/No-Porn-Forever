import 'package:flutter/material.dart';

import '../services/content_guardian.dart';
import 'app_theme.dart';
import 'pixel_dither_background.dart';

class LockoutScreen extends StatelessWidget {
  const LockoutScreen({super.key, required this.event, this.onDismiss});

  final GuardianEvent event;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PixelDitherBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/logo_square.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.none,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Blocked',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  event.reason,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  event.detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 28),
                Text(
                  'Closing…',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                ),
                if (onDismiss != null) ...[
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: onDismiss,
                    child: const Text(
                      'Dismiss',
                      style: TextStyle(color: AppColors.skyPale),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
