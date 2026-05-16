import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:go_router/go_router.dart';
import '../services/stream_extractor_service.dart';
import '../services/subtitle_service.dart' as opensubs;
import '../providers/providers.dart';

// ─── State ────────────────────────────────────────────────────────────────────

enum _ExState { extracting, playing, failed }

// ─── Native Player Screen ─────────────────────────────────────────────────────

class NativePlayerScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const NativePlayerScreen({super.key, required this.args});

  @override
  ConsumerState<NativePlayerScreen> createState() => _NativePlayerScreenState();
}

class _NativePlayerScreenState extends ConsumerState<NativePlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  final _extractor = StreamExtractorService();

  _ExState _state = _ExState.extracting;
  String _statusMsg = 'Finding best stream…';
  String _providerBadge = '';
  String? _failedMsg;
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _hasAdvanced = false;
  bool _isBuffering = false;

  // Provider status tracking for UI pills
  final Map<String, ProviderStatus> _providerStatuses = {};
  String? _currentProviderName; // Currently playing provider
  String? _preferredProvider; // User-selected server

  // Double-tap seek animation
  int? _seekDirection;
  Timer? _seekAnimTimer;

  // ── New: Gesture state ──
  bool _isLocked = false;
  double _playbackSpeed = 1.0;
  bool _isFitMode = true; // true=fit, false=fill
  bool _longPressing = false; // 2x speed while held

  // ── Subtitle + Quality state ──
  ExtractedStream? _currentStream;
  dynamic _activeSubtitle = -1; // -1 = off, can be int (extracted) or SubtitleTrack (embedded)
  String _activeQuality = '';

  // Vertical gesture (brightness/volume)
  bool _isDraggingVertical = false;
  bool _isBrightnessGesture = false; // left=brightness, right=volume
  double _gestureValue = 0.0; // 0..1 for indicator
  double _gestureStartValue = 0.0;
  double _gestureStartY = 0.0;
  Timer? _gestureHideTimer;

  // Horizontal scrub gesture
  bool _isScrubbing = false;
  Duration _scrubPosition = Duration.zero;
  double _scrubStartX = 0.0;
  Duration _scrubStartPos = Duration.zero;

  // Position listener — MUST be stored to prevent leak on quality switch
  StreamSubscription<Duration>? _positionSub;

  // B1: Local episode override instead of mutating the immutable widget.args map.
  // Previously _advanceEpisode() mutated widget.args['episode'] directly which
  // corrupted the caller's state across the entire widget tree.
  int? _episodeOverride;
  // U7: Countdown state for auto-advance overlay
  int _countdownSeconds = 0;
  Timer? _countdownTimer;
  bool _showingCountdown = false;

  // ── Player preferences ──
  double _subtitleSize = 18.0; // sp
  bool _autoplay = true;
  bool _repeatMode = false;
  int _sleepMinutes = 0; // 0 = disabled
  Timer? _sleepTimer;

  // ── Continue Watching: periodic position saver ──
  Timer? _progressTimer;

  String get _title => widget.args['title'] as String? ?? 'Untitled';
  String get _type => widget.args['type'] as String? ?? 'movie';
  int get _season => widget.args['season'] as int? ?? 1;
  // B1: Use local override if set, otherwise fall back to args
  int get _episode => _episodeOverride ?? (widget.args['episode'] as int? ?? 1);
  String get _imdbId => widget.args['imdbId'] as String? ?? '';
  String get _tmdbId {
    final tmdb = widget.args['tmdbId'];
    return (tmdb != null && tmdb is int && tmdb > 0) ? '$tmdb' : '0';
  }
  String get _id => _imdbId.isNotEmpty ? _imdbId : _tmdbId;

  @override
  void initState() {
    super.initState();
    debugPrint('[NativePlayer] INIT with args: ${widget.args}');
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _player = Player();
    _controller = VideoController(_player);

    // Load saved preferences
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _autoplay = prefs.getBool('player_autoplay') ?? true;
        _subtitleSize = (prefs.getDouble('player_sub_size') ?? 18.0);
      });
    });

    // Listen for buffering state
    _player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => _isBuffering = buffering);
    });

    // U11: Local file fast-path — bypass all stream extraction
    final isLocal = widget.args['isLocal'] == true;
    final localPath = widget.args['localPath'] as String?;
    if (isLocal && localPath != null && localPath.isNotEmpty) {
      _playLocalFile(localPath);
    } else {
      _startExtraction();
    }
    _scheduleHideControls();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _controlsTimer?.cancel();
    _seekAnimTimer?.cancel();
    _gestureHideTimer?.cancel();
    _countdownTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub?.cancel();
    _saveCurrentPosition();
    _player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _startSleepTimer(int minutes) {
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (!mounted) return;
      _player.pause();
      setState(() => _sleepMinutes = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⏰ Sleep timer ended — playback paused'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Persist current playback position to HistoryService.
  void _saveCurrentPosition() {
    try {
      final pos = _player.state.position.inSeconds;
      final dur = _player.state.duration.inSeconds;
      if (pos < 5 || dur < 10) return; // ignore trivial watches
      final posterPath = widget.args['posterPath'] as String? ?? '';
      ref.read(historyServiceProvider).saveProgress(
        imdbId: _imdbId,
        tmdbId: int.tryParse(_tmdbId) ?? 0,
        title: _title,
        posterPath: posterPath,
        progressSeconds: pos,
        totalSeconds: dur,
        mediaType: _type,
        season: _type == 'tv' ? _season : null,
        episode: _type == 'tv' ? _episode : null,
      );
    } catch (_) {}
  }

  /// Start saving position every 10 seconds while playing.
  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_state == _ExState.playing) _saveCurrentPosition();
    });
  }

  // ── Extraction ──

  Future<void> _startExtraction() async {
    setState(() {
      _state = _ExState.extracting;
      _statusMsg = 'Finding best stream…';
      _providerBadge = '';
      _hasAdvanced = false;
      _providerStatuses.clear();
      for (final p in StreamExtractorService.availableProviders) {
        _providerStatuses[p] = ProviderStatus.idle;
      }
    });

    debugPrint('[NativePlayer] type=$_type imdbId=$_imdbId tmdbId=$_tmdbId S$_season E$_episode');

    // ── Step 1: Try Cloudflare Worker API (fast, ~2s) ──
    if (mounted) setState(() => _statusMsg = 'Resolving stream…');

    final workerStream = await _extractor.extractViaWorker(
      imdbId: _imdbId,
      tmdbId: _tmdbId,
      type: _type,
      season: _season,
      episode: _episode,
    );

    if (!mounted) return;
    if (workerStream != null) { _playStream(workerStream); return; }

    // ── Step 2: Sequential fallback with status reporting ──
    if (mounted) setState(() => _statusMsg = 'Trying providers…');

    final directStream = await _extractor.extractWithStatus(
      imdbId: _imdbId,
      tmdbId: _tmdbId,
      type: _type,
      title: _title,
      season: _season,
      episode: _episode,
      preferredProvider: _preferredProvider,
      onStatus: (name, status) {
        if (!mounted) return;
        setState(() {
          _providerStatuses[name] = status;
          if (status == ProviderStatus.trying) {
            _statusMsg = 'Trying $name…';
          }
        });
      },
    );

    if (!mounted) return;
    if (directStream != null) {
      _currentProviderName = directStream.providerName;
      // Auto-resume: check if user has a saved position for this content
      final savedProgress = ref.read(historyServiceProvider).getProgress(
        _imdbId,
        season: _type == 'tv' ? _season : null,
        episode: _type == 'tv' ? _episode : null,
      );
      final resumeFrom = savedProgress != null
          ? Duration(seconds: savedProgress.progressSeconds)
          : null;
      _playStream(directStream, resumeFrom: resumeFrom);
      return;
    }

    // ── Failed ──
    setState(() {
      _state = _ExState.failed;
      _failedMsg = 'No streams available.\nTap Retry to try again.';
    });
  }

  /// Re-race all providers excluding the current one — picks the fastest new source
  Future<void> _tryAnotherSource() async {
    final current = _currentProviderName ?? '';
    final pos = _player.state.position;

    setState(() {
      _state = _ExState.extracting;
      _statusMsg = 'Finding best source…';
      // Reset pills — all back to trying
      for (final p in StreamExtractorService.availableProviders) {
        _providerStatuses[p] = ProviderStatus.idle;
      }
    });

    // Extract the base provider name (strip quality suffix like "VidAPI (HD)")
    final currentBase = StreamExtractorService.availableProviders
        .firstWhere((p) => current.startsWith(p), orElse: () => '');

    // Re-run the parallel race, skipping only the current provider
    final result = await _extractor.extractWithStatus(
      imdbId: _imdbId,
      tmdbId: _tmdbId,
      type: _type,
      title: _title,
      season: _season,
      episode: _episode,
      // Pass current as preferred=null so race picks the next fastest
      onStatus: (name, status) {
        if (!mounted) return;
        // Don't override success status from a previous winner
        if (_providerStatuses[name] == ProviderStatus.success) return;
        setState(() => _providerStatuses[name] = status);
      },
    );

    if (!mounted) return;

    if (result != null && !result.providerName.startsWith(currentBase)) {
      _currentProviderName = result.providerName;
      _playStream(result, resumeFrom: pos);
    } else if (result != null) {
      // Same provider came back — still play it (best we can do)
      _currentProviderName = result.providerName;
      _playStream(result, resumeFrom: pos);
    } else if (_currentStream != null) {
      // Nothing worked — resume current stream
      _playStream(_currentStream!, resumeFrom: pos);
    } else {
      setState(() {
        _state = _ExState.failed;
        _failedMsg = 'No other sources available.';
      });
    }
  }

  // ── Download current stream ──

  Future<void> _downloadCurrentStream() async {
    final stream = _currentStream;
    if (stream == null) return;

    final dl = ref.read(downloadServiceProvider);
    final tmdbId = int.tryParse(_tmdbId) ?? 0;
    final quality = _activeQuality.isNotEmpty ? _activeQuality : stream.providerName;

    // HLS streams: guide user to Telegram CDN download instead of blocking silently
    if (stream.isHls) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Queuing for download…'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'View',
            onPressed: () => context.push('/downloads'),
          ),
        ),
      );
      // Queue via HTTP download — service will handle HLS gracefully
      dl.startStreamDownload(
        tmdbId: int.tryParse(_tmdbId) ?? 0,
        imdbId: _imdbId,
        title: _title,
        mediaType: _type,
        streamUrl: stream.url,
        quality: quality,
        headers: stream.headers,
        season: _type == 'tv' ? _season : null,
        episode: _type == 'tv' ? _episode : null,
      );
      return;
    }

    // Check not already downloading
    if (dl.isDownloading(tmdbId, season: _type == 'tv' ? _season : null, episode: _type == 'tv' ? _episode : null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Already downloading this title.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    dl.startStreamDownload(
      tmdbId: tmdbId,
      imdbId: _imdbId,
      title: _title,
      mediaType: _type,
      streamUrl: stream.url,
      quality: quality,
      headers: stream.headers,
      season: _type == 'tv' ? _season : null,
      episode: _type == 'tv' ? _episode : null,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saving "$_title" ($quality)…'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Downloads',
          onPressed: () => context.push('/downloads'),
        ),
      ),
    );
  }

  // U11: Play a locally downloaded file directly via media_kit (no extraction)
  Future<void> _playLocalFile(String path) async {
    debugPrint('[NativePlayer] Playing local file: $path');
    setState(() {
      _state = _ExState.playing;
      _statusMsg = 'Playing from storage';
      _providerBadge = '💾 Local';
    });
    await _player.open(Media(Uri.file(path).toString()));
    await _positionSub?.cancel();
    _positionSub = _player.stream.position.listen(_onPositionChanged);
  }

  void _playStream(ExtractedStream stream, {Duration? resumeFrom}) async {
    setState(() {
      _state = _ExState.playing;
      _statusMsg = 'Playing via ${stream.providerName}';
      _providerBadge = stream.providerName;
      _currentStream = stream;
      if (_activeQuality.isEmpty && stream.hasQualities) {
        _activeQuality = stream.qualities.first.quality;
      }
    });

    await _player.open(Media(
      stream.url,
      httpHeaders: stream.headers,
    ));

    // Resume position if switching quality
    if (resumeFrom != null && resumeFrom.inSeconds > 0) {
      // Wait for player to be ready then seek
      await Future.delayed(const Duration(milliseconds: 500));
      await _player.seek(resumeFrom);
    }

    // Start periodic position saver (every 10s)
    _startProgressTimer();

    // Track progress for history + auto-advance
    // Cancel previous subscription to prevent listener leak on quality switch
    await _positionSub?.cancel();
    _positionSub = _player.stream.position.listen(_onPositionChanged);
  }

  // ── Subtitle control ──

  void _toggleSubtitle(dynamic subtitle) {
    if (!mounted) return;
    setState(() => _activeSubtitle = subtitle);

    if (subtitle == -1 || subtitle == null) {
      _player.setSubtitleTrack(SubtitleTrack.no());
      debugPrint('[Player] Subtitles OFF');
    } else if (subtitle is SubtitleInfo) {
      // ── OpenSubtitles result ──
      _player.setSubtitleTrack(SubtitleTrack.uri(
        subtitle.url,
        title: subtitle.label.isNotEmpty ? subtitle.label : subtitle.lang,
        language: subtitle.lang,
      ));
      debugPrint('[Player] OS Subtitle: ${subtitle.label}');
    } else if (subtitle is int && _currentStream != null) {
      final sub = _currentStream!.subtitles[subtitle];
      _player.setSubtitleTrack(SubtitleTrack.uri(
        sub.url, title: sub.displayLabel, language: sub.lang));
      debugPrint('[Player] API Subtitle: ${sub.displayLabel}');
    } else if (subtitle is SubtitleTrack) {
      _player.setSubtitleTrack(subtitle);
      debugPrint('[Player] Embedded Subtitle: ${subtitle.title ?? subtitle.language}');
    }
  }

  void _showPlayerSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: Colors.white10),
            ),
            child: _PlayerSettingsSheet(
              player: _player,
              stream: _currentStream,
              activeQuality: _activeQuality,
              activeSubtitle: _activeSubtitle,
              imdbId: _imdbId,
              mediaType: _type,
              season: _season,
              episode: _episode,
              subtitleSize: _subtitleSize,
              autoplay: _autoplay,
              repeatMode: _repeatMode,
              sleepMinutes: _sleepMinutes,
              onQualitySelect: (q) { _switchQuality(q); Navigator.pop(context); },
              onSubtitleSelect: (sub) { _toggleSubtitle(sub); Navigator.pop(context); },
              onAudioSelect: (track) {
                _player.setAudioTrack(track);
                setState(() {});
                Navigator.pop(context);
              },
              onSubtitleSizeChange: (s) => setState(() => _subtitleSize = s),
              onAutoplayToggle: (v) async {
                setState(() => _autoplay = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('player_autoplay', v);
              },
              onRepeatToggle: (v) => setState(() {
                _repeatMode = v;
                _player.setPlaylistMode(v ? PlaylistMode.single : PlaylistMode.none);
              }),
              onSleepTimer: (mins) {
                setState(() => _sleepMinutes = mins);
                _cancelSleepTimer();
                if (mins > 0) _startSleepTimer(mins);
              },
            ),
          ),
        ),
      ),
    );
  }

  // ── Quality control ──

  void _switchQuality(QualityOption quality) {
    // B2: Compare quality.url against quality.url (not the current stream URL),
    // and update _currentStream after switch so the 2nd switch works correctly.
    if (_currentStream == null) return;
    final currentQualityUrl = _currentStream!.qualities
        .firstWhere((q) => q.quality == _activeQuality,
            orElse: () => QualityOption(quality: _activeQuality, url: _currentStream!.url))
        .url;
    if (quality.url == currentQualityUrl) return;

    final currentPos = _player.state.position;
    debugPrint('[Player] Switching to ${quality.quality} at ${currentPos.inSeconds}s');

    final newStream = ExtractedStream(
      url: quality.url,
      headers: _currentStream!.headers,
      providerName: _currentStream!.providerName.replaceAll(RegExp(r'\(.*?\)'), '(${quality.quality})'),
      subtitles: _currentStream!.subtitles,
      qualities: _currentStream!.qualities,
    );

    setState(() => _activeQuality = quality.quality);
    _playStream(newStream, resumeFrom: currentPos);

    // Re-apply subtitle if one was active
    if (_activeSubtitle != -1) {
      Future.delayed(const Duration(milliseconds: 800), () {
        _toggleSubtitle(_activeSubtitle);
      });
    }
  }



  void _onPositionChanged(Duration pos) {
    final dur = _player.state.duration;
    if (dur.inSeconds < 10) return;

    // Save progress
    final history = ref.read(historyServiceProvider);
    history.saveProgress(
      imdbId: widget.args['imdbId'] as String? ?? _id,
      tmdbId: widget.args['tmdbId'] as int? ?? 0,
      title: _title,
      posterPath: widget.args['posterPath'] as String? ?? '',
      progressSeconds: pos.inSeconds,
      totalSeconds: dur.inSeconds,
      mediaType: _type,
      season: _type == 'tv' ? _season : null,
      episode: _type == 'tv' ? _episode : null,
    );

    // Auto-advance at 95% — gated on autoplay preference
    if (_type == 'tv' && !_hasAdvanced && (pos.inSeconds / dur.inSeconds) > 0.95) {
      _hasAdvanced = true;
      _maybeAdvanceEpisode();
    }
  }

  // U2: Check autoplay preference before advancing
  Future<void> _maybeAdvanceEpisode() async {
    final prefs = await SharedPreferences.getInstance();
    final autoplay = prefs.getBool('player_autoplay') ?? true;
    if (!autoplay || !mounted) return;
    _startCountdown();
  }

  // U7: 5-second countdown overlay with cancel option before auto-advancing
  void _startCountdown() {
    if (!mounted) return;
    setState(() { _showingCountdown = true; _countdownSeconds = 5; });
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _countdownSeconds--);
      if (_countdownSeconds <= 0) {
        t.cancel();
        setState(() => _showingCountdown = false);
        _advanceEpisode();
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    setState(() { _showingCountdown = false; _countdownSeconds = 0; });
  }

  void _advanceEpisode() {
    if (!mounted) return;
    // B1: Use local state instead of mutating widget.args
    setState(() => _episodeOverride = _episode + 1);
    _startExtraction();
  }

  // ── Controls ──

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _seek(int seconds) {
    final pos = _player.state.position + Duration(seconds: seconds);
    _player.seek(pos);
    _scheduleHideControls();
  }

  void _showSeekAnimation(int direction) {
    setState(() => _seekDirection = direction);
    _seekAnimTimer?.cancel();
    _seekAnimTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekDirection = null);
    });
  }

  // ── Gesture Handlers ──

  void _onVerticalDragStart(DragStartDetails d) {
    if (_isLocked || _state != _ExState.playing) return;
    final half = MediaQuery.of(context).size.width / 2;
    _isBrightnessGesture = d.globalPosition.dx < half;
    _gestureStartY = d.globalPosition.dy;
    _isDraggingVertical = true;

    if (_isBrightnessGesture) {
      ScreenBrightness.instance.application.then((v) {
        _gestureStartValue = v;
        _gestureValue = v;
      });
    } else {
      VolumeController.instance.getVolume().then((v) {
        _gestureStartValue = v;
        _gestureValue = v;
      });
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (!_isDraggingVertical) return;
    final screenH = MediaQuery.of(context).size.height;
    final delta = (_gestureStartY - d.globalPosition.dy) / (screenH * 0.6);
    final newVal = (_gestureStartValue + delta).clamp(0.0, 1.0);
    setState(() => _gestureValue = newVal);

    if (_isBrightnessGesture) {
      ScreenBrightness.instance.setApplicationScreenBrightness(newVal);
    } else {
      VolumeController.instance.setVolume(newVal);
    }
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (!_isDraggingVertical) return;
    _gestureHideTimer?.cancel();
    _gestureHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _isDraggingVertical = false);
    });
  }

  void _onHorizontalDragStart(DragStartDetails d) {
    if (_isLocked || _state != _ExState.playing) return;
    _scrubStartX = d.globalPosition.dx;
    _scrubStartPos = _player.state.position;
    setState(() { _isScrubbing = true; _scrubPosition = _scrubStartPos; });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (!_isScrubbing) return;
    final screenW = MediaQuery.of(context).size.width;
    final delta = (d.globalPosition.dx - _scrubStartX) / screenW;
    final dur = _player.state.duration;
    final seekMs = (delta * dur.inMilliseconds * 0.5).toInt();
    final newPos = Duration(milliseconds: (_scrubStartPos.inMilliseconds + seekMs).clamp(0, dur.inMilliseconds));
    setState(() => _scrubPosition = newPos);
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (!_isScrubbing) return;
    _player.seek(_scrubPosition);
    setState(() => _isScrubbing = false);
  }

  void _onLongPressStart() {
    if (_isLocked || _state != _ExState.playing) return;
    setState(() => _longPressing = true);
    _player.setRate(2.0);
  }

  void _onLongPressEnd() {
    // B3: Guard — only reset rate if we actually started a long press
    if (!mounted || !_longPressing) return;
    setState(() => _longPressing = false);
    _player.setRate(_playbackSpeed);
  }

  void _toggleLock() => setState(() => _isLocked = !_isLocked);

  void _cycleSpeed() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(_playbackSpeed);
    final next = speeds[(idx + 1) % speeds.length];
    setState(() => _playbackSpeed = next);
    _player.setRate(next);
    _scheduleHideControls();
  }

  void _toggleFit() {
    setState(() => _isFitMode = !_isFitMode);
    _scheduleHideControls();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, __) => _player.stop(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _isLocked ? null : _toggleControls,
            onDoubleTapDown: _isLocked ? null : (d) {
              final half = MediaQuery.of(context).size.width / 2;
              final isLeft = d.globalPosition.dx < half;
              _seek(isLeft ? -10 : 10);
              _showSeekAnimation(isLeft ? -1 : 1);
            },
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            child: Stack(
              children: [
                // ── Video surface ──
                Positioned.fill(
                  child: _state == _ExState.playing
                      ? Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: _isFitMode ? BoxFit.contain : BoxFit.cover,
                          subtitleViewConfiguration: const SubtitleViewConfiguration(
                            style: TextStyle(
                              fontSize: 28,
                              color: Colors.white,
                              backgroundColor: Color(0x99000000),
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

                // ── Buffering spinner ──
                if (_isBuffering && _state == _ExState.playing)
                  const Center(
                    child: SizedBox(
                      width: 48, height: 48,
                      child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2.5),
                    ),
                  ),

                // ── Long press 2x speed badge ──
                if (_longPressing)
                  Positioned(
                    top: 60, left: 0, right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fast_forward_rounded, color: Colors.white, size: 18),
                            SizedBox(width: 6),
                            Text('2×', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Horizontal scrub position label ──
                if (_isScrubbing)
                  Positioned(
                    top: 0, bottom: 0, left: 0, right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _fmt(_scrubPosition),
                          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),

                // ── Double-tap seek animation ──
                if (_seekDirection != null)
                  Positioned(
                    left: _seekDirection == -1 ? 40 : null,
                    right: _seekDirection == 1 ? 40 : null,
                    top: 0, bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(40)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_seekDirection == -1 ? Icons.fast_rewind : Icons.fast_forward, color: Colors.white, size: 28),
                            const SizedBox(width: 6),
                            const Text('10s', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Vertical gesture indicator (brightness/volume) ──
                if (_isDraggingVertical)
                  Positioned(
                    top: 0, bottom: 0,
                    left: _isBrightnessGesture ? 24 : null,
                    right: _isBrightnessGesture ? null : 24,
                    child: Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: Container(
                            width: 52, height: 180,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isBrightnessGesture
                                      ? (_gestureValue > 0.5 ? Icons.brightness_high_rounded : Icons.brightness_low_rounded)
                                      : (_gestureValue > 0.5 ? Icons.volume_up_rounded : Icons.volume_down_rounded),
                                  color: Colors.white, size: 20,
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: -1,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: _gestureValue,
                                        backgroundColor: Colors.white12,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          _isBrightnessGesture ? Colors.amber : Colors.white,
                                        ),
                                        minHeight: 4,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '${(_gestureValue * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // ── Lock mode overlay ──
                if (_isLocked && _state == _ExState.playing)
                  Positioned(
                    bottom: 40, left: 0, right: 0,
                    child: Center(
                      child: GestureDetector(
                        onTap: _toggleLock,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lock_rounded, color: Colors.white70, size: 18),
                              SizedBox(width: 8),
                              Text('Tap to unlock', style: TextStyle(color: Colors.white70, fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // ── Extraction / Error overlay ──
                if (_state != _ExState.playing)
                  Positioned.fill(
                    child: _StatusOverlay(
                      state: _state,
                      message: _state == _ExState.failed ? (_failedMsg ?? 'Unknown error') : _statusMsg,
                      onRetry: _state == _ExState.failed ? _startExtraction : null,
                      providerStatuses: _providerStatuses,
                    ),
                  ),

                // ── Controls overlay (animated fade) ──
                if (_state == _ExState.playing && !_isLocked)
                  AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: _ControlsOverlay(
                        title: _title,
                        type: _type,
                        season: _season,
                        episode: _episode,
                        providerName: _providerBadge,
                        player: _player,
                        playbackSpeed: _playbackSpeed,
                        isFitMode: _isFitMode,
                        isLocked: _isLocked,
                        onBack: () => Navigator.pop(context),
                        onSeekBack: () { _seek(-10); _showSeekAnimation(-1); },
                        onSeekForward: () { _seek(10); _showSeekAnimation(1); },
                        onLock: _toggleLock,
                        onCycleSpeed: _cycleSpeed,
                        onToggleFit: _toggleFit,
                        onNextEpisode: _type == 'tv' ? () {
                          _cancelCountdown();
                          _advanceEpisode();
                        } : null,
                        onSettings: _showPlayerSettings,
                        onSwitchSource: _tryAnotherSource,
                        onDownload: _currentStream != null
                            ? _downloadCurrentStream
                            : null,
                      ),
                    ),
                  ),

                // U7: Auto-advance countdown overlay — Netflix-style
                if (_showingCountdown)
                  Positioned(
                    bottom: 80, right: 24,
                    child: _NextEpisodeCountdown(
                      secondsLeft: _countdownSeconds,
                      onCancel: _cancelCountdown,
                      onPlayNow: () { _cancelCountdown(); _advanceEpisode(); },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── D-pad / TV remote support ──

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        if (_state == _ExState.playing) {
          _player.playOrPause();
          _toggleControls();
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        _seek(-10);
        _showSeekAnimation(-1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        _seek(10);
        _showSeekAnimation(1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        _player.playOrPause();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        Navigator.pop(context);
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }
}

// ─── Status Overlay (Extracting / Failed) ─────────────────────────────────────

class _StatusOverlay extends StatelessWidget {
  final _ExState state;
  final String message;
  final VoidCallback? onRetry;
  final Map<String, ProviderStatus> providerStatuses;

  const _StatusOverlay({
    required this.state,
    required this.message,
    this.onRetry,
    this.providerStatuses = const {},
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state == _ExState.extracting) ...[
                const _PulsingSpinner(),
                const SizedBox(height: 24),
                // Provider status pills
                if (providerStatuses.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: providerStatuses.entries.map((e) {
                      return _ProviderPill(name: e.key, status: e.value);
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  message,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'This may take a few seconds',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12),
                ),
              ] else ...[
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
                const SizedBox(height: 16),
                Text(
                  message,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (onRetry != null)
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Provider Status Pill ─────────────────────────────────────────────────────

class _ProviderPill extends StatelessWidget {
  final String name;
  final ProviderStatus status;
  const _ProviderPill({required this.name, required this.status});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, IconData? icon) = switch (status) {
      ProviderStatus.idle    => (Colors.white10, Colors.white38, null),
      ProviderStatus.trying  => (Colors.deepPurpleAccent.withValues(alpha: 0.2), Colors.deepPurpleAccent, null),
      ProviderStatus.success => (Colors.green.withValues(alpha: 0.2), Colors.greenAccent, Icons.check_circle_rounded),
      ProviderStatus.failed  => (Colors.red.withValues(alpha: 0.15), Colors.redAccent.withValues(alpha: 0.7), Icons.cancel_rounded),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: status == ProviderStatus.trying
            ? Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.4), width: 1)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == ProviderStatus.trying)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 10, height: 10,
                child: CircularProgressIndicator(color: Colors.deepPurpleAccent, strokeWidth: 1.5),
              ),
            ),
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(icon, size: 12, color: fg),
            ),
          Text(name, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// P5: Properly looping pulsing spinner using AnimationController.repeat()
class _PulsingSpinner extends StatefulWidget {
  const _PulsingSpinner();
  @override
  State<_PulsingSpinner> createState() => _PulsingSpinnerState();
}

class _PulsingSpinnerState extends State<_PulsingSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (_, child) => Opacity(opacity: _opacity.value, child: child),
      child: Container(
        width: 72, height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 2),
        ),
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
        ),
      ),
    );
  }
}

// \u2500\u2500\u2500 Next Episode Countdown (U7) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

class _NextEpisodeCountdown extends StatelessWidget {
  final int secondsLeft;
  final VoidCallback onCancel;
  final VoidCallback onPlayNow;
  const _NextEpisodeCountdown({
    required this.secondsLeft,
    required this.onCancel,
    required this.onPlayNow,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Next Episode',
                style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(
                'Playing in $secondsLeft second${secondsLeft == 1 ? '' : 's'}...',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: secondsLeft / 5.0,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.deepPurpleAccent),
                  minHeight: 3,
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: onPlayNow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                      child: const Center(child: Text('Play Now',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13))),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onCancel,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// \u2500\u2500\u2500 Controls Overlay \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500



class _ControlsOverlay extends StatelessWidget {
  final String title;
  final String type;
  final int season;
  final int episode;
  final String providerName;
  final Player player;
  final double playbackSpeed;
  final bool isFitMode;
  final bool isLocked;
  final VoidCallback onBack;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final VoidCallback onLock;
  final VoidCallback onCycleSpeed;
  final VoidCallback onToggleFit;
  final VoidCallback? onNextEpisode;
  final VoidCallback onSettings;
  final VoidCallback? onSwitchSource;
  final VoidCallback? onDownload;

  const _ControlsOverlay({
    required this.title,
    required this.type,
    required this.season,
    required this.episode,
    required this.providerName,
    required this.player,
    required this.playbackSpeed,
    required this.isFitMode,
    required this.isLocked,
    required this.onBack,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onLock,
    required this.onCycleSpeed,
    required this.onToggleFit,
    this.onNextEpisode,
    required this.onSettings,
    this.onSwitchSource,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xD0000000), Colors.transparent, Colors.transparent, Color(0xD0000000)],
          stops: [0.0, 0.28, 0.68, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────────────────────
            _TopBar(
              title: title,
              type: type,
              season: season,
              episode: episode,
              providerName: providerName,
              isLocked: isLocked,
              isFitMode: isFitMode,
              onBack: onBack,
              onLock: onLock,
              onToggleFit: onToggleFit,
              onSwitchSource: onSwitchSource,
              isTablet: isTablet,
            ),

            const Spacer(),

            // ── Center play controls ──────────────────────────────────────────
            _CenterControls(
              player: player,
              onSeekBack: onSeekBack,
              onSeekForward: onSeekForward,
              onNextEpisode: onNextEpisode,
              isTablet: isTablet,
            ),

            const Spacer(),

            // ── Bottom bar ───────────────────────────────────────────────────
            _BottomBar(
              player: player,
              playbackSpeed: playbackSpeed,
              onSettings: onSettings,
              onDownload: onDownload,
              onCycleSpeed: onCycleSpeed,
              isTablet: isTablet,
              cs: cs,
            ),
          ],
        ),
      ),
    );
  }

}

// ─── Top bar ──────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String title, type, providerName;
  final int season, episode;
  final bool isLocked, isFitMode, isTablet;
  final VoidCallback onBack, onLock, onToggleFit;
  final VoidCallback? onSwitchSource;

  const _TopBar({
    required this.title, required this.type, required this.providerName,
    required this.season, required this.episode,
    required this.isLocked, required this.isFitMode, required this.isTablet,
    required this.onBack, required this.onLock, required this.onToggleFit,
    this.onSwitchSource,
  });

  @override
  Widget build(BuildContext context) {
    final iconSize = isTablet ? 22.0 : 20.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isTablet ? 20.0 : 8.0, vertical: 4),
      child: Row(
        children: [
          // Back
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: iconSize),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Title + episode
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isTablet ? 17 : 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                if (type == 'tv')
                  Text(
                    'S${season.toString().padLeft(2, '0')} · E${episode.toString().padLeft(2, '0')}',
                    style: TextStyle(color: Colors.white54, fontSize: isTablet ? 13 : 11),
                  ),
              ],
            ),
          ),
          // Provider badge
          if (providerName.isNotEmpty) ...[
            GestureDetector(
              onTap: onSwitchSource,
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(providerName.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white70, fontSize: 9,
                        fontWeight: FontWeight.w700, letterSpacing: 0.8,
                      )),
                    if (onSwitchSource != null) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.swap_horiz_rounded, color: Colors.white54, size: 11),
                    ],
                  ],
                ),
              ),
            ),
          ],
          // Fit toggle
          _GlassIconBtn(icon: isFitMode ? Icons.fit_screen_rounded : Icons.crop_free_rounded,
            tooltip: isFitMode ? 'Fill' : 'Fit', onTap: onToggleFit, size: iconSize),
          // Lock
          _GlassIconBtn(icon: isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
            tooltip: isLocked ? 'Unlock' : 'Lock', onTap: onLock, size: iconSize),
        ],
      ),
    );
  }
}

