import 'package:hive/hive.dart';
import '../models/media_model.dart';
import 'tmdb_service.dart';

/// Local taste-profile engine that runs entirely on-device.
///
/// Every time the user watches or downloads something, [recordWatch] is called
/// which increments that title's genre IDs in a Hive box.  The box stores a
/// simple `Map<String, dynamic>` where keys are genre ID strings and values
/// are cumulative scores (double).
///
/// [getWatchNext] picks the most recently watched item and returns TMDB
/// recommendations + similar titles as a combined, de-duplicated list.
class RecommendationService {
  static const _boxName = 'taste_profile';
  static const _lastWatchedKey = 'last_watched';
  static const _lastWatchedTypeKey = 'last_watched_type';
  static const _lastWatchedTitleKey = 'last_watched_title';

  late Box _box;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox(_boxName);
    _initialized = true;
  }

  // ── Taste Profile ────────────────────────────────────────────────────────────

  /// Call this whenever a user opens a details page or starts watching.
  /// [genreIds] come from TmdbDetails.genreIds.
  void recordWatch({
    required int tmdbId,
    required String title,
    required MediaType type,
    required List<int> genreIds,
  }) {
    if (!_initialized) return;

    // Update last-watched anchor for Watch Next
    _box.put(_lastWatchedKey, tmdbId);
    _box.put(_lastWatchedTypeKey, type == MediaType.movie ? 'movie' : 'tv');
    _box.put(_lastWatchedTitleKey, title);

    // Increment genre scores
    final scores = Map<String, double>.from(
      (_box.get('genre_scores') as Map? ?? {}).cast<String, double>(),
    );
    for (final id in genreIds) {
      scores['$id'] = (scores['$id'] ?? 0) + 1.0;
    }
    _box.put('genre_scores', scores);
  }

  /// Returns the genre IDs sorted by score (highest first).
  List<int> get topGenreIds {
    if (!_initialized) return [];
    final raw = (_box.get('genre_scores') as Map? ?? {}).cast<String, double>();
    final sorted = raw.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => int.tryParse(e.key) ?? 0).where((id) => id > 0).toList();
  }

  /// Top genre name label (e.g. "Action") for display.
  String get topGenreName {
    final ids = topGenreIds;
    if (ids.isEmpty) return '';
    final g = TmdbService.movieGenres[ids.first] ?? TmdbService.tvGenres[ids.first];
    return g?.name ?? '';
  }

  // ── Watch Next ───────────────────────────────────────────────────────────────

  /// Last watched TMDB ID (0 if none).
  int get lastWatchedId => (_box.get(_lastWatchedKey) as int?) ?? 0;

  /// Last watched media type.
  MediaType get lastWatchedType {
    final raw = _box.get(_lastWatchedTypeKey) as String? ?? 'movie';
    return raw == 'tv' ? MediaType.tv : MediaType.movie;
  }

  /// Title of last watched item (for "Because you watched X" label).
  String get lastWatchedTitle =>
      (_box.get(_lastWatchedTitleKey) as String?) ?? '';

  /// Fetch combined Watch-Next list: TMDB recommendations + similar,
  /// de-duplicated and capped at 20 items.
  Future<List<TmdbMedia>> getWatchNext(TmdbService tmdb) async {
    if (!_initialized || lastWatchedId == 0) return [];

    final results = await Future.wait([
      tmdb.getRecommendations(lastWatchedId, lastWatchedType),
      tmdb.getSimilar(lastWatchedId, lastWatchedType),
    ]);

    final seen = <int>{};
    final combined = <TmdbMedia>[];
    for (final list in results) {
      for (final m in list) {
        if (seen.add(m.id)) combined.add(m);
      }
    }
    return combined.take(20).toList();
  }

  /// Fetch top-genre discovery row.
  Future<List<TmdbMedia>> getPersonalizedRow(TmdbService tmdb) async {
    if (!_initialized) return [];
    final ids = topGenreIds;
    if (ids.isEmpty) return [];
    // Use top genre ID, prefer movies
    return tmdb.discoverByGenre(ids.first, type: MediaType.movie, minRating: 6.0);
  }

  // ── Clear ────────────────────────────────────────────────────────────────────

  Future<void> clearProfile() async {
    await _box.clear();
  }
}
