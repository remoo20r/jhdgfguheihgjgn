import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/download_support.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/download_item.dart';
import '../../../data/models/series_item.dart';
import '../../../data/repositories/series_repository.dart';
import '../../../state/downloads_providers.dart';
import '../../../state/series_providers.dart';
import '../../../state/watch_progress_providers.dart';
import '../../common/download_button.dart';
import '../../common/tv_focusable.dart';
import '../../common/watch_bar.dart';

class SeriesDetailScreen extends ConsumerStatefulWidget {
  const SeriesDetailScreen({super.key, required this.seriesId});

  final String seriesId;

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  int? _selectedSeason;

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(seriesDetailProvider(widget.seriesId));

    return Scaffold(
      appBar: AppBar(title: const Text('Series Details')),
      body: detail.when(
        data: (series) {
          final seasons = series.episodesBySeason.keys.toList()..sort();
          if (seasons.isEmpty) {
            return const Center(child: Text('No episodes available.'));
          }
          _selectedSeason ??= seasons.first;
          final episodes = series.episodesBySeason[_selectedSeason] ?? const [];

          // Header (cover + description + continue) shown above everything.
          final header = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 150,
                  height: 220,
                  child: series.coverUrl != null
                      ? CachedNetworkImage(imageUrl: series.coverUrl!, fit: BoxFit.cover)
                      : Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.video_library_outlined, size: 40),
                        ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(series.name, style: Theme.of(context).textTheme.headlineMedium),
                    if (series.genre != null) ...[
                      const SizedBox(height: 6),
                      Text(series.genre!, style: const TextStyle(color: AppColors.textSecondary)),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      (series.plot != null && series.plot!.trim().isNotEmpty)
                          ? series.plot!
                          : 'No description available.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    _ContinueWatchingButton(
                      seriesId: widget.seriesId,
                      seriesName: series.name,
                      episodesBySeason: series.episodesBySeason,
                      coverUrl: series.coverUrl,
                    ),
                  ],
                ),
              ),
            ],
          );

          // Seasons list, styled like the live "Groups" column: each row is a
          // TvFocusable so it gets the red fill + silver outline, and focus
          // stays inside this list until a season is chosen.
          final seasonsList = _SeasonsColumn(
            seasons: seasons,
            selected: _selectedSeason!,
            episodesBySeason: series.episodesBySeason,
            onChanged: (v) => setState(() => _selectedSeason = v),
          );

          final episodesList = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (downloadsSupported())
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _SeasonDownloadButton(
                      seriesId: widget.seriesId,
                      seriesName: series.name,
                      episodes: episodes,
                      fallbackImage: series.coverUrl,
                    ),
                  ),
                ),
              ...episodes.asMap().entries.map((e) => _EpisodeTile(
                    episode: e.value,
                    seriesId: widget.seriesId,
                    seriesName: series.name,
                    fallbackImage: series.coverUrl,
                    autofocus: false,
                  )),
            ],
          );

          // Wide screens (TV / tablet landscape): seasons in a left sidebar,
          // episodes on the right. Narrow: stack seasons row over episodes.
          final wide = MediaQuery.of(context).size.width >= 760;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              header,
              const SizedBox(height: 20),
              if (wide)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 220, child: seasonsList),
                      const SizedBox(width: 16),
                      Expanded(child: episodesList),
                    ],
                  ),
                )
              else ...[
                seasonsList,
                const SizedBox(height: 16),
                episodesList,
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
      ),
    );
  }
}

/// Season picker shown as a vertical list (left sidebar on wide screens), in
/// the same visual language as the live "Groups" column: a titled panel whose
/// rows are [TvFocusable] (red fill + silver outline when focused), with D-pad
/// focus staying inside the list.
class _SeasonsColumn extends StatelessWidget {
  const _SeasonsColumn({
    required this.seasons,
    required this.selected,
    required this.episodesBySeason,
    required this.onChanged,
  });

