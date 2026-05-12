import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../services/stream_extractor_service.dart';
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

  String get _title => widget.args['title'] as String? ?? 'Untitled';
  String get _type => widget.args['type'] as String? ?? 'movie';
  int get _season => widget.args['season'] as int? ?? 1;
  int get _episode => widget.args['episode'] as int? ?? 1;
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

    // Listen for buffering state
    _player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => _isBuffering = buffering);
    });

    _startExtraction();
    _scheduleHideControls();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _seekAnimTimer?.cancel();
    _gestureHideTimer?.cancel();
    _positionSub?.cancel();
    _player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Extraction ──

  Future<void> _startExtraction() async {
    setState(() {
      _state = _ExState.extracting;
      _statusMsg = 'Finding best stream…';
      _providerBadge = '';
      _hasAdvanced = false;
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

    // ── Step 2: Direct API (VidAPI + Videasy race, ~2-5s) ──
    if (mounted) setState(() => _statusMsg = 'Extracting from providers…');

    final directStream = await _extractor.extractDirectAPIs(
      imdbId: _imdbId,
      tmdbId: _tmdbId,
      type: _type,
      title: _title,
      season: _season,
      episode: _episode,
    );

    if (!mounted) return;
    if (directStream != null) { _playStream(directStream); return; }

    // ── Failed ──
    setState(() {
      _state = _ExState.failed;
      _failedMsg = 'No streams available.\nTap Retry to try again.';
    });
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

    // Track progress for history + auto-advance
    // Cancel previous subscription to prevent listener leak on quality switch
    await _positionSub?.cancel();
    _positionSub = _player.stream.position.listen(_onPositionChanged);
  }

  // ── Subtitle control ──

  void _toggleSubtitle(dynamic subtitle) {
    if (!mounted || _currentStream == null) return;
    setState(() => _activeSubtitle = subtitle);
    
    if (subtitle == -1 || subtitle == SubtitleTrack.no()) {
      _player.setSubtitleTrack(SubtitleTrack.no());
      debugPrint('[Player] Subtitles OFF');
    } else if (subtitle is int) {
      final sub = _currentStream!.subtitles[subtitle];
      _player.setSubtitleTrack(SubtitleTrack.uri(sub.url, title: sub.displayLabel, language: sub.lang));
      debugPrint('[Player] API Subtitle: ${sub.displayLabel}');
    } else if (subtitle is SubtitleTrack) {
      _player.setSubtitleTrack(subtitle);
      debugPrint('[Player] Embedded Subtitle: ${subtitle.title ?? subtitle.language}');
    }
  }

  void _showPlayerSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PlayerSettingsSheet(
        player: _player,
        stream: _currentStream,
        activeQuality: _activeQuality,
        activeSubtitle: _activeSubtitle,
        onQualitySelect: (q) {
          _switchQuality(q);
          Navigator.pop(context);
        },
        onSubtitleSelect: (sub) {
          _toggleSubtitle(sub);
          Navigator.pop(context);
        },
        onAudioSelect: (track) {
          _player.setAudioTrack(track);
          setState(() {}); // Rebuild to reflect active track
          Navigator.pop(context);
        },
      ),
    );
  }

  // ── Quality control ──

  void _switchQuality(QualityOption quality) {
    if (_currentStream == null || quality.url == _currentStream!.url) return;
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

    // Auto-advance at 95%
    if (_type == 'tv' && !_hasAdvanced && (pos.inSeconds / dur.inSeconds) > 0.95) {
      _hasAdvanced = true;
      _advanceEpisode();
    }
  }

  void _advanceEpisode() {
    if (!mounted) return;
    widget.args['episode'] = _episode + 1;
    widget.args['episodeName'] = 'Episode ${_episode + 1}';
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
    if (!_longPressing) return;
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
                        onNextEpisode: _type == 'tv' ? _advanceEpisode : null,
                        onSettings: _showPlayerSettings,
                      ),
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

  const _StatusOverlay({
    required this.state,
    required this.message,
    this.onRetry,
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
                // Pulsing extraction indicator
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1.0),
                  duration: const Duration(milliseconds: 800),
                  builder: (_, v, child) => Opacity(opacity: v, child: child),
                  onEnd: () {},
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24, width: 2),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
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

