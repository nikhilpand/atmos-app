import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/media_model.dart';
import '../providers/providers.dart';
import '../services/tmdb_service.dart';
import '../theme/app_theme.dart';
import '../widgets/media_card.dart';
import '../services/ota_update_service.dart';
import '../widgets/update_dialog.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _heroIndex = 0;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    final release = await ref.read(otaUpdateProvider).checkForUpdate();
    if (release != null && mounted) {
      UpdateDialog.show(context, release);
    }
  }

  @override
  void dispose() { _scroll.dispose(); super.dispose(); }

  void _go(TmdbMedia m) =>
      context.push('/details/${m.mediaType == MediaType.movie ? 'movie' : 'tv'}/${m.id}');

  void _goGenre(int id, String name, String emoji, MediaType type) =>
      context.push('/genre/$id', extra: {'name': name, 'emoji': emoji, 'type': type.name});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filter = ref.watch(contentFilterProvider);
    final trending = ref.watch(trendingProvider);
    final popularMovies = ref.watch(popularMoviesProvider);
    final popularTv = ref.watch(popularTvProvider);
    final topRatedMovies = ref.watch(topRatedMoviesProvider);
    final topRatedTv = ref.watch(topRatedTvProvider);
    final nowPlaying = ref.watch(nowPlayingProvider);
    final airingToday = ref.watch(airingTodayProvider);
    final upcoming = ref.watch(upcomingProvider);
    final watchNext = ref.watch(watchNextProvider);
    final forYou = ref.watch(forYouProvider);
    final continueWatching = ref.watch(continueWatchingProvider);
    final recs = ref.watch(recommendationServiceProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          // ── AppBar ─────────────────────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            expandedHeight: 0,
            backgroundColor: cs.surface.withOpacity(0.95),
            flexibleSpace: Container(),
            title: Row(
              children: [
                ShaderMask(
                  shaderCallback: (b) => AtmosTheme.primaryGradient(cs).createShader(b),
                  child: Text('ATMOS',
                    style: TextStyle(
                      fontSize: context.isExpanded ? 28 : 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 4,
                    )),
                ),
                const Spacer(),
                const _FilterChips(),
              ],
            ),
          ),

          // ── Hero Banner ────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: trending.when(
              data: (items) {
                if (items.isEmpty) return const SizedBox.shrink();
                final hero = items[_heroIndex % items.length];
                return _HeroBanner(
                  media: hero,
                  onPlay: () => _go(hero),
                  onChangeHero: () => setState(() => _heroIndex = (_heroIndex + 1) % items.length),
                );
              },
              loading: () => const _HeroSkeleton(),
              error: (e, _) => _ErrorBanner(message: '$e'),
            ),
          ),

          // ── Genre Pills ────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: _GenrePillRow(onTap: _goGenre),
            ),
          ),

          // ── Resume Download Banner ─────────────────────────────────────────
          SliverToBoxAdapter(
            child: _ResumeBanner(
              onTap: () => context.push('/downloads'),
            ),
          ),

          // ── Continue Watching ──────────────────────────────────────────────
          if (continueWatching.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: _ContinueWatchingRow(items: continueWatching),
              ),
            ),

          // ── Watch Next (Because you watched X) ────────────────────────────
          if (recs.lastWatchedId > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: watchNext.when(
                  data: (items) => items.isEmpty
                      ? const SizedBox.shrink()
                      : MediaRow(
                          title: '▶ Because you watched "${recs.lastWatchedTitle}"',
                          items: items,
                          onTap: _go,
                        ),
                  loading: () => const _RowSkeleton(title: '▶ Watch Next'),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
            ),

          // ── For You (personalized genre) ───────────────────────────────────
          if (recs.topGenreName.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: forYou.when(
                  data: (items) => items.isEmpty
                      ? const SizedBox.shrink()
                      : MediaRow(
                          title: '✨ More ${recs.topGenreName} for You',
                          items: items,
                          onTap: _go,
                        ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
            ),

          // ── Popular Movies ─────────────────────────────────────────────────
          if (filter != ContentFilter.tv)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: popularMovies.when(
                  data: (items) => MediaRow(title: '🔥 Popular Movies', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '🔥 Popular Movies'),
                  error: (e, _) => _ErrorRow(title: '🔥 Popular Movies', error: '$e'),
                ),
              ),
            ),

          // ── Popular TV ─────────────────────────────────────────────────────
          if (filter != ContentFilter.movies)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: popularTv.when(
                  data: (items) => MediaRow(title: '📺 Popular Shows', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '📺 Popular Shows'),
                  error: (e, _) => _ErrorRow(title: '📺 Popular Shows', error: '$e'),
                ),
              ),
            ),

          // ── Top Rated Movies ───────────────────────────────────────────────
          if (filter != ContentFilter.tv)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: topRatedMovies.when(
                  data: (items) => MediaRow(title: '⭐ Top Rated Movies', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '⭐ Top Rated Movies'),
                  error: (e, _) => _ErrorRow(title: '⭐ Top Rated Movies', error: '$e'),
                ),
              ),
            ),

          // ── Top Rated TV ───────────────────────────────────────────────────
          if (filter != ContentFilter.movies)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: topRatedTv.when(
                  data: (items) => MediaRow(title: '⭐ Top Rated Shows', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '⭐ Top Rated Shows'),
                  error: (e, _) => _ErrorRow(title: '⭐ Top Rated Shows', error: '$e'),
                ),
              ),
            ),

          // ── Now in Theaters ────────────────────────────────────────────────
          if (filter != ContentFilter.tv)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: nowPlaying.when(
                  data: (items) => MediaRow(title: '🎬 Now in Theaters', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '🎬 Now in Theaters'),
                  error: (e, _) => _ErrorRow(title: '🎬 Now in Theaters', error: '$e'),
                ),
              ),
            ),

          // ── Airing Today ───────────────────────────────────────────────────
          if (filter != ContentFilter.movies)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: airingToday.when(
                  data: (items) => MediaRow(title: '📡 Airing Today', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '📡 Airing Today'),
                  error: (e, _) => _ErrorRow(title: '📡 Airing Today', error: '$e'),
                ),
              ),
            ),

          // ── Coming Soon ────────────────────────────────────────────────────
          if (filter != ContentFilter.tv)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: upcoming.when(
                  data: (items) => MediaRow(title: '🗓 Coming Soon', items: items, onTap: _go),
                  loading: () => const _RowSkeleton(title: '🗓 Coming Soon'),
                  error: (e, _) => _ErrorRow(title: '🗓 Coming Soon', error: '$e'),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
        ],
      ),
    );
  }
}

