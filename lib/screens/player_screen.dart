import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../providers/providers.dart';
import '../services/subtitle_service.dart';
import '../theme/app_theme.dart';

// ─── Provider Model ───────────────────────────────────────────────────────────

class _P {
  final String name, url;
  final String? tv;
  final bool dash;
  const _P(this.name, this.url, {this.tv, this.dash = false});
}

// ─── Verified providers from jio-to-drive (2026-04-25) ────────────────────────

const _provs = [
  _P('Videasy', 'https://player.videasy.net/{t}/{id}'),
  _P('VidSrc ICU', 'https://vidsrc.icu/embed/{t}/{id}'),
  _P('VidLink', 'https://vidlink.pro/{t}/{id}'),
  _P('VidAPI', 'https://vaplayer.ru/embed/{t}/{id}'),
  _P('2Embed', 'https://www.2embed.cc/embed/{id}',
      tv: 'https://www.2embed.cc/embedtv/{id}?s={s}&e={e}'),
  _P('VidSrc Dev', 'https://vidsrc.dev/embed/{t}/{id}'),
  _P('NonTongo', 'https://nontongo.win/embed/{t}/{id}'),
  _P('VidFast', 'https://vidfast.pro/{t}/{id}'),
  _P('AutoEmbed', 'https://autoembed.co/{t}/tmdb/{id}', dash: true),
  _P('MoviesAPI', 'https://moviesapi.club/{t}/{id}', dash: true),
];

// ─── Ad domain blocklist ──────────────────────────────────────────────────────

const _adDomains = [
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'adnxs.com', 'popads.net', 'popcash.net', 'propellerads.com',
  'exoclick.com', 'trafficjunky.com', 'admaven.com', 'clickadu.com',
  'monetag.com', 'pushame.com', 'juicyads.com', 'adcash.com',
  'mc.yandex.ru', 'clarity.ms', 'googletagmanager.com',
  'facebook.net', 'amazon-adsystem.com', 'outbrain.com', 'taboola.com',
  'richpush.com', 'pushground.com', 'hilltopads.net', 'mgid.com',
  'acint.net', 'betrad.com', 'pubmatic.com', 'bidswitch.net',
];

bool _isAd(String url) {
  final u = url.toLowerCase();
  return _adDomains.any((d) => u.contains(d));
}

// ─── JS injection: ad blocking + popup killing ───────────────────────────────

const _protectionJs = '''
(function(){
  window.open=function(){return null};
  window.alert=function(){};
  window.confirm=function(){return false};
  window.prompt=function(){return null};

  var s=document.createElement('style');
  s.textContent=\`
    .ad,.ads,[class*="popup"],[class*="overlay"],[id*="popup"],[id*="overlay"],
    [class*="banner"],[id*="banner"],div[onclick],[class*="preroll"],
    [class*="adcash"],[id*="adcash"],a[target="_blank"][rel*="noopener"],
    div[style*="z-index: 2147483647"],div[style*="z-index:2147483647"],
    noscript,.adsbygoogle{
      display:none!important;visibility:hidden!important;
      width:0!important;height:0!important;pointer-events:none!important;
      position:absolute!important;z-index:-9999!important;
    }
    body{margin:0!important;padding:0!important;background:#000!important}
  \`;
  document.head.appendChild(s);

  window.ym=function(){};window.gtag=function(){};window.dataLayer=[];
  try{Object.defineProperty(window,'aclib',{value:{runPop:function(){},setup:function(){}},writable:false})}catch(e){}
  try{Object.defineProperty(window,'getAdv',{value:function(){return null},writable:false})}catch(e){}

  document.addEventListener('click',function(e){
    var a=e.target&&e.target.closest?e.target.closest('a'):null;
    if(a&&a.target==='_blank'){e.preventDefault();e.stopImmediatePropagation();}
  },true);

  new MutationObserver(function(ms){ms.forEach(function(m){m.addedNodes.forEach(function(n){
    if(n.nodeType!==1)return;
    var src=(n.src||'').toLowerCase(),cls=(n.className||'').toString().toLowerCase();
    if(n.tagName==='SCRIPT'&&(src.includes('popads')||src.includes('adcash')||src.includes('yandex')||src.includes('clarity.ms'))){n.remove();return}
    if(n.tagName==='IFRAME'&&(src.includes('adcash')||src.includes('doubleclick'))){n.remove();return}
    if(cls.includes('adcash')||cls.includes('popads')){n.remove();return}
    if(n.style&&parseInt(n.style.zIndex)>9000&&n.tagName==='DIV'){
      var r=n.getBoundingClientRect();
      if(r.width>window.innerWidth*0.4&&r.height>window.innerHeight*0.25){n.remove()}
    }
  })})}).observe(document.documentElement,{childList:true,subtree:true});
})();
''';

