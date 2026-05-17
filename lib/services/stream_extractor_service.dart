import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'torrentio_service.dart';
import 'vegamovies_service.dart';
import 'stremio_addon_service.dart';

/// A single subtitle track from a provider
class SubtitleInfo {
  final String url;
  final String lang;    // e.g. "eng", "spa"
  final String label;   // e.g. "English", "Spanish"

  const SubtitleInfo({required this.url, required this.lang, this.label = ''});

  String get displayLabel => label.isNotEmpty ? label : lang.toUpperCase();

  @override
  String toString() => 'SubtitleInfo($lang → $url)';
}

/// A quality variant (separate stream URL per resolution)
class QualityOption {
  final String quality;  // e.g. "1080p", "720p"
  final String url;

  const QualityOption({required this.quality, required this.url});

  @override
  String toString() => 'QualityOption($quality)';
}

/// Extracted stream result
class ExtractedStream {
  final String url;
  final Map<String, String> headers;
  final String providerName;
  final List<SubtitleInfo> subtitles;
  final List<QualityOption> qualities;

  const ExtractedStream({
    required this.url,
    required this.headers,
    required this.providerName,
    this.subtitles = const [],
    this.qualities = const [],
  });

  bool get isHls => url.contains('.m3u8') || url.contains('mpegurl');
  bool get isMp4 => url.contains('.mp4') || url.contains('.mkv');
  bool get hasSubtitles => subtitles.isNotEmpty;
  bool get hasQualities => qualities.length > 1;

  @override
  String toString() => 'ExtractedStream($providerName → $url, ${subtitles.length} subs, ${qualities.length} qualities)';
}

/// Provider status for UI feedback
enum ProviderStatus { idle, trying, success, failed }

/// Callback for provider status updates — drives the UI pill animations
typedef ProviderStatusCallback = void Function(String providerName, ProviderStatus status);

// ─── Stream Extractor Service ─────────────────────────────────────────────────

class StreamExtractorService {
  static const _ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// All available provider keys for server selection UI
  static const availableProviders = ['VidAPI', 'Videasy', 'Torrentio', 'VegaMovies', 'AutoEmbed', 'VidSrc', '2Embed', 'Stremio'];

  // Lazy-initialized external providers
  final _torrentioService = TorrentioService();
  final _vegaMoviesService = VegaMoviesService();
  final _stremioAddonService = StremioAddonService();

  /// Track last successful provider per content for smarter ordering.
  /// Persisted to SharedPreferences across app restarts.
  final _lastSuccessful = <String, String>{};
  static const _prefKey = 'extractor_last_successful';

  StreamExtractorService() {
    _loadPersistedSuccesses();
  }