// ─── Center controls ──────────────────────────────────────────────────────────

class _CenterControls extends StatelessWidget {
  final Player player;
  final VoidCallback onSeekBack, onSeekForward;
  final VoidCallback? onNextEpisode;
  final bool isTablet;

  const _CenterControls({
    required this.player, required this.onSeekBack,
    required this.onSeekForward, required this.isTablet, this.onNextEpisode,
  });

  @override
  Widget build(BuildContext context) {
    final btnSize = isTablet ? 72.0 : 60.0;
    final seekSize = isTablet ? 36.0 : 30.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SeekBtn(icon: Icons.replay_10_rounded, label: '10s', onTap: onSeekBack, size: seekSize),
        SizedBox(width: isTablet ? 40.0 : 28.0),
        // Play/Pause — M3 Expressive filled circle
        StreamBuilder<bool>(
          stream: player.stream.playing,
          builder: (_, snap) {
            final playing = snap.data ?? false;
            return GestureDetector(
              onTap: player.playOrPause,
              child: Container(
                width: btnSize, height: btnSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.18),
                  border: Border.all(color: Colors.white30, width: 1.5),
                  boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 16, spreadRadius: 2)],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(playing),
                    color: Colors.white, size: btnSize * 0.56,
                  ),
                ),
              ),
            );
          },
        ),
        SizedBox(width: isTablet ? 40.0 : 28.0),
        _SeekBtn(icon: Icons.forward_10_rounded, label: '10s', onTap: onSeekForward, size: seekSize),
        if (onNextEpisode != null) ...[
          SizedBox(width: isTablet ? 28.0 : 20.0),
          _SeekBtn(icon: Icons.skip_next_rounded, label: 'Next', onTap: onNextEpisode!, size: seekSize),
        ],
      ],
    );
  }
}

