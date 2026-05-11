import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Extracted stream result
class ExtractedStream {
  final String url;
  final Map<String, String> headers;
  final String providerName;

  const ExtractedStream({
    required this.url,
    required this.headers,
    required this.providerName,
  });

  bool get isHls => url.contains('.m3u8') || url.contains('mpegurl');
  bool get isMp4 => url.contains('.mp4') || url.contains('.mkv');

  @override
  String toString() => 'ExtractedStream($providerName → $url)';
}

// ─── JS: Auto-click play buttons & server selectors ──────────────────────────
const _autoClickJs = r'''
(function() {
  function clickPlay() {
    // Common play button selectors across providers
    var selectors = [
      '.jw-icon-display', // JWPlayer
      '.vjs-big-play-button', // VideoJS  
      '[class*="play"]', 'button[aria-label*="play"]',
      '.plyr__control--overlaid', // Plyr
      'video', // clicking video element triggers play
      '[class*="server"]', '[class*="source"]', // server lists
      '.btn-play', '#play-btn', '.play-btn',
    ];
    for (var i = 0; i < selectors.length; i++) {
      var els = document.querySelectorAll(selectors[i]);
      els.forEach(function(el) {
        try { el.click(); } catch(e) {}
      });
    }
    // Also try to autoplay any video elements
    document.querySelectorAll('video').forEach(function(v) {
      try { v.play(); } catch(e) {}
    });
  }
  // Click immediately, then retry a few times
  setTimeout(clickPlay, 1500);
  setTimeout(clickPlay, 3000);
  setTimeout(clickPlay, 5000);
  setTimeout(clickPlay, 8000);
})();
''';

// ─── JS: Block ads & popups ──────────────────────────────────────────────────
const _adBlockJs = r'''
(function() {
  window.open = function() { return null; };
  window.alert = function() {};
  window.confirm = function() { return true; };
  window.prompt = function() { return null; };
  if (window.Notification) {
    window.Notification.requestPermission = function() {
      return Promise.resolve('denied');
    };
  }
})();
''';

// ─── Stream Extractor Service ─────────────────────────────────────────────────

class StreamExtractorService {
  static const _timeout = Duration(seconds: 15);
  static const _ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  // ── Primary entry: tries API extractors first, then WebView ──

  Future<ExtractedStream?> extractViaWorker({
    required String imdbId,
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
    if (workerUrl.isEmpty) return null;
    try {
      final uri = Uri.parse('$workerUrl/extract').replace(queryParameters: {
        'imdb': imdbId, 'tmdb': tmdbId, 'type': type,
        'season': '$season', 'episode': '$episode',
      });
      final response = await http.get(uri, headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['url'] != null) {
          return ExtractedStream(
            url: data['url'], providerName: data['provider'] ?? 'worker',
            headers: {'User-Agent': _ua, if (data['headers']?['Referer'] != null) 'Referer': data['headers']['Referer']},
          );
        }
      }
    } catch (e) { debugPrint('[Extractor] Worker failed: $e'); }
    return null;
  }

  // ── Single provider WebView extraction ──