// ─── Controls Overlay ─────────────────────────────────────────────────────────

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
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Colors.transparent, Colors.transparent, Color(0xCC000000)],
            stops: [0, 0.25, 0.7, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── Top bar ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (type == 'tv')
                            Text('S${season.toString().padLeft(2, '0')} · E${episode.toString().padLeft(2, '0')}',
                              style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                    // Lock button  
                    _OverlayIconBtn(
                      icon: isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                      onTap: onLock,
                      tooltip: isLocked ? 'Unlock' : 'Lock',
                    ),
                    // Fit/Fill toggle
                    _OverlayIconBtn(
                      icon: isFitMode ? Icons.fit_screen_rounded : Icons.crop_free_rounded,
                      onTap: onToggleFit,
                      tooltip: isFitMode ? 'Fill' : 'Fit',
                    ),
                    // Provider badge (info only)
                    if (providerName.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(providerName.toUpperCase(),
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 9,
                            fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                      ),
                  ],
                ),
              ),

              const Spacer(),

              // ── Center controls ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _SeekButton(icon: Icons.replay_10, label: '-10s', onTap: onSeekBack),
                  const SizedBox(width: 32),
                  StreamBuilder<bool>(
                    stream: player.stream.playing,
                    builder: (_, snap) {
                      final playing = snap.data ?? false;
                      return GestureDetector(
                        onTap: player.playOrPause,
                        child: Container(
                          width: 64, height: 64,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white30, width: 1.5),
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              key: ValueKey(playing),
                              color: Colors.white, size: 36,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 32),
                  _SeekButton(icon: Icons.forward_10, label: '+10s', onTap: onSeekForward),
                  if (onNextEpisode != null) ...[
                    const SizedBox(width: 32),
                    _SeekButton(icon: Icons.skip_next_rounded, label: 'Next', onTap: onNextEpisode!),
                  ],
                ],
              ),

              const Spacer(),

              // ── Bottom bar ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: StreamBuilder<Duration>(
                  stream: player.stream.position,
                  builder: (_, posSnap) {
                    return StreamBuilder<Duration>(
                      stream: player.stream.duration,
                      builder: (_, durSnap) {
                        final pos = posSnap.data ?? Duration.zero;
                        final dur = durSnap.data ?? Duration.zero;
                        final progress = dur.inMilliseconds > 0
                            ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                            : 0.0;
                        final remaining = dur - pos;

                        return Column(
                          children: [
                            // Seekbar with buffered progress underneath
                            Stack(
                              children: [
                                // Buffered bar
                                StreamBuilder<Duration>(
                                  stream: player.stream.buffer,
                                  builder: (_, bufSnap) {
                                    final buf = bufSnap.data ?? Duration.zero;
                                    final bufProgress = dur.inMilliseconds > 0
                                        ? (buf.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                                        : 0.0;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 24),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(2),
                                        child: LinearProgressIndicator(
                                          value: bufProgress,
                                          backgroundColor: Colors.white12,
                                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white24),
                                          minHeight: 3,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                // Seek slider
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.transparent,
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.white24,
                                  ),
                                  child: Slider(
                                    value: progress,
                                    onChanged: (v) {
                                      final newPos = Duration(milliseconds: (v * dur.inMilliseconds).toInt());
                                      player.seek(newPos);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            // Time + controls row
                            Row(
                              children: [
                                Text(_fmt(pos), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                const SizedBox(width: 6),
                                Text('-${_fmt(remaining)}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                const Spacer(),
                                // Settings button
                                _BottomPill(
                                  icon: Icons.settings_rounded,
                                  label: 'SETTINGS',
                                  isActive: false,
                                  onTap: onSettings,
                                ),
                                const SizedBox(width: 6),
                                // Speed pill
                                GestureDetector(
                                  onTap: onCycleSpeed,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: playbackSpeed != 1.0
                                          ? Colors.white.withValues(alpha: 0.2)
                                          : Colors.white.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text('$playbackSpeed×',
                                      style: TextStyle(
                                        color: playbackSpeed != 1.0 ? Colors.white : Colors.white70,
                                        fontSize: 11, fontWeight: FontWeight.w600,
                                      )),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(_fmt(dur), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ─── Small Icon Button for overlay ────────────────────────────────────────────

class _OverlayIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const _OverlayIconBtn({required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white70, size: 20),
        ),
      ),
    );
  }
}

class _SeekButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SeekButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
}

// ─── Bottom Pill Button (Subtitle / Quality / Speed) ──────────────────────────

class _BottomPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _BottomPill({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.deepPurpleAccent.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
          border: isActive
              ? Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.5), width: 0.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isActive ? Colors.deepPurpleAccent : Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(label,
              style: TextStyle(
                color: isActive ? Colors.deepPurpleAccent : Colors.white70,
                fontSize: 10, fontWeight: FontWeight.w600,
              )),
          ],
        ),
      ),
    );
  }
}

// ─── Unified Player Settings Sheet ──────────────────────────────────────────

class _PlayerSettingsSheet extends StatefulWidget {
  final Player player;
  final ExtractedStream? stream;
  final String activeQuality;
  final ValueChanged<QualityOption> onQualitySelect;
  final ValueChanged<dynamic> onSubtitleSelect; // SubtitleTrack or int
  final ValueChanged<AudioTrack> onAudioSelect;
  final dynamic activeSubtitle; // SubtitleTrack or int

  const _PlayerSettingsSheet({
    required this.player,
    required this.stream,
    required this.activeQuality,
    required this.onQualitySelect,
    required this.onSubtitleSelect,
    required this.onAudioSelect,
    required this.activeSubtitle,
  });

  @override
  State<_PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<_PlayerSettingsSheet> {
  String _activeTab = 'Quality';

  static const _langNames = {
    'eng': 'English', 'en': 'English', 'english': 'English',
    'spa': 'Spanish', 'es': 'Spanish', 'spanish': 'Spanish',
    'fre': 'French', 'fr': 'French', 'french': 'French',
    'ger': 'German', 'de': 'German', 'german': 'German',
    'ita': 'Italian', 'it': 'Italian', 'italian': 'Italian',
    'por': 'Portuguese', 'pt': 'Portuguese', 'portuguese': 'Portuguese',
    'rus': 'Russian', 'ru': 'Russian', 'russian': 'Russian',
    'jpn': 'Japanese', 'ja': 'Japanese', 'japanese': 'Japanese',
    'kor': 'Korean', 'ko': 'Korean', 'korean': 'Korean',
    'chi': 'Chinese', 'zh': 'Chinese', 'chinese': 'Chinese',
    'ara': 'Arabic', 'ar': 'Arabic', 'arabic': 'Arabic',
    'hin': 'Hindi', 'hi': 'Hindi', 'hindi': 'Hindi',
  };

  String _formatLang(String? lang) {
    if (lang == null || lang.isEmpty) return 'Unknown';
    return _langNames[lang.toLowerCase()] ?? lang.toUpperCase();
  }

  IconData _qualityIcon(String q) {
    if (q.contains('1080')) return Icons.hd_rounded;
    if (q.contains('720')) return Icons.hd_outlined;
    if (q.contains('480')) return Icons.sd_rounded;
    return Icons.play_circle_outline;
  }

  @override
  Widget build(BuildContext context) {
    final audioTracks = widget.player.state.tracks.audio;
    final embSubTracks = widget.player.state.tracks.subtitle;
    final extSubTracks = widget.stream?.subtitles ?? [];
    final qualities = widget.stream?.qualities ?? [];

    final hasAudio = audioTracks.length > 1; // Only show if more than 1 track (or even if 1 to be safe)
    final hasQualities = qualities.isNotEmpty;
    final hasSubs = embSubTracks.isNotEmpty || extSubTracks.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          // Tabs
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (hasQualities) _TabButton(
                  title: 'Quality',
                  isActive: _activeTab == 'Quality',
                  onTap: () => setState(() => _activeTab = 'Quality'),
                ),
                if (hasAudio) _TabButton(
                  title: 'Audio',
                  isActive: _activeTab == 'Audio',
                  onTap: () => setState(() => _activeTab = 'Audio'),
                ),
                if (hasSubs) _TabButton(
                  title: 'Subtitles',
                  isActive: _activeTab == 'Subtitles',
                  onTap: () => setState(() => _activeTab = 'Subtitles'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Content
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
            child: SingleChildScrollView(
              child: _buildContent(qualities, audioTracks, embSubTracks, extSubTracks),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    List<QualityOption> qualities,
    List<AudioTrack> audioTracks,
    List<SubtitleTrack> embSubTracks,
    List<SubtitleInfo> extSubTracks,
  ) {
    if (_activeTab == 'Quality') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: qualities.map((q) {
          final isActive = q.quality == widget.activeQuality;
          return _ListTile(
            icon: _qualityIcon(q.quality),
            title: q.quality,
            isActive: isActive,
            onTap: () => widget.onQualitySelect(q),
          );
        }).toList(),
      );
    } else if (_activeTab == 'Audio') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: audioTracks.map((t) {
          final isActive = widget.player.state.track.audio == t;
          final title = t.language ?? t.title ?? 'Audio Track ${t.id}';
          return _ListTile(
            icon: Icons.audiotrack_rounded,
            title: _formatLang(title),
            isActive: isActive,
            onTap: () => widget.onAudioSelect(t),
          );
        }).toList(),
      );
    } else {
      // Subtitles
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ListTile(
            icon: Icons.cancel_outlined,
            title: 'Off',
            isActive: widget.activeSubtitle == -1 || widget.activeSubtitle == SubtitleTrack.no() || widget.activeSubtitle == null,
            onTap: () => widget.onSubtitleSelect(-1),
          ),
          if (embSubTracks.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Embedded', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            ...embSubTracks.where((t) => t.id != 'no').map((t) {
              final isActive = widget.activeSubtitle == t;
              final title = t.language ?? t.title ?? 'Subtitle ${t.id}';
              return _ListTile(
                icon: Icons.subtitles_outlined,
                title: _formatLang(title),
                isActive: isActive,
                onTap: () => widget.onSubtitleSelect(t),
              );
            }),
          ],
          if (extSubTracks.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('External', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            ...List.generate(extSubTracks.length, (i) {
              final sub = extSubTracks[i];
              final isActive = widget.activeSubtitle == i;
              return _ListTile(
                icon: Icons.subtitles_outlined,
                title: sub.label.isNotEmpty ? sub.label : _formatLang(sub.lang),
                isActive: isActive,
                onTap: () => widget.onSubtitleSelect(i),
              );
            }),
          ],
        ],
      );
    }
  }
}

class _TabButton extends StatelessWidget {
  final String title;
  final bool isActive;
  final VoidCallback onTap;
  const _TabButton({required this.title, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.deepPurpleAccent : Colors.white12,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(title, style: TextStyle(
          color: isActive ? Colors.white : Colors.white70,
          fontWeight: FontWeight.w600,
        )),
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isActive;
  final VoidCallback onTap;
  const _ListTile({required this.icon, required this.title, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isActive ? Icons.check_circle : icon,
        color: isActive ? Colors.deepPurpleAccent : Colors.white54,
        size: 22,
      ),
      title: Text(title, style: TextStyle(
        color: isActive ? Colors.deepPurpleAccent : Colors.white,
        fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
        fontSize: 15,
      )),
      onTap: onTap,
    );
  }
}