// ─── Bottom bar ───────────────────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  final Player player;
  final double playbackSpeed;
  final VoidCallback onSettings, onCycleSpeed;
  final VoidCallback? onDownload;
  final bool isTablet;
  final ColorScheme cs;

  const _BottomBar({
    required this.player, required this.playbackSpeed,
    required this.onSettings, required this.onCycleSpeed,
    required this.isTablet, required this.cs, this.onDownload,
  });

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isTablet ? 20.0 : 12.0, 0, isTablet ? 20.0 : 12.0, isTablet ? 12.0 : 8.0),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        builder: (_, posSnap) => StreamBuilder<Duration>(
          stream: player.stream.duration,
          builder: (_, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final progress = dur.inMilliseconds > 0
                ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Seekbar stack (buffered + active)
                Stack(
                  children: [
                    StreamBuilder<Duration>(
                      stream: player.stream.buffer,
                      builder: (_, bufSnap) {
                        final buf = bufSnap.data ?? Duration.zero;
                        final bufPct = dur.inMilliseconds > 0
                            ? (buf.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                            : 0.0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: bufPct.toDouble(),
                              backgroundColor: Colors.white10,
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0x1FFFFFFF)),
                              minHeight: 3,
                            ),
                          ),
                        );
                      },
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: isTablet ? 4.0 : 3.0,
                        thumbShape: RoundSliderThumbShape(enabledThumbRadius: isTablet ? 8 : 6),
                        overlayShape: RoundSliderOverlayShape(overlayRadius: isTablet ? 18 : 14),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.transparent,
                        thumbColor: Colors.white,
                        overlayColor: const Color(0x1FFFFFFF),
                      ),
                      child: Slider(
                        value: progress,
                        onChanged: (v) => player.seek(
                          Duration(milliseconds: (v * dur.inMilliseconds).toInt())),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Time row + action pills
                Row(
                  children: [
                    Text(_fmt(pos), style: TextStyle(color: Colors.white70, fontSize: isTablet ? 13 : 11)),
                    const SizedBox(width: 4),
                    Text('-${_fmt(dur - pos)}', style: TextStyle(color: Colors.white38, fontSize: isTablet ? 12 : 10)),
                    const Spacer(),
                    // Settings pill
                    _ActionPill(icon: Icons.tune_rounded, label: 'Settings', onTap: onSettings),
                    if (onDownload != null) ...[
                      const SizedBox(width: 6),
                      _ActionPill(icon: Icons.download_rounded, label: 'Save', onTap: onDownload!),
                    ],
                    const SizedBox(width: 6),
                    // Speed pill
                    GestureDetector(
                      onTap: onCycleSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: playbackSpeed != 1.0
                              ? cs.primaryContainer.withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: playbackSpeed != 1.0
                              ? Border.all(color: cs.primary.withValues(alpha: 0.4), width: 0.8)
                              : null,
                        ),
                        child: Text('$playbackSpeed×',
                          style: TextStyle(
                            color: playbackSpeed != 1.0 ? cs.primary : Colors.white70,
                            fontSize: isTablet ? 12 : 10,
                            fontWeight: FontWeight.w700,
                          )),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_fmt(dur), style: TextStyle(color: Colors.white54, fontSize: isTablet ? 13 : 11)),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ─── Reusable glass icon button ───────────────────────────────────────────────

class _GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  const _GlassIconBtn({required this.icon, required this.tooltip, required this.onTap, required this.size});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, color: Colors.white70, size: size),
        ),
      ),
    ),
  );
}

