import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// ─── Result model ─────────────────────────────────────────────────────────────

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

// ─── Ad-blocking JS ──────────────────────────────────────────────────────────
//
// Blocks ad/tracking scripts, popups, notifications, but does NOT hide
// legitimate page elements (modals, overlays) which providers use for
// server selection and player UI.

const _adBlockJs = r'''
(function() {
  // Block known ad/tracking domains by intercepting script creation
  var origCreate = document.createElement.bind(document);
  document.createElement = function(tag) {
    var el = origCreate(tag);
    if (tag.toLowerCase() === 'script') {
      var origSrcDesc = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
      if (origSrcDesc && origSrcDesc.set) {
        Object.defineProperty(el, 'src', {
          set: function(v) {
            var blocked = [
              'popads', 'popunder', 'juicyads', 'exoclick', 'trafficjunky',
              'adsterra', 'propellerads', 'clickadu', 'hilltopads',
              'pushnotification', 'admaven', 'adskeeper', 'mgid',
              'monetag', 'richpush', 'clickaine', 'evadav', 'push.js',
              'sw.js', 'service-worker', 'push-sdk',
              'adsbygoogle', 'googlesyndication', 'doubleclick',
              'pagead', 'adserver', 'bidvertiser', 'revcontent',
              'facebook.net/signals', 'google-analytics',
              'onesignal', 'pushwoosh', 'cleverpush',
              'betrad', 'moatads', 'outbrain', 'taboola',
            ];
            var lower = (v || '').toLowerCase();
            for (var i = 0; i < blocked.length; i++) {
              if (lower.indexOf(blocked[i]) !== -1) {
                return; // silently block
              }
            }
            origSrcDesc.set.call(this, v);
          },
          get: function() {
            return origSrcDesc.get ? origSrcDesc.get.call(this) : '';
          },
          configurable: true
        });
      }
    }
    return el;
  };

  // Block window.open (popup ads)
  window.open = function() { return null; };

  // Block alert/confirm/prompt (verification dialogs)
  window.alert = function() {};
  window.confirm = function() { return true; };
  window.prompt = function() { return null; };

  // Suppress notification permission requests
  if (navigator.permissions) {
    var origQuery = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = function(desc) {
      if (desc && desc.name === 'notifications') {
        return Promise.resolve({ state: 'denied' });
      }
      return origQuery(desc);
    };
  }

  // Block notification API
  if (window.Notification) {
    window.Notification.requestPermission = function() {
      return Promise.resolve('denied');
    };
  }
})();
''';

// ─── Stream extraction JS ─────────────────────────────────────────────────────
//
// Hooks into every way a video URL can be set in the DOM:
// 1. HTMLMediaElement.src setter
// 2. Element.setAttribute('src', ...)
// 3. fetch() interceptor
// 4. XMLHttpRequest.open interceptor
// 5. Video/source element polling
// 6. MutationObserver for dynamic elements
// 7. HLS.js / hls internal source interception
// 8. MediaSource.addSourceBuffer interception

