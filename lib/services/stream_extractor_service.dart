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
  final String? magnetUrl;

  const ExtractedStream({
    required this.url,
    required this.headers,
    required this.providerName,
    this.subtitles = const [],
    this.qualities = const [],
    this.magnetUrl,
  });

  bool get isHls => url.contains('.m3u8') || url.contains('mpegurl');
  bool get isMp4 => url.contains('.mp4') || url.contains('.mkv') || url.contains('.webm');
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
  static const availableProviders = ['VidAPI', 'Videasy', 'VidLink', 'Consumet', 'Torrentio', 'VegaMovies', 'Stremio'];

  // Lazy-initialized external providers
  final _torrentioService = TorrentioService();
  final _vegaMoviesService = VegaMoviesService();
  final _stremioAddonService = StremioAddonService();

  /// Track last successful provider per content for smarter ordering.
  /// Persisted to SharedPreferences across app restarts.
  final _lastSuccessful = <String, String>{};
  static const _prefKey = 'extractor_last_successful';

  /// ── Background Resolution Cache ──
  /// Stores ALL resolved streams per content key so user can switch servers instantly.
  final _resolvedStreams = <String, Map<String, ExtractedStream>>{};
  final _resolutionStatus = <String, Map<String, ProviderStatus>>{};

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
    if (_lastSuccessful.length > 50) {
      _lastSuccessful.remove(_lastSuccessful.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_lastSuccessful));
    } catch (_) {}
  }

  // ── Background Resolution API ──

  /// Get list of servers that have successfully resolved for a content key
  List<String> getAvailableServers(String contentKey) {
    return _resolvedStreams[contentKey]?.keys.toList() ?? [];
  }

  /// Get a resolved stream for a specific provider (instant server switch)
  ExtractedStream? getResolvedStream(String contentKey, String provider) {
    return _resolvedStreams[contentKey]?[provider];
  }

  /// Get status of all providers for a content key
  Map<String, ProviderStatus> getProviderStatuses(String contentKey) {
    return Map.unmodifiable(_resolutionStatus[contentKey] ?? {});
  }

  /// Clear all cached resolution data for a content key (use before a forced retry).
  void clearCache(String contentKey) {
    _resolvedStreams.remove(contentKey);
    _resolutionStatus.remove(contentKey);
    debugPrint('[Extractor] Cache cleared for $contentKey');
  }

  // ── Primary entry: PARALLEL RACE with background resolution ──

  /// Extract stream by racing ALL providers in parallel.
  /// Returns first successful result immediately, but continues resolving ALL
  /// others in background. User can then switch servers instantly via
  /// getResolvedStream().
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

    // ── IMPORTANT: do NOT wipe the cache map — preserve background resolutions.
    // Only create the maps if they don't already exist for this content key.
    _resolvedStreams.putIfAbsent(contentKey, () => {});
    final statusMap = _resolutionStatus.putIfAbsent(contentKey, () => {});

    // Mark all providers as trying (only if not already resolved/failed)
    for (final p in providers) {
      if (statusMap[p] != ProviderStatus.success) {
        statusMap[p] = ProviderStatus.trying;
        onStatus?.call(p, ProviderStatus.trying);
      } else {
        // Already cached — fire success callback so UI pill updates
        onStatus?.call(p, ProviderStatus.success);
      }
    }

    // If we already have a cached result for the preferred provider, return it immediately
    if (preferredProvider != null) {
      final existing = _resolvedStreams[contentKey]![preferredProvider];
      if (existing != null) {
        debugPrint('[Extractor] ⚡ Instant cache hit for $preferredProvider');
        return existing;
      }
    }

    // Fire all providers in parallel — skip any already resolved
    final completer = Completer<ExtractedStream?>();
    bool firstResolved = false;

    // Count only providers that aren't already done
    final pending = providers.where((p) => statusMap[p] != ProviderStatus.success).toList();
    int remaining = pending.length;

    // If all providers are already resolved, return the best cached one immediately
    if (remaining == 0) {
      final cached = _resolvedStreams[contentKey]!;
      if (cached.isNotEmpty) {
        // Return in provider priority order
        for (final p in providers) {
          if (cached.containsKey(p)) return cached[p];
        }
      }
      return null;
    }

    for (final provider in pending) {
      _extractSingle(
        provider: provider,
        imdbId: imdbId, tmdbId: tmdbId, type: type,
        title: title, season: season, episode: episode,
      ).then((result) {
        if (result != null) {
          // Cache the resolved stream if cache hasn't been cleared
          if (_resolvedStreams.containsKey(contentKey)) {
            _resolvedStreams[contentKey]![provider] = result;
          }
          if (_resolutionStatus.containsKey(contentKey)) {
            statusMap[provider] = ProviderStatus.success;
          }
          onStatus?.call(provider, ProviderStatus.success);

          // Complete the future with the FIRST successful result
          if (!firstResolved) {
            firstResolved = true;
            _persistSuccess(contentKey, provider);
            if (!completer.isCompleted) completer.complete(result);
          }
        } else {
          statusMap[provider] = ProviderStatus.failed;
          onStatus?.call(provider, ProviderStatus.failed);
        }

        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }).catchError((e) {
        debugPrint('[Extractor] $provider threw: $e');
        statusMap[provider] = ProviderStatus.failed;
        onStatus?.call(provider, ProviderStatus.failed);
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    // Global timeout — if nothing responds in 15s, give up
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        debugPrint('[Extractor] Global timeout — no provider responded');
        if (!completer.isCompleted) completer.complete(null);
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
      case 'VidLink':
        return extractVidLinkDirect(tmdbId: tmdbId, type: type, season: season, episode: episode);
      case 'Consumet':
        final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
        final hfUrl = envUrl.isNotEmpty
            ? (envUrl.endsWith('/') ? envUrl.substring(0, envUrl.length - 1) : envUrl)
            : 'https://nikhil1776-torrentindex.hf.space';
        return _fetchFromBackend(
          hfUrl: hfUrl,
          path: '/api/extract/anime',
          params: {
            'title': title,
            'episode': '$episode',
            'season': '$season',
          },
          providerName: 'Consumet',
        );
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

  // ── Backend API Helper ──

  Future<ExtractedStream?> _fetchFromBackend({
    required String hfUrl,
    required String path,
    required Map<String, String> params,
    required String providerName,
  }) async {
    try {
      final uri = Uri.parse('$hfUrl$path').replace(queryParameters: params);
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        final qualities = <QualityOption>[];
        if (data['qualities'] is List) {
          for (final q in data['qualities']) {
            if (q is Map) {
              qualities.add(QualityOption(
                quality: q['quality']?.toString() ?? 'Auto',
                url: q['url']?.toString() ?? '',
              ));
            }
          }
        }

        final subtitles = <SubtitleInfo>[];
        if (data['subtitles'] is List) {
          for (final sub in data['subtitles']) {
            if (sub is Map) {
              subtitles.add(SubtitleInfo(
                url: sub['url']?.toString() ?? '',
                lang: sub['lang']?.toString() ?? 'English',
                label: sub['label']?.toString() ?? '',
              ));
            }
          }
        }

        final Map<String, String> headers = {};
        if (data['headers'] is Map) {
          (data['headers'] as Map).forEach((k, v) {
            headers[k.toString()] = v.toString();
          });
        }

        final url = data['url']?.toString() ?? '';
        if (url.isNotEmpty) {
          return ExtractedStream(
            url: url,
            headers: headers,
            providerName: data['providerName']?.toString() ?? providerName,
            qualities: qualities,
            subtitles: subtitles,
            magnetUrl: data['magnetUrl']?.toString(),
          );
        }
      }
    } catch (e) {
      debugPrint('[Extractor] Backend fetch failed for $providerName: $e');
    }
    return null;
  }

  // ── Scraper Delegates ──

  Future<ExtractedStream?> extractVidAPIDirect({
    required String imdbId,
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
    final hfUrl = envUrl.isNotEmpty
        ? (envUrl.endsWith('/') ? envUrl.substring(0, envUrl.length - 1) : envUrl)
        : 'https://nikhil1776-torrentindex.hf.space';
    return _fetchFromBackend(
      hfUrl: hfUrl,
      path: '/api/extract/vidapi',
      params: {
        if (imdbId.isNotEmpty) 'imdb': imdbId,
        if (tmdbId.isNotEmpty) 'tmdb': tmdbId,
        'type': type,
        'season': '$season',
        'episode': '$episode',
      },
      providerName: 'VidAPI',
    );
  }

  Future<ExtractedStream?> extractVideasyDirect({
    required String tmdbId,
    required String title,
    required String type,
    String imdbId = '',
    int season = 1,
    int episode = 1,
    int year = 0,
  }) async {
    final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
    final hfUrl = envUrl.isNotEmpty
        ? (envUrl.endsWith('/') ? envUrl.substring(0, envUrl.length - 1) : envUrl)
        : 'https://nikhil1776-torrentindex.hf.space';
    return _fetchFromBackend(
      hfUrl: hfUrl,
      path: '/api/extract/videasy',
      params: {
        'tmdb': tmdbId,
        'title': title,
        'type': type,
        if (imdbId.isNotEmpty) 'imdb': imdbId,
        'season': '$season',
        'episode': '$episode',
        if (year > 0) 'year': '$year',
      },
      providerName: 'Videasy',
    );
  }

  Future<ExtractedStream?> extractVidLinkDirect({
    required String tmdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
    final hfUrl = envUrl.isNotEmpty
        ? (envUrl.endsWith('/') ? envUrl.substring(0, envUrl.length - 1) : envUrl)
        : 'https://nikhil1776-torrentindex.hf.space';
    return _fetchFromBackend(
      hfUrl: hfUrl,
      path: '/api/extract/vidlink',
      params: {
        'tmdb': tmdbId,
        'type': type,
        'season': '$season',
        'episode': '$episode',
      },
      providerName: 'VidLink',
    );
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