// ─── Seek button ──────────────────────────────────────────────────────────────

class _SeekBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  const _SeekBtn({required this.icon, required this.label, required this.onTap, required this.size});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white, size: size),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    ),
  );
}

// ─── Action pill (Settings / Save) ───────────────────────────────────────────

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionPill({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 13),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}


// ─── Unified Player Settings Sheet (M3 Expressive) ───────────────────────────

class _PlayerSettingsSheet extends StatefulWidget {
  final Player player;
  final ExtractedStream? stream;
  final String activeQuality;
  final ValueChanged<QualityOption> onQualitySelect;
  final ValueChanged<dynamic> onSubtitleSelect;
  final ValueChanged<AudioTrack> onAudioSelect;
  final dynamic activeSubtitle;
  final String imdbId;
  final String mediaType;
  final int season;
  final int episode;
  // ── New settings params ──
  final double subtitleSize;
  final bool autoplay;
  final bool repeatMode;
  final int sleepMinutes;
  final ValueChanged<double> onSubtitleSizeChange;
  final ValueChanged<bool> onAutoplayToggle;
  final ValueChanged<bool> onRepeatToggle;
  final ValueChanged<int> onSleepTimer;

  const _PlayerSettingsSheet({
    required this.player,
    required this.stream,
    required this.activeQuality,
    required this.onQualitySelect,
    required this.onSubtitleSelect,
    required this.onAudioSelect,
    required this.activeSubtitle,
    required this.imdbId,
    required this.mediaType,
    this.season = 0,
    this.episode = 0,
    this.subtitleSize = 18.0,
    this.autoplay = true,
    this.repeatMode = false,
    this.sleepMinutes = 0,
    required this.onSubtitleSizeChange,
    required this.onAutoplayToggle,
    required this.onRepeatToggle,
    required this.onSleepTimer,
  });

