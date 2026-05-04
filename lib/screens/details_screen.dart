import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/media_model.dart';
import '../models/download_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/episode_tile.dart';
import '../widgets/media_card.dart';
import '../theme/app_tokens.dart';
import '../screens/download_screen.dart';
import '../widgets/download_filter_sheet.dart';


class DetailsScreen extends ConsumerStatefulWidget {
  final String mediaType;
  final int tmdbId;

  const DetailsScreen({
    super.key,
    required this.mediaType,
    required this.tmdbId,
  });

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  MediaType get type =>
      widget.mediaType == 'movie' ? MediaType.movie : MediaType.tv;

  @override
  void initState() {
    super.initState();
    // Feed the taste profile as soon as the user opens a details page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final details = type == MediaType.movie
          ? ref.read(movieDetailsProvider(widget.tmdbId)).valueOrNull
          : ref.read(tvDetailsProvider(widget.tmdbId)).valueOrNull;
      if (details == null) return;
      ref.read(recommendationServiceProvider).recordWatch(
        tmdbId: widget.tmdbId,
        title: details.title,
        type: type,
        genreIds: details.genreIds,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final details = type == MediaType.movie
        ? ref.watch(movieDetailsProvider(widget.tmdbId))
        : ref.watch(tvDetailsProvider(widget.tmdbId));

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: details.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          // Also record once data loads (covers cases where cache already has it)
          ref.read(recommendationServiceProvider).recordWatch(
            tmdbId: widget.tmdbId,
            title: d.title,
            type: type,
            genreIds: d.genreIds,
          );
          return _DetailsContent(details: d);
        },
      ),
    );
  }
}

// ─── Details Content ──────────────────────────────────────────────────────────

class _DetailsContent extends ConsumerWidget {
  final TmdbDetails details;
  const _DetailsContent({required this.details});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = context.isExpanded;

    return CustomScrollView(
      slivers: [
        // Sticky back button + backdrop
        SliverAppBar(
          expandedHeight: isTv ? 500.0 : 400.0,
          pinned: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          leading: Focus(
            autofocus: false,
            child: IconButton(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          actions: [
            // Watchlist bookmark button
            Consumer(builder: (ctx, ref, _) {
              final wl = ref.watch(watchlistProvider);
              final inList = wl.isInWatchlist(details.id);
              return IconButton(
                icon: Icon(inList
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded),
                color: inList
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
                tooltip: inList ? 'Remove from Watchlist' : 'Add to Watchlist',
                onPressed: () {
                  final media = TmdbMedia(
                    id: details.id,
                    title: details.title,
                    posterPath: details.posterPath,
                    backdropPath: details.backdropPath,
                    overview: details.overview,
                    voteAverage: details.voteAverage,
                    mediaType: details.mediaType,
                  );
                  ref.read(watchlistProvider).toggle(media);
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(inList
                        ? 'Removed from Watchlist'
                        : '✅ Added to Watchlist'),
                    duration: const Duration(seconds: 2),
                  ));
                },
              );
            }),
            const SizedBox(width: 4),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: _BackdropHeader(details: details),
          ),
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isTv ? 60 : 20,
              vertical: 24,
            ),
            child: isTv
                ? _TvLayout(details: details)
                : _MobileLayout(details: details),
          ),
        ),

        // Episodes for TV
        if (details.mediaType == MediaType.tv && details.seasons.isNotEmpty)
          SliverToBoxAdapter(
            child: _EpisodesSection(details: details),
          ),

        // Recommendations
        SliverToBoxAdapter(
          child: Consumer(builder: (ctx, ref, _) {
            final recs = ref.watch(recommendationsProvider(
              (tmdbId: details.id, type: details.mediaType),
            ));
            return recs.when(
              data: (items) => items.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 40),
                      child: MediaRow(
                        title: 'More Like This',
                        items: items,
                        onTap: (m) => context.push(
                          '/details/${m.mediaType == MediaType.movie ? 'movie' : 'tv'}/${m.id}',
                        ),
                      ),
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            );
          }),
        ),
      ],
    );
  }
}

// ─── Backdrop Header ──────────────────────────────────────────────────────────

class _BackdropHeader extends StatelessWidget {
  final TmdbDetails details;
  const _BackdropHeader({required this.details});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(
          imageUrl: details.backdropUrl,
          fit: BoxFit.cover,
          memCacheWidth: 1280,
        ),
        DecoratedBox(
          decoration: BoxDecoration(gradient: AtmosTheme.heroGradient(Theme.of(context).colorScheme)),
        ),
      ],
    );
  }
}

