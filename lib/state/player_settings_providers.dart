import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/storage_service.dart';

enum VideoAspect { auto, fill, ratio169, ratio43 }

extension VideoAspectLabel on VideoAspect {
  String get label {
    switch (this) {
      case VideoAspect.auto:
        return 'Auto';
      case VideoAspect.fill:
        return 'Fill';
      case VideoAspect.ratio169:
        return '16:9';
      case VideoAspect.ratio43:
        return '4:3';
    }
  }
}

class PlayerSettings {
  const PlayerSettings({
    required this.aspect,
    required this.subtitlesEnabled,
    required this.skipSeconds,
    required this.volume,
    required this.introSkipSeconds,
    required this.movieSkipEnabled,
    required this.movieSkipSeconds,
    required this.seriesSkipEnabled,
  });

  final VideoAspect aspect;
  final bool subtitlesEnabled;

  /// Seek step for the skip forward/back buttons (10, 30 or 60 seconds).
  final int skipSeconds;

  /// Where "Skip intro" jumps to for SERIES, measured from the start of an
  /// episode.
  final int introSkipSeconds;

  /// Last used player volume (0–100 UI scale), remembered across sessions.
  final double volume;

  /// Whether the "Skip intro" shortcut is offered on MOVIES.
  final bool movieSkipEnabled;

  /// Where "Skip intro" jumps to for MOVIES (default 120s = 2 minutes).
  final int movieSkipSeconds;

  /// Whether the "Skip intro" shortcut is offered on SERIES.
  final bool seriesSkipEnabled;

  PlayerSettings copyWith({
    VideoAspect? aspect,
    bool? subtitlesEnabled,
    int? skipSeconds,
    double? volume,
    int? introSkipSeconds,
    bool? movieSkipEnabled,
    int? movieSkipSeconds,
    bool? seriesSkipEnabled,
  }) {
    return PlayerSettings(
      aspect: aspect ?? this.aspect,
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      skipSeconds: skipSeconds ?? this.skipSeconds,
      volume: volume ?? this.volume,
      introSkipSeconds: introSkipSeconds ?? this.introSkipSeconds,
      movieSkipEnabled: movieSkipEnabled ?? this.movieSkipEnabled,
      movieSkipSeconds: movieSkipSeconds ?? this.movieSkipSeconds,
      seriesSkipEnabled: seriesSkipEnabled ?? this.seriesSkipEnabled,
    );
  }
}

const kSkipOptions = [10, 30, 60];

/// Choices for how long an intro lasts (seconds). Panels give us no chapter
/// markers, so "Skip intro" is a heuristic: it jumps to this mark from the
/// start, and the button only shows while you are before it.
const kIntroSkipOptions = [30, 60, 90, 120, 150, 180];

class PlayerSettingsNotifier extends Notifier<PlayerSettings> {
  static const _aspectKey = 'default_aspect';
  static const _subtitlesKey = 'subtitles_enabled';
  static const _skipKey = 'skip_seconds';
  static const _volumeKey = 'player_volume';
  static const _introSkipKey = 'intro_skip_seconds';
  static const _movieSkipEnabledKey = 'movie_skip_enabled';
  static const _movieSkipSecondsKey = 'movie_skip_seconds';
  static const _seriesSkipEnabledKey = 'series_skip_enabled';

  @override
  PlayerSettings build() {
    final rawAspect = StorageService.prefsBox.get(_aspectKey) as String?;
    var aspect = VideoAspect.auto;
    for (final a in VideoAspect.values) {
      if (a.name == rawAspect) aspect = a;
    }
    final subtitles = StorageService.prefsBox.get(_subtitlesKey) as bool? ?? false;
    final skip = (StorageService.prefsBox.get(_skipKey) as num?)?.toInt() ?? 10;
    final volume = (StorageService.prefsBox.get(_volumeKey) as num?)?.toDouble() ?? 100.0;
    final introSkip = (StorageService.prefsBox.get(_introSkipKey) as num?)?.toInt() ?? 90;
    final movieSkipEnabled =
        StorageService.prefsBox.get(_movieSkipEnabledKey) as bool? ?? true;
    final movieSkip =
        (StorageService.prefsBox.get(_movieSkipSecondsKey) as num?)?.toInt() ?? 120;
    final seriesSkipEnabled =
        StorageService.prefsBox.get(_seriesSkipEnabledKey) as bool? ?? true;
    return PlayerSettings(
      aspect: aspect,
      subtitlesEnabled: subtitles,
      skipSeconds: kSkipOptions.contains(skip) ? skip : 10,
      volume: volume.clamp(0, 100),
      introSkipSeconds: kIntroSkipOptions.contains(introSkip) ? introSkip : 90,
      movieSkipEnabled: movieSkipEnabled,
      movieSkipSeconds: kIntroSkipOptions.contains(movieSkip) ? movieSkip : 120,
      seriesSkipEnabled: seriesSkipEnabled,
    );
  }

  Future<void> setIntroSkipSeconds(int seconds) async {
    final flushed = StorageService.prefsBox.put(_introSkipKey, seconds);
    state = state.copyWith(introSkipSeconds: seconds);
    await flushed;
  }

  Future<void> setMovieSkipEnabled(bool enabled) async {
    final flushed = StorageService.prefsBox.put(_movieSkipEnabledKey, enabled);
    state = state.copyWith(movieSkipEnabled: enabled);
    await flushed;
  }

  Future<void> setMovieSkipSeconds(int seconds) async {
    final flushed = StorageService.prefsBox.put(_movieSkipSecondsKey, seconds);
    state = state.copyWith(movieSkipSeconds: seconds);
    await flushed;
  }

  Future<void> setSeriesSkipEnabled(bool enabled) async {
    final flushed = StorageService.prefsBox.put(_seriesSkipEnabledKey, enabled);
    state = state.copyWith(seriesSkipEnabled: enabled);
    await flushed;
  }

  void setVolume(double volume) {
    final v = volume.clamp(0, 100).toDouble();
    StorageService.prefsBox.put(_volumeKey, v);
    state = state.copyWith(volume: v);
  }

  Future<void> setAspect(VideoAspect aspect) async {
    final flushed = StorageService.prefsBox.put(_aspectKey, aspect.name);
    state = state.copyWith(aspect: aspect);
    await flushed;
  }

  Future<void> setSubtitlesEnabled(bool enabled) async {
    final flushed = StorageService.prefsBox.put(_subtitlesKey, enabled);
    state = state.copyWith(subtitlesEnabled: enabled);
    await flushed;
  }

  Future<void> setSkipSeconds(int seconds) async {
    final flushed = StorageService.prefsBox.put(_skipKey, seconds);
    state = state.copyWith(skipSeconds: seconds);
    await flushed;
  }
}

final playerSettingsProvider = NotifierProvider<PlayerSettingsNotifier, PlayerSettings>(
  PlayerSettingsNotifier.new,
);