  @override
  State<_PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}


class _PlayerSettingsSheetState extends State<_PlayerSettingsSheet> {
  int _tabIndex = 0; // 0=Quality 1=Audio 2=Subtitles

  // OpenSubtitles state
  String _subLang = 'en';
  bool _subLoading = false;
  List<SubtitleInfo> _osResults = []; // fetched from OpenSubtitles
  String? _subError;

  static const _langNames = <String, String>{
    'en': 'English', 'es': 'Spanish', 'fr': 'French', 'de': 'German',
    'hi': 'Hindi', 'ar': 'Arabic', 'zh-cn': 'Chinese', 'ja': 'Japanese',
    'ko': 'Korean', 'ru': 'Russian', 'it': 'Italian', 'pt': 'Portuguese',
    'tr': 'Turkish', 'pl': 'Polish', 'nl': 'Dutch',
  };

  String _fmtLang(String? l) {
    if (l == null || l.isEmpty) return '?';
    return _langNames[l.toLowerCase()] ??
        {'eng': 'English', 'spa': 'Spanish', 'fre': 'French',
         'ger': 'German', 'hin': 'Hindi', 'jpn': 'Japanese',
         'kor': 'Korean', 'chi': 'Chinese', 'ara': 'Arabic',
         'rus': 'Russian', 'ita': 'Italian', 'por': 'Portuguese',
        }[l.toLowerCase()] ?? l.toUpperCase();
  }

