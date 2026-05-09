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

// ─── Ad-blocking CSS/JS injected before provider page loads ──────────────────
//
// This runs BEFORE the provider's own JS, blocking ad scripts from loading
// and hiding overlay elements that trigger "verification" flows.

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
            var dominated = [
              'popads', 'popunder', 'juicyads', 'exoclick', 'trafficjunky',
              'adsterra', 'propellerads', 'clickadu', 'hilltopads',
              'pushnotification', 'admaven', 'adskeeper', 'mgid',
              'monetag', 'richpush', 'clickaine', 'evadav', 'push.js',
              'sw.js', 'service-worker', 'notification', 'push-sdk',
              'adsbygoogle', 'googlesyndication', 'doubleclick',
              'pagead', 'adserver', 'bidvertiser', 'revcontent',
              'disqus.com/embed', 'facebook.net/signals', 'analytics',
            ];
            var lower = (v || '').toLowerCase();
            for (var i = 0; i < dominated.length; i++) {
              if (lower.indexOf(dominated[i]) !== -1) {
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

  // Hide overlay ads via CSS injection
  var style = document.createElement('style');
  style.textContent = [
    '[class*="popup"]', '[class*="overlay"]', '[class*="modal"]',
    '[id*="popup"]', '[id*="overlay"]', '[id*="modal"]',
    '[class*="adblock"]', '[class*="Adblock"]',
    '[class*="verify"]', '[class*="captcha"]',
    'iframe[src*="ads"]', 'iframe[src*="pop"]',
  ].join(',') + '{ display:none !important; pointer-events:none !important; }';
  (document.head || document.documentElement).appendChild(style);
})();
''';

// ─── JavaScript that hooks into every possible way a video URL can be set ─────
//
// The previous approach (shouldInterceptRequest) failed because providers use
// blob: URLs via MediaSource API. Those NEVER appear as network requests.
//
// This JS instead:
// 1. Overrides HTMLMediaElement.prototype.src setter — catches direct src assignment
// 2. Overrides .setAttribute('src', ...) — catches setAttribute-based assignment
// 3. Hooks fetch() and XMLHttpRequest — catches .m3u8 manifest fetches
// 4. Polls every 500ms for <video> and <source> elements with non-blob src
// 5. Reports back to Flutter via window.flutter_inappwebview.callHandler
//

const _extractorJs = r'''
(function() {
  var reported = {};
  function report(url, method) {
    if (!url || reported[url]) return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    // Filter out non-stream URLs (tracking pixels, images, etc.)
    if (url.match(/\.(gif|png|jpg|jpeg|svg|ico|css|woff|woff2|ttf|eot)(\?|$)/i)) return;
    if (url.length > 2000) return; // suspiciously long URLs are usually tracking
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
        || u.includes('mpegurl');
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
      if (isVideo(url)) report(url, 'xhr');
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}

  // ── Hook 5: Poll for <video> and <source> elements ──
  var pollCount = 0;
  var pollId = setInterval(function() {
    pollCount++;
    // Check all video elements
    var videos = document.querySelectorAll('video');
    videos.forEach(function(v) {
      if (v.src && isVideo(v.src)) report(v.src, 'poll-video-src');
      if (v.currentSrc && isVideo(v.currentSrc)) report(v.currentSrc, 'poll-video-currentSrc');
    });
    // Check all source elements
    var sources = document.querySelectorAll('source');
    sources.forEach(function(s) {
      if (s.src && isVideo(s.src)) report(s.src, 'poll-source');
    });
    // Check iframes recursively for video elements
    try {
      var iframes = document.querySelectorAll('iframe');
      iframes.forEach(function(iframe) {
        try {
          var idoc = iframe.contentDocument || iframe.contentWindow.document;
          if (!idoc) return;
          idoc.querySelectorAll('video').forEach(function(v) {
            if (v.src && isVideo(v.src)) report(v.src, 'iframe-video-src');
            if (v.currentSrc && isVideo(v.currentSrc)) report(v.currentSrc, 'iframe-video-currentSrc');
          });
          idoc.querySelectorAll('source').forEach(function(s) {
            if (s.src && isVideo(s.src)) report(s.src, 'iframe-source');
          });
        } catch(e) { /* cross-origin, skip */ }
      });
    } catch(e) {}
    if (pollCount > 60) clearInterval(pollId); // stop after 30s
  }, 500);

  // ── Hook 6: MutationObserver for dynamically added video elements ──
  try {
    new MutationObserver(function(mutations) {
      mutations.forEach(function(m) {
        m.addedNodes.forEach(function(node) {
          if (node.nodeType !== 1) return;
          if (node.tagName === 'VIDEO') {
            if (node.src && isVideo(node.src)) report(node.src, 'mutation-video');
            if (node.currentSrc && isVideo(node.currentSrc)) report(node.currentSrc, 'mutation-video-current');
          }
          if (node.tagName === 'SOURCE') {
            if (node.src && isVideo(node.src)) report(node.src, 'mutation-source');
          }
          // Check children
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
})();
''';

// ─── Stream Extractor Service ─────────────────────────────────────────────────

/// Loads an embed page in a [HeadlessInAppWebView] and injects JavaScript
/// hooks that monitor every way a video URL can be set in the DOM.
///
/// Architecture (from the M3U8/HLS research):
/// - Providers use obfuscated JS to resolve stream URLs
/// - The JS runs in the WebView, resolving the m3u8 URL
/// - Our hooks intercept the URL at the moment it's assigned
/// - media_kit (mpv/ffmpeg) handles HLS playback natively
///
/// This approach is necessary because:
/// - Providers don't put m3u8 URLs in their initial HTML
/// - Server-side fetch + regex returns nothing useful
/// - The m3u8 URL is only resolved after JS execution
class StreamExtractorService {
  static const _timeout = Duration(seconds: 18);

  final List<String> _userAgents = [
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15',
  ];

  /// Primary extraction: Worker API → WebView fallback.
  /// Call this for direct URL extraction from a single provider.
  Future<ExtractedStream?> extract({
    required String url,
    required String providerName,
  }) async {
    // Headless WebView Extraction with ad-blocking + JS hooks
    // Try with 2 different user agents if first fails
    for (int i = 0; i < 2; i++) {
      final stream = await _extractWithUa(
        url,
        providerName,
        _userAgents[i % _userAgents.length],
      );
      if (stream != null) return stream;
    }
    return null;
  }

  /// Worker-first extraction: calls /extract API with media identifiers.
  /// This is the preferred entry point — faster than WebView extraction.
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
      }).timeout(const Duration(seconds: 8));

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
          // Allow cross-origin iframe access where possible
          javaScriptCanOpenWindowsAutomatically: false,
          useShouldInterceptRequest: true,
          // Block popups and new windows (ad redirects)
          supportMultipleWindows: false,
          // Disable geolocation (used by some verification flows)
          geolocationEnabled: false,
        ),

        onWebViewCreated: (controller) {
          // Register the handler that the injected JS calls
          controller.addJavaScriptHandler(
            handlerName: 'onStreamFound',
            callback: (args) {
              if (completer.isCompleted) return;
              final streamUrl = args[0] as String? ?? '';
              final method = args.length > 1 ? args[1] as String : 'unknown';

              if (streamUrl.isEmpty) return;

              // Validate the URL looks like a real stream
              if (!_isValidStreamUrl(streamUrl)) {
                debugPrint(
                    '[Extractor] ⚠ Rejected suspicious URL via $method: $streamUrl');
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

        // Also intercept network requests as a secondary detection layer
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

        onLoadError: (_, __, code, msg) {
          debugPrint(
              '[Extractor] ❌ Load error on $providerName: $code $msg');
          // Don't complete on load error — some providers trigger errors but
          // still load video content in sub-frames
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

  /// Try sources sequentially (not batched — one headless webview at a time
  /// is more reliable on low-memory devices).
  Future<ExtractedStream?> extractBestFrom(
    List<(String name, String url)> sources, {
    ValueChanged<String>? onStatusUpdate,
  }) async {
    for (int i = 0; i < sources.length; i++) {
      final source = sources[i];
      final status = 'Trying ${source.$1}… (${i + 1}/${sources.length})';
      debugPrint('[Extractor] ── $status');
      onStatusUpdate?.call(status);

      final result = await extract(url: source.$2, providerName: source.$1);
      if (result != null) return result;
    }
    return null;
  }

  /// Validate that a URL actually looks like a video stream
  /// and not a tracking pixel or ad redirect.
  bool _isValidStreamUrl(String url) {
    final u = url.toLowerCase();

    // Must be HTTP(S)
    if (!u.startsWith('http://') && !u.startsWith('https://')) return false;

    // Must contain a stream indicator
    final hasStreamIndicator = u.contains('.m3u8') ||
        u.contains('.mp4') ||
        u.contains('.mkv') ||
        u.contains('.mpd') ||
        u.contains('/hls/') ||
        u.contains('mpegurl');

    if (!hasStreamIndicator) return false;

    // Reject known non-stream URLs
    final rejectPatterns = [
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

    // URL shouldn't be suspiciously short (tracking redirect) or long
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
      'pushnotification',
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
  /// Uses the Cloudflare Worker's /proxy endpoint.
  static String? getProxyUrl(String streamUrl, String referer) {
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'];
    if (workerUrl == null || workerUrl.isEmpty) return null;

    return '$workerUrl/proxy?url=${Uri.encodeComponent(streamUrl)}&referer=${Uri.encodeComponent(referer)}';
  }
}
