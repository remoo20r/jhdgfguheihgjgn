import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/fullscreen.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/channel.dart';
import '../../../data/models/series_item.dart';
import '../../../data/models/watch_progress.dart';
import '../../../state/live_providers.dart';
import '../../../core/ui_mode.dart';
import '../../common/tv_focusable.dart';
import 'player_keys.dart';
import 'series_prompts.dart';
import '../../../state/player_settings_providers.dart';
import '../../../state/series_providers.dart';
import '../../../state/watch_progress_providers.dart';

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// Desktop-only software gain on top of the 0–100 UI volume: IPTV streams are
/// often encoded quiet, so UI 100% maps to mpv 150 (the UI keeps its normal
/// 0–100 scale). Android stays at 1.0 — volume belongs to the hardware keys.
final double _volumeBoost = Platform.isAndroid ? 1.0 : 1.5;

/// Human-readable label for an audio track (language name, else title, else id).
String _audioTrackLabel(AudioTrack t) {
  final lang = (t.language ?? '').trim().toLowerCase();
  const names = {
    'ita': 'Italiano', 'it': 'Italiano',
    'eng': 'Inglese', 'en': 'Inglese',
    'spa': 'Spagnolo', 'es': 'Spagnolo',
    'fra': 'Francese', 'fre': 'Francese', 'fr': 'Francese',
    'deu': 'Tedesco', 'ger': 'Tedesco', 'de': 'Tedesco',
    'por': 'Portoghese', 'pt': 'Portoghese',
    'rus': 'Russo', 'ru': 'Russo',
    'ara': 'Arabo', 'ar': 'Arabo',
    'jpn': 'Giapponese', 'ja': 'Giapponese',
    'zho': 'Cinese', 'chi': 'Cinese', 'zh': 'Cinese',
  };
  if (names.containsKey(lang)) return names[lang]!;
  final title = (t.title ?? '').trim();
  if (title.isNotEmpty) return title;
  if (lang.isNotEmpty) return lang.toUpperCase();
  return 'Traccia ${t.id}';
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    this.streamUrl,
    this.isLive = false,
    this.streamId,
    this.channelName,
    this.seriesId,
    this.episodeId,
    this.episodeLabel,
    this.vodId,
    this.posterUrl,
    this.resumeMs = 0,
  });

  final String? streamUrl;

  /// True for live TV channels: no seek bar, no speed, never stops.
  final bool isLive;

  /// Live channel id, used to show the current EPG program.
  final String? streamId;
  final String? channelName;

  /// Set only when playing a series episode; enables "next episode" + progress.
  final String? seriesId;
  final String? episodeId;
  final String? episodeLabel;

  /// Set only when playing a movie; enables progress tracking.
  final String? vodId;

  final String? posterUrl;
  final int resumeMs;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription> _subscriptions = [];

  String? _error;
  String? _title;
  String? _currentEpisodeId;
  String? _currentEpisodeLabel;
  String? _currentStreamId;
  String _currentUrl = '';

  bool _controlsVisible = true;
  Timer? _hideTimer;

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100;
  double _volumeBeforeMute = 100;
  double _rate = 1.0;
  bool _subtitlesOn = false;
  late VideoAspect _aspect;

  // Playback resilience: auto-reconnect with a ts↔m3u8 fallback for live.
  int _retry = 0;
  bool _reconnecting = false;
  String _liveExt = 'ts';
  Timer? _retryTimer;
  int? _videoWidth;
  int? _videoHeight;

  // Live channel-list overlay (zap without leaving the player).
  bool _channelListOpen = false;

  /// The control the D-pad lands on when the menu opens (play/pause, or the
  /// channel list button on live, which has no play/pause).
  final FocusNode _primaryControlNode = FocusNode(debugLabel: 'player.primary');

  /// "Salta sigla" / "Prossimo episodio". Focused on TV as soon as it appears
  /// (with the controls down), so OK presses it.
  final FocusNode _floatingActionNode = FocusNode(debugLabel: 'player.floating');
  bool _floatingFocusRequested = false;

  /// How close to the end the credits button appears.
  static const _creditsWindow = Duration(seconds: 90);

  // Audio tracks (multi-language). We try to auto-select Italian per media.
  List<AudioTrack> _audioTracks = const [];
  String? _currentAudioId;
  bool _autoAudioApplied = false;

  int? _pendingResumeMs;
  int _lastSavedMs = 0;

  // Cached at init so the final save in dispose() never touches `ref` (using
  // `ref` during dispose can throw — which previously aborted teardown on
  // VOD/series and left audio playing).
  late final WatchProgressNotifier _watchProgress;

  bool get _isSeries => widget.seriesId != null;
  bool get _isVod => widget.vodId != null;
  bool get _isLive => widget.isLive;

  @override
  void initState() {
    super.initState();
    // Only the player is landscape-only on Android: the rest of the app
    // rotates freely. Restored in dispose().
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]));
    }
    final settings = ref.read(playerSettingsProvider);
    _aspect = settings.aspect;
    _subtitlesOn = settings.subtitlesEnabled;
    // On Android the volume is the system one, driven by the phone/remote
    // hardware keys: keep the software volume at 100 (a remembered low/zero
    // value would silently cap the hardware keys) and hide the in-app controls.
    _volume = Platform.isAndroid ? 100 : settings.volume;
    _volumeBeforeMute = _volume > 0 ? _volume : 100;
    _title = widget.channelName;
    _currentEpisodeId = widget.episodeId;
    _currentEpisodeLabel = widget.episodeLabel;
    _currentStreamId = widget.streamId;
    _pendingResumeMs = widget.resumeMs > 0 ? widget.resumeMs : null;
    _watchProgress = ref.read(watchProgressProvider.notifier);

    // Tuned for low-RAM Android TV boxes (e.g. 2 GB): a small demuxer buffer
    // keeps memory down, and hardware decoding offloads video from the weak
    // CPU to the GPU — without it, playback stutters like slow-motion. On
    // Windows we keep the generous defaults.
    _player = Player(
      configuration: PlayerConfiguration(
        // ~8 MB read-ahead instead of the 32 MB default: far lighter on RAM,
        // still enough to keep live TV smooth.
        bufferSize: Platform.isAndroid ? 8 * 1024 * 1024 : 32 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        // Hardware-accelerated decoding is the single biggest win on TV boxes.
        enableHardwareAcceleration: true,
      ),
    );
    // The desktop boost needs headroom above mpv's default `volume-max` of
    // 130: raise the ceiling to UI 100% × boost, then re-apply the remembered
    // volume — a set issued before the new ceiling landed would have been
    // clamped to the old one.
    final native = _player.platform;
    if (!Platform.isAndroid && native is NativePlayer) {
      unawaited(native
          .setProperty('volume-max', (100 * _volumeBoost).round().toString())
          .then((_) {
        if (mounted) _applyVolume(_volume);
      }).catchError((_) {}));
    }

    // Android TV playback tuning. The slow-motion / stutter on heavy streams
    // (HEVC/x265, 4K, high-bitrate channels) happens when mpv decodes in
    // SOFTWARE on the weak CPU. The fixes, in order of impact:
    //  • profile=fast   — lighter scaling/processing so a slow CPU keeps up.
    //  • hwdec=auto-safe — use the GPU decoder when it's safe, auto-falling
    //    back to software (safer than forcing mediacodec-copy, which broke
    //    channel-switching with a black screen).
    //  • video-sync=audio + framedrop — stay in sync by dropping late frames
    //    instead of playing everything late (which looks like slow motion).
    if (Platform.isAndroid && native is NativePlayer) {
      unawaited(() async {
        try {
          // ---- Decode path (biggest win on 4K / HEVC / high-bitrate) ----
          // 'fast' preset trims post-processing so a weak CPU/GPU keeps up.
          await native.setProperty('profile', 'fast');
          // Use the Android hardware decoder. mediacodec-copy is the compatible
          // path that still releases the surface cleanly on channel switch.
          await native.setProperty('hwdec', 'mediacodec-copy');
          await native.setProperty('hwdec-codecs', 'h264,hevc,vp9,av1,mpeg2video');
          // ---- Software-decode fallback tuning ----
          // When a stream lands on the CPU (e.g. HEVC 10-bit a cheap box can't
          // hardware-decode), these keep it from running in slow motion:
          //  • use ALL CPU cores for decoding,
          //  • skip the heaviest in-loop deblocking filter,
          //  • the 'fast' lavc path skips a few expensive steps.
          await native.setProperty('vd-lavc-fast', 'yes');
          await native.setProperty('vd-lavc-threads', '0'); // 0 = auto = all cores
          await native.setProperty('vd-lavc-skiploopfilter', 'all');
          await native.setProperty('vd-lavc-skipidct', 'nonref');
          await native.setProperty('sws-fast', 'yes');
          // ---- Frame pacing ----
          // Drop late frames instead of playing everything behind (slow motion);
          // audio stays the master clock so lips don't drift.
          await native.setProperty('framedrop', 'decoder+vo');
          await native.setProperty('video-sync', 'audio');
          // ---- Buffering (live latency + low RAM) ----
          await native.setProperty('cache', 'yes');
          await native.setProperty('demuxer-max-bytes', '16MiB');
          await native.setProperty('demuxer-max-back-bytes', '8MiB');
          // ---- Audio resilience ----
          await native.setProperty('audio-fallback-to-null', 'yes');
        } catch (_) {}
      }());
    }

    _subscriptions.addAll([
      _player.stream.error.listen((message) {
        if (mounted) _handlePlaybackError(message);
      }),
      _player.stream.buffering.listen((buffering) {
        if (mounted) setState(() => _buffering = buffering);
      }),
      _player.stream.width.listen((w) {
        if (mounted && w != _videoWidth) setState(() => _videoWidth = w);
      }),
      _player.stream.height.listen((h) {
        if (mounted && h != _videoHeight) setState(() => _videoHeight = h);
      }),
      _player.stream.playing.listen((playing) {
        // A successful (re)start clears the reconnect state.
        if (playing) {
          _retry = 0;
          _reconnecting = false;
        }
        if (mounted) setState(() => _playing = playing);
      }),
      _player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
        _maybeSaveProgress();
        // Fallback auto-advance: some streams never emit `completed`, so if a
        // series episode reaches its final second and there's a next episode,
        // roll into it. Guarded by _advancing so it fires once.
        if (widget.seriesId != null && !_advancing) {
          final dur = _duration.inMilliseconds;
          final pos = position.inMilliseconds;
          if (dur > 0 && pos > 0 && (dur - pos) <= 1200 && _findNextEpisode() != null) {
            _advancing = true;
            _playNextEpisode();
          }
        }
      }),
      _player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
        // A fresh (non-zero) duration means new media loaded — clear the
        // auto-advance guard so the NEXT episode can also auto-advance.
        if (duration.inMilliseconds > 1000) _advancing = false;
        // Seek to the saved resume point once the media is ready.
        if (_pendingResumeMs != null && duration.inMilliseconds > 0) {
          final target = _pendingResumeMs!;
          _pendingResumeMs = null;
          if (target < duration.inMilliseconds - 5000) {
            _player.seek(Duration(milliseconds: target));
          }
        }
      }),
      _player.stream.volume.listen((volume) {
        // mpv reports the boosted value: bring it back to the 0–100 UI scale.
        final ui = (volume / _volumeBoost).clamp(0.0, 100.0);
        if (mounted) setState(() => _volume = ui);
      }),
      // New media resets track selection: re-apply the subtitle preference and
      // pick up the available audio tracks (auto-selecting Italian) each time
      // the track list changes.
      _player.stream.tracks.listen((tracks) {
        if (!_subtitlesOn) _player.setSubtitleTrack(SubtitleTrack.no());
        final audios =
            tracks.audio.where((a) => a.id != 'auto' && a.id != 'no').toList();
        if (mounted) setState(() => _audioTracks = audios);
        _maybeApplyItalianAudio(audios);
      }),
      _player.stream.track.listen((track) {
        if (mounted) setState(() => _currentAudioId = track.audio.id);
      }),
      // Auto-play the next episode: when a series episode finishes, roll
      // straight into the next one (like Netflix). Only for series with a next
      // episode; live and single movies just stop.
      _player.stream.completed.listen((completed) {
        if (completed && widget.seriesId != null && _findNextEpisode() != null) {
          _playNextEpisode();
        }
      }),
    ]);

    final url = widget.streamUrl;
    if (url != null) {
      _open(url);
    } else {
      _error = 'No stream to play.';
    }
    _scheduleHide();
  }

  void _open(String url) {
    _currentUrl = url;
    _autoAudioApplied = false;
    setState(() {
      _error = null;
      _buffering = true;
    });
    final resume = _pendingResumeMs;
    final media = (resume != null && resume > 5000)
        ? Media(url, start: Duration(milliseconds: resume))
        : Media(url);
    if (resume != null && resume > 5000) _pendingResumeMs = null;
    // Release the previous decoder/surface BEFORE opening the next stream.
    // Without an explicit stop, the hardware MediaCodec surface stays connected
    // to the old channel, so the next channel can't attach and you get a black
    // screen — and returning to the first channel then fails too. Doing
    // stop() → open() in sequence guarantees the surface is free.
    () async {
      try {
        await _player.stop();
      } catch (_) {}
      if (!mounted || _currentUrl != url) return;
      await _player.open(media, play: true);
      await _player.setRate(_rate);
      _applyVolume(_volume);
      if (!_subtitlesOn) _player.setSubtitleTrack(SubtitleTrack.no());
    }();
  }

  /// Auto-reconnect a dropped stream a few times before giving up. For live we
  /// also alternate the container (.ts ↔ .m3u8) as a format fallback, since a
  /// panel may only serve one of them reliably.
  void _handlePlaybackError(String message) {
    if (_retry >= 4) {
      setState(() {
        _error = message;
        _reconnecting = false;
        _buffering = false;
      });
      return;
    }
    _retry++;
    setState(() {
      _error = null;
      _reconnecting = true;
      _buffering = true;
    });
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: 800 + 700 * _retry), () {
      if (!mounted) return;
      if (_isLive && _currentStreamId != null) {
        // Flip format on odd attempts to try the other container.
        if (_retry.isEven) _liveExt = _liveExt == 'ts' ? 'm3u8' : 'ts';
        final url = _liveUrl(_currentStreamId!, _liveExt);
        if (url != null) {
          _open(url);
          return;
        }
      }
      _open(_currentUrl);
    });
  }

  String? _liveUrl(String streamId, String ext) {
    final source = ref.read(xtreamSessionProvider).value;
    return source?.liveStreamUrl(streamId, ext: ext);
  }

  void _switchChannel(String streamId, String name) {
    final url = _liveUrl(streamId, 'ts');
    if (url == null) return;
    // Picking a channel (from the overlay) re-anchors the zap category to that
    // channel's group, so subsequent up/down zapping stays inside the group the
    // user just chose from. (Zapping itself calls _open via here too, but it
    // keeps _currentStreamId inside the same category, so the lookup below just
    // re-confirms the same category — no drift.)
    final all = ref.read(allChannelsProvider).value;
    if (all != null) {
      final match = all.where((c) => c.streamId == streamId);
      if (match.isNotEmpty && match.first.categoryId.isNotEmpty) {
        _zapCategoryId = match.first.categoryId;
      }
    }
    setState(() {
      _channelListOpen = false;
      _currentStreamId = streamId;
      _title = name;
      _liveExt = 'ts';
      _retry = 0;
      _reconnecting = false;
    });
    _open(url);
    _poke();
  }

  /// The category the up/down zapping is confined to. Updated whenever the user
  /// picks a channel (see _switchChannel) so zapping stays inside the open group
  /// instead of wandering into the full "all channels" list.
  String? _zapCategoryId;

  /// Moves to the next/previous live channel (delta = +1 / -1) WITHIN the
  /// current channel's category, wrapping at the ends. Used for one-button
  /// zapping (D-pad / arrow keys) without opening the channel list overlay.
  void _stepLiveChannel(int delta) {
    if (!_isLive) return;
    final all = ref.read(allChannelsProvider).value;
    if (all == null || all.isEmpty) return;

    // Resolve the category to cycle within: the remembered zap category, else
    // the current channel's own category.
    var catId = _zapCategoryId;
    if (catId == null) {
      final cur = all.where((c) => c.streamId == _currentStreamId);
      if (cur.isNotEmpty && cur.first.categoryId.isNotEmpty) {
        catId = cur.first.categoryId;
        _zapCategoryId = catId;
      }
    }

    // Only channels in this category (fall back to all if unknown).
    final list = (catId != null)
        ? all.where((c) => c.categoryId == catId).toList()
        : all;
    if (list.isEmpty) return;

    var index = list.indexWhere((c) => c.streamId == _currentStreamId);
    if (index < 0) index = 0;
    final next = (index + delta) % list.length;
    final wrapped = next < 0 ? next + list.length : next;
    final c = list[wrapped];
    _switchChannel(c.streamId, c.name);
  }

  String? get _qualityLabel {
    final h = _videoHeight ?? 0;
    if (h <= 0) return null;
    if (h >= 2000) return '4K';
    if (h >= 1400) return '1440p';
    if (h >= 1000) return '1080p';
    if (h >= 700) return '720p';
    if (h >= 460) return '480p';
    return 'SD';
  }

  void _maybeSaveProgress({bool force = false}) {
    if (_isLive || (!_isVod && !_isSeries)) return;
    final pos = _position.inMilliseconds;
    final dur = _duration.inMilliseconds;
    if (dur <= 0) return;
    // Throttle to roughly one write every 5 seconds.
    if (!force && (pos - _lastSavedMs).abs() < 5000) return;
    _lastSavedMs = pos;

    final progress = _isVod
        ? WatchProgress(
            kind: WatchKind.vod,
            vodId: widget.vodId,
            seriesId: null,
            episodeId: null,
            episodeLabel: null,
            name: widget.channelName ?? '',
            imageUrl: widget.posterUrl,
            url: _currentUrl,
            positionMs: pos,
            durationMs: dur,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          )
        : WatchProgress(
            kind: WatchKind.series,
            vodId: null,
            seriesId: widget.seriesId,
            episodeId: _currentEpisodeId,
            episodeLabel: _currentEpisodeLabel,
            name: widget.channelName ?? '',
            imageUrl: widget.posterUrl,
            url: _currentUrl,
            positionMs: pos,
            durationMs: dur,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
    _watchProgress.save(progress);
  }

  @override
  void dispose() {
    // Leaving the player: give rotation back to the system (empty list =
    // platform default, i.e. free rotation).
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setPreferredOrientations(const []));
    }
    // Silence immediately, then tear the native player down defensively.
    // NB: the "audio keeps playing after exit" bug only ever showed on
    // VOD/series — for live, progress-save is skipped so the teardown always
    // ran; on VOD/series a throwing save could abort dispose *before* stop(),
    // leaving audio playing. So guard the save and never let it block teardown.
    final player = _player;
    player.setVolume(0);
    try {
      _maybeSaveProgress(force: true);
    } catch (_) {}
    _hideTimer?.cancel();
    _retryTimer?.cancel();
    _primaryControlNode.dispose();
    _floatingActionNode.dispose();
    for (final s in _subscriptions) {
      s.cancel();
    }
    // stop() must fully apply before dispose(), otherwise audio can linger on
    // Windows. dispose() can't be async, so run the ordered teardown on the
    // captured instance after super.dispose().
    unawaited(() async {
      try {
        await player.stop();
      } catch (_) {}
      await player.dispose();
    }());
    super.dispose();
  }

  void _skip(int seconds) {
    var target = _position.inSeconds + seconds;
    if (target < 0) target = 0;
    final maxS = _duration.inSeconds;
    if (maxS > 0 && target > maxS) target = maxS;
    _player.seek(Duration(seconds: target));
    _poke();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      // Keep controls (and the bottom-left "Canali" button) visible while the
      // channel list is open, and while paused (you want the play button).
      if (mounted && _playing && !_channelListOpen) {
        _hideControls();
      }
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (_controlsVisible) setState(() => _controlsVisible = false);
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      // On TV, land the focus on the main control straight away: otherwise the
      // focus sits on the root node and OK would have no target (the ring is
      // also the "you are here" the remote needs). Not on phone/desktop, where
      // a focus ring appearing on a tap would just look odd.
      if (isTvMode()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _controlsVisible) _primaryControlNode.requestFocus();
        });
      }
    }
    _scheduleHide();
  }

  void _poke() => _showControls();

  /// Screen tap: open the controls, tap again to close them.
  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// Executes the decision made by [playerKeyAction].
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // One-button live zapping: Up/Down switch to the next/previous channel
    // straight away, without opening the channel list — works whether the
    // controls are showing or hidden, as long as the list overlay is closed.
    if (_isLive && !_channelListOpen && event is KeyDownEvent) {
      final key = event.logicalKey;
      // Up = next channel, Down = previous channel (was reversed before).
      if (key == LogicalKeyboardKey.arrowUp) {
        _stepLiveChannel(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _stepLiveChannel(-1);
        return KeyEventResult.handled;
      }
    }

    switch (playerKeyAction(
      key: event.logicalKey,
      isKeyDown: event is KeyDownEvent,
      controlsVisible: _controlsVisible,
    )) {
      case PlayerKeyAction.ignore:
        return KeyEventResult.ignored;
      case PlayerKeyAction.revealControls:
        _poke();
        return KeyEventResult.handled;
      case PlayerKeyAction.pokeAndPass:
        _poke();
        return KeyEventResult.ignored;
    }
  }

  void _togglePlayPause() {
    _player.playOrPause();
    _poke();
  }

  void _toggleSubtitles() {
    setState(() => _subtitlesOn = !_subtitlesOn);
    _player.setSubtitleTrack(_subtitlesOn ? SubtitleTrack.auto() : SubtitleTrack.no());
    _poke();
  }

  void _selectAudio(AudioTrack track) {
    _player.setAudioTrack(track);
    setState(() => _currentAudioId = track.id);
    _poke();
  }

  static bool _isItalianAudio(AudioTrack a) {
    final lang = (a.language ?? '').toLowerCase();
    final title = (a.title ?? '').toLowerCase();
    return lang.startsWith('it') ||
        lang.contains('ita') ||
        title.contains('ita') ||
        title.contains('italian');
  }

  /// Once per media, prefer the Italian audio track when one is available.
  void _maybeApplyItalianAudio(List<AudioTrack> audios) {
    if (_autoAudioApplied || audios.isEmpty) return;
    _autoAudioApplied = true;
    for (final a in audios) {
      if (_isItalianAudio(a)) {
        _player.setAudioTrack(a);
        if (mounted) setState(() => _currentAudioId = a.id);
        return;
      }
    }
  }

  void _cycleAspect() {
    final next = VideoAspect
        .values[(VideoAspect.values.indexOf(_aspect) + 1) % VideoAspect.values.length];
    setState(() => _aspect = next);
    _poke();
  }

  void _cycleSpeed() {
    final index = _speeds.indexWhere((s) => (s - _rate).abs() < 0.01);
    final next = _speeds[(index + 1) % _speeds.length];
    setState(() => _rate = next);
    _player.setRate(next);
    _poke();
  }

  /// Sends a 0–100 UI volume to the player, applying the desktop gain boost.
  void _applyVolume(double uiVolume) {
    _player.setVolume(uiVolume * _volumeBoost);
  }

  void _toggleMute() {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      _applyVolume(0);
    } else {
      _applyVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 100);
    }
    _poke();
  }

  Episode? _findNextEpisode() {
    final seriesId = widget.seriesId;
    if (seriesId == null || _currentEpisodeId == null) return null;
    final detail = ref.read(seriesDetailProvider(seriesId)).value;
    if (detail == null) return null;

    final seasons = detail.episodesBySeason.keys.toList()..sort();
    final ordered = <Episode>[
      for (final season in seasons) ...detail.episodesBySeason[season]!,
    ];
    final index = ordered.indexWhere((e) => e.id == _currentEpisodeId);
    if (index < 0 || index + 1 >= ordered.length) return null;
    return ordered[index + 1];
  }

  /// Guards the position-based auto-advance so it fires once per episode end.
  bool _advancing = false;

  void _playNextEpisode() {
    final next = _findNextEpisode();
    if (next == null) return;
    final repo = ref.read(seriesRepositoryProvider).value;
    if (repo == null) return;
    _maybeSaveProgress(force: true);
    setState(() {
      _currentEpisodeId = next.id;
      _currentEpisodeLabel = '${next.episodeNum}. ${next.title}';
      _title = _currentEpisodeLabel;
      _lastSavedMs = 0;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    _open(repo.episodeUrl(next.id, next.containerExtension));
    _poke();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Widget _buildVideo() {
    switch (_aspect) {
      case VideoAspect.auto:
        return Video(controller: _controller, fit: BoxFit.contain, controls: NoVideoControls);
      case VideoAspect.fill:
        // "Riempi" = stretch to the screen in BOTH directions: the whole frame
        // stays visible (nothing cropped like BoxFit.cover) and there are no
        // black bars — at the cost of distorting the aspect ratio.
        return Video(controller: _controller, fit: BoxFit.fill, controls: NoVideoControls);
      case VideoAspect.ratio169:
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(controller: _controller, fit: BoxFit.fill, controls: NoVideoControls),
          ),
        );
      case VideoAspect.ratio43:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Video(controller: _controller, fit: BoxFit.fill, controls: NoVideoControls),
          ),
        );
    }
  }

  /// Jumps to the end of the intro. There are no chapter markers from a panel,
  /// so this is the configured mark measured from the start of the episode.
  void _skipIntro(Duration introEnd) {
    _player.seek(introEnd);
    _hideControls();
  }

  @override
  Widget build(BuildContext context) {
    final hasNext = _isSeries && _findNextEpisode() != null;

    // Series/movie floating shortcuts: "Skip intro" early on, "Next episode"
    // over the end credits (see seriesPromptFor). Series and movies each have
    // their own skip-enabled toggle and intro length in settings.
    final settings = ref.watch(playerSettingsProvider);
    final introSeconds =
        _isVod ? settings.movieSkipSeconds : settings.introSkipSeconds;
    final skipEnabled =
        _isVod ? settings.movieSkipEnabled : settings.seriesSkipEnabled;
    final introEnd = Duration(seconds: introSeconds);
    final prompt = seriesPromptFor(
      isSeries: _isSeries,
      isLive: _isLive,
      hasNextEpisode: hasNext,
      position: _position,
      duration: _duration,
      introEnd: introEnd,
      creditsWindow: _creditsWindow,
      isMovie: _isVod,
      skipEnabled: skipEnabled,
    );
    final showFloating = prompt != SeriesPrompt.none;

    // On TV, put the ring on it as soon as it shows (only while the menu is
    // down, so it never steals focus from controls being navigated).
    if (isTvMode()) {
      if (showFloating && !_floatingFocusRequested && !_controlsVisible) {
        _floatingFocusRequested = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_controlsVisible) _floatingActionNode.requestFocus();
        });
      } else if (!showFloating) {
        _floatingFocusRequested = false;
      }
    }

    return PopScope(
      // Back (TV remote / Android): if the channel list overlay is open, Back
      // just closes it. Otherwise Back LEAVES the player (so the user can get
      // back to Live/Movies/Series). Previously Back only hid the on-screen
      // controls and never exited — it felt like the button was dead.
      canPop: !_channelListOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_channelListOpen) {
          setState(() => _channelListOpen = false);
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKey,
        child: MouseRegion(
          onHover: (_) => _poke(),
          child: Stack(
            children: [
              Positioned.fill(
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : _buildVideo(),
              ),
              // Opaque tap catcher above the video (media_kit's Video otherwise
              // swallows taps); it sits below the controls layer so buttons
              // still receive their taps when the controls are visible.
              // Tap = open the controls, tap again = close them.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                ),
              ),
              // Loading state: a plain black screen while a channel/stream is
              // opening or reconnecting — no spinner, no text, so nothing
              // flashes on screen while switching channels.
              if (_error == null && (_buffering || _reconnecting))
                const Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(color: Colors.black),
                  ),
                ),
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  // Hidden controls must not keep the focus either: otherwise a
                  // D-pad press acts on an invisible button, and the root node
                  // never gets the key that should reveal the menu.
                  child: ExcludeFocus(
                    excluding: !_controlsVisible,
                    child: Column(
                    children: [
                      _TopBar(
                        title: _title,
                        isLive: _isLive,
                        streamId: _currentStreamId,
                        qualityLabel: _qualityLabel,
                        onBack: () => context.pop(),
                      ),
                      const Spacer(),
                      // Satellite-style banner: channel name + info along the
                      // bottom, just above the transport controls. It sits
                      // inside the same controls layer, so it auto-hides with
                      // the controls after a few seconds.
                      _NowPlayingBar(
                        title: _title,
                        isLive: _isLive,
                        streamId: _currentStreamId,
                        qualityLabel: _qualityLabel,
                      ),
                      _ControlsPanel(
                        playing: _playing,
                        isLive: _isLive,
                        channelListOpen: _channelListOpen,
                        onChannelList: _isLive
                            ? () => setState(() => _channelListOpen = !_channelListOpen)
                            : null,
                        audioTracks: _audioTracks,
                        currentAudioId: _currentAudioId,
                        onSelectAudio: _selectAudio,
                        primaryFocusNode: _primaryControlNode,
                        showVolume: !Platform.isAndroid,
                        position: _position,
                        duration: _duration,
                        volume: _volume,
                        rate: _rate,
                        subtitlesOn: _subtitlesOn,
                        aspect: _aspect,
                        hasNext: hasNext,
                        skipSeconds: ref.watch(playerSettingsProvider).skipSeconds,
                        formatDuration: _formatDuration,
                        onSkipBack: () => _skip(-ref.read(playerSettingsProvider).skipSeconds),
                        onSkipForward: () => _skip(ref.read(playerSettingsProvider).skipSeconds),
                        onPlayPause: _togglePlayPause,
                        onSeek: (d) {
                          _player.seek(d);
                          _poke();
                        },
                        onVolume: (v) {
                          _applyVolume(v);
                          ref.read(playerSettingsProvider.notifier).setVolume(v);
                          _poke();
                        },
                        onMute: _toggleMute,
                        onSubtitles: _toggleSubtitles,
                        onAspect: _cycleAspect,
                        onSpeed: _cycleSpeed,
                        onNext: _playNextEpisode,
                      ),
                    ],
                  ),
                  ),
                ),
              ),
              // Series shortcuts, above the controls layer and outside its
              // ExcludeFocus: they must stay usable with the menu down.
              if (showFloating)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  right: 20,
                  // Sit clear of the controls box when it is up.
                  bottom: _controlsVisible ? 150 : 40,
                  child: _FloatingAction(
                    focusNode: _floatingActionNode,
                    icon: prompt == SeriesPrompt.nextEpisode
                        ? Icons.skip_next
                        : Icons.fast_forward,
                    label: prompt == SeriesPrompt.nextEpisode
                        ? 'Next episode'
                        : 'Skip intro',
                    onPressed: prompt == SeriesPrompt.nextEpisode
                        ? _playNextEpisode
                        : () => _skipIntro(introEnd),
                  ),
                ),
              // Live channel list overlay (zap without leaving the player).
              if (_channelListOpen)
                _ChannelListOverlay(
                  currentStreamId: _currentStreamId,
                  onClose: () => setState(() => _channelListOpen = false),
                  onSelect: _switchChannel,
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.title,
    required this.isLive,
    required this.streamId,
    required this.qualityLabel,
    required this.onBack,
  });

  final String? title;
  final bool isLive;
  final String? streamId;
  final String? qualityLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Top bar is now just a small Back button in the corner. All channel info
    // (name, EPG, quality, LIVE badge) has moved to the bottom name-bar, like a
    // satellite receiver's on-screen banner.
    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: _PlayerButton(
              tooltip: 'Back',
              onPressed: onBack,
              child: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom "now playing" banner (satellite-receiver style): channel name, the
/// current EPG programme, a LIVE badge and the quality label — all along the
/// bottom, above the transport controls.
class _NowPlayingBar extends ConsumerWidget {
  const _NowPlayingBar({
    required this.title,
    required this.isLive,
    required this.streamId,
    required this.qualityLabel,
  });

  final String? title;
  final bool isLive;
  final String? streamId;
  final String? qualityLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? epgLine;
    if (streamId != null) {
      final epg = ref.watch(shortEpgProvider(streamId!)).value;
      if (epg != null && epg.isNotEmpty) {
        final live = epg.where((p) => p.isLive).toList();
        if (live.isNotEmpty) epgLine = live.first.title;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          children: [
            if (isLive)
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFD01020),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (epgLine != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        epgLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (qualityLabel != null)
              Container(
                margin: const EdgeInsets.only(left: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  qualityLabel!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A prominent floating action button (icon + label) shown over the video for
/// series shortcuts like "Next episode" / "Skip intro". Uses [TvFocusable] so a
/// D-pad remote can reach it, with the given [focusNode] so the player can move
/// focus onto it when a prompt appears.
class _FloatingAction extends StatelessWidget {
  const _FloatingAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      borderRadius: 14,
      focusNode: focusNode,
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFD01020),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerButton extends StatelessWidget {
  const _PlayerButton({
    required this.onPressed,
    required this.child,
    this.tooltip,
    this.focusNode,
  });

  final VoidCallback onPressed;
  final Widget child;
  final String? tooltip;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    Widget button = TvFocusable(
      borderRadius: 12,
      focusNode: focusNode,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: child,
      ),
    );
    final message = tooltip;
    if (message != null) button = Tooltip(message: message, child: button);
    return button;
  }
}

/// Audio-track picker. The menu is opened from the [TvFocusable] wrapper (so a
/// remote can reach it); the inner button is kept out of the focus traversal so
/// it isn't a second, invisible stop.
class _AudioMenuButton extends StatefulWidget {
  const _AudioMenuButton({
    required this.tracks,
    required this.currentAudioId,
    required this.onSelected,
  });

  final List<AudioTrack> tracks;
  final String? currentAudioId;
  final ValueChanged<AudioTrack> onSelected;

  @override
  State<_AudioMenuButton> createState() => _AudioMenuButtonState();
}

class _AudioMenuButtonState extends State<_AudioMenuButton> {
  final _menuKey = GlobalKey<PopupMenuButtonState<AudioTrack>>();

  @override
  Widget build(BuildContext context) {
    return _PlayerButton(
      tooltip: 'Lingua audio',
      onPressed: () => _menuKey.currentState?.showButtonMenu(),
      child: ExcludeFocus(
        child: PopupMenuButton<AudioTrack>(
          key: _menuKey,
          tooltip: '',
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.multitrack_audio, color: Colors.white),
          color: const Color(0xF01C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.glassBorder),
          ),
          onSelected: widget.onSelected,
          itemBuilder: (context) => [
            for (final t in widget.tracks)
              PopupMenuItem<AudioTrack>(
                value: t,
                child: Row(
                  children: [
                    Icon(
                      Icons.check,
                      size: 18,
                      color: t.id == widget.currentAudioId ? Colors.white : Colors.transparent,
                    ),
                    const SizedBox(width: 8),
                    Text(_audioTrackLabel(t), style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Seek bar with its own focus ring: a bare Slider takes focus from the D-pad
/// with no visible sign, which reads as "the focus vanished". Left/Right scrub
/// while it is focused; Up/Down move on to the buttons.
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.formatDuration,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final String Function(Duration) formatDuration;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  final _node = FocusNode(debugLabel: 'player.seekbar');

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          widget.formatDuration(widget.position),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _node.hasFocus ? AppColors.focusRing : Colors.transparent,
                width: 2,
              ),
            ),
            child: Slider(
              focusNode: _node,
              value: widget.position.inMilliseconds
                  .clamp(0, widget.duration.inMilliseconds)
                  .toDouble(),
              max: widget.duration.inMilliseconds
                  .clamp(1, double.maxFinite.toInt())
                  .toDouble(),
              onChanged: (v) => widget.onSeek(Duration(milliseconds: v.round())),
            ),
          ),
        ),
        Text(
          widget.formatDuration(widget.duration),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }
}

class _ControlsPanel extends StatelessWidget {
  const _ControlsPanel({
    required this.playing,
    required this.isLive,
    required this.position,
    required this.duration,
    required this.volume,
    required this.rate,
    required this.subtitlesOn,
    required this.aspect,
    required this.hasNext,
    required this.skipSeconds,
    required this.formatDuration,
    required this.onSkipBack,
    required this.onSkipForward,
    required this.onPlayPause,
    required this.onSeek,
    required this.onVolume,
    required this.onMute,
    required this.onSubtitles,
    required this.onAspect,
    required this.onSpeed,
    required this.onNext,
    required this.channelListOpen,
    required this.onChannelList,
    required this.audioTracks,
    required this.currentAudioId,
    required this.onSelectAudio,
    required this.showVolume,
    required this.primaryFocusNode,
  });

  /// Where the D-pad focus lands when the menu opens.
  final FocusNode primaryFocusNode;

  final bool playing;
  final bool isLive;
  final Duration position;
  final Duration duration;
  final double volume;
  final double rate;
  final bool subtitlesOn;
  final VideoAspect aspect;
  final bool hasNext;
  final int skipSeconds;
  final String Function(Duration) formatDuration;
  final VoidCallback onSkipBack;
  final VoidCallback onSkipForward;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onMute;
  final VoidCallback onSubtitles;
  final VoidCallback onAspect;
  final VoidCallback onSpeed;
  final VoidCallback onNext;

  /// Live channel list (only for live). Null hides the "Canali" button.
  final bool channelListOpen;
  final VoidCallback? onChannelList;

  final List<AudioTrack> audioTracks;
  final String? currentAudioId;
  final ValueChanged<AudioTrack> onSelectAudio;

  /// False on Android: volume is handled by the hardware keys there.
  final bool showVolume;

  @override
  Widget build(BuildContext context) {
    // A translucent black surface behind the controls keeps them readable over
    // any content underneath (bright films/series included) while still letting
    // the video show through.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          // Live streams have no seek bar (and can't be scrubbed).
          if (!isLive)
            _SeekBar(
              position: position,
              duration: duration,
              onSeek: onSeek,
              formatDuration: formatDuration,
            ),
          Row(
            children: [
              // Live channel list opener, at the bottom-left of the controls box.
              if (onChannelList != null)
                _PlayerButton(
                  // Live has no play/pause, so this is the main control.
                  focusNode: isLive ? primaryFocusNode : null,
                  onPressed: onChannelList!,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        channelListOpen ? Icons.close : Icons.playlist_play,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 6),
                      const Text('Channels',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              // Skip back/forward (on-demand content only).
              if (!isLive)
                _SkipButton(
                  seconds: skipSeconds,
                  forward: false,
                  onPressed: onSkipBack,
                ),
              // Live streams can't be paused, so there's no play/pause button.
              if (!isLive)
                _PlayerButton(
                  focusNode: primaryFocusNode,
                  tooltip: playing ? 'Pause' : 'Play',
                  onPressed: onPlayPause,
                  child: Icon(
                    playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              if (!isLive)
                _SkipButton(
                  seconds: skipSeconds,
                  forward: true,
                  onPressed: onSkipForward,
                ),
              // On Android the hardware keys (phone/remote) drive the system
              // volume, so the in-app mute + slider only exist on desktop.
              if (showVolume) ...[
                const SizedBox(width: 4),
                _PlayerButton(
                  tooltip: volume > 0 ? 'Mute' : 'Unmute',
                  onPressed: onMute,
                  child: Icon(
                    volume > 0 ? Icons.volume_up : Icons.volume_off,
                    color: Colors.white,
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Slider(
                    value: volume.clamp(0, 100),
                    max: 100,
                    onChanged: onVolume,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${volume.round()}%',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              // Speed only makes sense for on-demand content, not live.
              if (!isLive)
                _PlayerButton(
                  tooltip: 'Speed',
                  onPressed: onSpeed,
                  child: Text(
                    '${rate.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              _PlayerButton(
                tooltip: 'Subtitles',
                onPressed: onSubtitles,
                child: Icon(
                  subtitlesOn ? Icons.subtitles : Icons.subtitles_off_outlined,
                  color: subtitlesOn ? Colors.white : Colors.white54,
                ),
              ),
              // Audio-track / language selector (only when there is a choice).
              if (audioTracks.length > 1)
                _AudioMenuButton(
                  tracks: audioTracks,
                  currentAudioId: currentAudioId,
                  onSelected: onSelectAudio,
                ),
              _PlayerButton(
                tooltip: 'Aspect ratio',
                onPressed: onAspect,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.aspect_ratio, color: Colors.white, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      aspect.label,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (hasNext)
                _PlayerButton(
                  tooltip: 'Next episode',
                  onPressed: onNext,
                  child: const Icon(Icons.skip_next, color: Colors.white, size: 30),
                ),
            ],
          ),
          ],
        ),
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.seconds, required this.forward, required this.onPressed});

  final int seconds;
  final bool forward;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Plain fast-forward/rewind glyph (no baked-in number) with the chosen
    // step written *below* it as +N / -N, so nothing overlaps the icon.
    return _PlayerButton(
      tooltip: forward ? 'Avanti $seconds s' : 'Back $seconds s',
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(forward ? Icons.fast_forward : Icons.fast_rewind, color: Colors.white, size: 30),
          const SizedBox(height: 2),
          Text(
            '${forward ? '+' : '-'}$seconds',
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Bottom-left overlay listing live channels so you can zap without leaving the
/// player. It also lets you navigate between categories. A tap on the dim area
/// closes it; picking a channel switches playback in place.

/// Live channel picker shown over the running full-screen video. Two
/// translucent columns sit side by side — categories on the left, the selected
/// category's channels on the right — so the viewer can browse groups and
/// channels while still watching the current channel behind the panels. The
/// backdrop is only a light grey wash (not opaque) to keep the video visible.
class _ChannelListOverlay extends ConsumerStatefulWidget {
  const _ChannelListOverlay({
    required this.currentStreamId,
    required this.onClose,
    required this.onSelect,
  });

  final String? currentStreamId;
  final VoidCallback onClose;
  final void Function(String streamId, String name) onSelect;

  @override
  ConsumerState<_ChannelListOverlay> createState() => _ChannelListOverlayState();
}

class _ChannelListOverlayState extends ConsumerState<_ChannelListOverlay> {
  // null = "All channels" (across every category).
  String? _catId;
  // True until the first build has placed focus on the current channel, so we
  // only autofocus it once (not on every rebuild).
  bool _initialFocusDone = false;

  @override
  void initState() {
    super.initState();
    // Preselect the category that contains the currently playing channel, so
    // opening the overlay shows the running channel's group (not "All") with
    // that channel highlighted — instead of jumping to the first channel.
    final current = widget.currentStreamId;
    if (current != null) {
      final all = ref.read(allChannelsProvider).value;
      if (all != null) {
        for (final c in all) {
          if (c.streamId == current && c.categoryId.isNotEmpty) {
            _catId = c.categoryId;
            break;
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Panels occupy the left ~72% of the width and most of the height, leaving
    // the running video visible around/behind them.
    // Fill most of the screen height so more channels/groups are visible at
    // once (the panels used to be short). Leave a slim margin top and bottom.
    const topOffset = 24.0;
    const bottomOffset = 24.0;
    final panelH = (size.height - topOffset - bottomOffset).clamp(200.0, 2000.0);
    final catW = (size.width * 0.30).clamp(150.0, 300.0);
    final chW = (size.width * 0.42).clamp(200.0, 460.0);

    final cats = ref.watch(liveCategoriesProvider).value ?? const [];
    final channelsAsync =
        _catId == null ? ref.watch(allChannelsProvider) : ref.watch(liveStreamsProvider(_catId!));

    return Positioned.fill(
      child: Stack(
        children: [
          // Tap outside the panels to dismiss. A faint grey wash improves the
          // panels' legibility without hiding the video.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: Container(color: Colors.black.withValues(alpha: 0.28)),
            ),
          ),
          Positioned(
            left: 12,
            top: topOffset,
            height: panelH,
            // Trap D-pad focus inside the two panels: FocusTraversalGroup with
            // a bounded policy stops the remote from wandering onto the video
            // controls behind the overlay, and FocusScope(autofocus) makes sure
            // focus actually lands here when the overlay opens.
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: FocusScope(
                autofocus: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ---- Categories column ------------------------------
                    _GlassPanel(
                      width: catW,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _PanelHeader(icon: Icons.dashboard_outlined, label: 'Groups'),
                          const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          children: [
                            _CatRow(
                              label: 'All channels',
                              icon: Icons.grid_view,
                              selected: _catId == null,
                              autofocus: _catId == null && Platform.isAndroid,
                              onTap: () => setState(() => _catId = null),
                            ),
                            for (final c in cats)
                              _CatRow(
                                label: c.name,
                                selected: _catId == c.id,
                                onTap: () => setState(() => _catId = c.id),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // ---- Channels column ----------------------------------
                _GlassPanel(
                  width: chW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: _PanelHeader(icon: Icons.live_tv, label: 'Channels'),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: channelsAsync.when(
                          data: (list) {
                            if (list.isEmpty) {
                              return const Center(
                                child: Text('No channels.',
                                    style: TextStyle(color: AppColors.textSecondary)),
                              );
                            }
                            return ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: list.length,
                              itemBuilder: (context, index) {
                                final Channel c = list[index];
                                final selected = c.streamId == widget.currentStreamId;
                                // Focus the currently playing channel when the
                                // overlay opens (falls back to the first row if
                                // the current channel isn't in this list).
                                final autofocus = Platform.isAndroid &&
                                    !_initialFocusDone &&
                                    (selected ||
                                        (widget.currentStreamId == null && index == 0));
                                if (autofocus) _initialFocusDone = true;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  child: TvFocusable(
                                    autofocus: autofocus,
                                    borderRadius: 10,
                                    onTap: () => widget.onSelect(c.streamId, c.name),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        // Currently-playing channel keeps a
                                        // faint persistent tint even when not
                                        // focused.
                                        color: selected
                                            ? Colors.white.withValues(alpha: 0.08)
                                            : Colors.transparent,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: c.logoUrl != null
                                                ? CachedNetworkImage(
                                                    imageUrl: c.logoUrl!,
                                                    fit: BoxFit.contain,
                                                    errorWidget: (_, _, _) =>
                                                        const Icon(Icons.tv,
                                                            color: Colors.white54),
                                                  )
                                                : const Icon(Icons.tv,
                                                    color: Colors.white54),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              c.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: selected
                                                    ? Colors.white
                                                    : AppColors.textPrimary,
                                                fontWeight: selected
                                                    ? FontWeight.w700
                                                    : FontWeight.normal,
                                              ),
                                            ),
                                          ),
                                          if (selected)
                                            const Icon(Icons.equalizer,
                                                color: Color(0xFFFF2D46), size: 18),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                          loading: () => const Center(child: CircularProgressIndicator()),
                          error: (e, _) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('$e',
                                  style: const TextStyle(color: AppColors.textSecondary)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A translucent, blurred panel container used by the live overlay columns.
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        // No BackdropFilter blur here on purpose: real-time backdrop blur is
        // one of the heaviest GPU ops and tanks performance on 2 GB TV boxes.
        // A plain translucent fill gives the same "see the video behind"
        // effect the design calls for, at almost no cost.
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFFE6E9F0)),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFE6E9F0),
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// One category row in the left column of the live overlay.
class _CatRow extends StatelessWidget {
  const _CatRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: 10,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        color: selected ? Colors.white.withValues(alpha: 0.10) : Colors.transparent,
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? Colors.white : AppColors.textSecondary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