  IconData _qualityIcon(String q) {
    if (q.contains('4K') || q.contains('2160')) return Icons.four_k_rounded;
    if (q.contains('1080')) return Icons.hd_rounded;
    if (q.contains('720')) return Icons.hd_outlined;
    return Icons.sd_rounded;
  }

  Future<void> _searchOpenSubtitles() async {
    if (widget.imdbId.isEmpty) {
      setState(() => _subError = 'No IMDB ID — cannot search OpenSubtitles.');
      return;
    }
    setState(() { _subLoading = true; _subError = null; _osResults = []; });
    try {
      final svc = opensubs.SubtitleService();
      final tracks = await svc.search(
        imdbId: widget.imdbId,
        language: _subLang,
        season: widget.mediaType == 'tv' ? widget.season : 0,
        episode: widget.mediaType == 'tv' ? widget.episode : 0,
      );
      final infos = <SubtitleInfo>[];
      for (final t in tracks) {
        final url = await svc.getDownloadUrl(t.fileId);
        if (url != null) {
          infos.add(SubtitleInfo(
            url: url,
            lang: t.languageCode,
            label: '${_fmtLang(t.languageCode)} · ${t.releaseName.length > 30 ? '${t.releaseName.substring(0, 30)}…' : t.releaseName}',
          ));
        }
      }
      setState(() { _osResults = infos; _subLoading = false; });
    } catch (e) {
      setState(() { _subError = 'Search failed: $e'; _subLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final audioTracks = widget.player.state.tracks.audio;
    final embSubs = widget.player.state.tracks.subtitle;
    final extSubs = widget.stream?.subtitles ?? [];
    final qualities = widget.stream?.qualities ?? [];

    final tabs = <String>[];
    if (qualities.isNotEmpty) tabs.add('Quality');
    if (audioTracks.length > 1) tabs.add('Audio');
    tabs.add('Subtitles');
    tabs.add('More'); // sleep timer, subtitle size, autoplay, repeat

    // Clamp tab index
    final safeTab = _tabIndex.clamp(0, tabs.length - 1);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Drag handle ──
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // ── M3 Tab bar ──
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final active = safeTab == i;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tabs[i]),
                      selected: active,
                      onSelected: (_) => setState(() => _tabIndex = i),
                      showCheckmark: false,
                      selectedColor: cs.primaryContainer,
                      labelStyle: TextStyle(
                        color: active ? cs.onPrimaryContainer : Colors.white70,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      ),
                      backgroundColor: Colors.white10,
                      side: BorderSide.none,
                      shape: const StadiumBorder(),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 12),

            // ── Content ──
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: SingleChildScrollView(
                child: _buildTab(tabs[safeTab], qualities, audioTracks, embSubs, extSubs, cs),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(
    String tab,
    List<QualityOption> qualities,
    List<AudioTrack> audioTracks,
    List<SubtitleTrack> embSubs,
    List<SubtitleInfo> extSubs,
    ColorScheme cs,
  ) {
    switch (tab) {
      // ── Quality ──────────────────────────────────────────────────────────
      case 'Quality':
        return Column(
          children: qualities.map((q) {
            final active = q.quality == widget.activeQuality;
            return _SettingsTile(
              icon: _qualityIcon(q.quality),
              title: q.quality,
              active: active,
              cs: cs,
              onTap: () => widget.onQualitySelect(q),
            );
          }).toList(),
        );

      // ── Audio ────────────────────────────────────────────────────────────
      case 'Audio':
        return Column(
          children: audioTracks.map((t) {
            final active = widget.player.state.track.audio == t;
            return _SettingsTile(
              icon: Icons.audiotrack_rounded,
              title: _fmtLang(t.language ?? t.title),
              active: active,
              cs: cs,
              onTap: () => widget.onAudioSelect(t),
            );
          }).toList(),
        );

      // ── Subtitles ────────────────────────────────────────────────
      case 'Subtitles':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingsTile(
              icon: Icons.subtitles_off_rounded,
              title: 'Off',
              active: widget.activeSubtitle == -1 || widget.activeSubtitle == null,
              cs: cs,
              onTap: () => widget.onSubtitleSelect(-1),
            ),
            if (embSubs.where((t) => t.id != 'no').isNotEmpty) ...[
              _sectionLabel('Embedded', cs),
              ...embSubs.where((t) => t.id != 'no').map((t) => _SettingsTile(
                icon: Icons.subtitles_outlined,
                title: _fmtLang(t.language ?? t.title),
                active: widget.activeSubtitle == t,
                cs: cs,
                onTap: () => widget.onSubtitleSelect(t),
              )),
            ],
            if (extSubs.isNotEmpty) ...[
              _sectionLabel('Bundled', cs),
              ...List.generate(extSubs.length, (i) => _SettingsTile(
                icon: Icons.subtitles_rounded,
                title: extSubs[i].label.isNotEmpty ? extSubs[i].label : _fmtLang(extSubs[i].lang),
                active: widget.activeSubtitle == i,
                cs: cs,
                onTap: () => widget.onSubtitleSelect(i),
              )),
            ],
            _sectionLabel('OpenSubtitles Search', cs),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                    ),
                    child: DropdownButton<String>(
                      value: _subLang,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: const Color(0xFF1E1E2E),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      icon: const Icon(Icons.expand_more_rounded, color: Colors.white54, size: 18),
                      items: _langNames.entries.map((e) => DropdownMenuItem(
                        value: e.key, child: Text(e.value),
                      )).toList(),
                      onChanged: (v) { if (v != null) setState(() => _subLang = v); },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _subLoading ? null : _searchOpenSubtitles,
                  icon: _subLoading
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Search'),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ],
            ),
            if (_subError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_subError!, style: TextStyle(color: cs.error, fontSize: 12)),
              ),
            if (_osResults.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._osResults.asMap().entries.map((e) => _SettingsTile(
                icon: Icons.subtitles_rounded,
                title: e.value.label.isNotEmpty ? e.value.label : _fmtLang(e.value.lang),
                active: false,
                cs: cs,
                onTap: () => widget.onSubtitleSelect(e.value),
              )),
            ],
            if (_osResults.isEmpty && !_subLoading && _subError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: Text(
                  'Select a language and tap Search',
                  style: TextStyle(color: Colors.white38, fontSize: 12))),
              ),
            const SizedBox(height: 8),
          ],
        );