// ─── Genre Pill Row ───────────────────────────────────────────────────────────

class _GenrePillRow extends ConsumerWidget {
  final void Function(int id, String name, String emoji, MediaType type) onTap;
  const _GenrePillRow({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final filter = ref.watch(contentFilterProvider);
    final genres = filter == ContentFilter.tv
        ? TmdbService.tvGenres
        : TmdbService.movieGenres;
    final type = filter == ContentFilter.tv ? MediaType.tv : MediaType.movie;
    final hPad = context.isExpanded ? AppSpacing.xxl : AppSpacing.md;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: hPad, bottom: AppSpacing.sm),
          child: Text('Browse by Genre',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            )),
        ),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemCount: genres.length,
            itemBuilder: (ctx, i) {
              final entry = genres.entries.elementAt(i);
              return Focus(
                child: GestureDetector(
                  onTap: () => onTap(entry.key, entry.value.name, entry.value.emoji, type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          cs.primaryContainer,
                          cs.secondaryContainer,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.full),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(entry.value.emoji, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 6),
                        Text(entry.value.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: cs.onPrimaryContainer,
                          )),
                      ],
                    ),
                  ).animate(delay: Duration(milliseconds: i * 30))
                    .fadeIn(duration: 300.ms)
                    .slideX(begin: 0.2, end: 0, duration: 300.ms),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── Filter Chips ─────────────────────────────────────────────────────────────