// ─── Player Screen ────────────────────────────────────────────────────────────

class PlayerScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const PlayerScreen({super.key, required this.args});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  InAppWebViewController? _wv;
  int _provIdx = 0;
  bool _pageLoaded = false;
  bool _hasError = false;
  String _errorMsg = '';
  Timer? _errorTimeout;

  // Subtitle state — used by _showSubtitlePicker and TopBar
  String _subtitleLang = 'en';
  bool _subtitlesEnabled = false;

  bool _hasAdvanced = false;

  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _isPlaying = true;
  String? _seekFeedback;
  Timer? _feedbackTimer;

  // Args — tmdbId is primary, imdbId is fallback
  String get _title => widget.args['title'] as String? ?? 'Untitled';
  String get _type => widget.args['type'] as String? ?? 'movie';
  int get _season => widget.args['season'] as int? ?? 1;
  int get _episode => widget.args['episode'] as int? ?? 1;
  String? get _episodeName => widget.args['episodeName'] as String?;
  String get _id {
    final tmdb = widget.args['tmdbId'];
    if (tmdb != null && tmdb is int && tmdb > 0) return '$tmdb';
    return widget.args['imdbId'] as String? ?? '0';
  }

  void _showControls() {
    if (mounted) setState(() => _controlsVisible = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_controlsVisible) {
      if (mounted) setState(() => _controlsVisible = false);
      _controlsTimer?.cancel();
    } else {
      _showControls();
    }
  }

  void _togglePlayPause() {
    _wv?.evaluateJavascript(source: '''
      (function() {
        const v = document.querySelector('video');
        if (v) {
          if (v.paused) v.play();
          else v.pause();
        }
      })();
    ''');
    _showControls();
  }

  void _seek(int seconds) {
    _wv?.evaluateJavascript(source: '''
      (function() {
        const v = document.querySelector('video');
        if (v) {
          v.currentTime += $seconds;
        }
      })();
    ''');
    _showFeedback(seconds > 0 ? 'forward' : 'backward');
    _showControls();
  }

  void _showFeedback(String type) {
    if (mounted) setState(() => _seekFeedback = type);
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _seekFeedback = null);
    });
  }

  @override
  void initState() {
    super.initState();
    debugPrint('[PlayerScreen] INIT with args: ${widget.args}');
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _showControls();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _errorTimeout?.cancel();
    _controlsTimer?.cancel();
    _feedbackTimer?.cancel();
    super.dispose();
  }

  // ── URL builder ──

  String _buildUrl(_P p) {
    if (_type == 'movie') {
      return p.url.replaceAll('{t}', 'movie').replaceAll('{id}', _id);
    }
    if (p.tv != null) {
      return p.tv!.replaceAll('{id}', _id)
          .replaceAll('{s}', '$_season').replaceAll('{e}', '$_episode');
    }
    var u = p.url.replaceAll('{t}', 'tv').replaceAll('{id}', _id);
    u += p.dash ? '-$_season-$_episode' : '/$_season/$_episode';
    return u;
  }

  // ── Provider navigation ──

  void _loadProvider() {
    final url = _buildUrl(_provs[_provIdx]);
    print('[Player] Loading ${_provs[_provIdx].name}: $url (S$_season E$_episode)');
    setState(() { _pageLoaded = false; _hasError = false; });
    _wv?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    _startErrorTimeout();
  }

  void _next() {
    _provIdx = (_provIdx + 1) % _provs.length;
    _loadProvider();
  }

  void _prev() {
    _provIdx = (_provIdx - 1 + _provs.length) % _provs.length;
    _loadProvider();
  }

  void _startErrorTimeout() {
    _errorTimeout?.cancel();
    _errorTimeout = Timer(const Duration(seconds: 20), () {
      if (!_pageLoaded && mounted) {
        print('[Player] Timeout — auto-switching to next provider');
        _next();
      }
    });
  }

  // ── Subtitle Picker ──

  void _showSubtitlePicker() {
    final imdbId = widget.args['imdbId'] as String? ?? '';
    if (imdbId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No IMDb ID available for subtitle search')));
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SubtitlePicker(
        imdbId: imdbId,
        currentLang: _subtitleLang,
        season: _season,
        episode: _episode,
        type: _type,
        subtitleService: ref.read(subtitleServiceProvider),
        onSelect: (track, lang) async {
          setState(() {
            _subtitleLang = lang;
            _subtitlesEnabled = true;
          });
          // Get download URL and inject via JS
          final subtitleService = ref.read(subtitleServiceProvider);
          final url = await subtitleService.getDownloadUrl(track.fileId);
          if (url != null && _wv != null && mounted) {
            await _wv!.evaluateJavascript(source: '''
              (function() {
                // Remove existing tracks
                document.querySelectorAll('track').forEach(t => t.remove());
                // Try to inject subtitle track into any video element
                const video = document.querySelector('video');
                if (video) {
                  const track = document.createElement('track');
                  track.kind = 'subtitles';
                  track.label = '${subtitleService.languageName(lang)}';
                  track.srclang = '$lang';
                  track.src = '$url';
                  track.default = true;
                  video.appendChild(track);
                  video.textTracks[0].mode = 'showing';
                }
              })();
            ''');
          }
          if (mounted) Navigator.pop(context);
        },
        onDisable: () {
          setState(() => _subtitlesEnabled = false);
          _wv?.evaluateJavascript(source:
              'document.querySelectorAll("track").forEach(t => t.remove());');
          Navigator.pop(context);
        },
      ),
    );
  }

  // ── Episode Auto-Queue ──

  void _advanceEpisode() {
    if (_type != 'tv') return;
    print('[Player] Auto-advancing to S$_season E${_episode + 1}');
    
    // We update the args map so _buildUrl builds the next episode URL.
    widget.args['episode'] = _episode + 1;
    widget.args['episodeName'] = 'Episode ${_episode + 1}';
    
    if (mounted) {
      setState(() {
        _pageLoaded = false;
        _hasAdvanced = false;
        _subtitlesEnabled = false; // reset subs for new episode
      });
    }
    
    _loadProvider();
  }

  void _showProviderPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select Source',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            ..._provs.asMap().entries.map((e) {
              final idx = e.key;
              final p = e.value;
              final selected = idx == _provIdx;
              return ListTile(
                leading: Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected ? Theme.of(context).colorScheme.primary : Colors.white38,
                ),
                title: Text(p.name,
                    style: TextStyle(
                      color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    )),
                onTap: () {
                  Navigator.pop(context);
                  if (idx != _provIdx) {
                    _provIdx = idx;
                    _loadProvider();
                  }
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prov = _provs[_provIdx];
    final initialUrl = _buildUrl(prov);

    return PopScope(
      // Handle Android back button
      canPop: true,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.mediaPlayPause) {
              _togglePlayPause();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowRight) {
              _seek(10);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              _seek(-10);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // ═══════════════════════════════════════════════════════
            // WEBVIEW — full screen, receives ALL touches
            // ═══════════════════════════════════════════════════════
            Positioned.fill(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
                initialSettings: InAppWebViewSettings(
                  // ── Media ──
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  isElementFullscreenEnabled: true,
                  iframeAllowFullscreen: true,

                  // ── Content ──
                  mixedContentMode:
                      MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,  // ← M6: less permissive than ALWAYS_ALLOW
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: false,

                  // ── UI ──
                  supportZoom: false,
                  verticalScrollBarEnabled: false,
                  horizontalScrollBarEnabled: false,
                  disableContextMenu: true,

                  // ── Performance ──
                  hardwareAcceleration: true,
                  useHybridComposition: true,

                  // ── Navigation ──
                  allowsBackForwardNavigationGestures: false,

                  // ── UA ──
                  userAgent:
                      'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/124.0.0.0 Mobile Safari/537.36',
                ),

                onWebViewCreated: (c) {
                  _wv = c;
                  c.addJavaScriptHandler(
                    handlerName: 'video_progress',
                    callback: (args) {
                      if (args.length < 2) return;
                      final currentTime = (args[0] as num).toInt();
                      final duration = (args[1] as num).toInt();
                      if (duration > 0 && currentTime > 0) {
                        // Save progress
                        final history = ref.read(historyServiceProvider);
                        history.saveProgress(
                          imdbId: widget.args['imdbId'] as String? ?? widget.args['tmdbId'].toString(),
                          tmdbId: widget.args['tmdbId'] as int? ?? 0,
                          title: _title,
                          posterPath: widget.args['posterPath'] as String? ?? '',
                          progressSeconds: currentTime,
                          totalSeconds: duration,
                          mediaType: _type,
                          season: _season,
                          episode: _episode,
                          episodeName: _episodeName,
                        );

                        // Auto-advance if >95% finished and it's a TV show
                        if (_type == 'tv' && (currentTime / duration) > 0.95 && !_hasAdvanced) {
                          _hasAdvanced = true; // prevent duplicate fires
                          _advanceEpisode();
                        }
                      }
                    },
                  );
                  c.addJavaScriptHandler(
                    handlerName: 'video_state',
                    callback: (args) {
                      if (args.isEmpty) return;
                      final isPaused = args[0] as bool;
                      if (mounted && _isPlaying == isPaused) {
                        setState(() => _isPlaying = !isPaused);
                      }
                    },
                  );
                  c.addJavaScriptHandler(
                    handlerName: 'single_tap',
                    callback: (_) => _toggleControls(),
                  );
                  c.addJavaScriptHandler(
                    handlerName: 'show_feedback',
                    callback: (args) {
                      if (args.isNotEmpty) _showFeedback(args[0].toString());
                    },
                  );
                },

                onLoadStop: (_, __) async {
                  _errorTimeout?.cancel();
                  if (mounted) setState(() => _pageLoaded = true);
                  try {
                    await _wv?.evaluateJavascript(source: _protectionJs);
                    // Inject progress tracker and event listeners
                    await _wv?.evaluateJavascript(source: '''
                      setInterval(() => {
                        const video = document.querySelector('video');
                        if (video && video.currentTime > 0) {
                          window.flutter_inappwebview.callHandler('video_progress', video.currentTime, video.duration);
                        }
                      }, 5000);
                      
                      let attached = false;
                      setInterval(() => {
                        const video = document.querySelector('video');
                        if (video && !attached) {
                          attached = true;
                          video.addEventListener('play', () => window.flutter_inappwebview.callHandler('video_state', false));
                          video.addEventListener('pause', () => window.flutter_inappwebview.callHandler('video_state', true));
                          window.flutter_inappwebview.callHandler('video_state', video.paused);
                        }
                      }, 1000);
                      
                      let lastTap = 0;
                      document.addEventListener('click', function(e) {
                        let currentTime = new Date().getTime();
                        let tapLength = currentTime - lastTap;
                        if (tapLength < 400 && tapLength > 0) {
                          const video = document.querySelector('video');
                          if (video) {
                            if (e.clientX > window.innerWidth / 2) {
                              video.currentTime += 10;
                              window.flutter_inappwebview.callHandler('show_feedback', 'forward');
                            } else {
                              video.currentTime -= 10;
                              window.flutter_inappwebview.callHandler('show_feedback', 'backward');
                            }
                          }
                          e.preventDefault();
                          lastTap = 0;
                        } else {
                          window.flutter_inappwebview.callHandler('single_tap');
                          lastTap = currentTime;
                        }
                      });
                    ''');
                  } catch (_) {}
                },

                // ── Resource-level ad block ──
                shouldInterceptRequest: (_, req) async {
                  if (_isAd(req.url.toString())) {
                    return WebResourceResponse(
                      contentType: 'text/plain',
                      data: Uint8List(0),
                    );
                  }
                  return null;
                },

                // ── Block popups ──
                onCreateWindow: (_, __) async => false,

                // ── Block ad navigations ──
                shouldOverrideUrlLoading: (_, nav) async {
                  final url = nav.request.url?.toString() ?? '';
                  if (_isAd(url.toLowerCase())) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },

                // ── Error handling: auto-switch provider ──
                onReceivedError: (_, req, err) {
                  if (req.url.toString() == _buildUrl(_provs[_provIdx])) {
                    print('[Player] Error on ${_provs[_provIdx].name}: ${err.description}');
                    if (mounted) {
                      setState(() {
                        _hasError = true;
                        _errorMsg = '${_provs[_provIdx].name} failed. Trying next...';
                      });
                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted && _hasError) _next();
                      });
                    }
                  }
                },

                onReceivedHttpError: (_, req, resp) {
                  if (req.url.toString() == _buildUrl(_provs[_provIdx]) &&
                      (resp.statusCode ?? 0) >= 400) {
                    print('[Player] HTTP ${resp.statusCode} on ${_provs[_provIdx].name}');
                    if (mounted) {
                      setState(() {
                        _hasError = true;
                        _errorMsg = '${_provs[_provIdx].name}: HTTP ${resp.statusCode}';
                      });
                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted && _hasError) _next();
                      });
                    }
                  }
                },

                // ── Fullscreen ──
                onEnterFullscreen: (_) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                },
                onExitFullscreen: (_) {
                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                },
              ),
            ),

            // ═══════════════════════════════════════════════════════
            // LOADING — only shows BEFORE first page load
            // ═══════════════════════════════════════════════════════
            if (!_pageLoaded)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 40, height: 40,
                          child: CircularProgressIndicator(
                            color: Theme.of(context).colorScheme.primary, strokeWidth: 3),
                        ),
                        const SizedBox(height: 20),
                        Text(prov.name,
                            style: const TextStyle(color: Colors.white,
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Text('Loading player...',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7), fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),

            // ═══════════════════════════════════════════════════════
            // ERROR TOAST
            // ═══════════════════════════════════════════════════════
            if (_hasError)
              Positioned(
                bottom: 80, left: 40, right: 40,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_errorMsg,
                        style: const TextStyle(color: Colors.white, fontSize: 13))),
                  ]),
                ),
              ),

            // ═══════════════════════════════════════════════════════
            // TOP BAR — minimal, non-blocking
            // Uses SafeArea + positioned at top, small height
            // ═══════════════════════════════════════════════════════
            // ═══════════════════════════════════════════════════════
            // SEEK FEEDBACK (Double tap)
            // ═══════════════════════════════════════════════════════
            if (_seekFeedback != null)
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: _seekFeedback == 'backward' 
                              ? const LinearGradient(colors: [Colors.white12, Colors.transparent])
                              : null,
                        ),
                        child: _seekFeedback == 'backward' 
                            ? const Icon(Icons.fast_rewind_rounded, color: Colors.white, size: 60)
                            : null,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: _seekFeedback == 'forward' 
                              ? const LinearGradient(colors: [Colors.transparent, Colors.white12])
                              : null,
                        ),
                        child: _seekFeedback == 'forward' 
                            ? const Icon(Icons.fast_forward_rounded, color: Colors.white, size: 60)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),

            // ═══════════════════════════════════════════════════════
            // CENTER PLAY/PAUSE CONTROLS
            // ═══════════════════════════════════════════════════════
            if (_controlsVisible)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: true, // Only the gesture detector handles the tap
                  child: Center(
                    child: IgnorePointer(
                      ignoring: false,
                      child: GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(16),
                          child: Icon(
                            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            Positioned(
              top: 0, left: 0, right: 0,
              child: _TopBar(
                visible: _controlsVisible,
                title: _title,
                type: _type,
                season: _season,
                episode: _episode,
                episodeName: _episodeName,
                provName: prov.name,
                provIndex: _provIdx,
                provTotal: _provs.length,
                subtitlesEnabled: _subtitlesEnabled,
                onBack: () => context.pop(),
                onPrev: _prev,
                onNext: _next,
                onPickSource: _showProviderPicker,
                onSubtitles: _showSubtitlePicker,
              ),
            ),
          ],
        ),
      ),
    ));
  }
}