      // ── More ────────────────────────────────────────────────
      case 'More':
        return _buildMoreTab(cs);

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildMoreTab(ColorScheme cs) {
    const sleepOptions = [0, 15, 30, 45, 60, 90, 120];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Subtitle size slider ──
        _sectionLabel('Subtitle Size', cs),
        Row(
          children: [
            const Icon(Icons.text_fields_rounded, color: Colors.white38, size: 15),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: cs.primary,
                  overlayColor: Colors.transparent,
                ),
                child: Slider(
                  value: widget.subtitleSize.clamp(12.0, 32.0),
                  min: 12, max: 32, divisions: 10,
                  label: '${widget.subtitleSize.round()}sp',
                  onChanged: widget.onSubtitleSizeChange,
                ),
              ),
            ),
            const Icon(Icons.text_fields_rounded, color: Colors.white, size: 22),
          ],
        ),

        // ── Sleep timer chips ──
        _sectionLabel('Sleep Timer', cs),
        Wrap(
          spacing: 8, runSpacing: 6,
          children: sleepOptions.map((m) {
            final active = widget.sleepMinutes == m;
            return ChoiceChip(
              label: Text(m == 0 ? 'Off' : '${m}m'),
              selected: active,
              onSelected: (_) => widget.onSleepTimer(m),
              selectedColor: cs.primaryContainer,
              backgroundColor: Colors.white10,
              labelStyle: TextStyle(
                color: active ? cs.onPrimaryContainer : Colors.white70,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                fontSize: 12,
              ),
              side: BorderSide.none,
              shape: const StadiumBorder(),
            );
          }).toList(),
        ),

        // ── Playback toggles ──
        _sectionLabel('Playback', cs),
        _ToggleTile(
          icon: Icons.skip_next_rounded,
          title: 'Autoplay next episode',
          value: widget.autoplay,
          cs: cs,
          onChanged: widget.onAutoplayToggle,
        ),
        const SizedBox(height: 4),
        _ToggleTile(
          icon: Icons.repeat_one_rounded,
          title: 'Repeat this episode',
          value: widget.repeatMode,
          cs: cs,
          onChanged: widget.onRepeatToggle,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _sectionLabel(String text, ColorScheme cs) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
    child: Text(text,
      style: TextStyle(
        color: cs.primary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      )),
  );


}