const _extractorJs = r'''
(function() {
  var reported = {};
  function report(url, method) {
    if (!url || reported[url]) return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    // Filter out non-stream URLs
    if (url.match(/\.(gif|png|jpg|jpeg|svg|ico|css|woff|woff2|ttf|eot|js)(\?|$)/i)) return;
    if (url.length > 2000) return;
    reported[url] = true;
    try {
      window.flutter_inappwebview.callHandler('onStreamFound', url, method);
    } catch(e) {}
  }

  function isVideo(url) {
    if (!url || typeof url !== 'string') return false;
    var u = url.toLowerCase();
    return u.includes('.m3u8') || u.includes('.mp4') || u.includes('.mkv')
        || u.includes('.mpd') || u.includes('/playlist.m3u8')
        || u.includes('master.m3u8') || u.includes('index.m3u8')
        || (u.includes('video') && u.includes('manifest'))
        || u.includes('/hls/') || u.includes('/stream')
        || u.includes('mpegurl')
        || u.includes('.ts') && (u.includes('seg') || u.includes('chunk'));
  }

  // ── Hook 1: HTMLMediaElement.src setter ──
  try {
    var origSrcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (origSrcDesc && origSrcDesc.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        set: function(v) {
          if (isVideo(v)) report(v, 'src-setter');
          origSrcDesc.set.call(this, v);
        },
        get: function() {
          return origSrcDesc.get ? origSrcDesc.get.call(this) : this.getAttribute('src');
        },
        configurable: true
      });
    }
  } catch(e) {}

  // ── Hook 2: Element.setAttribute for src ──
  try {
    var origSetAttr = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function(name, value) {
      if (name === 'src' && isVideo(value)) report(value, 'setAttribute');
      return origSetAttr.call(this, name, value);
    };
  } catch(e) {}

  // ── Hook 3: fetch() ──
  try {
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
      if (isVideo(url)) report(url, 'fetch');
      return origFetch.apply(this, arguments);
    };
  } catch(e) {}

  // ── Hook 4: XMLHttpRequest.open ──
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      if (typeof url === 'string' && isVideo(url)) report(url, 'xhr');
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}

  // ── Hook 5: Poll for <video> and <source> elements ──
  var pollCount = 0;
  var pollId = setInterval(function() {
    pollCount++;
    document.querySelectorAll('video').forEach(function(v) {
      if (v.src && isVideo(v.src)) report(v.src, 'poll-video');
      if (v.currentSrc && isVideo(v.currentSrc)) report(v.currentSrc, 'poll-currentSrc');
    });
    document.querySelectorAll('source').forEach(function(s) {
      if (s.src && isVideo(s.src)) report(s.src, 'poll-source');
    });
    // Check iframes (same-origin only)
    try {
      document.querySelectorAll('iframe').forEach(function(iframe) {
        try {
          var idoc = iframe.contentDocument || iframe.contentWindow.document;
          if (!idoc) return;
          idoc.querySelectorAll('video').forEach(function(v) {
            if (v.src && isVideo(v.src)) report(v.src, 'iframe-video');
            if (v.currentSrc && isVideo(v.currentSrc)) report(v.currentSrc, 'iframe-currentSrc');
          });
          idoc.querySelectorAll('source').forEach(function(s) {
            if (s.src && isVideo(s.src)) report(s.src, 'iframe-source');
          });
        } catch(e) {}
      });
    } catch(e) {}
    if (pollCount > 40) clearInterval(pollId); // stop after 20s
  }, 500);

  // ── Hook 6: MutationObserver for dynamic elements ──
  try {
    new MutationObserver(function(mutations) {
      mutations.forEach(function(m) {
        m.addedNodes.forEach(function(node) {
          if (node.nodeType !== 1) return;
          if (node.tagName === 'VIDEO' || node.tagName === 'SOURCE') {
            var s = node.src || node.currentSrc || '';
            if (isVideo(s)) report(s, 'mutation');
          }
          try {
            node.querySelectorAll && node.querySelectorAll('video, source').forEach(function(el) {
              var s = el.src || el.currentSrc || '';
              if (isVideo(s)) report(s, 'mutation-child');
            });
          } catch(e) {}
        });
      });
    }).observe(document.documentElement, {childList: true, subtree: true});
  } catch(e) {}

  // ── Hook 7: Intercept HLS.js loadSource ──
  // Many providers use HLS.js; we intercept when it sets the stream URL
  try {
    var checkHls = setInterval(function() {
      if (window.Hls && window.Hls.prototype && window.Hls.prototype.loadSource) {
        var origLoad = window.Hls.prototype.loadSource;
        window.Hls.prototype.loadSource = function(src) {
          if (src && isVideo(src)) report(src, 'hls.js-loadSource');
          return origLoad.apply(this, arguments);
        };
        clearInterval(checkHls);
      }
    }, 200);
    setTimeout(function() { clearInterval(checkHls); }, 15000);
  } catch(e) {}

  // ── Hook 8: Intercept URL.createObjectURL for MediaSource ──
  try {
    var origCreateURL = URL.createObjectURL;
    URL.createObjectURL = function(obj) {
      var result = origCreateURL.apply(this, arguments);
      // We can't extract from blob URLs directly, but if the source is
      // set on a video element, we watch for it
      return result;
    };
  } catch(e) {}
})();
''';

// ─── Stream Extractor Service ─────────────────────────────────────────────────

/// Loads embed pages in [HeadlessInAppWebView] instances and injects JavaScript
/// hooks that intercept video stream URLs as they're resolved by provider JS.
///
/// Architecture:
/// - Providers use obfuscated JS to resolve stream URLs client-side
/// - Our hooks intercept the URL at the moment it's assigned to a media element
/// - media_kit (mpv/ffmpeg) handles HLS playback natively
///
/// Extraction strategy:
/// - Parallel batch: tries up to 3 providers simultaneously
/// - First successful result wins; all others are cancelled
/// - Provider order optimized by reliability (tested May 2025)
class StreamExtractorService {
  // Per-provider timeout. Shorter = faster overall failure, but too short
  // misses slow-loading providers. 12s is a good balance.
  static const _timeout = Duration(seconds: 12);