  final List<int> seasons;
  final int selected;
  final Map<int, List<Episode>> episodesBySeason;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(
                children: [
                  Icon(Icons.subscriptions_outlined,
                      size: 18, color: Color(0xFFF2F4F8)),
                  SizedBox(width: 8),
                  Text(
                    'SEASONS',
                    style: TextStyle(
                      color: Color(0xFFF2F4F8),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            for (int i = 0; i < seasons.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: TvFocusable(
                  autofocus: i == 0 && seasons[i] == selected,
                  borderRadius: 10,
                  onTap: () => onChanged(seasons[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: seasons[i] == selected
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.transparent,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Season ${seasons[i]}',
                            style: TextStyle(
                              color: seasons[i] == selected
                                  ? Colors.white
                                  : AppColors.textPrimary,
                              fontWeight: seasons[i] == selected
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        Text(
                          '${episodesBySeason[seasons[i]]!.length}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Builds the download entry for one episode. Shared by the per-episode button
/// and the whole-season one, so both produce identical keys/urls/labels.
DownloadItem episodeDownloadTemplate({
  required SeriesRepository repo,
  required String seriesId,
  required String seriesName,
  required Episode episode,
  required String? image,
}) {
  final label = '${episode.episodeNum}. ${episode.title}';
  return DownloadItem(
    key: DownloadItem.episodeKey(seriesId, episode.id),
    type: DownloadType.series,
    name: '$seriesName — $label',
    remoteUrl: repo.episodeUrl(episode.id, episode.containerExtension),
    containerExtension: episode.containerExtension,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    imageUrl: image,
    seriesId: seriesId,
    episodeId: episode.id,
    episodeLabel: label,
  );
}

/// Bulk-downloads every episode of the selected season (phone only). They go
/// through the same one-at-a-time queue as single downloads.
class _SeasonDownloadButton extends ConsumerWidget {
  const _SeasonDownloadButton({
    required this.seriesId,
    required this.seriesName,
    required this.episodes,
    required this.fallbackImage,
  });

  final String seriesId;
  final String seriesName;
  final List<Episode> episodes;
  final String? fallbackImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(seriesRepositoryProvider).value;
    if (repo == null || episodes.isEmpty) return const SizedBox.shrink();

    final byKey = {for (final d in ref.watch(downloadsProvider)) d.key: d};
    var done = 0;
    var active = 0;
    for (final e in episodes) {
      final d = byKey[DownloadItem.episodeKey(seriesId, e.id)];
      if (d == null) continue;
      if (d.isCompleted) {
        done++;
      } else if (d.isActive) {
        active++;
      }
    }
    final total = episodes.length;
    final allDone = done == total;

    final String label;
    final IconData icon;
    if (allDone) {
      label = 'Season downloaded';
      icon = Icons.download_done;
    } else if (active > 0) {
      label = 'Downloading… $done/$total';
      icon = Icons.downloading;
    } else {
      label = 'Download season';
      icon = Icons.download_outlined;
    }

    return TvFocusable(
      borderRadius: 14,
      onTap: () async {
        if (allDone) return;
        final notifier = ref.read(downloadsProvider.notifier);
        for (final e in episodes) {
          await notifier.enqueue(episodeDownloadTemplate(
            repo: repo,
            seriesId: seriesId,
            seriesName: seriesName,
            episode: e,
            image: e.imageUrl ?? fallbackImage,
          ));
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: allDone ? Colors.white : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: allDone ? Colors.black : AppColors.textPrimary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: allDone ? Colors.black : AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeTile extends ConsumerWidget {
  const _EpisodeTile({
    required this.episode,
    required this.seriesId,
    required this.seriesName,
    required this.fallbackImage,
    this.autofocus = false,
  });

  final Episode episode;
  final String seriesId;
  final String seriesName;
  final String? fallbackImage;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(watchProgressProvider);
    final progress = ref.read(watchProgressProvider.notifier).forEpisode(seriesId, episode.id);
    final image = episode.imageUrl ?? fallbackImage;
    final label = '${episode.episodeNum}. ${episode.title}';
    final repo = ref.watch(seriesRepositoryProvider).value;

    final playTile = TvFocusable(
        autofocus: autofocus,
        borderRadius: 12,
        onTap: () {
          if (repo == null) return;
          final url = repo.episodeUrl(episode.id, episode.containerExtension);
          context.push(
            Uri(path: '/player', queryParameters: {
              'url': url,
              'name': label,
              'seriesId': seriesId,
              'episodeId': episode.id,
              'epLabel': label,
              // Continue-watching uses the series cover, not the episode still.
              'poster': ?fallbackImage,
              if (progress != null && !progress.finished && progress.positionMs > 5000)
                'resume': '${progress.positionMs}',
            }).toString(),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              // Video-frame style thumbnail preview.
              // Thumbnail with a "watched" check badge overlaid when finished.
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 128,
                  height: 72,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      image != null
                          ? CachedNetworkImage(
                              imageUrl: image,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                color: AppColors.surface,
                                child: const Icon(Icons.play_circle_outline, color: Colors.white54),
                              ),
                            )
                          : Container(
                              color: AppColors.surface,
                              child: const Icon(Icons.play_circle_outline, color: Colors.white54),
                            ),
                      // Watched overlay: dim the still and stamp a green check
                      // so finished episodes read at a glance.
                      if (progress?.finished == true) ...[
                        Container(color: Colors.black.withValues(alpha: 0.45)),
                        const Center(
                          child: Icon(Icons.check_circle,
                              color: Color(0xFF2ECC71), size: 30),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${episode.episodeNum}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            episode.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.textPrimary),
                          ),
                        ),
                        // "Watched" pill next to the title for finished episodes.
                        if (progress?.finished == true) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2ECC71).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check, size: 13, color: Color(0xFF2ECC71)),
                                SizedBox(width: 3),
                                Text('Watched',
                                    style: TextStyle(
                                        color: Color(0xFF2ECC71),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    WatchBar(fraction: progress?.fraction ?? 0),
                    if (progress != null && !progress.finished) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Left at ${_fmt(progress.positionMs)}',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.play_circle_outline, color: Colors.white),
            ],
          ),
        ),
      );

    // Downloads (phone/touch APK only): a peer focusable next to the play
    // tile — never nested inside it, so the D-pad gets two clean stops.
    final showDownload = downloadsSupported() && repo != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: playTile),
          if (showDownload) ...[
            const SizedBox(width: 8),
            DownloadButton(
              compact: true,
              template: episodeDownloadTemplate(
                repo: repo,
                seriesId: seriesId,
                seriesName: seriesName,
                episode: episode,
                image: image,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// Compact season picker using the shared glass-styled dropdown.

/// "Continue watching" button for a series. Finds the most recently watched
/// episode (see [WatchProgressNotifier.lastForSeries]) and, on tap, opens the
/// player resuming from exactly where the user left off. Hidden when the series
/// has never been played.
class _ContinueWatchingButton extends ConsumerWidget {
  const _ContinueWatchingButton({
    required this.seriesId,
    required this.seriesName,
    required this.episodesBySeason,
    required this.coverUrl,
  });

  final String seriesId;
  final String seriesName;
  final Map<int, List<Episode>> episodesBySeason;
  final String? coverUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(watchProgressProvider);
    final last = ref.read(watchProgressProvider.notifier).lastForSeries(seriesId);
    if (last == null) return const SizedBox.shrink();

    // Resolve the episode object so we can rebuild its stream URL.
    Episode? episode;
    for (final list in episodesBySeason.values) {
      for (final e in list) {
        if (e.id == last.episodeId) {
          episode = e;
          break;
        }
      }
      if (episode != null) break;
    }
    if (episode == null) return const SizedBox.shrink();

    final resumeMs = last.finished ? 0 : last.positionMs;
    final label = last.episodeLabel ?? 'Episode ${episode.episodeNum}';
    final buttonText = last.finished
        ? 'Watch again · $label'
        : 'Continue watching · $label';

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: TvFocusable(
        borderRadius: 14,
        onTap: () => _resume(context, ref, episode!, resumeMs, label),
        child: ExcludeFocus(
          child: ElevatedButton.icon(
            onPressed: () => _resume(context, ref, episode!, resumeMs, label),
            icon: Icon(last.finished ? Icons.replay : Icons.play_arrow),
            label: Text(
              buttonText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  void _resume(BuildContext context, WidgetRef ref, Episode episode, int resumeMs, String label) {
    final repo = ref.read(seriesRepositoryProvider).value;
    if (repo == null) return;
    final url = repo.episodeUrl(episode.id, episode.containerExtension);
    context.push(
      Uri(path: '/player', queryParameters: {
        'url': url,
        'name': label,
        'seriesId': seriesId,
        'episodeId': episode.id,
        'epLabel': label,
        'poster': ?coverUrl,
        if (resumeMs > 5000) 'resume': '$resumeMs',
      }).toString(),
    );
  }
}
