/// The floating shortcut to offer over a series episode, if any.
enum SeriesPrompt {
  none,

  /// Early in the episode: jump past the opening titles.
  skipIntro,

  /// Over the end credits: start the next episode.
  nextEpisode,
}

/// Decides which shortcut the player should float over the video.
///
/// Pure (and so testable) because it is all edge cases: live streams, an
/// unknown duration (the panel hasn't reported it yet), an episode shorter
/// than the credits window, the very first instant of playback.
///
/// Panels give no chapter markers, so "skip intro" is a heuristic: [introEnd]
/// is where the intro is assumed to end, measured from the start, and the
/// prompt only shows while the position is before it.
SeriesPrompt seriesPromptFor({
  required bool isSeries,
  required bool isLive,
  required bool hasNextEpisode,
  required Duration position,
  required Duration duration,
  required Duration introEnd,
  Duration creditsWindow = const Duration(seconds: 90),
  bool isMovie = false,
  bool skipEnabled = true,
}) {
  if (isLive) return SeriesPrompt.none;
  if (duration <= Duration.zero) return SeriesPrompt.none;

  // Credits first (series only).
  if (isSeries &&
      hasNextEpisode &&
      duration > const Duration(minutes: 2) &&
      position > Duration.zero &&
      (duration - position) <= creditsWindow) {
    return SeriesPrompt.nextEpisode;
  }

  // Skip intro: series episodes AND movies, when enabled in settings.
  if (!skipEnabled) return SeriesPrompt.none;
  if (!isSeries && !isMovie) return SeriesPrompt.none;

  if (duration <= introEnd + const Duration(seconds: 10)) return SeriesPrompt.none;

  if (position >= const Duration(seconds: 2) &&
      position < introEnd - const Duration(seconds: 2)) {
    return SeriesPrompt.skipIntro;
  }

  return SeriesPrompt.none;
}
