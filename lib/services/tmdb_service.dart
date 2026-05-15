import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive/hive.dart';
import '../models/media_model.dart';

/// A Hive-backed cache for TMDB list responses.
/// Every entry stores the raw JSON list + a timestamp.
/// Entries older than [_ttl] are considered stale and refreshed on next call.
class _TmdbCache {
  static const _boxName = 'tmdb_cache_v1';
  static const _ttl = Duration(hours: 6);

  late Box _box;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _box = await Hive.openBox(_boxName);
    _ready = true;
  }

  /// Returns cached data if fresh, null if stale or missing.
  List<dynamic>? get(String key) {
    if (!_ready) return null;
    final entry = _box.get(key);
    if (entry == null) return null;
    final ts = entry['ts'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - ts > _ttl.inMilliseconds) {
      return null; // stale
    }
    return List<dynamic>.from(entry['data'] as List? ?? []);
  }

  Future<void> set(String key, List<dynamic> data) async {
    if (!_ready) return;
    await _box.put(key, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    });
  }

  Future<void> clear() async => _box.clear();
}

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

  /// Perform GET and decode JSON.
  Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic>? queryParams]) async {
    final uri = _uri(path, queryParams);
    final res = await http.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('TMDB ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Genre Constants ──────────────────────────────────────────────────────────

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

  // ── Cached list helper ───────────────────────────────────────────────────────

  Future<List<TmdbMedia>> _getCached(
    String cacheKey,
    String path, {
    Map<String, dynamic>? queryParams,
    MediaType? defaultType,
  }) async {
    // Try cache first
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      return _parseResults(cached, defaultType: defaultType);
    }
    // Fetch fresh
    try {
      final data = await _get(path, queryParams);
      final results = data['results'] as List? ?? [];
      await _cache.set(cacheKey, results);
      return _parseResults(results, defaultType: defaultType);
    } catch (_) {
      return [];
    }
  }

  // ── Home / Discovery ─────────────────────────────────────────────────────────

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

  // ── Genre Discovery ──────────────────────────────────────────────────────────

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

  // ── Recommendations & Similar ────────────────────────────────────────────────

  Future<List<TmdbMedia>> getRecommendations(int tmdbId, MediaType type) async {
    try {
      final path = type == MediaType.movie
          ? '/movie/$tmdbId/recommendations'
          : '/tv/$tmdbId/recommendations';
      final data = await _get(path);
      return _parseResults(data['results'] ?? [], defaultType: type);
    } catch (_) { return []; }
  }

  Future<List<TmdbMedia>> getSimilar(int tmdbId, MediaType type) async {
    try {
      final path = type == MediaType.movie
          ? '/movie/$tmdbId/similar'
          : '/tv/$tmdbId/similar';
      final data = await _get(path);
      return _parseResults(data['results'] ?? [], defaultType: type);
    } catch (_) { return []; }
  }

  // ── Search ───────────────────────────────────────────────────────────────────

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

  // ── Details ──────────────────────────────────────────────────────────────────

  Future<TmdbDetails> getMovieDetails(int tmdbId) async {
    final data = await _get('/movie/$tmdbId', {
      'append_to_response': 'credits,external_ids,videos',
    });
    return TmdbDetails.fromJson(data, MediaType.movie);
  }

  Future<TmdbDetails> getTvDetails(int tmdbId) async {
    final data = await _get('/tv/$tmdbId', {
      'append_to_response': 'credits,external_ids,videos',
    });
    return TmdbDetails.fromJson(data, MediaType.tv);
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

  // ── Episodes ─────────────────────────────────────────────────────────────────

  Future<List<Episode>> getEpisodes(int tmdbId, int season) async {
    final data = await _get('/tv/$tmdbId/season/$season');
    return (data['episodes'] as List? ?? [])
        .map((e) => Episode.fromJson(e))
        .toList();
  }

  // ── Cache management ─────────────────────────────────────────────────────────

  Future<void> clearCache() => _cache.clear();

  // ── Helper ───────────────────────────────────────────────────────────────────

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