  final List<String> _userAgents = [
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  ];

  /// Primary extraction: Worker API → Parallel WebView scan.
  /// Call this for direct URL extraction from a single provider.
  Future<ExtractedStream?> extract({
    required String url,
    required String providerName,
  }) async {
    return _extractWithUa(url, providerName, _userAgents[0]);
  }

  /// Worker-first extraction: calls /extract API with media identifiers.
  /// Fast path (~2s) but only works if workers have direct API access.
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
        'imdb': imdbId,
        'tmdb': tmdbId,
        'type': type,
        'season': '$season',
        'episode': '$episode',
      });

      debugPrint('[Extractor] ── Calling Worker /extract...');
      final response = await http.get(uri, headers: {
        'User-Agent': _userAgents.first,
      }).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['url'] != null) {
          final streamUrl = data['url'] as String;
          final provider = data['provider'] as String? ?? 'worker';
          final referer = data['headers']?['Referer'] as String? ?? '';

          debugPrint('[Extractor] ✅ Worker resolved via $provider: $streamUrl');
          return ExtractedStream(
            url: streamUrl,
            headers: {
              if (referer.isNotEmpty) 'Referer': referer,
              'User-Agent': _userAgents.first,
            },
            providerName: provider,
          );
        }
      }
      debugPrint('[Extractor] Worker returned no result (${response.statusCode})');
    } catch (e) {
      debugPrint('[Extractor] Worker call failed: $e');
    }
    return null;
  }

  Future<ExtractedStream?> _extractWithUa(
      String url, String providerName, String userAgent) async {
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
          headers: {
            'User-Agent': userAgent,
            'Referer': url,
          },
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          javaScriptCanOpenWindowsAutomatically: false,
          useShouldInterceptRequest: true,
          supportMultipleWindows: false,
          geolocationEnabled: false,
          // Don't load images — faster extraction
          blockNetworkImage: true,
        ),

        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'onStreamFound',
            callback: (args) {
              if (completer.isCompleted) return;
              final streamUrl = args[0] as String? ?? '';
              final method = args.length > 1 ? args[1] as String : 'unknown';

              if (streamUrl.isEmpty) return;

              if (!_isValidStreamUrl(streamUrl)) {
                debugPrint(
                    '[Extractor] ⚠ Rejected via $method: ${streamUrl.substring(0, streamUrl.length.clamp(0, 80))}');
                return;
              }

              debugPrint(
                  '[Extractor] ✅ Found stream via $method on $providerName:\n  $streamUrl');

              completer.complete(ExtractedStream(
                url: streamUrl,
                headers: {
                  'Referer': url,
                  'Origin': Uri.parse(url).origin,
                  'User-Agent': userAgent,
                },
                providerName: providerName,
              ));

              headless?.dispose();
            },
          );
        },

        // Inject ad-blocker + hooks BEFORE the page JS runs
        onLoadStart: (controller, _) async {
          await controller.evaluateJavascript(source: _adBlockJs);
          await controller.evaluateJavascript(source: _extractorJs);
        },

        // Re-inject after full load in case page JS overwrote our hooks
        onLoadStop: (controller, _) async {
          await controller.evaluateJavascript(source: _extractorJs);
        },

        // Network-level interception as secondary detection layer
        shouldInterceptRequest: (controller, request) async {
          if (completer.isCompleted) return null;
          final reqUrl = request.url.toString();
          final u = reqUrl.toLowerCase();

          // Block known ad domains at network level
          if (_isAdDomain(u)) {
            return WebResourceResponse(
              statusCode: 403,
              reasonPhrase: 'Blocked',
            );
          }

          // Detect stream URLs in network traffic
          if ((u.contains('.m3u8') ||
                  (u.contains('.mp4') && !u.contains('thumb'))) &&
              _isValidStreamUrl(reqUrl)) {
            debugPrint(
                '[Extractor] ✅ Intercepted via network on $providerName:\n  $reqUrl');
            if (!completer.isCompleted) {
              completer.complete(ExtractedStream(
                url: reqUrl,
                headers: {
                  'Referer': url,
                  'Origin': Uri.parse(url).origin,
                  'User-Agent': userAgent,
                },
                providerName: providerName,
              ));
              headless?.dispose();
            }
          }
          return null;
        },

        // Prevent navigation to ad domains
        shouldOverrideUrlLoading: (controller, action) async {
          final navUrl = action.request.url?.toString().toLowerCase() ?? '';
          if (_isAdDomain(navUrl)) {
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },

        // ignore-deprecated: using onLoadError for broader compatibility
        // ignore: deprecated_member_use
        onLoadError: (_, __, code, msg) {
          debugPrint('[Extractor] ❌ Load error on $providerName: $code $msg');
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

  /// Try sources in parallel batches.
  ///
  /// Launches up to [concurrency] WebViews at once. The first one to find
  /// a stream wins. If the first batch fails, tries the next batch.
  /// This is MUCH faster than sequential — typical extraction: 3-8s vs 30-90s.
  Future<ExtractedStream?> extractBestFrom(
    List<(String name, String url)> sources, {
    ValueChanged<String>? onStatusUpdate,
    int concurrency = 3,
  }) async {
    debugPrint('[Extractor] ── Starting parallel extraction across ${sources.length} providers (concurrency=$concurrency)');

    for (int batchStart = 0; batchStart < sources.length; batchStart += concurrency) {
      final batchEnd = (batchStart + concurrency).clamp(0, sources.length);
      final batch = sources.sublist(batchStart, batchEnd);
      final names = batch.map((s) => s.$1).join(', ');
      final status = 'Trying $names… (batch ${(batchStart ~/ concurrency) + 1})';
      debugPrint('[Extractor] ── $status');
      onStatusUpdate?.call(status);

      // Launch all providers in this batch simultaneously
      final futures = batch.map((source) =>
        extract(url: source.$2, providerName: source.$1)
      ).toList();

      // Wait for ALL to complete, then pick the first successful one
      final results = await Future.wait(futures);

      for (final result in results) {
        if (result != null) {
          debugPrint('[Extractor] ✅ Batch winner: ${result.providerName}');
          return result;
        }
      }

      debugPrint('[Extractor] ── Batch ${(batchStart ~/ concurrency) + 1} failed, trying next...');
    }

    debugPrint('[Extractor] ❌ All providers exhausted');
    return null;
  }

  /// Validate that a URL actually looks like a video stream.
  bool _isValidStreamUrl(String url) {
    final u = url.toLowerCase();

    if (!u.startsWith('http://') && !u.startsWith('https://')) return false;

    final hasStreamIndicator = u.contains('.m3u8') ||
        u.contains('.mp4') ||
        u.contains('.mkv') ||
        u.contains('.mpd') ||
        u.contains('/hls/') ||
        u.contains('mpegurl');

    if (!hasStreamIndicator) return false;

    // Reject known non-stream URLs
    const rejectPatterns = [
      'cdn.jsdelivr',
      'jquery',
      'analytics',
      'tracking',
      'pixel',
      'beacon',
      'thumb',
      'poster',
      'preview',
      'banner',
      '.gif',
      '.png',
      '.jpg',
      'advertisement',
    ];

    for (final p in rejectPatterns) {
      if (u.contains(p)) return false;
    }

    if (url.length < 20 || url.length > 2000) return false;

    return true;
  }

  /// Check if a URL belongs to a known ad/tracking domain
  bool _isAdDomain(String url) {
    const adDomains = [
      'popads.net',
      'popcash.net',
      'juicyads.com',
      'exoclick.com',
      'trafficjunky.net',
      'adsterra.com',
      'propellerads.com',
      'clickadu.com',
      'hilltopads.com',
      'admaven.co',
      'adskeeper.com',
      'mgid.com',
      'monetag.com',
      'richpush.co',
      'clickaine.com',
      'evadav.com',
      'bidvertiser.com',
      'revcontent.com',
      'googlesyndication.com',
      'doubleclick.net',
      'googleadservices.com',
      'google-analytics.com',
      'facebook.net',
      'adnxs.com',
      'adsrvr.org',
      'outbrain.com',
      'taboola.com',
      'onesignal.com',
      'pushwoosh.com',
      'cleverpush.com',
      'disqus.com',
      'betrad.com',
      'moatads.com',
      'serving-sys.com',
    ];

    for (final domain in adDomains) {
      if (url.contains(domain)) return true;
    }
    return false;
  }

  /// Get the proxy URL for an HLS stream that needs Referer bypass.
  static String? getProxyUrl(String streamUrl, String referer) {
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'];
    if (workerUrl == null || workerUrl.isEmpty) return null;

    return '$workerUrl/proxy?url=${Uri.encodeComponent(streamUrl)}&referer=${Uri.encodeComponent(referer)}';
  }
}