  Future<ExtractedStream?> extract({
    required String url,
    required String providerName,
  }) async {
    final completer = Completer<ExtractedStream?>();
    HeadlessInAppWebView? headless;

    final timer = Timer(_timeout, () {
      if (!completer.isCompleted) {
        debugPrint('[Extractor] ⏱ Timeout on $providerName');
        completer.complete(null);
        headless?.dispose();
      }
    });

    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(url),
          headers: {'User-Agent': _ua, 'Referer': url},
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          javaScriptCanOpenWindowsAutomatically: false,
          useShouldInterceptRequest: true,
          supportMultipleWindows: false,
          geolocationEnabled: false,
          // Key: allow mixed content and third-party cookies for provider iframes
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          thirdPartyCookiesEnabled: true,
          // Use desktop UA for better compatibility
          userAgent: _ua,
        ),

        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'onStreamFound',
            callback: (args) {
              if (completer.isCompleted) return;
              final streamUrl = args[0] as String? ?? '';
              if (streamUrl.isEmpty || !_isValidStreamUrl(streamUrl)) return;
              debugPrint('[Extractor] ✅ JS hook found on $providerName: $streamUrl');
              completer.complete(ExtractedStream(
                url: streamUrl,
                headers: {'Referer': url, 'Origin': Uri.parse(url).origin, 'User-Agent': _ua},
                providerName: providerName,
              ));
              headless?.dispose();
            },
          );
        },

        onLoadStart: (controller, _) async {
          await controller.evaluateJavascript(source: _adBlockJs);
          await controller.evaluateJavascript(source: _hookJs);
        },

        onLoadStop: (controller, _) async {
          await controller.evaluateJavascript(source: _hookJs);
          await controller.evaluateJavascript(source: _autoClickJs);
        },

        // Network-level interception — THE critical layer
        shouldInterceptRequest: (controller, request) async {
          if (completer.isCompleted) return null;
          final reqUrl = request.url.toString();
          final u = reqUrl.toLowerCase();

          // Block ad domains
          if (_isAdDomain(u)) {
            return WebResourceResponse(statusCode: 403, reasonPhrase: 'Blocked');
          }

          // Capture stream URLs from network traffic
          if (_isValidStreamUrl(reqUrl)) {
            debugPrint('[Extractor] ✅ Network intercepted on $providerName: $reqUrl');
            if (!completer.isCompleted) {
              completer.complete(ExtractedStream(
                url: reqUrl,
                headers: {'Referer': url, 'Origin': Uri.parse(url).origin, 'User-Agent': _ua},
                providerName: providerName,
              ));
              headless?.dispose();
            }
          }
          return null;
        },

        shouldOverrideUrlLoading: (controller, action) async {
          final navUrl = action.request.url?.toString().toLowerCase() ?? '';
          if (_isAdDomain(navUrl)) return NavigationActionPolicy.CANCEL;
          return NavigationActionPolicy.ALLOW;
        },

        onReceivedError: (controller, request, error) {
          debugPrint('[Extractor] ❌ Load error on $providerName: ${error.type} ${error.description}');
        },
      );

      await headless.run();
      final result = await completer.future;
      timer.cancel();
      return result;
    } catch (e) {
      debugPrint('[Extractor] ❌ Exception on $providerName: $e');
      timer.cancel();
      headless?.dispose();
      return null;
    }
  }

  // ── Parallel batch extraction ──

  Future<ExtractedStream?> extractBestFrom(
    List<(String name, String url)> sources, {
    ValueChanged<String>? onStatusUpdate,
    int concurrency = 3,
  }) async {
    for (int i = 0; i < sources.length; i += concurrency) {
      final batchEnd = (i + concurrency).clamp(0, sources.length);
      final batch = sources.sublist(i, batchEnd);
      final names = batch.map((s) => s.$1).join(', ');
      onStatusUpdate?.call('Trying $names…');
      debugPrint('[Extractor] ── Batch: $names');

      final futures = batch.map((s) => extract(url: s.$2, providerName: s.$1)).toList();
      final results = await Future.wait(futures);

      for (final r in results) {
        if (r != null) {
          debugPrint('[Extractor] ✅ Winner: ${r.providerName}');
          return r;
        }
      }
    }
    return null;
  }

  // ── Validation helpers ──

  bool _isValidStreamUrl(String url) {
    final u = url.toLowerCase();
    if (!u.startsWith('http')) return false;
    final hasStream = u.contains('.m3u8') || u.contains('.mp4') ||
        u.contains('.mkv') || u.contains('.mpd') ||
        u.contains('/hls/') || u.contains('mpegurl');
    if (!hasStream) return false;
    const reject = ['jquery','analytics','tracking','pixel','beacon','thumb','poster','preview','banner','.gif','.png','.jpg','advertisement','cdn.jsdelivr'];
    for (final p in reject) { if (u.contains(p)) return false; }
    if (url.length < 20 || url.length > 2000) return false;
    return true;
  }

  bool _isAdDomain(String url) {
    const ads = ['popads.net','popcash.net','juicyads.com','exoclick.com','trafficjunky.net','adsterra.com','propellerads.com','clickadu.com','hilltopads.com','admaven.co','adskeeper.com','mgid.com','monetag.com','richpush.co','clickaine.com','evadav.com','bidvertiser.com','revcontent.com','googlesyndication.com','doubleclick.net','googleadservices.com','google-analytics.com','facebook.net','adnxs.com','adsrvr.org','outbrain.com','taboola.com','onesignal.com','pushwoosh.com','cleverpush.com','disqus.com','betrad.com','moatads.com','serving-sys.com'];
    for (final d in ads) { if (url.contains(d)) return true; }
    return false;
  }

  static String? getProxyUrl(String streamUrl, String referer) {
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'];
    if (workerUrl == null || workerUrl.isEmpty) return null;
    return '$workerUrl/proxy?url=${Uri.encodeComponent(streamUrl)}&referer=${Uri.encodeComponent(referer)}';
  }
}

