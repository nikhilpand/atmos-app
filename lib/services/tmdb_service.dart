import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive/hive.dart';
import '../models/media_model.dart';

// ─── Hive Cache ───────────────────────────────────────────────────────────────

/// Unified Hive-backed cache supporting both List and Map payloads.
/// Uses two TTLs: fresh (6h for lists) and details (24h for movie/TV details).
class _TmdbCache {
  static const _boxName = 'tmdb_cache_v2';
  static const _listTtl    = Duration(hours: 6);
  static const _detailsTtl = Duration(hours: 24);

  late Box _box;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      _box = await Hive.openBox(_boxName);
    } catch (e) {
      debugPrint('TMDB cache box corrupted, deleting: $e');
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox(_boxName);
    }
    _ready = true;
  }

  bool get isReady => _ready;

  // ── List cache ──────────────────────────────────────────────────────────────

  /// Fresh list — returns null if stale or missing.
  List<dynamic>? getList(String key) {
    if (!_ready) return null;
    return _getEntry(key, _listTtl, isList: true) as List<dynamic>?;
  }

  /// Stale list — returns cached data even if expired (for offline mode).
  List<dynamic>? getStaleList(String key) {
    if (!_ready) return null;
    final entry = _box.get(key);
    if (entry == null) return null;
    final data = entry['data'];
    if (data is List) return List<dynamic>.from(data);
    return null;
  }

  Future<void> setList(String key, List<dynamic> data) async {
    if (!_ready) return;
    await _box.put(key, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    });
  }

  // ── Map cache (details, episodes) ──────────────────────────────────────────

  /// Fresh map — returns null if stale or missing.
  Map<String, dynamic>? getMap(String key) {
    if (!_ready) return null;
    return _getEntry(key, _detailsTtl, isList: false) as Map<String, dynamic>?;
  }

  /// Stale map — always returns if present regardless of age.
  Map<String, dynamic>? getStaleMap(String key) {
    if (!_ready) return null;
    final entry = _box.get(key);
    if (entry == null) return null;
    final data = entry['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  Future<void> setMap(String key, Map<String, dynamic> data) async {
    if (!_ready) return;
    await _box.put(key, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    });
  }

  // ── Episodes (list of maps) ─────────────────────────────────────────────────

  List<Map<String, dynamic>>? getEpisodes(String key) {
    if (!_ready) return null;
    final entry = _box.get(key);
    if (entry == null) return null;
    final ts = entry['ts'] as int? ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > _detailsTtl.inMilliseconds) return null;
    final data = entry['data'] as List? ?? [];
    return data.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  List<Map<String, dynamic>>? getStaleEpisodes(String key) {
    if (!_ready) return null;
    final entry = _box.get(key);
    if (entry == null) return null;
    final data = entry['data'] as List? ?? [];
    return data.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> setEpisodes(String key, List<Map<String, dynamic>> data) async {
    if (!_ready) return;
    await _box.put(key, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    });
  }

  Future<void> clear() async => _box.clear();

  // ── Internal ────────────────────────────────────────────────────────────────

  dynamic _getEntry(String key, Duration ttl, {required bool isList}) {
    final entry = _box.get(key);
    if (entry == null) return null;
    final ts = entry['ts'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - ts > ttl.inMilliseconds) {
      return null; // stale
    }
    final data = entry['data'];
    if (isList && data is List) return List<dynamic>.from(data);
    if (!isList && data is Map) return Map<String, dynamic>.from(data);
    return null;
  }
}

// ─── TmdbService ─────────────────────────────────────────────────────────────

class TmdbService {
  late final String _base;
  late final String _apiKey;
  final _cache = _TmdbCache();

  TmdbService() {
    _apiKey = dotenv.env['TMDB_API_KEY'] ?? '';
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
    _base = workerUrl.isNotEmpty ? '$workerUrl/tmdb' : 'https://api.themoviedb.org/3';
  }

  Future<void> initCache() => _cache.init();

  /// Build a full URI with default query params merged in.
  Uri _uri(String path, [Map<String, dynamic>? extra]) {
    final params = <String, String>{
      'api_key': _apiKey,
      'language': 'en-US',
    };
    if (extra != null) {
      for (final e in extra.entries) {
        params[e.key] = '${e.value}';
      }
    }
    return Uri.parse('$_base$path').replace(queryParameters: params);
  }