// ─── Mobile Layout ────────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  final TmdbDetails details;
  const _MobileLayout({required this.details});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poster with slide-in
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: details.posterUrl,
                width: 120,
                height: 180,
                fit: BoxFit.cover,
                memCacheWidth: 240,
              ),
            ).animate()
              .fadeIn(duration: 400.ms, curve: Curves.easeOut)
              .slideX(begin: -0.15, end: 0, duration: 450.ms,
                  curve: const Cubic(0.05, 0.7, 0.1, 1.0)),
            const SizedBox(width: 16),
            Expanded(
              child: _MediaInfo(details: details),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _PlayButton(details: details)
          .animate(delay: 150.ms)
          .fadeIn(duration: 350.ms)
          .slideY(begin: 0.1, end: 0, duration: 350.ms,
              curve: Curves.easeOut),
        const SizedBox(height: 20),
        _Overview(details: details)
          .animate(delay: 200.ms)
          .fadeIn(duration: 400.ms),
        if (details.cast.isNotEmpty) ...[
          const SizedBox(height: 20),
          _CastRow(cast: details.cast)
            .animate(delay: 250.ms)
            .fadeIn(duration: 400.ms),
        ],
      ],
    );
  }
}

// ─── TV Layout ────────────────────────────────────────────────────────────────

