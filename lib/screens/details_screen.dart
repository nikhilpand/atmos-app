import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:collection/collection.dart';
import '../models/media_model.dart';
import '../models/download_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/episode_tile.dart';
import '../widgets/media_card.dart';
import '../screens/download_screen.dart';
import '../widgets/download_filter_sheet.dart';
import '../services/vegamovies_service.dart';

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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide   = screenWidth >= AppBreakpoints.expanded; // TV/large
    final isTablet = screenWidth >= AppBreakpoints.compact;  // tablet

    return CustomScrollView(
      slivers: [
        // Sticky back button + backdrop
        SliverAppBar(
          expandedHeight: isWide ? 500.0 : 400.0,
          pinned: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          leading: IconButton(
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            color: Theme.of(context).colorScheme.onSurface,
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
              horizontal: isWide ? 60 : isTablet ? 40 : 20,
              vertical: 24,
            ),
            child: isWide
                ? _TvLayout(details: details)
                : _MobileLayout(details: details, isTablet: isTablet),
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
  final bool isTablet;
  const _MobileLayout({required this.details, this.isTablet = false});

  @override
  Widget build(BuildContext context) {
    final posterW = isTablet ? 160.0 : 120.0;
    final posterH = isTablet ? 240.0 : 180.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: details.posterUrl,
                width: posterW,
                height: posterH,
                fit: BoxFit.cover,
                memCacheWidth: 320,
              ),
            ).animate()
              .fadeIn(duration: 400.ms, curve: Curves.easeOut)
              .slideX(begin: -0.15, end: 0, duration: 450.ms,
                  curve: const Cubic(0.05, 0.7, 0.1, 1.0)),
            SizedBox(width: isTablet ? 24 : 16),
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
    final cs = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final isWide   = screenW >= AppBreakpoints.expanded;
    final isTablet = screenW >= AppBreakpoints.compact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          details.title,
          style: TextStyle(
            fontSize: isWide ? 36 : isTablet ? 28 : 22,
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
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
                label: '${details.voteAverage.toStringAsFixed(1)} (${_formatVoteCount(details.voteCount)})',
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

  String _formatVoteCount(int count) {
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
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
            Icon(icon, size: 12, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
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
    final dl = ref.read(downloadServiceProvider);

    if (widget.details.mediaType == MediaType.movie) {
      final dlTask = dl.allTasks.firstWhereOrNull(
          (t) => t.tmdbId == widget.details.id && t.mediaType == 'movie' && t.status == DownloadStatus.completed);
      final hasLocal = dlTask != null && dlTask.filePath != null && dlTask.filePath!.isNotEmpty;

      baseArgs = {
        'imdbId': widget.details.imdbId ?? '',
        'tmdbId': widget.details.id,
        'title': widget.details.title,
        'posterPath': widget.details.posterPath ?? '',
        'type': 'movie',
        if (hasLocal) ...{
          'isLocal': true,
          'localPath': dlTask.filePath,
        }
      };
    } else {
      final seasons = widget.details.seasons;
      final firstSeason = seasons.isNotEmpty
          ? seasons.firstWhere((s) => s.seasonNumber > 0,
              orElse: () => seasons.first)
          : null;
      if (firstSeason == null) return;

      final dlTask = dl.allTasks.firstWhereOrNull((t) =>
          t.tmdbId == widget.details.id &&
          t.season == firstSeason.seasonNumber &&
          t.episode == 1 &&
          t.status == DownloadStatus.completed);
      final hasLocal = dlTask != null && dlTask.filePath != null && dlTask.filePath!.isNotEmpty;

      baseArgs = {
        'imdbId': widget.details.imdbId ?? '',
        'tmdbId': widget.details.id,
        'title': widget.details.title,
        'posterPath': widget.details.posterPath ?? '',
        'type': 'tv',
        'season': firstSeason.seasonNumber,
        'episode': 1,
        'episodeName': '',
        if (hasLocal) ...{
          'isLocal': true,
          'localPath': dlTask.filePath,
        }
      };
    }

    // Go directly to native player (unified player)
    if (!mounted) return;
    context.push('/native-player', extra: baseArgs);
  }

  void _onDownload() async {
    final choice = await _DownloadSourcePickerSheet.show(context, details: widget.details);
    if (!mounted || choice == null) return;

    if (choice == _DownloadSourceChoice.telegram) {
      final telegram = ref.read(telegramServiceProvider);
      if (!telegram.isLoggedIn) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Log in to Telegram in Settings to download'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final filters = await DownloadFilterSheet.show(
        context,
        title: widget.details.title,
      );
      if (!mounted || filters == null) return;

      setState(() => _loadingDownload = true);
      try {
        final hint = filters.searchHint;
        final queryTitle = hint.isNotEmpty
            ? '${widget.details.title} $hint'
            : widget.details.title;
        final results = await telegram.searchVideos(
          queryTitle,
          year: widget.details.releaseDate != null
              ? int.tryParse(widget.details.releaseDate!.split('-').first)
              : null,
          mediaType: 'movie',
          preferLang: filters.hasLanguageFilter ? filters.language.token : null,
          baseTitle: widget.details.title,
        );
        var allOptions = telegram.toQualityOptions(results);

        if (!filters.isDefault) {
          final filtered = allOptions.where((q) => filters.matchesOption(
            quality: q.quality,
            audioChannels: q.audioChannels,
          )).toList();
          if (filtered.isNotEmpty) allOptions = filtered;
        }

        if (!mounted) return;
        if (allOptions.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No Telegram download sources found'),
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
                content: Text('Downloading ${widget.details.title} via Telegram ⚡'),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        );
      } finally {
        if (mounted) setState(() => _loadingDownload = false);
      }
    } else if (choice == _DownloadSourceChoice.vegamovies) {
      setState(() => _loadingDownload = true);
      try {
        final vega = ref.read(vegaMoviesServiceProvider);
        final results = await vega.getDownloadLinks(
          title: widget.details.title,
          year: widget.details.releaseDate != null
              ? int.tryParse(widget.details.releaseDate!.split('-').first)
              : null,
        );
        if (!mounted) return;
        if (results.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No VegaMovies direct links found for this title'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        // Keep original link objects for resolution
        final linkMap = <String, VegaDownloadLink>{};
        final allOptions = results.map((link) {
          final key = '${link.host}_${link.quality}_${link.url.hashCode}';
          linkMap[key] = link;
          return QualityOption(
            quality: link.quality,
            hash: key, // Store lookup key, NOT raw URL
            sizeBytes: _parseSize(link.sizeLabel),
            type: link.host,
            videoCodec: link.codec,
            audioChannels: link.language,
            source: 'vegamovies',
          );
        }).toList();

        await QualityPickerSheet.show(
          context,
          options: allOptions,
          title: widget.details.title,
          onSelect: (q) async {
            final link = linkMap[q.hash];
            if (link == null) return;

            // Show resolving indicator for shortener hosts
            final needsResolve = link.host != 'gdrive' && link.host != 'pixeldrain';
            if (needsResolve && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Resolving ${link.host} link...'),
                  duration: const Duration(seconds: 10),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }

            // Resolve the shortener URL to a direct download link
            final vega = ref.read(vegaMoviesServiceProvider);
            final resolvedUrl = await vega.resolveDownloadUrl(link);

            if (!mounted) return;
            ScaffoldMessenger.of(context).clearSnackBars();

            if (resolvedUrl.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Could not resolve download link'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            final dl = ref.read(downloadServiceProvider);
            dl.startStreamDownload(
              tmdbId: widget.details.id,
              imdbId: widget.details.imdbId ?? '',
              title: widget.details.title,
              mediaType: 'movie',
              streamUrl: resolvedUrl,
              quality: q.quality,
              posterPath: widget.details.posterPath,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Downloading ${widget.details.title} via VegaMovies 🌐'),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('VegaMovies search failed: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _loadingDownload = false);
      }
    } else if (choice == _DownloadSourceChoice.torrentio) {
      setState(() => _loadingDownload = true);
      try {
        final torrentio = ref.read(torrentioServiceProvider);
        final sources = await torrentio.fetchSources(
          imdbId: widget.details.imdbId ?? '',
          type: 'movie',
        );
        if (!mounted) return;
        if (sources.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No Torrentio sources found for this movie'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        final allOptions = sources.map((src) {
          return QualityOption(
            quality: src.quality,
            hash: src.infoHash ?? '',
            sizeBytes: _parseSize(src.sizeLabel),
            type: src.provider,
            videoCodec: src.codec,
            audioChannels: src.audio,
            source: 'torrent',
            seeders: src.seeders,
          );
        }).toList();

        await QualityPickerSheet.show(
          context,
          options: allOptions,
          title: widget.details.title,
          onSelect: (q) async {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Resolving stream link via Webtor...')),
            );
            final directUrl = await ref.read(torrentioServiceProvider).resolveStreamUrl(q.hash);
            if (directUrl == null) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not resolve stream link'), backgroundColor: Colors.red),
                );
              }
              return;
            }
            final dl = ref.read(downloadServiceProvider);
            dl.startStreamDownload(
              tmdbId: widget.details.id,
              imdbId: widget.details.imdbId ?? '',
              title: widget.details.title,
              mediaType: 'movie',
              streamUrl: directUrl,
              quality: q.quality,
              posterPath: widget.details.posterPath,
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Downloading ${widget.details.title} via Torrentio 🔗'),
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Torrentio search failed: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _loadingDownload = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMovie = widget.details.mediaType == MediaType.movie;
    final history = ref.watch(historyServiceProvider);
    final dl = ref.watch(downloadServiceProvider);
    final movieTask = isMovie
        ? dl.allTasks.firstWhereOrNull((t) => t.tmdbId == widget.details.id && t.mediaType == 'movie')
        : null;
    final downloadStatus = movieTask?.status;

    final imdbId = widget.details.imdbId ?? '';
    final saved = imdbId.isNotEmpty
        ? history.getProgress(imdbId)
        : null;
    final hasResume = saved != null &&
        saved.progressSeconds > 10 &&
        saved.totalSeconds > 0 &&
        (saved.progressSeconds / saved.totalSeconds) < 0.95;
    final resumeLabel = hasResume ? _formatDuration(saved.progressSeconds) : null;
    final resumePct = hasResume ? (saved.progressSeconds / saved.totalSeconds).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Resume progress bar ──
        if (hasResume) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: resumePct,
              backgroundColor: cs.surfaceContainerHighest,
              color: cs.primary,
              minHeight: 3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Continue from $resumeLabel',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
        ],
        // ── Buttons row ──
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: _onPlay,
              autofocus: true,
              icon: Icon(hasResume ? Icons.play_arrow_rounded : Icons.play_arrow_rounded, size: 24),
              label: Text(
                hasResume ? 'Resume' : (isMovie ? 'Play Movie' : 'Play S01E01'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
              if (isMovie) ...[
                Builder(builder: (context) {
                  final String label;
                  final Widget icon;
                  final VoidCallback? onPressed;
                  final Color? foregroundColor;
                  final Color? backgroundColor;

                  if (downloadStatus == DownloadStatus.completed) {
                    label = 'Downloaded';
                    icon = const Icon(Icons.download_done_rounded, size: 20, color: Colors.green);
                    foregroundColor = Colors.green;
                    backgroundColor = cs.surfaceContainer;
                    onPressed = () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Movie already downloaded 💾'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    };
                  } else if (downloadStatus == DownloadStatus.downloading ||
                      downloadStatus == DownloadStatus.queued ||
                      downloadStatus == DownloadStatus.searching ||
                      downloadStatus == DownloadStatus.converting) {
                    label = 'Downloading';
                    icon = const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                    );
                    foregroundColor = Colors.blue;
                    backgroundColor = cs.surfaceContainer;
                    onPressed = () {
                      context.push('/downloads');
                    };
                  } else if (downloadStatus == DownloadStatus.failed) {
                    label = 'Retry';
                    icon = const Icon(Icons.error_outline_rounded, size: 20, color: Colors.red);
                    foregroundColor = Colors.red;
                    backgroundColor = cs.surfaceContainer;
                    onPressed = () {
                      if (movieTask != null) {
                        dl.retryTask(movieTask.id);
                      }
                    };
                  } else {
                    label = 'Download';
                    icon = _loadingDownload
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.download_rounded, size: 20);
                    foregroundColor = Colors.white;
                    backgroundColor = cs.surfaceContainer;
                    onPressed = _loadingDownload ? null : _onDownload;
                  }

                  return ElevatedButton.icon(
                    onPressed: onPressed,
                    icon: icon,
                    label: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: backgroundColor,
                      foregroundColor: foregroundColor,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                      side: BorderSide(color: foregroundColor.withValues(alpha: 0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }),
              ],
              if (widget.details.trailerKey != null)
                ElevatedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse('https://www.youtube.com/watch?v=${widget.details.trailerKey}');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  icon: const Icon(Icons.movie_filter_rounded, size: 22),
                  label: const Text('Trailer',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.surfaceContainerHigh,
                    foregroundColor: cs.onSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
            ],
          ),
        ],
      );
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
    final isWide = context.isExpanded;
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
          height: isWide ? 120 : 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            itemBuilder: (context, i) {
              final c = cast[i];
              return Padding(
                padding: const EdgeInsets.only(right: 14),
                child: SizedBox(
                  width: isWide ? 80 : 65,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: isWide ? 36 : 28,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                        backgroundImage: c.profileUrl.isNotEmpty
                            ? CachedNetworkImageProvider(c.profileUrl)
                            : null,
                        child: c.profileUrl.isEmpty
                            ? Icon(Icons.person, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7))
                            : null,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        c.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isWide ? 11 : 10,
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
    final isWide = context.isExpanded;
    final selectedSeason = ref.watch(selectedSeasonProvider(details.id));
    final episodes = ref.watch(
      episodesProvider((tmdbId: details.id, season: selectedSeason)),
    );
    final historyService = ref.watch(historyServiceProvider);
    final hPad = isWide ? 60.0 : 20.0;

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
                  fontSize: isWide ? 22 : 18,
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
                bool isFocused = false;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      return Focus(
                        onFocusChange: (focused) => setState(() => isFocused = focused),
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              (event.logicalKey == LogicalKeyboardKey.enter ||
                                  event.logicalKey == LogicalKeyboardKey.select)) {
                            ref
                                .read(selectedSeasonProvider(details.id).notifier)
                                .state = s.seasonNumber;
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: GestureDetector(
                          onTap: () {
                            ref
                                .read(selectedSeasonProvider(details.id).notifier)
                                .state = s.seasonNumber;
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            transform: Matrix4.identity()..scale(isFocused ? 1.06 : 1.0),
                            transformAlignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              gradient: sel ? AtmosTheme.primaryGradient(Theme.of(context).colorScheme) : null,
                              color: sel ? null : Theme.of(context).colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isFocused
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              s.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: sel
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
            data: (eps) => Column(
              children: eps.map((ep) {
                final history = historyService.getProgress(
                  details.imdbId ?? '',
                  season: selectedSeason,
                  episode: ep.episodeNumber,
                );
                final dl = ref.watch(downloadServiceProvider);
                final dlTask = dl.allTasks.firstWhereOrNull((t) =>
                    t.tmdbId == details.id &&
                    t.season == selectedSeason &&
                    t.episode == ep.episodeNumber);
                final downloadStatus = dlTask?.status;
                final hasLocal = dlTask != null &&
                    dlTask.status == DownloadStatus.completed &&
                    dlTask.filePath != null &&
                    dlTask.filePath!.isNotEmpty;

                return EpisodeTile(
                  episode: ep,
                  watchHistory: history,
                  downloadStatus: downloadStatus,
                  onTap: () {
                    if (!context.mounted) return;
                    context.push('/native-player', extra: {
                      'imdbId': details.imdbId ?? '',
                      'tmdbId': details.id,
                      'title': details.title,
                      'posterPath': details.posterPath ?? '',
                      'type': 'tv',
                      'season': selectedSeason,
                      'episode': ep.episodeNumber,
                      'episodeName': ep.name,
                      if (hasLocal) ...{
                        'isLocal': true,
                        'localPath': dlTask.filePath,
                      }
                    });
                  },
                  onDownload: () async {
                    final choice = await _DownloadSourcePickerSheet.show(context, details: details);
                    if (!context.mounted || choice == null) return;

                    final titleString = '${details.title} S${selectedSeason.toString().padLeft(2, "0")}E${ep.episodeNumber.toString().padLeft(2, "0")}';

                    if (choice == _DownloadSourceChoice.telegram) {
                      final telegram = ref.read(telegramServiceProvider);
                      if (!telegram.isLoggedIn) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Log in to Telegram in Settings to download')),
                        );
                        return;
                      }

                      final filters = await DownloadFilterSheet.show(
                        context,
                        title: titleString,
                      );
                      if (!context.mounted || filters == null) return;

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Searching Telegram for S${selectedSeason.toString().padLeft(2, "0")}E${ep.episodeNumber.toString().padLeft(2, "0")}...')),
                      );

                      final hint = filters.searchHint;
                      final queryTitle = hint.isNotEmpty ? '${details.title} $hint' : details.title;
                      final results = await telegram.searchVideos(
                        queryTitle,
                        mediaType: 'tv',
                        season: selectedSeason,
                        episode: ep.episodeNumber,
                        preferLang: filters.hasLanguageFilter ? filters.language.token : null,
                        baseTitle: details.title,
                      );
                      var allOptions = telegram.toQualityOptions(results);

                      if (!filters.isDefault) {
                        final filtered = allOptions.where((q) => filters.matchesOption(
                          quality: q.quality, audioChannels: q.audioChannels)).toList();
                        if (filtered.isNotEmpty) allOptions = filtered;
                      }

                      if (!context.mounted) return;
                      if (allOptions.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('No Telegram download sources found'), backgroundColor: Colors.red),
                        );
                        return;
                      }

                      await QualityPickerSheet.show(
                        context,
                        options: allOptions,
                        title: titleString,
                        onSelect: (q) {
                          ref.read(downloadServiceProvider).startDownload(
                            tmdbId: details.id, imdbId: details.imdbId ?? '', title: details.title,
                            mediaType: 'tv', quality: q, season: selectedSeason,
                            episode: ep.episodeNumber, episodeName: ep.name,
                            posterPath: details.posterPath,
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Downloading ${ep.name} in ${q.quality} via Telegram ⚡'),
                              duration: const Duration(seconds: 3),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      );
                    } else if (choice == _DownloadSourceChoice.torrentio) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Searching Torrentio for S${selectedSeason.toString().padLeft(2, "0")}E${ep.episodeNumber.toString().padLeft(2, "0")}...')),
                      );

                      try {
                        final torrentio = ref.read(torrentioServiceProvider);
                        final sources = await torrentio.fetchSources(
                          imdbId: details.imdbId ?? '',
                          type: 'tv',
                          season: selectedSeason,
                          episode: ep.episodeNumber,
                        );

                        if (!context.mounted) return;
                        if (sources.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('No Torrentio sources found for this episode'), backgroundColor: Colors.orange),
                          );
                          return;
                        }

                        final allOptions = sources.map((src) {
                          return QualityOption(
                            quality: src.quality,
                            hash: src.infoHash ?? '',
                            sizeBytes: _parseSize(src.sizeLabel),
                            type: src.provider,
                            videoCodec: src.codec,
                            audioChannels: src.audio,
                            source: 'torrent',
                            seeders: src.seeders,
                          );
                        }).toList();

                        await QualityPickerSheet.show(
                          context,
                          options: allOptions,
                          title: titleString,
                          onSelect: (q) async {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Resolving stream link via Webtor...')),
                            );
                            final directUrl = await ref.read(torrentioServiceProvider).resolveStreamUrl(q.hash);
                            if (directUrl == null) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Could not resolve stream link'), backgroundColor: Colors.red),
                                );
                              }
                              return;
                            }
                            final dl = ref.read(downloadServiceProvider);
                            dl.startStreamDownload(
                              tmdbId: details.id,
                              imdbId: details.imdbId ?? '',
                              title: details.title,
                              mediaType: 'tv',
                              streamUrl: directUrl,
                              quality: q.quality,
                              season: selectedSeason,
                              episode: ep.episodeNumber,
                              episodeName: ep.name,
                              posterPath: details.posterPath,
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Downloading ${ep.name} in ${q.quality} via Torrentio 🔗'),
                                  duration: const Duration(seconds: 3),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Torrentio search failed: $e'), backgroundColor: Colors.red),
                          );
                        }
                      }
                    } else if (choice == _DownloadSourceChoice.vegamovies) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('VegaMovies does not support individual episode downloads'), backgroundColor: Colors.orange),
                      );
                    }
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
  bool _isFocused = false;

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
                onFocusChange: (focused) => setState(() => _isFocused = focused),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: _isFocused ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
                    border: Border.all(
                      color: _isFocused ? cs.primary : cs.primary.withValues(alpha: 0.5),
                      width: _isFocused ? 2.0 : 1.0,
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

// All playback now routes to /native-player directly.
// The old _PlayerModeSheet and _ModeCard classes were removed.

enum _DownloadSourceChoice {
  telegram,
  vegamovies,
  torrentio,
}

class _DownloadSourcePickerSheet extends ConsumerWidget {
  final TmdbDetails details;
  final bool isMovie;

  const _DownloadSourcePickerSheet({
    required this.details,
    required this.isMovie,
  });

  static Future<_DownloadSourceChoice?> show(
    BuildContext context, {
    required TmdbDetails details,
  }) {
    final isMovie = details.mediaType == MediaType.movie;
    return showModalBottomSheet<_DownloadSourceChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DownloadSourcePickerSheet(
        details: details,
        isMovie: isMovie,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final telegram = ref.watch(telegramServiceProvider);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF12121E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.download_rounded, color: cs.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Select Download Source',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        details.title,
                        style: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: AppSpacing.md),
          
          // Option 1: Telegram CDN
          _buildSourceOption(
            context,
            icon: Icons.telegram,
            iconColor: const Color(0xFF2AABEE),
            title: 'Telegram CDN (Fastest)',
            subtitle: telegram.isLoggedIn
                ? 'Direct high-speed download (requires account)'
                : 'Requires Telegram Login (Configure in Settings)',
            choice: _DownloadSourceChoice.telegram,
          ),
          const SizedBox(height: AppSpacing.md),

          // Option 2: VegaMovies Direct DDL (only for Movies)
          if (isMovie) ...[
            _buildSourceOption(
              context,
              icon: Icons.cloud_download_rounded,
              iconColor: Colors.orange,
              title: 'VegaMovies Direct (No Login)',
              subtitle: 'Direct web download (Google Drive, PixelDrain, etc.)',
              choice: _DownloadSourceChoice.vegamovies,
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // Option 3: Torrentio / Stremio Cache (No Login)
          _buildSourceOption(
            context,
            icon: Icons.link_rounded,
            iconColor: Colors.purple,
            title: 'Torrentio Cache / Direct (No Login)',
            subtitle: 'Stream cached HTTP links directly via Webtor',
            choice: _DownloadSourceChoice.torrentio,
          ),
        ],
      ),
    );
  }

  Widget _buildSourceOption(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required _DownloadSourceChoice choice,
  }) {
    final cs = Theme.of(context).colorScheme;
    bool isFocused = false;
    return StatefulBuilder(
      builder: (context, setState) {
        return InkWell(
          onTap: () => Navigator.pop(context, choice),
          onFocusChange: (focused) => setState(() => isFocused = focused),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: isFocused
                  ? cs.primary.withValues(alpha: 0.15)
                  : Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isFocused ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.outline),
              ],
            ),
          ),
        );
      },
    );
  }
}

int _parseSize(String? sizeLabel) {
  if (sizeLabel == null || sizeLabel.isEmpty) return 0;
  final match = RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(sizeLabel);
  if (match == null) return 0;
  final value = double.tryParse(match.group(1)!) ?? 0.0;
  final unit = match.group(2)!.toUpperCase();
  if (unit == 'GB') {
    return (value * 1024 * 1024 * 1024).toInt();
  } else {
    return (value * 1024 * 1024).toInt();
  }
}