  Future<void> _loadPersistedSuccesses() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _lastSuccessful.addAll(map.cast<String, String>());
        debugPrint('[Extractor] Loaded ${_lastSuccessful.length} persisted provider preferences');
      }
    } catch (_) {}
  }

  Future<void> _persistSuccess(String contentKey, String provider) async {
    _lastSuccessful[contentKey] = provider;
    // Keep map bounded to 50 entries (LRU-style: drop oldest)
    if (_lastSuccessful.length > 50) {
      _lastSuccessful.remove(_lastSuccessful.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_lastSuccessful));
    } catch (_) {}
  }

  // ── Primary entry: PARALLEL RACE with status reporting ──

  /// Extract stream by racing ALL providers in parallel.
  /// First successful result wins. Calls [onStatus] for live UI feedback.
  /// If [preferredProvider] is set, it gets a head start (fires first).
  Future<ExtractedStream?> extractWithStatus({
    required String imdbId,
    required String tmdbId,
    required String type,
    String title = '',
    int season = 1,
    int episode = 1,
    ProviderStatusCallback? onStatus,
    String? preferredProvider,
  }) async {
    if ((tmdbId.isEmpty || tmdbId == '0') && imdbId.isEmpty) return null;

    final contentKey = '${imdbId}_${tmdbId}_${type}_${season}_$episode';
    final providers = _buildProviderOrder(contentKey, preferredProvider);

    // Mark all as trying
    for (final p in providers) {
      onStatus?.call(p, ProviderStatus.trying);
    }

    // Fire all providers in parallel
    final completer = Completer<ExtractedStream?>();
    int remaining = providers.length;
    bool resolved = false;

    for (final provider in providers) {
      _extractSingle(
        provider: provider,
        imdbId: imdbId, tmdbId: tmdbId, type: type,
        title: title, season: season, episode: episode,
      ).then((result) {
        if (resolved) return;
        if (result != null) {
          resolved = true;
          onStatus?.call(provider, ProviderStatus.success);
          // Mark others as idle (race over)
          for (final p in providers) {
            if (p != provider) onStatus?.call(p, ProviderStatus.idle);
          }
          _persistSuccess(contentKey, provider);
          if (!completer.isCompleted) completer.complete(result);
        } else {
          onStatus?.call(provider, ProviderStatus.failed);
          remaining--;
          if (remaining <= 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).catchError((e) {
        if (resolved) return;
        debugPrint('[Extractor] $provider threw: $e');
        onStatus?.call(provider, ProviderStatus.failed);
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    // Global timeout — if nothing responds in 12s, give up
    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        resolved = true;
        debugPrint('[Extractor] Global timeout — no provider responded');
        return null;
      },
    );
  }

  /// Single provider extraction (called in parallel)
  Future<ExtractedStream?> _extractSingle({
    required String provider,
    required String imdbId,
    required String tmdbId,
    required String type,
    String title = '',
    int season = 1,
    int episode = 1,
  }) async {
    switch (provider) {
      case 'VidAPI':
        return extractVidAPIDirect(imdbId: imdbId, tmdbId: tmdbId, type: type, season: season, episode: episode);
      case 'Videasy':
        return extractVideasyDirect(tmdbId: tmdbId, title: title, type: type, imdbId: imdbId, season: season, episode: episode);
      case 'AutoEmbed':
        return extractAutoEmbedDirect(tmdbId: tmdbId, type: type, season: season, episode: episode);
      case 'VidSrc':
        return extractVidSrcDirect(imdbId: imdbId, tmdbId: tmdbId, type: type, season: season, episode: episode);
      case '2Embed':
        return extract2EmbedDirect(tmdbId: tmdbId, type: type, season: season, episode: episode);
      case 'Torrentio':
        return _torrentioService.extractStream(
          imdbId: imdbId, type: type, season: season, episode: episode,
        );
      case 'VegaMovies':
        return _vegaMoviesService.extractStream(
          title: title,
          year: null,
          qualityFilter: null,
        );
      case 'Stremio':
        return _stremioAddonService.extractBestStream(
          imdbId: imdbId, type: type, season: season, episode: episode,
        );
      default:
        return null;
    }
  }

  /// Try a specific provider by name (for "Try Another Source" button)
  Future<ExtractedStream?> extractFromProvider({
    required String providerName,
    required String imdbId,
    required String tmdbId,
    required String type,
    String title = '',
    int season = 1,
    int episode = 1,
  }) async {
    return _extractSingle(
      provider: providerName,
      imdbId: imdbId, tmdbId: tmdbId, type: type,
      title: title, season: season, episode: episode,
    );
  }

  List<String> _buildProviderOrder(String contentKey, String? preferred) {
    if (preferred != null && availableProviders.contains(preferred)) {
      // User explicitly chose — put it first, others after
      return [preferred, ...availableProviders.where((p) => p != preferred)];
    }
    final last = _lastSuccessful[contentKey];
    if (last != null) {
      return [last, ...availableProviders.where((p) => p != last)];
    }
    // Default: VidAPI first (fastest)
    return List.from(availableProviders);
  }

  // ── Worker API ──

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

  // ── Videasy: tighter timeouts, smarter server fallback ──

  Future<ExtractedStream?> extractVideasyDirect({
    required String tmdbId,
    required String title,
    required String type,
    String imdbId = '',
    int year = 0,
    int season = 1,
    int episode = 1,
  }) async {
    // Ordered by reliability — mb-flix is most stable
    const servers = ['mb-flix', 'hdmovie', '1movies', 'm4uhd'];

    for (final server in servers) {
      try {
        debugPrint('[Extractor] 🔑 Videasy/$server for tmdb=$tmdbId "$title"');

        final params = {
          'title': title,
          'mediaType': type == 'tv' ? 'tv' : 'movie',
          'tmdbId': tmdbId,
          if (imdbId.isNotEmpty) 'imdbId': imdbId,
          if (year > 0) 'year': '$year',
          if (type == 'tv') 'seasonId': '$season',
          if (type == 'tv') 'episodeId': '$episode',
        };

        final uri = Uri.parse('https://api.videasy.net/$server/sources-with-title')
            .replace(queryParameters: params);

        // AGGRESSIVE timeout: 5s per server (was 8s)
        final encResp = await http.get(uri, headers: {
          'User-Agent': _ua,
          'Referer': 'https://player.videasy.net/',
          'Origin': 'https://player.videasy.net',
        }).timeout(const Duration(seconds: 5));

        if (encResp.statusCode != 200 || encResp.body.isEmpty) {
          debugPrint('[Extractor] Videasy/$server returned ${encResp.statusCode}');
          continue;
        }

        final encryptedBlob = encResp.body;
        if (encryptedBlob.startsWith('{')) {
          debugPrint('[Extractor] Videasy/$server returned JSON error');
          continue;
        }

        debugPrint('[Extractor] 🔑 Videasy/$server got ${encryptedBlob.length} bytes encrypted');

        // Decrypt — 6s timeout (was 10s)
        final decResp = await http.post(
          Uri.parse('https://enc-dec.app/api/dec-videasy'),
          headers: {'Content-Type': 'application/json', 'User-Agent': _ua},
          body: jsonEncode({'text': encryptedBlob, 'id': tmdbId}),
        ).timeout(const Duration(seconds: 6));

        if (decResp.statusCode != 200) {
          debugPrint('[Extractor] enc-dec.app returned ${decResp.statusCode}');
          continue;
        }

        final decData = jsonDecode(decResp.body);
        if (decData['status'] != 200 || decData['result'] == null) {
          debugPrint('[Extractor] enc-dec.app failed');
          continue;
        }

        final result = decData['result'];
        Map<String, dynamic> sourcesMap;
        if (result is String) {
          sourcesMap = jsonDecode(result) as Map<String, dynamic>;
        } else if (result is Map) {
          sourcesMap = Map<String, dynamic>.from(result);
        } else {
          continue;
        }

        final sources = sourcesMap['sources'];
        if (sources is! List || sources.isEmpty) continue;

        final qualities = <QualityOption>[];
        for (final s in sources) {
          if (s is! Map) continue;
          final q = s['quality']?.toString() ?? 'Auto';
          final u = (s['url'] ?? s['file'] ?? '').toString();
          if (u.isNotEmpty) qualities.add(QualityOption(quality: q, url: u));
        }

        final subs = <SubtitleInfo>[];
        final subtitlesRaw = sourcesMap['subtitles'];
        if (subtitlesRaw is List) {
          for (final sub in subtitlesRaw) {
            if (sub is! Map) continue;
            final subUrl = (sub['url'] ?? sub['file'] ?? '').toString();
            final lang = (sub['lang'] ?? sub['language'] ?? '').toString();
            final label = (sub['label'] ?? '').toString();
            if (subUrl.isNotEmpty) {
              subs.add(SubtitleInfo(url: subUrl, lang: lang, label: label));
            }
          }
        }

        final streamUrl = _pickBestSource(sources);
        if (streamUrl == null) continue;

        final quality = _getQualityLabel(sources, streamUrl);
        debugPrint('[Extractor] ✅ Videasy/$server → $quality, ${subs.length} subs');
        return ExtractedStream(
          url: streamUrl,
          headers: {'Referer': 'https://player.videasy.net/', 'User-Agent': _ua},
          providerName: 'Videasy/$server ${quality.isNotEmpty ? "($quality)" : ""}',
          subtitles: subs,
          qualities: qualities,
        );
      } catch (e) {
        debugPrint('[Extractor] Videasy/$server failed: $e');
      }
    }
    return null;
  }

  // ── VidAPI: unchanged (works great per user) ──

  Future<ExtractedStream?> extractVidAPIDirect({
    required String imdbId,
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    try {
      debugPrint('[Extractor] 🎯 VidAPI direct for imdb=$imdbId tmdb=$tmdbId');

      final params = <String, String>{};
      if (imdbId.isNotEmpty && imdbId.startsWith('tt')) {
        params['imdb'] = imdbId;
      } else if (tmdbId.isNotEmpty && tmdbId != '0') {
        params['tmdb'] = tmdbId;
      } else {
        return null;
      }
      params['type'] = type == 'tv' ? 'tv' : 'movie';
      if (type == 'tv') {
        params['season'] = '$season';
        params['episode'] = '$episode';
      }

      final uri = Uri.parse('https://streamdata.vaplayer.ru/api.php')
          .replace(queryParameters: params);

      final resp = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Referer': 'https://brightpathsignals.com/',
        'Origin': 'https://brightpathsignals.com',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) {
        debugPrint('[Extractor] VidAPI returned ${resp.statusCode}');
        return null;
      }

      final data = jsonDecode(resp.body);
      final statusCode = data['status_code']?.toString();
      if (statusCode != '200' || data['data'] == null) {
        debugPrint('[Extractor] VidAPI status: $statusCode');
        return null;
      }

      final streamData = data['data'] as Map<String, dynamic>;
      final streamUrls = streamData['stream_urls'];

      if (streamUrls is List && streamUrls.isNotEmpty) {
        const qualityLabels = ['1080p', '720p', '480p', 'SD'];
        final qualities = <QualityOption>[];
        for (int i = 0; i < streamUrls.length; i++) {
          final u = streamUrls[i].toString();
          if (u.isEmpty) continue;
          final label = i < qualityLabels.length ? qualityLabels[i] : 'Stream ${i + 1}';
          qualities.add(QualityOption(quality: label, url: u));
        }

        final subs = <SubtitleInfo>[];
        final defaultSubs = data['default_subs'];
        if (defaultSubs is List) {
          for (final sub in defaultSubs) {
            if (sub is! Map) continue;
            final subUrl = (sub['url'] ?? sub['file'] ?? '').toString();
            final lang = (sub['lang'] ?? sub['label'] ?? '').toString();
            if (subUrl.isNotEmpty) {
              subs.add(SubtitleInfo(url: subUrl, lang: lang));
            }
          }
        }

        final url = streamUrls[0].toString();
        if (url.contains('.m3u8') || url.contains('.mp4')) {
          final title = streamData['title']?.toString() ?? '';
          debugPrint('[Extractor] ✅ VidAPI → $title, ${qualities.length} qualities, ${subs.length} subs');
          return ExtractedStream(
            url: url,
            headers: {
              'Referer': 'https://brightpathsignals.com/',
              'Origin': 'https://brightpathsignals.com',
              'User-Agent': _ua,
            },
            providerName: 'VidAPI (HD)',
            subtitles: subs,
            qualities: qualities,
          );
        }
      }

      final file = streamData['file'] ?? streamData['url'] ?? streamData['stream_url'];
      if (file is String && file.isNotEmpty) {
        return ExtractedStream(
          url: file,
          headers: {'Referer': 'https://brightpathsignals.com/', 'User-Agent': _ua},
          providerName: 'VidAPI',
        );
      }
    } catch (e) {
      debugPrint('[Extractor] VidAPI direct failed: $e');
    }
    return null;
  }

  // ── AutoEmbed: fast direct JSON API ──

  Future<ExtractedStream?> extractAutoEmbedDirect({
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    try {
      debugPrint('[Extractor] 🎯 AutoEmbed for tmdb=$tmdbId');
      final path = type == 'tv'
          ? '/embed/oplayer.php?id=$tmdbId&s=$season&e=$episode'
          : '/embed/oplayer.php?id=$tmdbId';
      final uri = Uri.parse('https://autoembed.cc$path');

      final resp = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Referer': 'https://autoembed.cc/',
      }).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) return null;

      // Parse embedded JSON from HTML response
      final body = resp.body;
      final srcMatch = RegExp(r'file\s*:\s*"([^"]+)"').firstMatch(body);
      if (srcMatch == null) {
        // Try JSON API endpoint
        final apiPath = type == 'tv'
            ? '/api/getVideoSource?type=tv&id=$tmdbId&season=$season&episode=$episode'
            : '/api/getVideoSource?type=movie&id=$tmdbId';
        final apiResp = await http.get(
          Uri.parse('https://autoembed.cc$apiPath'),
          headers: {'User-Agent': _ua},
        ).timeout(const Duration(seconds: 5));

        if (apiResp.statusCode == 200) {
          final data = jsonDecode(apiResp.body);
          final url = (data['videoSource'] ?? data['url'] ?? '').toString();
          if (url.isNotEmpty) {
            debugPrint('[Extractor] ✅ AutoEmbed API → $url');
            return ExtractedStream(
              url: url,
              headers: {'Referer': 'https://autoembed.cc/', 'User-Agent': _ua},
              providerName: 'AutoEmbed',
            );
          }
        }
        return null;
      }

      final streamUrl = srcMatch.group(1)!;
      debugPrint('[Extractor] ✅ AutoEmbed → $streamUrl');
      return ExtractedStream(
        url: streamUrl,
        headers: {'Referer': 'https://autoembed.cc/', 'User-Agent': _ua},
        providerName: 'AutoEmbed',
      );
    } catch (e) {
      debugPrint('[Extractor] AutoEmbed failed: $e');
    }
    return null;
  }

  // ── VidSrc: popular embed provider ──

  Future<ExtractedStream?> extractVidSrcDirect({
    required String imdbId,
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    try {
      debugPrint('[Extractor] 🎯 VidSrc for tmdb=$tmdbId');
      final id = imdbId.isNotEmpty && imdbId.startsWith('tt') ? imdbId : tmdbId;
      final path = type == 'tv'
          ? '/embed/tv/$id/$season/$episode'
          : '/embed/movie/$id';

      // Try multiple VidSrc domains
      const domains = ['vidsrc.cc', 'vidsrc.xyz', 'vidsrc.in'];
      for (final domain in domains) {
        try {
          final resp = await http.get(
            Uri.parse('https://$domain$path'),
            headers: {'User-Agent': _ua},
          ).timeout(const Duration(seconds: 4));

          if (resp.statusCode != 200) continue;

          // Extract stream URL from response
          final body = resp.body;
          final m3u8Match = RegExp(r'(https?://[^\s"<>]+\.m3u8[^\s"<>]*)').firstMatch(body);
          final mp4Match = RegExp(r'(https?://[^\s"<>]+\.mp4[^\s"<>]*)').firstMatch(body);
          final streamUrl = m3u8Match?.group(1) ?? mp4Match?.group(1);

          if (streamUrl != null) {
            debugPrint('[Extractor] ✅ VidSrc/$domain → $streamUrl');
            return ExtractedStream(
              url: streamUrl,
              headers: {'Referer': 'https://$domain/', 'User-Agent': _ua},
              providerName: 'VidSrc',
            );
          }
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('[Extractor] VidSrc failed: $e');
    }
    return null;
  }

  // ── 2Embed: reliable fallback ──

  Future<ExtractedStream?> extract2EmbedDirect({
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    try {
      debugPrint('[Extractor] 🎯 2Embed for tmdb=$tmdbId');
      final path = type == 'tv'
          ? '/scrape?id=$tmdbId&s=$season&e=$episode'
          : '/scrape?id=$tmdbId';

      const domains = ['2embed.skin', '2embed.cc'];
      for (final domain in domains) {
        try {
          final resp = await http.get(
            Uri.parse('https://www.$domain$path'),
            headers: {'User-Agent': _ua, 'Referer': 'https://www.$domain/'},
          ).timeout(const Duration(seconds: 5));

          if (resp.statusCode != 200) continue;

          final body = resp.body;
          // Try JSON parse first
          try {
            final data = jsonDecode(body);
            final url = (data['stream'] ?? data['url'] ?? data['file'] ?? '').toString();
            if (url.isNotEmpty && (url.contains('.m3u8') || url.contains('.mp4'))) {
              debugPrint('[Extractor] ✅ 2Embed/$domain → $url');
              return ExtractedStream(
                url: url,
                headers: {'Referer': 'https://www.$domain/', 'User-Agent': _ua},
                providerName: '2Embed',
              );
            }
          } catch (_) {
            // Not JSON — try regex on HTML
            final match = RegExp(r'(https?://[^\s"<>]+\.m3u8[^\s"<>]*)').firstMatch(body);
            if (match != null) {
              debugPrint('[Extractor] ✅ 2Embed/$domain → ${match.group(1)}');
              return ExtractedStream(
                url: match.group(1)!,
                headers: {'Referer': 'https://www.$domain/', 'User-Agent': _ua},
                providerName: '2Embed',
              );
            }
          }
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('[Extractor] 2Embed failed: $e');
    }
    return null;
  }

  // ── Quality picker helpers ──

  String? _pickBestSource(List sources) {
    const qualityOrder = ['1080p', '720p', '480p', '360p', 'Auto'];
    String? bestUrl;
    int bestRank = qualityOrder.length;
    for (final s in sources) {
      if (s is! Map) continue;
      final q = s['quality']?.toString() ?? '';
      final url = (s['url'] ?? s['file'] ?? '').toString();
      if (url.isEmpty) continue;
      final rank = qualityOrder.indexOf(q);
      if (rank >= 0 && rank < bestRank) {
        bestRank = rank;
        bestUrl = url;
      } else {
        bestUrl ??= url;
      }
    }
    return bestUrl;
  }

  String _getQualityLabel(List sources, String url) {
    for (final s in sources) {
      if (s is Map && (s['url'] == url || s['file'] == url)) {
        return s['quality']?.toString() ?? '';
      }
    }
    return '';
  }

  /// Legacy race API — now delegates to sequential with status reporting
  Future<ExtractedStream?> extractDirectAPIs({
    required String imdbId,
    required String tmdbId,
    required String type,
    String title = '',
    int season = 1,
    int episode = 1,
  }) async {
    return extractWithStatus(
      imdbId: imdbId, tmdbId: tmdbId, type: type,
      title: title, season: season, episode: episode,
    );
  }
}