class _TvLayout extends StatelessWidget {
  final TmdbDetails details;
  const _TvLayout({required this.details});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left: Poster
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CachedNetworkImage(
            imageUrl: details.posterUrl,
            width: 220,
            height: 330,
            fit: BoxFit.cover,
            memCacheWidth: 440,
          ),
        ).animate()
          .fadeIn(duration: 400.ms, curve: Curves.easeOut)
          .slideX(begin: -0.15, end: 0, duration: 450.ms,
              curve: const Cubic(0.05, 0.7, 0.1, 1.0)),
        const SizedBox(width: 40),
        // Right: Info + Play
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MediaInfo(details: details),
              const SizedBox(height: 24),
              _PlayButton(details: details)
                .animate(delay: 150.ms)
                .fadeIn(duration: 350.ms)
                .slideY(begin: 0.1, end: 0, duration: 350.ms,
                    curve: Curves.easeOut),
              const SizedBox(height: 24),
              _Overview(details: details)
                .animate(delay: 200.ms)
                .fadeIn(duration: 400.ms),
              if (details.cast.isNotEmpty) ...[
                const SizedBox(height: 24),
                _CastRow(cast: details.cast)
                  .animate(delay: 250.ms)
                  .fadeIn(duration: 400.ms),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Info Block ───────────────────────────────────────────────────────────────

class _MediaInfo extends StatelessWidget {
  final TmdbDetails details;
  const _MediaInfo({required this.details});

  @override
  Widget build(BuildContext context) {
    final isTv = context.isExpanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          details.title,
          style: TextStyle(
            fontSize: isTv ? 36 : 22,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.onSurface,
            height: 1.2,
          ),
        ).animate().fadeIn().slideY(begin: 0.1, end: 0),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            if (details.voteAverage > 0)
              _Badge(
                icon: Icons.star_rounded,
                label: details.voteAverage.toStringAsFixed(1),
                color: Colors.amber.shade400,
              ),
            if (details.year.isNotEmpty) _Badge(label: details.year),
            if (details.runtime != null)
              _Badge(label: '${details.runtime} min'),
            if (details.numberOfSeasons != null)
              _Badge(label: '${details.numberOfSeasons} Seasons'),
            ...details.genres.take(3).map((g) => _Badge(label: g.name)),
          ],
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color? color;
  const _Badge({this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Action Buttons (Play + Download) ────────────────────────────────────────

class _PlayButton extends ConsumerStatefulWidget {
  final TmdbDetails details;
  const _PlayButton({required this.details});

  @override
  ConsumerState<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends ConsumerState<_PlayButton> {
  bool _loadingDownload = false;

  void _onPlay() async {
    // Build the args map for both players
    final Map<String, dynamic> baseArgs;
    if (widget.details.mediaType == MediaType.movie) {
      baseArgs = {
        'imdbId': widget.details.imdbId ?? '',
        'tmdbId': widget.details.id,
        'title': widget.details.title,
        'posterPath': widget.details.posterPath ?? '',
        'type': 'movie',
      };
    } else {
      final seasons = widget.details.seasons;
      final firstSeason = seasons.isNotEmpty
          ? seasons.firstWhere((s) => s.seasonNumber > 0,
              orElse: () => seasons.first)
          : null;
      if (firstSeason == null) return;
      baseArgs = {
        'imdbId': widget.details.imdbId ?? '',
        'tmdbId': widget.details.id,
        'title': widget.details.title,
        'posterPath': widget.details.posterPath ?? '',
        'type': 'tv',
        'season': firstSeason.seasonNumber,
        'episode': 1,
        'episodeName': '',
      };
    }

    // Show player mode picker
    if (!mounted) return;
    final route = await _PlayerModeSheet.show(context);
    if (!mounted || route == null) return;

    context.push(route, extra: baseArgs);
  }

  void _onDownload() async {
    // ── Step 1: Show quality/audio filter picker ──────────────────────────
    final filters = await DownloadFilterSheet.show(
      context,
      title: widget.details.title,
    );
    if (!mounted || filters == null) return; // user dismissed

    setState(() => _loadingDownload = true);
    try {
      final telegram = ref.read(telegramServiceProvider);

      // ── Step 2: Build search futures (quality hint appended to Telegram query)
      final futures = <Future<List<QualityOption>>>[];

      if (telegram.isLoggedIn) {
        // Append filter hints so TDLib search is more precise
        final hint = filters.searchHint;
        final queryTitle = hint.isNotEmpty
            ? '${widget.details.title} $hint'
            : widget.details.title;
        futures.add(
          telegram.searchVideos(
            queryTitle,
            year: widget.details.releaseDate != null
                ? int.tryParse(widget.details.releaseDate!.split('-').first)
                : null,
            mediaType: widget.details.mediaType == MediaType.movie ? 'movie' : 'tv',
          ).then((results) => telegram.toQualityOptions(results)),
        );
      }

      if (futures.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No sources available. Check Settings → Download Source.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final results = await Future.wait(futures);
      var allOptions = results.expand((r) => r).toList();

      // ── Step 3: Filter results by quality + language
      if (!filters.isDefault) {
        final filtered = allOptions.where((q) => filters.matchesOption(
          quality: q.quality,
          audioChannels: q.audioChannels,
        )).toList();

        if (filtered.isEmpty) {
          // Nothing matched — warn user and show full list
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'No ${filters.quality != QualityFilter.any ? filters.quality.label : ""}'
                  '${filters.hasLanguageFilter ? " ${filters.language.label}" : ""} '
                  'results found — showing all available sources',
                ),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          // allOptions stays as-is (full list)
        } else {
          allOptions = filtered;
        }
      }

      if (!mounted) return;
      if (allOptions.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No download sources found for this title'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      await QualityPickerSheet.show(
        context,
        options: allOptions,
        title: widget.details.title,
        onSelect: (q) {
          final dl = ref.read(downloadServiceProvider);
          dl.startDownload(
            tmdbId: widget.details.id,
            imdbId: widget.details.imdbId ?? '',
            title: widget.details.title,
            mediaType: 'movie',
            quality: q,
            posterPath: widget.details.posterPath,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Downloading ${widget.details.title} in ${q.quality} via Telegram ⚡',
              ),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      );
    } finally {
      if (mounted) setState(() => _loadingDownload = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMovie = widget.details.mediaType == MediaType.movie;
    return Focus(
      autofocus: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Play button
          ElevatedButton.icon(
            onPressed: _onPlay,
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: Text(
              isMovie ? 'Play Movie' : 'Play S01E01',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          if (isMovie) ...[  
            const SizedBox(width: 10),
            // ── Download button
            ElevatedButton.icon(
              onPressed: _loadingDownload ? null : _onDownload,
              icon: _loadingDownload
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download_rounded, size: 20),
              label: const Text('Download',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                side: BorderSide(color: Theme.of(context).colorScheme.primary.withOpacity(0.4)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Overview ─────────────────────────────────────────────────────────────────

class _Overview extends StatefulWidget {
  final TmdbDetails details;
  const _Overview({required this.details});

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final overview = widget.details.overview ?? '';
    if (overview.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Overview',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          overview,
          maxLines: _expanded ? null : 4,
          overflow: _expanded ? null : TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            _expanded ? 'Show less' : 'Read more',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Cast Row ─────────────────────────────────────────────────────────────────

class _CastRow extends StatelessWidget {
  final List<Cast> cast;
  const _CastRow({required this.cast});

  @override
  Widget build(BuildContext context) {
    final isTv = context.isExpanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cast',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: isTv ? 120 : 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            itemBuilder: (context, i) {
              final c = cast[i];
              return Padding(
                padding: const EdgeInsets.only(right: 14),
                child: SizedBox(
                  width: isTv ? 80 : 65,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: isTv ? 36 : 28,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                        backgroundImage: c.profileUrl.isNotEmpty
                            ? CachedNetworkImageProvider(c.profileUrl)
                            : null,
                        child: c.profileUrl.isEmpty
                            ? Icon(Icons.person, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7))
                            : null,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        c.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isTv ? 11 : 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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

// ─── Episodes Section (TV Only) ───────────────────────────────────────────────

class _EpisodesSection extends ConsumerWidget {
  final TmdbDetails details;
  const _EpisodesSection({required this.details});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = context.isExpanded;
    final selectedSeason = ref.watch(selectedSeasonProvider(details.id));
    final episodes = ref.watch(
      episodesProvider((tmdbId: details.id, season: selectedSeason)),
    );
    final historyService = ref.watch(historyServiceProvider);
    final hPad = isTv ? 60.0 : 20.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          // Season header + Download Season button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Episodes',
                style: TextStyle(
                  fontSize: isTv ? 22 : 18,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              _DownloadSeasonButton(
                details: details,
                selectedSeason: selectedSeason,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Season selector
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: details.seasons.length,
              itemBuilder: (context, i) {
                final s = details.seasons[i];
                final sel = s.seasonNumber == selectedSeason;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Focus(
                    child: GestureDetector(
                      onTap: () {
                        ref
                            .read(selectedSeasonProvider(details.id).notifier)
                            .state = s.seasonNumber;
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: sel ? AtmosTheme.primaryGradient(Theme.of(context).colorScheme) : null,
                          color: sel ? null : Theme.of(context).colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          s.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: sel
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          // Episode list — Column avoids shrinkWrap double-layout penalty
          episodes.when(
            loading: () => Center(
              child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            ),
            error: (e, _) => Text(
              'Error loading episodes: $e',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)),
            ),
            data: (eps) => Column(
              children: eps.map((ep) {
                final history = historyService.getProgress(
                  details.imdbId ?? '',
                  season: selectedSeason,
                  episode: ep.episodeNumber,
                );
                return EpisodeTile(
                  episode: ep,
                  watchHistory: history,
                  onTap: () async {
                    final route = await _PlayerModeSheet.show(context);
                    if (!context.mounted || route == null) return;
                    context.push(route, extra: {
                      'imdbId': details.imdbId ?? '',
                      'tmdbId': details.id,
                      'title': details.title,
                      'posterPath': details.posterPath ?? '',
                      'type': 'tv',
                      'season': selectedSeason,
                      'episode': ep.episodeNumber,
                      'episodeName': ep.name,
                    });
                  },
                  onDownload: () async {
                    final filters = await DownloadFilterSheet.show(
                      context,
                      title: '${details.title} S${selectedSeason.toString().padLeft(2, '0')}E${ep.episodeNumber.toString().padLeft(2, '0')}',
                    );
                    if (!context.mounted || filters == null) return;

                    final telegram = ref.read(telegramServiceProvider);
                    if (!telegram.isLoggedIn) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log in to Telegram in Settings to download')),
                      );
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Searching S${selectedSeason.toString().padLeft(2, "0")}E${ep.episodeNumber.toString().padLeft(2, "0")}...')),
                    );

                    final futures = <Future<List<QualityOption>>>[];
                    final hint = filters.searchHint;
                    final queryTitle = hint.isNotEmpty ? '${details.title} $hint' : details.title;
                    futures.add(
                      telegram.searchVideos(queryTitle, mediaType: 'tv', season: selectedSeason, episode: ep.episodeNumber)
                          .then((r) => telegram.toQualityOptions(r)),
                    );

                    if (futures.isEmpty) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No sources available'), backgroundColor: Colors.orange),
                      );
                      return;
                    }

                    final results = await Future.wait(futures);
                    var allOptions = results.expand((r) => r).toList();

                    if (!filters.isDefault) {
                      final filtered = allOptions.where((q) => filters.matchesOption(
                        quality: q.quality, audioChannels: q.audioChannels)).toList();
                      if (filtered.isNotEmpty) allOptions = filtered;
                    }

                    if (!context.mounted) return;
                    if (allOptions.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No sources found'), backgroundColor: Colors.red),
                      );
                      return;
                    }
                    await QualityPickerSheet.show(
                      context,
                      options: allOptions,
                      title: '${details.title} S${selectedSeason.toString().padLeft(2, "0")}E${ep.episodeNumber.toString().padLeft(2, "0")}',
                      onSelect: (q) {
                        ref.read(downloadServiceProvider).startDownload(
                          tmdbId: details.id, imdbId: details.imdbId ?? '', title: details.title,
                          mediaType: 'tv', quality: q, season: selectedSeason,
                          episode: ep.episodeNumber, episodeName: ep.name,
                          posterPath: details.posterPath,
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Downloading ${ep.name} in ${q.quality}'
                                '${q.source == "telegram" ? " via Telegram ⚡" : " via Torrent 🔗"}'),
                            duration: const Duration(seconds: 3),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    );
                  },
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ─── Download Season Button ──────────────────────────────────────────────────

class _DownloadSeasonButton extends ConsumerStatefulWidget {
  final TmdbDetails details;
  final int selectedSeason;

  const _DownloadSeasonButton({
    required this.details,
    required this.selectedSeason,
  });

  @override
  ConsumerState<_DownloadSeasonButton> createState() =>
      _DownloadSeasonButtonState();
}

class _DownloadSeasonButtonState extends ConsumerState<_DownloadSeasonButton> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _loading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            )
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _onTap,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cs.primary.withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_rounded, size: 16, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(
                        'Season',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _onTap() async {
    final telegram = ref.read(telegramServiceProvider);
    if (!telegram.isLoggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Log in to Telegram in Settings to download'),
        ),
      );
      return;
    }

    // Get episode count for the selected season
    final selectedSeason = widget.selectedSeason;
    final seasonMeta = widget.details.seasons.firstWhere(
      (s) => s.seasonNumber == selectedSeason,
      orElse: () => widget.details.seasons.first,
    );
    final episodeCount = seasonMeta.episodeCount;

    // Confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Download Season $selectedSeason',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Download all $episodeCount episodes of '
          '${widget.details.title} Season $selectedSeason?\n\n'
          'Already downloaded episodes will be skipped.',
          style: TextStyle(
            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _loading = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Searching for Season $selectedSeason episodes...',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      final dl = ref.read(downloadServiceProvider);
      final tasks = await dl.downloadSeason(
        tmdbId: widget.details.id,
        imdbId: widget.details.imdbId ?? '',
        title: widget.details.title,
        season: selectedSeason,
        totalEpisodes: episodeCount,
        posterPath: widget.details.posterPath,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tasks.isEmpty
                ? 'No episodes found in catalog for Season $selectedSeason'
                : '${tasks.length}/$episodeCount episodes queued for download ⚡',
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          backgroundColor:
              tasks.isEmpty ? Colors.orange : Theme.of(context).colorScheme.primary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Season download failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ─── Player Mode Picker Sheet ────────────────────────────────────────────────

class _PlayerModeSheet extends StatelessWidget {
  const _PlayerModeSheet();

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _PlayerModeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Choose Player',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('How do you want to watch?',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          _ModeCard(
            icon: Icons.language_rounded,
            iconColor: Colors.blueAccent,
            title: 'Web Player',
            subtitle: 'Iframe embed — always works',
            bullets: const ['⚡ Fastest to start', '🛡️ Ads blocked', '🔄 Auto provider fallback'],
            onTap: () => Navigator.pop(context, '/player'),
          ),
          const SizedBox(height: 12),
          _ModeCard(
            icon: Icons.play_circle_fill_rounded,
            iconColor: Colors.deepPurpleAccent,
            title: 'Native Player',
            subtitle: 'Hardware decoded · mpv engine',
            bullets: const ['🔋 Better battery life', '🎞️ True hardware decoding', '🖼️ Picture-in-Picture'],
            badge: 'BETA',
            onTap: () => Navigator.pop(context, '/native-player'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<String> bullets;
  final String? badge;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon, required this.iconColor, required this.title,
    required this.subtitle, required this.bullets, required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.orange.withOpacity(0.4)),
                        ),
                        child: Text(badge!,
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 9,
                                fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 8),
                  ...bullets.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(b, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  )),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
