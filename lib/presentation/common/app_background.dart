import 'package:flutter/material.dart';

/// App-wide backdrop: a lightweight black→dark-red vertical gradient.
///
/// This used to be a CustomPainter drawing many blurred, additively-blended
/// light-streaks. That looked nice but was far too expensive to repaint on
/// low-end Android TV boxes (blur + BlendMode.plus are among the heaviest GPU
/// ops), and it painted behind EVERY screen — a constant tax on the raster
/// thread that made the whole UI feel sluggish. A plain gradient is effectively
/// free and keeps the premium black/red identity.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF17060A), // near-black with a red undertone
            Color(0xFF050506), // black
          ],
        ),
      ),
      child: child,
    );
  }
}