// ─── JS hooks: intercept all ways a video URL can be set ─────────────────────
const _hookJs = r'''
(function() {
  var reported = {};
  function report(url, method) {
    if (!url || reported[url]) return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (url.match(/\.(gif|png|jpg|jpeg|svg|ico|css|woff|woff2|ttf|eot|js)(\?|$)/i)) return;
    if (url.length > 2000) return;
    reported[url] = true;
    try { window.flutter_inappwebview.callHandler('onStreamFound', url, method); } catch(e) {}
  }
  function isVid(url) {
    if (!url || typeof url !== 'string') return false;
    var u = url.toLowerCase();
    return u.includes('.m3u8') || u.includes('.mp4') || u.includes('.mkv')
        || u.includes('.mpd') || u.includes('/hls/') || u.includes('mpegurl')
        || u.includes('master.m3u8') || u.includes('index.m3u8')
        || u.includes('/playlist') || u.includes('/stream');
  }
  // Hook src setter
  try {
    var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (d && d.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        set: function(v) { if (isVid(v)) report(v, 'src'); d.set.call(this, v); },
        get: function() { return d.get ? d.get.call(this) : this.getAttribute('src'); },
        configurable: true
      });
    }
  } catch(e) {}
  // Hook setAttribute
  try {
    var origSet = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function(n, v) {
      if (n === 'src' && isVid(v)) report(v, 'attr');
      return origSet.call(this, n, v);
    };
  } catch(e) {}
  // Hook fetch
  try {
    var origFetch = window.fetch;
    window.fetch = function(input) {
      var url = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
      if (isVid(url)) report(url, 'fetch');
      return origFetch.apply(this, arguments);
    };
  } catch(e) {}
  // Hook XHR
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(m, url) {
      if (typeof url === 'string' && isVid(url)) report(url, 'xhr');
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}
  // Hook HLS.js
  try {
    var hInt = setInterval(function() {
      if (window.Hls && window.Hls.prototype.loadSource) {
        var orig = window.Hls.prototype.loadSource;
        window.Hls.prototype.loadSource = function(s) {
          if (s && isVid(s)) report(s, 'hlsjs');
          return orig.apply(this, arguments);
        };
        clearInterval(hInt);
      }
    }, 300);
    setTimeout(function() { clearInterval(hInt); }, 12000);
  } catch(e) {}
  // Poll for video elements
  var pc = 0;
  var pi = setInterval(function() {
    pc++;
    document.querySelectorAll('video').forEach(function(v) {
      if (v.src && isVid(v.src)) report(v.src, 'poll');
      if (v.currentSrc && isVid(v.currentSrc)) report(v.currentSrc, 'poll');
    });
    document.querySelectorAll('source').forEach(function(s) {
      if (s.src && isVid(s.src)) report(s.src, 'poll-src');
    });
    if (pc > 30) clearInterval(pi);
  }, 500);
  // MutationObserver
  try {
    new MutationObserver(function(muts) {
      muts.forEach(function(m) {
        m.addedNodes.forEach(function(n) {
          if (n.nodeType !== 1) return;
          if ((n.tagName === 'VIDEO' || n.tagName === 'SOURCE') && n.src && isVid(n.src)) report(n.src, 'mut');
          try { n.querySelectorAll && n.querySelectorAll('video,source').forEach(function(el) {
            if (el.src && isVid(el.src)) report(el.src, 'mut-child');
          }); } catch(e) {}
        });
      });
    }).observe(document.documentElement, {childList: true, subtree: true});
  } catch(e) {}
})();
''';