class _FilterChips extends ConsumerWidget {
  const _FilterChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(contentFilterProvider);
    final cs = Theme.of(context).colorScheme;
    const filters = [
      (ContentFilter.all, 'All'),
      (ContentFilter.movies, 'Movies'),
      (ContentFilter.tv, 'TV'),
    ];
    return Row(
      children: filters.map((f) {
        final selected = current == f.$1;
        return Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm),
          child: Focus(
            child: GestureDetector(
              onTap: () => ref.read(contentFilterProvider.notifier).state = f.$1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: EdgeInsets.symmetric(
                  horizontal: context.isExpanded ? 16 : 12,
                  vertical: context.isExpanded ? 8 : 6,
                ),
                decoration: BoxDecoration(
                  color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: selected ? cs.primary : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Text(f.$2,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  )),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Hero Banner ──────────────────────────────────────────────────────────────

class _HeroBanner extends StatelessWidget {
  final TmdbMedia media;
  final VoidCallback onPlay;
  final VoidCallback onChangeHero;
  const _HeroBanner({required this.media, required this.onPlay, required this.onChangeHero});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = context.isExpanded ? 600.0 : 500.0;
    final screenW = MediaQuery.sizeOf(context).width;
    final cacheW = (screenW * MediaQuery.of(context).devicePixelRatio).toInt();

    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(imageUrl: media.backdropUrl, fit: BoxFit.cover, memCacheWidth: cacheW),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.black.withOpacity(0.4), Colors.transparent, cs.surface],
                stops: const [0.0, 0.35, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft, end: Alignment.centerRight,
                colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          Positioned(
            bottom: AppSpacing.xxl,
            left: context.isExpanded ? AppSpacing.xxl : AppSpacing.md,
            right: context.isExpanded ? AppSpacing.xxl : AppSpacing.md,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: AppRadius.smAll,
                  ),
                  child: Text(
                    media.mediaType == MediaType.movie ? 'MOVIE' : 'SERIES',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                      color: cs.onSecondaryContainer, letterSpacing: 1.5),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(media.title,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontSize: context.isExpanded ? 52 : 36,
                    color: Colors.white, height: 1.1,
                  ),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.1, end: 0),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Icon(Icons.star_rounded, size: 16, color: Colors.amber.shade400),
                    const SizedBox(width: AppSpacing.xs),
                    Text(media.voteAverage.toStringAsFixed(1),
                      style: TextStyle(color: Colors.amber.shade400, fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(width: AppSpacing.md),
                    Text(media.year, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                if (media.overview != null)
                  SizedBox(
                    width: context.isExpanded ? 560 : double.infinity,
                    child: Text(media.overview!,
                      maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.5)),
                  ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Focus(
                      autofocus: true,
                      child: FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow_rounded, size: 22),
                        label: Text(media.mediaType == MediaType.movie ? 'Watch Now' : 'Episodes'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Focus(
                      child: OutlinedButton.icon(
                        onPressed: onChangeHero,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Next'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Continue Watching Row ────────────────────────────────────────────────────

class _ContinueWatchingRow extends StatelessWidget {
  final List<WatchHistory> items;
  const _ContinueWatchingRow({required this.items});

  @override
  Widget build(BuildContext context) {
    final hPad = context.isExpanded ? AppSpacing.xxl : AppSpacing.md;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: hPad, bottom: AppSpacing.md),
          child: Text('▶ Continue Watching',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: context.isExpanded ? 200 : 160,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final h = items[i];
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Focus(
                  child: GestureDetector(
                    onTap: () { if (h.tmdbId > 0) context.push('/details/${h.mediaType}/${h.tmdbId}'); },
                    child: SizedBox(
                      width: context.isExpanded ? 300 : 220,
                      child: ClipRRect(
                        borderRadius: AppRadius.mdAll,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: h.posterPath.startsWith('http')
                                  ? h.posterPath
                                  : 'https://image.tmdb.org/t/p/w342${h.posterPath}',
                              fit: BoxFit.cover, memCacheWidth: 300,
                            ),
                            Container(color: Colors.black.withOpacity(0.5)),
                            Positioned(
                              bottom: 0, left: 0, right: 0,
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                                    if (h.displaySubtitle.isNotEmpty)
                                      Text(h.displaySubtitle, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                                    const SizedBox(height: AppSpacing.xs),
                                    LinearProgressIndicator(
                                      value: h.progressPercent,
                                      backgroundColor: Colors.white.withOpacity(0.2),
                                      valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                                      minHeight: 3,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── Skeletons & Errors ───────────────────────────────────────────────────────

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) => Container(
    height: context.isExpanded ? 600 : 500,
    color: Theme.of(context).colorScheme.surfaceContainer,
  );
}

class _RowSkeleton extends StatelessWidget {
  final String title;
  const _RowSkeleton({required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hPad = context.isExpanded ? AppSpacing.xxl : AppSpacing.md;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: hPad, bottom: AppSpacing.md),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            itemCount: 6,
            itemBuilder: (_, __) => Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: ClipRRect(
                borderRadius: AppRadius.mdAll,
                child: SizedBox(width: 130, height: 195, child: ColoredBox(color: cs.surfaceContainer)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 300, margin: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: AppRadius.lgAll),
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.cloud_off_rounded, size: 48, color: cs.onErrorContainer),
          const SizedBox(height: AppSpacing.md),
          Text('Unable to load content',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.sm),
          Text(message, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: cs.onErrorContainer.withOpacity(0.8))),
        ]),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String title, error;
  const _ErrorRow({required this.title, required this.error});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hPad = context.isExpanded ? AppSpacing.xxl : AppSpacing.md;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: AppSpacing.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(color: cs.errorContainer, borderRadius: AppRadius.smAll),
          child: Row(children: [
            Icon(Icons.error_outline, size: 16, color: cs.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onErrorContainer))),
          ]),
        ),
      ]),
    );
  }
}

// ─── Resume Download Banner ───────────────────────────────────────────────────

class _ResumeBanner extends ConsumerWidget {
  final VoidCallback onTap;
  const _ResumeBanner({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(downloadServiceProvider);

    // Find any active download that is >50% done and paused/queued
    final paused = service.active.where((t) =>
      t.progress > 0.5 &&
      (t.status.name == 'paused' || t.status.name == 'queued')).toList();

    if (paused.isEmpty) return const SizedBox.shrink();

    final task = paused.first;
    final cs = Theme.of(context).colorScheme;
    final pct = (task.progress * 100).toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                colors: [cs.primaryContainer, cs.primaryContainer.withOpacity(0.6)],
              ),
              border: Border.all(color: cs.primary.withOpacity(0.3), width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.download_rounded, color: cs.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Resume downloading',
                          style: TextStyle(fontSize: 11,
                              color: cs.onPrimaryContainer.withOpacity(0.7))),
                      Text(task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onPrimaryContainer)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text('$pct%',
                    style: TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w700, color: cs.primary)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded, size: 14, color: cs.primary),
              ],
            ),
          ),
        ),
      ).animate().fadeIn(duration: 400.ms).slideY(
          begin: -0.3, end: 0, duration: 400.ms, curve: Curves.easeOutCubic),
    );
  }
}
