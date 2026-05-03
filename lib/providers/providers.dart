import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_model.dart';
import '../models/download_source.dart';
import '../services/tmdb_service.dart';
import '../services/history_service.dart';
import '../services/download_service.dart';
import '../services/telegram_service.dart';
import '../services/recommendation_service.dart';
import '../services/watchlist_service.dart';
import '../services/subtitle_service.dart';
import '../theme/app_tokens.dart';

// ─── Core Service Providers ───────────────────────────────────────────────────

final tmdbServiceProvider = Provider<TmdbService>((ref) => TmdbService());

final historyServiceProvider = Provider<HistoryService>((ref) {
  throw UnimplementedError('historyServiceProvider must be overridden in main()');
});

final downloadServiceProvider = ChangeNotifierProvider<DownloadService>((ref) {
  throw UnimplementedError('downloadServiceProvider must be overridden in main()');
});


final telegramServiceProvider = ChangeNotifierProvider<TelegramService>((ref) {
  throw UnimplementedError('telegramServiceProvider must be overridden in main()');
});

final recommendationServiceProvider = Provider<RecommendationService>((ref) {
  throw UnimplementedError('recommendationServiceProvider must be overridden in main()');
});

final watchlistServiceProvider = Provider<WatchlistService>((ref) {
  throw UnimplementedError('watchlistServiceProvider must be overridden in main()');
});

/// Reactive watchlist state — updates automatically when items are added/removed.
final watchlistProvider = ChangeNotifierProvider<WatchlistService>((ref) {
  throw UnimplementedError('watchlistProvider must be overridden in main()');
});

/// OpenSubtitles API client — singleton, no init needed.
final subtitleServiceProvider = Provider<SubtitleService>((ref) => SubtitleService());

/// Current download source preference (telegram only).
final downloadSourceProvider = StateProvider<DownloadSource>(
  (ref) => DownloadSource.telegram,
);

// ─── Theme Seed Color ─────────────────────────────────────────────────────────

final seedColorProvider = StateNotifierProvider<SeedColorNotifier, Color>(
  (ref) => SeedColorNotifier(),
);

class SeedColorNotifier extends StateNotifier<Color> {
  static const _key = 'theme_seed_color';

  SeedColorNotifier() : super(kThemeSeeds.first.seed);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_key);
    if (value != null) state = Color(value);
  }

  Future<void> setSeed(Color color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, color.toARGB32());
  }
}

// ─── Home Screen Data ─────────────────────────────────────────────────────────

final trendingProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getTrending();
});

final popularMoviesProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getPopularMovies();
});

final popularTvProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getPopularTv();
});

final topRatedMoviesProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getTopRatedMovies();
});

final topRatedTvProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getTopRatedTv();
});

final nowPlayingProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getNowPlayingMovies();
});

final airingTodayProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getAiringToday();
});

final upcomingProvider = FutureProvider<List<TmdbMedia>>((ref) {
  return ref.watch(tmdbServiceProvider).getUpcoming();
});

// ─── Genre Discovery ─────────────────────────────────────────────────────────

/// Which genre pill is selected on the home screen (null = no genre filter).
final selectedGenreProvider = StateProvider<int?>((ref) => null);

/// Which content type is active for the genre row (movies vs TV).
final genreTypeProvider = StateProvider<MediaType>((ref) => MediaType.movie);

/// Parameterised: fetch content for a specific genre + type + page.
final genreContentProvider = FutureProvider.family<List<TmdbMedia>,
    ({int genreId, MediaType type, int page})>((ref, params) {
  return ref.watch(tmdbServiceProvider).discoverByGenre(
    params.genreId,
    type: params.type,
    page: params.page,
  );
});

// ─── Recommendations ─────────────────────────────────────────────────────────

/// TMDB recommendations for a specific title (used in Details + Watch Next row).
final recommendationsProvider =
    FutureProvider.family<List<TmdbMedia>, ({int tmdbId, MediaType type})>(
        (ref, params) {
  return ref
      .watch(tmdbServiceProvider)
      .getRecommendations(params.tmdbId, params.type);
});

/// Similar titles (same themes/keywords).
final similarProvider =
    FutureProvider.family<List<TmdbMedia>, ({int tmdbId, MediaType type})>(
        (ref, params) {
  return ref
      .watch(tmdbServiceProvider)
      .getSimilar(params.tmdbId, params.type);
});

/// "Watch Next" — combined recs + similar for the last-watched title.
final watchNextProvider = FutureProvider<List<TmdbMedia>>((ref) async {
  final recs = ref.watch(recommendationServiceProvider);
  final tmdb = ref.watch(tmdbServiceProvider);
  return recs.getWatchNext(tmdb);
});

/// "For You" — top-genre personalized discovery row.
final forYouProvider = FutureProvider<List<TmdbMedia>>((ref) async {
  final recs = ref.watch(recommendationServiceProvider);
  final tmdb = ref.watch(tmdbServiceProvider);
  return recs.getPersonalizedRow(tmdb);
});

// ─── Watch History ────────────────────────────────────────────────────────────

final continueWatchingProvider =
    StateNotifierProvider<ContinueWatchingNotifier, List<WatchHistory>>((ref) {
  return ContinueWatchingNotifier(ref.watch(historyServiceProvider));
});

class ContinueWatchingNotifier extends StateNotifier<List<WatchHistory>> {
  final HistoryService _history;
  ContinueWatchingNotifier(this._history)
      : super(_history.getContinueWatching());

  void refresh() => state = _history.getContinueWatching();
}

// ─── Search ───────────────────────────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider =
    FutureProvider.family<List<TmdbMedia>, String>((ref, query) {
  if (query.isEmpty) return Future.value([]);
  return ref.watch(tmdbServiceProvider).search(query);
});

// ─── Media Details ────────────────────────────────────────────────────────────

final movieDetailsProvider =
    FutureProvider.family<TmdbDetails, int>((ref, tmdbId) {
  return ref.watch(tmdbServiceProvider).getMovieDetails(tmdbId);
});

final tvDetailsProvider =
    FutureProvider.family<TmdbDetails, int>((ref, tmdbId) {
  return ref.watch(tmdbServiceProvider).getTvDetails(tmdbId);
});

final episodesProvider =
    FutureProvider.family<List<Episode>, ({int tmdbId, int season})>(
        (ref, params) {
  return ref.watch(tmdbServiceProvider).getEpisodes(params.tmdbId, params.season);
});

// ─── Selected Season (Details Screen) ────────────────────────────────────────

final selectedSeasonProvider = StateProvider.family<int, int>(
  (ref, tmdbId) => 1,
);

// ─── Selected Filter (Home Screen — Movies / TV / All) ────────────────────────

enum ContentFilter { all, movies, tv }

final contentFilterProvider = StateProvider<ContentFilter>(
  (ref) => ContentFilter.all,
);
