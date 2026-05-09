import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../providers/providers.dart';
import '../services/stream_extractor_service.dart';

// ─── Embed providers to try (ordered by reliability) ─────────────────────────

List<(String, String)> _buildSourceList(
    String type, String imdbId, String tmdbId, int season, int episode) {
  final tvSources = [
    ('VidSrc.me', 'https://vidsrc.me/embed/tv?imdb=$imdbId&season=$season&episode=$episode'),
    ('Videasy', 'https://player.videasy.net/tv/$imdbId/$season/$episode'),
    ('VidAPI', 'https://vaplayer.ru/embed/tv/$imdbId/$season/$episode'),
    ('VidLink', 'https://vidlink.pro/tv/$tmdbId/$season/$episode'),
    ('VidSrc ICU', 'https://vidsrc.icu/embed/tv/$imdbId/$season/$episode'),
    ('VidSrc Dev', 'https://vidsrc.dev/embed/tv/$imdbId/$season/$episode'),
    ('VidFast', 'https://vidfast.pro/tv/$imdbId/$season/$episode'),
    ('AutoEmbed', 'https://autoembed.co/tv/tmdb/$tmdbId-$season-$episode'),
  ];
  final movieSources = [
    ('VidSrc.me', 'https://vidsrc.me/embed/movie?imdb=$imdbId'),
    ('Videasy', 'https://player.videasy.net/movie/$imdbId'),
    ('VidAPI', 'https://vaplayer.ru/embed/movie/$imdbId'),
    ('VidLink', 'https://vidlink.pro/movie/$tmdbId'),
    ('VidSrc ICU', 'https://vidsrc.icu/embed/movie/$imdbId'),
    ('VidSrc Dev', 'https://vidsrc.dev/embed/movie/$imdbId'),
    ('VidFast', 'https://vidfast.pro/movie/$imdbId'),
    ('AutoEmbed', 'https://autoembed.co/movie/tmdb/$tmdbId'),
  ];
  return type == 'tv' ? tvSources : movieSources;
}

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
  int? _seekDirection; // -1 = left, 1 = right, null = none
  Timer? _seekAnimTimer;

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
    _player.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Extraction ──

  Future<void> _startExtraction() async {
    setState(() {
      _state = _ExState.extracting;
      _statusMsg = 'Scanning providers…';
      _providerBadge = '';
      _hasAdvanced = false;
    });

    final sources = _buildSourceList(_type, _imdbId, _tmdbId, _season, _episode);
    debugPrint('[NativePlayer] type=$_type imdbId=$_imdbId tmdbId=$_tmdbId S$_season E$_episode');

    final stream = await _extractor.extractBestFrom(
      sources,
      onStatusUpdate: (status) {
        if (mounted) setState(() => _statusMsg = status);
      },
    );

    if (!mounted) return;

    if (stream == null) {
      setState(() {
        _state = _ExState.failed;
        _failedMsg = 'Could not extract stream from any provider.\nTap Retry to try again.';
      });
      return;
    }

    setState(() {
      _state = _ExState.playing;
      _statusMsg = 'Playing via ${stream.providerName}';
      _providerBadge = stream.providerName;
    });

    await _player.open(Media(
      stream.url,
      httpHeaders: stream.headers,
    ));

    // Track progress for history + auto-advance
    _player.stream.position.listen(_onPositionChanged);
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
            onTap: _toggleControls,
            onDoubleTapDown: (d) {
              final half = MediaQuery.of(context).size.width / 2;
              final isLeft = d.globalPosition.dx < half;
              _seek(isLeft ? -10 : 10);
              _showSeekAnimation(isLeft ? -1 : 1);
            },
            child: Stack(
              children: [
                // ── Video surface ──
                Positioned.fill(
                  child: _state == _ExState.playing
                      ? Video(controller: _controller)
                      : const SizedBox.shrink(),
                ),

                // ── Buffering spinner ──
                if (_isBuffering && _state == _ExState.playing)
                  const Center(
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        color: Colors.white70,
                        strokeWidth: 2.5,
                      ),
                    ),
                  ),

                // ── Double-tap seek animation ──
                if (_seekDirection != null)
                  Positioned(
                    left: _seekDirection == -1 ? 40 : null,
                    right: _seekDirection == 1 ? 40 : null,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(40),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _seekDirection == -1 ? Icons.fast_rewind : Icons.fast_forward,
                                color: Colors.white,
                                size: 28,
                              ),
                              const SizedBox(width: 6),
                              const Text('10s',
                                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
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
                      message: _state == _ExState.failed
                          ? (_failedMsg ?? 'Unknown error')
                          : _statusMsg,
                      onRetry: _state == _ExState.failed ? _startExtraction : null,
                    ),
                  ),

                // ── Controls overlay ──
                if (_state == _ExState.playing && _controlsVisible)
                  _ControlsOverlay(
                    title: _title,
                    type: _type,
                    season: _season,
                    episode: _episode,
                    providerName: _providerBadge,
                    player: _player,
                    onBack: () => Navigator.pop(context),
                    onSeekBack: () {
                      _seek(-10);
                      _showSeekAnimation(-1);
                    },
                    onSeekForward: () {
                      _seek(10);
                      _showSeekAnimation(1);
                    },
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
                  style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
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
  final VoidCallback onBack;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;

  const _ControlsOverlay({
    required this.title,
    required this.type,
    required this.season,
    required this.episode,
    required this.providerName,
    required this.player,
    required this.onBack,
    required this.onSeekBack,
    required this.onSeekForward,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC000000),
            Colors.transparent,
            Colors.transparent,
            Color(0xCC000000),
          ],
          stops: [0, 0.25, 0.75, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        if (type == 'tv')
                          Text(
                              'S${season.toString().padLeft(2, '0')} · E${episode.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  // Provider badge
                  if (providerName.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.deepPurpleAccent.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.deepPurpleAccent.withOpacity(0.5)),
                      ),
                      child: Text(providerName.toUpperCase(),
                          style: const TextStyle(
                              color: Colors.deepPurpleAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8)),
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
                const SizedBox(width: 40),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  builder: (_, snap) {
                    final playing = snap.data ?? false;
                    return GestureDetector(
                      onTap: player.playOrPause,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white30, width: 1.5),
                        ),
                        child: Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 40),
                _SeekButton(icon: Icons.forward_10, label: '+10s', onTap: onSeekForward),
              ],
            ),

            const Spacer(),

            // ── Seek bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: StreamBuilder<Duration>(
                stream: player.stream.position,
                builder: (_, posSnap) {
                  return StreamBuilder<Duration>(
                    stream: player.stream.duration,
                    builder: (_, durSnap) {
                      final pos = posSnap.data ?? Duration.zero;
                      final dur = durSnap.data ?? Duration.zero;
                      final progress = dur.inMilliseconds > 0
                          ? pos.inMilliseconds / dur.inMilliseconds
                          : 0.0;

                      return Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white24,
                            ),
                            child: Slider(
                              value: progress.clamp(0.0, 1.0),
                              onChanged: (v) {
                                final newPos = Duration(
                                    milliseconds: (v * dur.inMilliseconds).toInt());
                                player.seek(newPos);
                              },
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(pos),
                                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              Text(_fmt(dur),
                                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
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
          Icon(icon, color: Colors.white, size: 36),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
}
