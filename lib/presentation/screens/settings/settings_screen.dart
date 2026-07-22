import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/xtream_profile.dart';
import '../../../data/services/content_source.dart';
import '../../../data/services/device_mode_service.dart';
import '../../../data/services/speed_test_service.dart';
import '../../../data/services/storage_service.dart';
import '../../../state/favorites_providers.dart';
import '../../../state/live_providers.dart';
import '../../../state/player_settings_providers.dart';
import '../../../state/profile_providers.dart';
import '../../../state/series_providers.dart';
import '../../../state/vod_providers.dart';
import '../../../state/watch_progress_providers.dart';
import 'package:broken_iptv/presentation/common/app_dialogs.dart';
import 'package:broken_iptv/presentation/common/tv_focusable.dart';

// Shared text styles for settings: **bold** titles, *italic* descriptions.
const _kSectionTitle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.bold,
  letterSpacing: -0.2,
  color: AppColors.textPrimary,
);
const _kItemTitle = TextStyle(
  color: AppColors.textPrimary,
  fontWeight: FontWeight.bold,
);
const _kItemDesc = TextStyle(
  color: AppColors.textSecondary,
  fontStyle: FontStyle.italic,
);

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _deviceModeService = DeviceModeService();
  DeviceMode? _currentMode;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _currentMode = _deviceModeService.getSaved();
    }
  }

  Future<void> _setMode(DeviceMode mode) async {
    await _deviceModeService.save(mode);
    if (mounted) setState(() => _currentMode = mode);
  }

  Future<void> _clearData() async {
    final ok = await showAppConfirmDialog(
      context,
      title: 'Clear cache?',
      message: 'This removes favorites, "Continue Watching" history and '
          'cached images/catalogs. Saved playlists are kept.',
      confirmLabel: 'Clear',
    );
    if (!ok) return;

    await DefaultCacheManager().emptyCache();
    await StorageService.favoritesBox.clear();
    await StorageService.watchProgressBox.clear();
    await StorageService.catalogCacheBox.clear();
    // Bulk EPG files (one per profile), best-effort.
    try {
      final dir = await getApplicationSupportDirectory();
      await for (final f in dir.list()) {
        if (f is File && f.uri.pathSegments.last.startsWith('epg_')) {
          await f.delete();
        }
      }
    } catch (_) {}
    ref.invalidate(favoritesProvider);
    ref.invalidate(watchProgressProvider);
    ref.invalidate(liveCategoriesProvider);
    ref.invalidate(vodCategoriesProvider);
    ref.invalidate(seriesCategoriesProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Personal data cleared.')),
      );
    }
  }

  Future<void> _confirmDeletePlaylist(XtreamProfile profile) async {
    final ok = await showAppConfirmDialog(
      context,
      title: 'Delete playlist?',
      message: '"${profile.name}" will be removed along with its saved credentials.',
      confirmLabel: 'Delete',
    );
    if (ok) {
      await ref.read(profilesProvider.notifier).remove(profile.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    final selectedId = ref.watch(selectedProfileIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Playlist', style: _kSectionTitle),
          const SizedBox(height: 8),
          // Each playlist shows only its name; the selected one is filled white
          // like the other setting chips. Edit/delete live on the box itself.
          // D-pad: the first item autofocuses, so entering Settings on TV
          // always has a visibly focused starting point.
          ...profiles.asMap().entries.map((e) => _PlaylistTile(
                profile: e.value,
                autofocus: e.key == 0,
                selected: e.value.id == selectedId,
                onSelect: () =>
                    ref.read(selectedProfileIdProvider.notifier).select(e.value.id),
                onEdit: () => context.push('/profiles/add', extra: e.value),
                onDelete: () => _confirmDeletePlaylist(e.value),
              )),
          const SizedBox(height: 4),
          TvFocusable(
            borderRadius: 14,
            autofocus: profiles.isEmpty,
            onTap: () => context.push('/profiles/add'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: const Row(
                children: [
                  Icon(Icons.add, color: AppColors.textPrimary),
                  SizedBox(width: 12),
                  Text('Add playlist', style: _kItemTitle),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Account', style: _kSectionTitle),
          const SizedBox(height: 8),
          const _AccountSection(),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 24),
            const Text('Device mode', style: _kSectionTitle),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TvFocusable(
                    onTap: () => _setMode(DeviceMode.tv),
                    child: _ModeChip(label: 'TV / Remote', selected: _currentMode == DeviceMode.tv),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TvFocusable(
                    onTap: () => _setMode(DeviceMode.touch),
                    child: _ModeChip(label: 'Phone / Tablet', selected: _currentMode == DeviceMode.touch),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          const Text('Playback', style: _kSectionTitle),
          const SizedBox(height: 8),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.aspect_ratio),
            title: Text('Default aspect ratio', style: _kItemTitle),
          ),
          Row(
            children: [
              for (final aspect in VideoAspect.values) ...[
                Expanded(
                  child: TvFocusable(
                    borderRadius: 14,
                    onTap: () => ref.read(playerSettingsProvider.notifier).setAspect(aspect),
                    child: _ModeChip(
                      label: aspect.label,
                      selected: ref.watch(playerSettingsProvider).aspect == aspect,
                    ),
                  ),
                ),
                if (aspect != VideoAspect.values.last) const SizedBox(width: 12),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.subtitles_outlined),
            title: const Text('Subtitles', style: _kItemTitle),
            subtitle: const Text('Off by default', style: _kItemDesc),
            value: ref.watch(playerSettingsProvider).subtitlesEnabled,
            onChanged: (v) => ref.read(playerSettingsProvider.notifier).setSubtitlesEnabled(v),
          ),
          const SizedBox(height: 12),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.forward_10),
            title: Text('Skip forward/back', style: _kItemTitle),
            subtitle: Text('Movies and series only', style: _kItemDesc),
          ),
          Row(
            children: [
              for (final s in kSkipOptions) ...[
                Expanded(
                  child: TvFocusable(
                    borderRadius: 14,
                    onTap: () => ref.read(playerSettingsProvider.notifier).setSkipSeconds(s),
                    child: _ModeChip(
                      label: '$s s',
                      selected: ref.watch(playerSettingsProvider).skipSeconds == s,
                    ),
                  ),
                ),
                if (s != kSkipOptions.last) const SizedBox(width: 12),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // ---- Series: skip intro -------------------------------------
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fast_forward),
            title: Text('Skip intro — Series', style: _kItemTitle),
            subtitle: const Text(
              'Show a "Skip intro" button on series episodes.',
              style: _kItemDesc,
            ),
            trailing: Switch(
              value: ref.watch(playerSettingsProvider).seriesSkipEnabled,
              onChanged: (v) =>
                  ref.read(playerSettingsProvider.notifier).setSeriesSkipEnabled(v),
            ),
          ),
          if (ref.watch(playerSettingsProvider).seriesSkipEnabled)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final s in kIntroSkipOptions)
                  SizedBox(
                    width: 92,
                    child: TvFocusable(
                      borderRadius: 14,
                      onTap: () =>
                          ref.read(playerSettingsProvider.notifier).setIntroSkipSeconds(s),
                      child: _ModeChip(
                        label: '$s s',
                        selected:
                            ref.watch(playerSettingsProvider).introSkipSeconds == s,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 20),
          // ---- Movies: skip intro -------------------------------------
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fast_forward),
            title: Text('Skip intro — Movies', style: _kItemTitle),
            subtitle: const Text(
              'Show a "Skip intro" button on movies (default 120s = 2 min).',
              style: _kItemDesc,
            ),
            trailing: Switch(
              value: ref.watch(playerSettingsProvider).movieSkipEnabled,
              onChanged: (v) =>
                  ref.read(playerSettingsProvider.notifier).setMovieSkipEnabled(v),
            ),
          ),
          if (ref.watch(playerSettingsProvider).movieSkipEnabled)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final s in kIntroSkipOptions)
                  SizedBox(
                    width: 92,
                    child: TvFocusable(
                      borderRadius: 14,
                      onTap: () =>
                          ref.read(playerSettingsProvider.notifier).setMovieSkipSeconds(s),
                      child: _ModeChip(
                        label: '$s s',
                        selected:
                            ref.watch(playerSettingsProvider).movieSkipSeconds == s,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          const Text('Network', style: _kSectionTitle),
          const SizedBox(height: 8),
          const _SpeedTestTile(),
          const SizedBox(height: 24),
          const Text('Cache', style: _kSectionTitle),
          const SizedBox(height: 8),
          TvFocusable(
            onTap: _clearData,
            child: const ListTile(
              leading: Icon(Icons.cleaning_services_outlined),
              title: Text('Clear cache', style: _kItemTitle),
              subtitle: Text(
                'clears all personal app data on this device',
                style: _kItemDesc,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    this.autofocus = false,
  });

  final XtreamProfile profile;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.black : AppColors.textPrimary;
    final subFg = selected ? Colors.black54 : AppColors.textSecondary;
    return TvFocusable(
      borderRadius: 14,
      autofocus: autofocus,
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          children: [
            Icon(Icons.playlist_play, color: selected ? Colors.black : AppColors.accent),
            const SizedBox(width: 12),
            // Only the name is shown here — host/username appear only in Edit.
            Expanded(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: Icon(Icons.edit_outlined, color: subFg),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: subFg),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  static String _fmtDate(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _countdown(DateTime expiry) {
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    if (days > 0) return 'in ${days}d ${hours}h';
    final minutes = diff.inMinutes % 60;
    return 'in ${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountInfoProvider);
    return account.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, _) => const Text('Account information unavailable.', style: _kItemDesc),
      data: (AccountInfo? a) {
        if (a == null) {
          return const Text('Account information unavailable.', style: _kItemDesc);
        }
        final rows = <Widget>[];
        void row(IconData icon, String label, String value) {
          rows.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Text('$label: ', style: _kItemTitle),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(color: AppColors.textPrimary),
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ));
        }

        if (a.status != null) {
          row(Icons.verified_user_outlined, 'Status',
              a.isTrial == true ? '${a.status} (trial)' : a.status!);
        }
        if (a.expiresAt != null) {
          row(Icons.event_outlined, 'Expiry', '${_fmtDate(a.expiresAt!)}  •  ${_countdown(a.expiresAt!)}');
        }
        if (a.maxConnections != null || a.activeConnections != null) {
          final active = a.activeConnections?.toString() ?? '?';
          final max = a.maxConnections?.toString() ?? '?';
          row(Icons.lan_outlined, 'Connections', '$active / $max active');
        }
        // Server URL intentionally hidden from the UI everywhere.
        if (rows.isEmpty) {
          return const Text('Account information unavailable.', style: _kItemDesc);
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        );
      },
    );
  }
}

class _SpeedTestTile extends ConsumerStatefulWidget {
  const _SpeedTestTile();

  @override
  ConsumerState<_SpeedTestTile> createState() => _SpeedTestTileState();
}

class _SpeedTestTileState extends ConsumerState<_SpeedTestTile> {
  bool _running = false;
  SpeedTestResult? _result;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await SpeedTestService().run();
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = 'Test failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusable(
          onTap: _running ? () {} : _run,
          child: ListTile(
            leading: _running
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.speed),
            title: Text(_running ? 'Testing...' : 'Run speed test', style: _kItemTitle),
            subtitle: const Text('Measure your connection speed (fast.com)', style: _kItemDesc),
          ),
        ),
        if (_result != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_result!.mbps.toStringAsFixed(1)} Mbps — ${_result!.verdict}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(_result!.detail, style: const TextStyle(color: AppColors.textSecondary)),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: AppColors.textSecondary)),
          ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.black : AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
