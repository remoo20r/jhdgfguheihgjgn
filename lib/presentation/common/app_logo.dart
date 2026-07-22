import 'package:flutter/material.dart';

/// BellaTV brand mark: the 3D logo image (assets/images/app_logo.png) with a
/// soft blue/magenta glow behind it so it reads as premium and luminous
/// wherever it appears (app bars, login).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.24;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          // Cool blue glow (matches the logo's icy facets).
          BoxShadow(
            color: const Color(0xFF4AA3FF).withValues(alpha: 0.28),
            blurRadius: size * 0.5,
            spreadRadius: -size * 0.10,
          ),
          // Warm magenta glow (matches the logo's pink edge) for depth.
          BoxShadow(
            color: const Color(0xFFE84BC9).withValues(alpha: 0.22),
            blurRadius: size * 0.6,
            spreadRadius: -size * 0.14,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/images/app_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            color: const Color(0xFF0B121D),
          ),
        ),
      ),
    );
  }
}