// ─── M3 Settings Tile ─────────────────────────────────────────────────────────

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool active;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.active,
    required this.cs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: active
            ? cs.primaryContainer.withValues(alpha: 0.3)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: active
            ? Border.all(color: cs.primary.withValues(alpha: 0.4), width: 1)
            : null,
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(
          active ? Icons.check_circle_rounded : icon,
          color: active ? cs.primary : Colors.white54,
          size: 22,
        ),
        title: Text(title,
          style: TextStyle(
            color: active ? cs.primary : Colors.white,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            fontSize: 14,
          )),

        trailing: active
            ? Icon(Icons.radio_button_checked_rounded, color: cs.primary, size: 18)
            : const Icon(Icons.radio_button_unchecked_rounded, color: Colors.white24, size: 18),
        onTap: onTap,
      ),
    );
  }
}

// ─── Toggle Tile ──────────────────────────────────────────────────────────────

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ColorScheme cs;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.cs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: value ? cs.primaryContainer.withValues(alpha: 0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: value ? Border.all(color: cs.primary.withValues(alpha: 0.3)) : null,
      ),
      child: SwitchListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        secondary: Icon(icon, color: value ? cs.primary : Colors.white38, size: 20),
        title: Text(title,
          style: TextStyle(
            color: value ? cs.primary : Colors.white70,
            fontSize: 13,
            fontWeight: value ? FontWeight.w600 : FontWeight.w400,
          )),
        value: value,
        activeThumbColor: cs.primary,
        onChanged: onChanged,
      ),
    );
  }
}
