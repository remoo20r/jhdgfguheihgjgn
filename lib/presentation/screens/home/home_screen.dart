import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/download_support.dart';
import '../../../core/fullscreen.dart';
import '../../../core/theme/app_theme.dart';
import '../../../state/catalog_refresh.dart';
import '../../../state/live_providers.dart'
    show expiryDateProvider, liveCategoriesProvider;
import '../../../state/series_providers.dart' show seriesCategoriesProvider;
import '../../../state/vod_providers.dart' show vodCategoriesProvider;
import '../../common/app_dialogs.dart';
import '../../common/app_logo.dart';
import '../../common/support_contact_bar.dart';
import '../../../data/services/ip_region_service.dart';
import '../../common/tv_focusable.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Instantiate the refresher so its 24h auto-refresh timer runs.
    ref.watch(catalogRefreshProvider);
    // Warm the three catalogs in the background: on slow panels (tens of
    // seconds per call) the fetch starts now instead of on the first tap on
    // TV/Film/Serie. read(...) doesn't subscribe, and the FutureProviders
    // cache the in-flight future, so repeated builds are no-ops. Errors are
    // ignored here — the catalog screens surface them with a retry.
    ref.read(liveCategoriesProvider.future).ignore();
    ref.read(vodCategoriesProvider.future).ignore();
    ref.read(seriesCategoriesProvider.future).ignore();
    final isFullscreen = ref.watch(fullscreenProvider);

    // The home is the root route: a system Back here would kill the app cold.
    // Ask first (app-themed dialog, D-pad friendly) — mainly for TV remotes.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final exit = await showAppConfirmDialog(
          context,
          title: 'Exit BellaTV?',
          message: 'Do you want to close the app?',
          confirmLabel: 'Exit',
        );
        if (exit) SystemNavigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        centerTitle: true,
        // Refresh moved to the top-left, per the new home layout.
        leading: _RefreshIconButton(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(size: 30),
            const SizedBox(width: 12),
            Text('BellaTV', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          // Offline downloads: phone (touch) mode on the APK only.
          if (downloadsSupported())
            IconButton(
              tooltip: 'Downloads',
              icon: const Icon(Icons.download_outlined),
              onPressed: () => context.push('/downloads'),
            ),
          // Windows only: on Android the app is permanently fullscreen.
          if (fullscreenToggleAvailable)
            IconButton(
              tooltip: isFullscreen ? 'Exit Fullscreen' : 'Fullscreen',
              icon: Icon(isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: () => ref.read(fullscreenProvider.notifier).toggle(),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          // Center the three tiles as a group with a sensible max size, instead
          // of stretching them across the whole width. Each tile is capped so
          // it stays elegant on big TVs and compact on small phones.
          final gap = (w * 0.03).clamp(14.0, 36.0);
          final maxRowWidth = 900.0;
          final rowWidth = w.clamp(0.0, maxRowWidth);
          final horizontalPadding = ((w - rowWidth) / 2).clamp(16.0, w);
          final usableW = rowWidth - horizontalPadding.clamp(0, 40) * 0 - gap * 2 - 32;
          final tileW = (usableW / 3).clamp(90.0, 240.0);
          final tileH = (tileW * 1.32).clamp(140.0, h * 0.66);

          return Column(
            children: [
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _HomeTile(
                          label: 'Live TV',
                          icon: Icons.tv_rounded,
                          gradientColors: const [Color(0xFFE23744), Color(0xFF1A0608)],
                          glowColor: AppColors.red,
                          width: tileW,
                          height: tileH,
                          // D-pad: land on TV when the home opens.
                          autofocus: true,
                          onTap: () => context.push('/live'),
                        ),
                        SizedBox(width: gap),
                        _HomeTile(
                          label: 'Movies',
                          icon: Icons.movie_creation_rounded,
                          gradientColors: const [Color(0xFFC01F2E), Color(0xFF120406)],
                          glowColor: AppColors.gold,
                          width: tileW,
                          height: tileH,
                          onTap: () => context.push('/vod'),
                        ),
                        SizedBox(width: gap),
                        _HomeTile(
                          label: 'Series',
                          icon: Icons.video_library_rounded,
                          gradientColors: const [Color(0xFFE23744), Color(0xFF1A0608)],
                          glowColor: AppColors.goldDark,
                          width: tileW,
                          height: tileH,
                          onTap: () => context.push('/series'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const _ExpiryLine(),
              // Bottom bar: customer-service number (left), live clock + date +
              // region (center), and the NEW shortcut (right).
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Left: customer-service number only (compact).
                    const Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SupportContactBar(compact: true, numberOnly: true),
                      ),
                    ),
                    // Center: clock / date / region.
                    const Expanded(
                      flex: 2,
                      child: Center(child: _ClockPanel()),
                    ),
                    // Right: NEW shortcut (recently-added movies + series).
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _NewTile(onTap: () => context.push('/new')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }
}

/// A premium, color-coded card for one of the three main sections. Each card
/// is a rounded tile with a rich diagonal gradient, a soft outer glow, a glossy
/// top sheen and a large content icon inside a frosted circle — red for Live,
/// gold for Movies, and a gold→red blend for Series, matching the app's
/// black/red/gold identity.
class _HomeTile extends StatelessWidget {
  const _HomeTile({
    required this.label,
    required this.icon,
    required this.gradientColors,
    required this.glowColor,
    required this.width,
    required this.height,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final List<Color> gradientColors;
  final Color glowColor;
  final double width;
  final double height;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // Circular tile: a glossy disc with a black→red gradient and a gold/silver
    // rim, the label sitting just below. No animation — the TvFocusable ring
    // (static red fill + silver outline) provides the "selected" cue.
    final circle = (width * 0.92).clamp(96.0, 200.0);
    final iconSize = (circle * 0.40).clamp(34.0, 84.0);
    final fontSize = (width * 0.12).clamp(15.0, 22.0);

    return SizedBox(
      width: width,
      height: height,
      child: TvFocusable(
        borderRadius: circle,
        autofocus: autofocus,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: circle,
              height: circle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  radius: 1.0,
                  colors: gradientColors,
                ),
                boxShadow: [
                  // Colored outer glow for a premium "lit" look.
                  BoxShadow(
                    color: glowColor.withValues(alpha: 0.45),
                    blurRadius: 26,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 12,
                    offset: const Offset(0, 8),
                  ),
                ],
                // Gold rim for that first-class metallic edge.
                border: Border.all(
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.7),
                  width: 2,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Glossy top sheen (static).
                  Positioned(
                    top: circle * 0.10,
                    child: Container(
                      width: circle * 0.62,
                      height: circle * 0.34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(circle),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: 0.30),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Icon(icon, size: iconSize, color: Colors.white),
                ],
              ),
            ),
            SizedBox(height: height * 0.05),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: Colors.white,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatExpiry(DateTime d) {
  final local = d.toLocal();
  final dd = local.day.toString().padLeft(2, '0');
  final mm = local.month.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$dd/$mm/${local.year} $hh:$mi';
}

class _ExpiryLine extends ConsumerWidget {
  const _ExpiryLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expiry = ref.watch(expiryDateProvider);
    return expiry.maybeWhen(
      data: (date) {
        if (date == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Subscription valid until ${formatExpiry(date)}',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Compact refresh icon-button for the app bar's top-left. Triggers the same
/// catalog refresh as the old text button, with a brief spinner while it runs.
class _RefreshIconButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refreshing = ref.watch(catalogRefreshingProvider);
    return IconButton(
      tooltip: 'Refresh list',
      icon: refreshing
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
      onPressed: refreshing
          ? null
          : () => ref.read(catalogRefreshProvider).refreshNow(),
    );
  }
}

/// Live clock + date + region shown in the center of the home's bottom bar.
/// Time is 12-hour format. The region name (state/province, not city) is
/// resolved once from the network IP; the clock ticks locally every second.
class _ClockPanel extends StatefulWidget {
  const _ClockPanel();

  @override
  State<_ClockPanel> createState() => _ClockPanelState();
}

class _ClockPanelState extends State<_ClockPanel> {
  Timer? _timer;
  DateTime _now = DateTime.now();
  String? _region;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _loadRegion();
  }

  Future<void> _loadRegion() async {
    // Region from IP geolocation (state/province, not city — the ISP's exit
    // city is often wrong). Best-effort: silently ignored if offline.
    final region = await fetchIpRegion();
    if (mounted && region != null) setState(() => _region = region);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _time {
    int h = _now.hour;
    h = h % 12;
    if (h == 0) h = 12;
    final m = _now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get _ampm => _now.hour >= 12 ? 'PM' : 'AM';

  String get _date {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[_now.weekday - 1]}, ${_now.day} ${months[_now.month - 1]} ${_now.year}';
  }

  @override
  Widget build(BuildContext context) {
    // A framed "clock" card: big digital HH:MM (no seconds — it's the thing
    // people glance at all day, so it's the largest element), with the day,
    // date and region underneath.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A0A0E), Color(0xFF0A0304)],
        ),
        border: Border.all(color: const Color(0xFFD4AF37).withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: AppColors.red.withValues(alpha: 0.25),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _time,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _ampm,
                style: const TextStyle(
                  color: Color(0xFFD4AF37),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _region != null ? '$_date  •  $_region' : _date,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// "NEW" shortcut tile (bottom-right of home): opens the combined recently-added
/// movies + series screen. A bit smaller than the three main tiles.
class _NewTile extends StatelessWidget {
  const _NewTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      borderRadius: 40,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                center: Alignment(-0.3, -0.4),
                colors: [Color(0xFFE23744), Color(0xFF1A0608)],
              ),
              border: Border.all(
                color: const Color(0xFFD4AF37).withValues(alpha: 0.7),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.red.withValues(alpha: 0.4),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(Icons.fiber_new_rounded, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 6),
          const Text(
            'NEW',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}
