import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Full-screen light-blue pixel dither, inspired by logo_square.png.
class PixelDitherBackground extends StatelessWidget {
  const PixelDitherBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.skyDeep),
        const CustomPaint(painter: _DitherPainter(), size: Size.infinite),
        ?child,
      ],
    );
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter();

  // Bayer 4×4 ordered dither thresholds (0..15)
  static const _bayer = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
  ];

  static const _palette = [
    Color(0xFF0E4F8A),
    Color(0xFF1A6BB5),
    Color(0xFF2B86D6),
    Color(0xFF4AA3EA),
    Color(0xFF7EC8F5),
    Color(0xFFB8E0FB),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 5.0;
    final cols = (size.width / cell).ceil() + 1;
    final rows = (size.height / cell).ceil() + 1;
    final cx = size.width * 0.5;
    final cy = size.height * 0.38;
    final maxD = math.sqrt(cx * cx + (size.height * 0.7) * (size.height * 0.7));

    final paint = Paint()..style = PaintingStyle.fill;

    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final px = x * cell + cell * 0.5;
        final py = y * cell + cell * 0.5;
        final dx = px - cx;
        final dy = py - cy;
        final dist = math.sqrt(dx * dx + dy * dy) / maxD;
        // Radial falloff: center bright, edges deeper blue
        var t = (1.0 - dist.clamp(0.0, 1.0));
        t = t * t;
        final level = (t * (_palette.length - 1) * 16).floor();
        final threshold = _bayer[y & 3][x & 3];
        var idx = (level + threshold) ~/ 16;
        if (idx < 0) idx = 0;
        if (idx >= _palette.length) idx = _palette.length - 1;
        // slight vertical vignette
        if (py > size.height * 0.72 && idx > 0 && ((x + y) & 1) == 0) {
          idx = (idx - 1).clamp(0, _palette.length - 1);
        }
        paint.color = _palette[idx];
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
