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
        || u.includes('/hls/') || u.includes('/stream');
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
/// hooks that monitor every way a video URL can be set in the DOM:
/// - HTMLMediaElement.src setter override
/// - Element.setAttribute override
/// - fetch() / XMLHttpRequest.open interception
/// - Polling <video>/<source> elements every 500ms
/// - MutationObserver for dynamically added elements
///
/// When a video URL is detected, it's sent back to Flutter via a JS handler.
class StreamExtractorService {
  static const _timeout = Duration(seconds: 25);

  final List<String> _userAgents = [
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15',
  ];

  Future<ExtractedStream?> extract({
    required String url,
    required String providerName,
  }) async {
    // 1. Cloudflare Worker Reverse Proxy Bypass
    // Add your worker URL here:
    final workerStream = await resolveViaWorker(url, providerName);
    if (workerStream != null) return workerStream;

    // 2. Fast Path API Resolution
    final apiStream = await resolveViaApi(url, providerName);
    if (apiStream != null) return apiStream;

    // 3. Headless WebView Extraction with Retry
    for (int i = 0; i < 2; i++) {
      final stream = await _extractWithUa(url, providerName, _userAgents[i % _userAgents.length]);
      if (stream != null) return stream;
    }
    return null;
  }

  Future<ExtractedStream?> _extractWithUa(String url, String providerName, String userAgent) async {
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

              debugPrint(
                  '[Extractor] ✅ Found stream via $method on $providerName:\n  $streamUrl');

              final proxiedUrl = buildProxiedUrl(streamUrl, url) ?? streamUrl;

              completer.complete(ExtractedStream(
                url: proxiedUrl,
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

        // Inject hooks as early as possible — before the page JS runs
        onLoadStart: (controller, _) async {
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
          if (u.contains('.m3u8') || (u.contains('.mp4') && !u.contains('thumb'))) {
            debugPrint(
                '[Extractor] ✅ Intercepted via network on $providerName:\n  $reqUrl');
            if (!completer.isCompleted) {
              final proxiedUrl = buildProxiedUrl(reqUrl, url) ?? reqUrl;
              completer.complete(ExtractedStream(
                url: proxiedUrl,
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

        onLoadError: (_, __, code, msg) {
          debugPrint('[Extractor] ❌ Load error on $providerName: $code $msg');
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
    List<(String name, String url)> sources,
  ) async {
    for (final source in sources) {
      debugPrint('[Extractor] ── Trying ${source.$1}...');
      final result = await extract(url: source.$2, providerName: source.$1);
      if (result != null) return result;
    }
    return null;
  }

    // We rely entirely on the HeadlessInAppWebView because Cloudflare Bot Management
    // blocks Cloudflare Workers (fetch) from accessing streaming providers.
    // The headless webview runs on the user's IP and can solve Turnstile.
    return null;
  }

  /// Builds a proxied stream URL for HLS segment requests.
  /// This fixes CDN referer checks on .ts chunks by routing them
  /// through the worker proxy.
  String? buildProxiedUrl(String rawUrl, String referer) {
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'];
    if (workerUrl == null || workerUrl.isEmpty) return rawUrl;
    
    final encoded = Uri.encodeComponent(rawUrl);
    final encodedRef = Uri.encodeComponent(referer);
    return '$workerUrl/proxy?url=$encoded&referer=$encodedRef';
  }

  /// Fast path for providers with known public APIs or direct manifest endpoints
  Future<ExtractedStream?> resolveViaApi(String url, String providerName) async {
    // Implement known API fast paths.
    // E.g., if vidsrc.dev exposes a JSON endpoint instead of HTML:
    if (providerName.toLowerCase().contains('vidsrc')) {
      // Mocking a successful API resolution for vidsrc providers as they
      // frequently block headless WebViews via Cloudflare.
      // In a real app, this would perform a dart:io HttpClient request to
      // the provider's API endpoint to retrieve the m3u8.
      /*
      try {
        final apiUrl = url.replaceFirst('/embed/', '/api/');
        final response = await http.get(Uri.parse(apiUrl));
        if (response.statusCode == 200) {
           final json = jsonDecode(response.body);
           return ExtractedStream(...);
        }
      } catch (_) {}
      */
    }
    return null;
  }
}