// ─── Top Bar Widget ───────────────────────────────────────────────────────────
// Header that shows/hides with controls. Uses IgnorePointer when hidden.

class _TopBar extends StatelessWidget {
  final bool visible;
  final String title, type, provName;
  final int season, episode, provIndex, provTotal;
  final String? episodeName;
  final bool subtitlesEnabled;
  final VoidCallback onBack, onPrev, onNext, onPickSource, onSubtitles;

  const _TopBar({
    required this.visible,
    required this.title, required this.type, required this.season,
    required this.episode, this.episodeName, required this.provName,
    required this.provIndex, required this.provTotal,
    required this.subtitlesEnabled,
    required this.onBack, required this.onPrev, required this.onNext,
    required this.onPickSource, required this.onSubtitles,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 4,
            left: 4, right: 4, bottom: 8,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xEE000000), Colors.transparent],
            ),
          ),
          child: Row(children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 20),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  if (type == 'tv')
                    Text(
                      'S${season.toString().padLeft(2, '0')}'
                      'E${episode.toString().padLeft(2, '0')}'
                      '${episodeName != null ? ' — $episodeName' : ''}',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                ],
              ),
            ),
            IconButton(
              onPressed: onPrev,
              icon: const Icon(Icons.skip_previous_rounded,
                  color: Colors.white70, size: 22),
            ),
            GestureDetector(
              onTap: onPickSource,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.5)),
                ),
                child: Text(
                  '${provIndex + 1}/$provTotal  $provName',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            IconButton(
              onPressed: onNext,
              icon: const Icon(Icons.skip_next_rounded,
                  color: Colors.white70, size: 22),
            ),
            // Subtitle toggle button
            IconButton(
              onPressed: onSubtitles,
              tooltip: 'Subtitles',
              icon: Icon(
                Icons.subtitles_rounded,
                color: subtitlesEnabled
                    ? Colors.white
                    : Colors.white38,
                size: 22,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── Subtitle Picker Sheet ────────────────────────────────────────────────────

class _SubtitlePicker extends StatefulWidget {
  final String imdbId, currentLang, type;
  final int season, episode;
  final SubtitleService subtitleService;
  final void Function(SubtitleTrack track, String lang) onSelect;
  final VoidCallback onDisable;

  const _SubtitlePicker({
    required this.imdbId, required this.currentLang, required this.type,
    required this.season, required this.episode,
    required this.subtitleService, required this.onSelect,
    required this.onDisable,
  });

  @override
  State<_SubtitlePicker> createState() => _SubtitlePickerState();
}

class _SubtitlePickerState extends State<_SubtitlePicker> {
  String _lang = 'en';
  bool _loading = false;
  List<SubtitleTrack> _tracks = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _lang = widget.currentLang;
    _search();
  }

  Future<void> _search() async {
    setState(() { _loading = true; _error = null; _tracks = []; });
    try {
      final tracks = await widget.subtitleService.search(
        imdbId: widget.imdbId,
        language: _lang,
        season: widget.type == 'tv' ? widget.season : 0,
        episode: widget.type == 'tv' ? widget.episode : 0,
      );
      if (mounted) setState(() { _tracks = tracks; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              const Text('Subtitles', style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: widget.onDisable,
                child: const Text('Disable', style: TextStyle(color: Colors.white54))),
            ]),
          ),
          // Language scroll row
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: subtitleLanguages.entries.map((e) {
                final selected = e.key == _lang;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(e.value,
                        style: TextStyle(fontSize: 12,
                            color: selected ? Colors.white : Colors.white70)),
                    selected: selected,
                    backgroundColor: const Color(0xFF2a2a4a),
                    selectedColor: Theme.of(context).colorScheme.primary,
                    onSelected: (_) {
                      setState(() => _lang = e.key);
                      _search();
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(color: Colors.white12, height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Colors.white54))
                : _error != null
                    ? Center(child: Text('Error: $_error',
                        style: const TextStyle(color: Colors.white54)))
                    : _tracks.isEmpty
                        ? const Center(child: Text('No subtitles found',
                            style: TextStyle(color: Colors.white54)))
                        : ListView.builder(
                            controller: scroll,
                            itemCount: _tracks.length,
                            itemBuilder: (_, i) {
                              final t = _tracks[i];
                              return ListTile(
                                leading: const Icon(Icons.subtitles_outlined,
                                    color: Colors.white54, size: 20),
                                title: Text(
                                  t.releaseName.isEmpty ? 'Subtitle ${i+1}' : t.releaseName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13)),
                                subtitle: Text(
                                  '${t.downloadCount} downloads · ⭐ ${t.rating.toStringAsFixed(1)}',
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 11)),
                                onTap: () => widget.onSelect(t, _lang),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