  /// Perform GET and decode JSON. Throws on failure.
  Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic>? queryParams]) async {
    final uri = _uri(path, queryParams);
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('TMDB ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Genre Constants ─────────────────────────────────────────────────────────

  static const movieGenres = <int, ({String name, String emoji})>{
    28:     (name: 'Action',      emoji: '💥'),
    12:     (name: 'Adventure',   emoji: '🗺️'),
    16:     (name: 'Animation',   emoji: '🎨'),
    35:     (name: 'Comedy',      emoji: '😂'),
    80:     (name: 'Crime',       emoji: '🔪'),
    99:     (name: 'Documentary', emoji: '🎙️'),
    18:     (name: 'Drama',       emoji: '🎭'),
    10751:  (name: 'Family',      emoji: '👨‍👩‍👧'),
    14:     (name: 'Fantasy',     emoji: '🧙'),
    36:     (name: 'History',     emoji: '📜'),
    27:     (name: 'Horror',      emoji: '👻'),
    10402:  (name: 'Music',       emoji: '🎵'),
    9648:   (name: 'Mystery',     emoji: '🕵️'),
    10749:  (name: 'Romance',     emoji: '❤️'),
    878:    (name: 'Sci-Fi',      emoji: '🚀'),
    53:     (name: 'Thriller',    emoji: '😰'),
    10752:  (name: 'War',         emoji: '⚔️'),
    37:     (name: 'Western',     emoji: '🤠'),
  };

  static const tvGenres = <int, ({String name, String emoji})>{
    10759:  (name: 'Action',      emoji: '💥'),
    16:     (name: 'Animation',   emoji: '🎨'),
    35:     (name: 'Comedy',      emoji: '😂'),
    80:     (name: 'Crime',       emoji: '🔪'),
    99:     (name: 'Documentary', emoji: '🎙️'),
    18:     (name: 'Drama',       emoji: '🎭'),
    10751:  (name: 'Family',      emoji: '👨‍👩‍👧'),
    10762:  (name: 'Kids',        emoji: '🧸'),
    9648:   (name: 'Mystery',     emoji: '🕵️'),
    10764:  (name: 'Reality',     emoji: '📸'),
    10765:  (name: 'Sci-Fi',      emoji: '🚀'),
    10767:  (name: 'Talk',        emoji: '🎤'),
    10768:  (name: 'War',         emoji: '⚔️'),
    37:     (name: 'Western',     emoji: '🤠'),
  };

  // ── Stale-while-revalidate list helper ──────────────────────────────────────

  /// Returns cached data immediately if fresh.
  /// If stale/missing, fetches and caches. On network error, returns stale data.
  Future<List<TmdbMedia>> _getCached(
    String cacheKey,
    String path, {
    Map<String, dynamic>? queryParams,
    MediaType? defaultType,
  }) async {
    // 1. Return fresh cache immediately
    final fresh = _cache.getList(cacheKey);
    if (fresh != null) return _parseResults(fresh, defaultType: defaultType);

    // 2. Fetch from network
    try {
      final data = await _get(path, queryParams);
      final results = data['results'] as List? ?? [];
      await _cache.setList(cacheKey, results);
      return _parseResults(results, defaultType: defaultType);
    } catch (_) {
      // 3. Network failed — return stale cache (offline fallback)
      final stale = _cache.getStaleList(cacheKey);
      if (stale != null) return _parseResults(stale, defaultType: defaultType);
      return [];
    }
  }

  // ── Home / Discovery ────────────────────────────────────────────────────────

  Future<List<TmdbMedia>> getTrending({String window = 'week'}) =>
      _getCached('trending_$window', '/trending/all/$window');

  Future<List<TmdbMedia>> getPopularMovies({int page = 1}) =>
      _getCached('popular_movies_$page', '/movie/popular',
          queryParams: {'page': page}, defaultType: MediaType.movie);

  Future<List<TmdbMedia>> getPopularTv({int page = 1}) =>
      _getCached('popular_tv_$page', '/tv/popular',
          queryParams: {'page': page}, defaultType: MediaType.tv);

  Future<List<TmdbMedia>> getTopRatedMovies({int page = 1}) =>
      _getCached('top_rated_movies_$page', '/movie/top_rated',
          queryParams: {'page': page}, defaultType: MediaType.movie);

  Future<List<TmdbMedia>> getTopRatedTv({int page = 1}) =>
      _getCached('top_rated_tv_$page', '/tv/top_rated',
          queryParams: {'page': page}, defaultType: MediaType.tv);

  Future<List<TmdbMedia>> getNowPlayingMovies() =>
      _getCached('now_playing', '/movie/now_playing',
          defaultType: MediaType.movie);

  Future<List<TmdbMedia>> getAiringToday() =>
      _getCached('airing_today', '/tv/airing_today',
          defaultType: MediaType.tv);

  Future<List<TmdbMedia>> getUpcoming() =>
      _getCached('upcoming', '/movie/upcoming',
          defaultType: MediaType.movie);

  // ── Genre Discovery ─────────────────────────────────────────────────────────

  Future<List<TmdbMedia>> discoverByGenre(
    int genreId, {
    required MediaType type,
    int page = 1,
    String sortBy = 'popularity.desc',
    double minRating = 0,
  }) {
    final cacheKey = 'genre_${genreId}_${type.name}_$page';
    final endpoint = type == MediaType.movie ? '/discover/movie' : '/discover/tv';
    return _getCached(
      cacheKey,
      endpoint,
      queryParams: {
        'with_genres': genreId,
        'page': page,
        'sort_by': sortBy,
        if (minRating > 0) 'vote_average.gte': minRating,
        'vote_count.gte': 50,
      },
      defaultType: type,
    );
  }

  Future<List<TmdbMedia>> discoverByGenres(
    List<int> genreIds, {
    required MediaType type,
    int page = 1,
    String sortBy = 'popularity.desc',
    double minRating = 0,
  }) {
    final idsStr = genreIds.join('|');
    final cacheKey = 'genres_${idsStr}_${type.name}_$page';
    final endpoint = type == MediaType.movie ? '/discover/movie' : '/discover/tv';
    return _getCached(
      cacheKey,
      endpoint,
      queryParams: {
        'with_genres': idsStr,
        'page': page,
        'sort_by': sortBy,
        if (minRating > 0) 'vote_average.gte': minRating,
        'vote_count.gte': 50,
      },
      defaultType: type,
    );
  }

  // ── Recommendations & Similar ───────────────────────────────────────────────

  Future<List<TmdbMedia>> getRecommendations(int tmdbId, MediaType type) async {
    final cacheKey = 'recs_${type.name}_$tmdbId';
    final path = type == MediaType.movie
        ? '/movie/$tmdbId/recommendations'
        : '/tv/$tmdbId/recommendations';
    return _getCached(cacheKey, path, defaultType: type);
  }

  Future<List<TmdbMedia>> getSimilar(int tmdbId, MediaType type) async {
    final cacheKey = 'similar_${type.name}_$tmdbId';
    final path = type == MediaType.movie
        ? '/movie/$tmdbId/similar'
        : '/tv/$tmdbId/similar';
    return _getCached(cacheKey, path, defaultType: type);
  }

  // ── Search ──────────────────────────────────────────────────────────────────

  Future<List<TmdbMedia>> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return [];
    try {
      final data = await _get('/search/multi', {
        'query': query.trim(),
        'page': page,
        'include_adult': false,
      });
      return _parseResults(data['results'] ?? []);
    } catch (_) { return []; }
  }

  // ── Details (cached 24h + offline stale fallback) ──────────────────────────

  Future<TmdbDetails> getMovieDetails(int tmdbId) async {
    final key = 'movie_detail_$tmdbId';
    // Fresh cache?
    final cached = _cache.getMap(key);
    if (cached != null) return TmdbDetails.fromJson(cached, MediaType.movie);

    try {
      final data = await _get('/movie/$tmdbId', {
        'append_to_response': 'credits,external_ids,videos',
      });
      await _cache.setMap(key, data);
      return TmdbDetails.fromJson(data, MediaType.movie);
    } catch (_) {
      // Offline stale fallback
      final stale = _cache.getStaleMap(key);
      if (stale != null) return TmdbDetails.fromJson(stale, MediaType.movie);
      rethrow;
    }
  }

  Future<TmdbDetails> getTvDetails(int tmdbId) async {
    final key = 'tv_detail_$tmdbId';
    final cached = _cache.getMap(key);
    if (cached != null) return TmdbDetails.fromJson(cached, MediaType.tv);

    try {
      final data = await _get('/tv/$tmdbId', {
        'append_to_response': 'credits,external_ids,videos',
      });
      await _cache.setMap(key, data);
      return TmdbDetails.fromJson(data, MediaType.tv);
    } catch (_) {
      final stale = _cache.getStaleMap(key);
      if (stale != null) return TmdbDetails.fromJson(stale, MediaType.tv);
      rethrow;
    }
  }

  Future<String?> getImdbId(int tmdbId, MediaType type) async {
    try {
      final path = type == MediaType.movie
          ? '/movie/$tmdbId/external_ids'
          : '/tv/$tmdbId/external_ids';
      final data = await _get(path);
      return data['imdb_id'] as String?;
    } catch (_) { return null; }
  }

  // ── Episodes (cached 24h + offline stale fallback) ─────────────────────────

  Future<List<Episode>> getEpisodes(int tmdbId, int season) async {
    final key = 'episodes_${tmdbId}_$season';

    // Fresh cache?
    final cached = _cache.getEpisodes(key);
    if (cached != null) return cached.map((e) => Episode.fromJson(e)).toList();

    try {
      final data = await _get('/tv/$tmdbId/season/$season');
      final episodes = (data['episodes'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      await _cache.setEpisodes(key, episodes);
      return episodes.map((e) => Episode.fromJson(e)).toList();
    } catch (_) {
      final stale = _cache.getStaleEpisodes(key);
      if (stale != null) return stale.map((e) => Episode.fromJson(e)).toList();
      return [];
    }
  }

  // ── Cache management ────────────────────────────────────────────────────────

  Future<void> clearCache() => _cache.clear();

  // ── Helper ──────────────────────────────────────────────────────────────────

  List<TmdbMedia> _parseResults(List results, {MediaType? defaultType}) {
    return results
        .where((r) => r['poster_path'] != null)
        .map((r) {
          final json = Map<String, dynamic>.from(r);
          if (!json.containsKey('media_type') && defaultType != null) {
            json['media_type'] =
                defaultType == MediaType.movie ? 'movie' : 'tv';
          }
          return TmdbMedia.fromJson(json);
        })
        .where((m) => m.mediaType == MediaType.movie || m.mediaType == MediaType.tv)
        .toList();
  }
}
