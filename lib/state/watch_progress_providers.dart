import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/watch_progress.dart';
import '../data/repositories/watch_progress_repository.dart';

final watchProgressRepositoryProvider = Provider<WatchProgressRepository>((ref) {
  return WatchProgressRepository();
});

/// Exposes all progress entries and refreshes when any is written.
class WatchProgressNotifier extends Notifier<List<WatchProgress>> {
  @override
  List<WatchProgress> build() => ref.watch(watchProgressRepositoryProvider).getAll();

  Future<void> save(WatchProgress p) async {
    final repo = ref.read(watchProgressRepositoryProvider);
    await repo.save(p);
    state = repo.getAll();
  }

  Future<void> remove(String key) async {
    final repo = ref.read(watchProgressRepositoryProvider);
    await repo.remove(key);
    state = repo.getAll();
  }

  /// Removes every episode entry of a series from "continue watching".
  Future<void> removeSeries(String seriesId) async {
    final repo = ref.read(watchProgressRepositoryProvider);
    for (final p in repo.getAll()) {
      if (p.seriesId == seriesId) await repo.remove(p.key);
    }
    state = repo.getAll();
  }

  WatchProgress? forVod(String vodId) {
    for (final p in state) {
      if (p.kind == WatchKind.vod && p.vodId == vodId) return p;
    }
    return null;
  }

  WatchProgress? forEpisode(String seriesId, String episodeId) {
    for (final p in state) {
      if (p.kind == WatchKind.series && p.seriesId == seriesId && p.episodeId == episodeId) {
        return p;
      }
    }
    return null;
  }

  /// The most recently watched episode of [seriesId] that isn't finished yet —
  /// used by the series "Continue watching" button to jump straight back in.
  /// Falls back to the newest entry even if finished, so the button can still
  /// offer a rewatch when everything has been seen.
  WatchProgress? lastForSeries(String seriesId) {
    WatchProgress? best;
    for (final p in state) {
      if (p.kind != WatchKind.series || p.seriesId != seriesId) continue;
      if (best == null || p.updatedAt > best.updatedAt) best = p;
    }
    return best;
  }
}

final watchProgressProvider =
    NotifierProvider<WatchProgressNotifier, List<WatchProgress>>(WatchProgressNotifier.new);
