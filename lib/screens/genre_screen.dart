import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../models/media_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/media_card.dart';

// ─── Genre Screen ─────────────────────────────────────────────────────────────

class GenreScreen extends ConsumerStatefulWidget {
  final int genreId;
  final String genreName;
  final String genreEmoji;
  final MediaType initialType;

  const GenreScreen({
    super.key,
    required this.genreId,
    required this.genreName,
    required this.genreEmoji,
    this.initialType = MediaType.movie,
  });

  @override
  ConsumerState<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends ConsumerState<GenreScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  late MediaType _type;

  // Pagination state
  final List<TmdbMedia> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  final ScrollController _scroll = ScrollController();

  // Sort options
  String _sortBy = 'popularity.desc';
  static const _sortOptions = [
    ('popularity.desc',    'Most Popular'),
    ('vote_average.desc',  'Highest Rated'),
    ('release_date.desc',  'Newest First'),
    ('vote_count.desc',    'Most Votes'),
  ];

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: _type == MediaType.movie ? 0 : 1,
    );
    _tabs.addListener(_onTabChange);
    _scroll.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChange);
    _tabs.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onTabChange() {
    if (_tabs.indexIsChanging) return;
    setState(() {
      _type = _tabs.index == 0 ? MediaType.movie : MediaType.tv;
      _items.clear();
      _page = 1;
      _hasMore = true;
    });
    _loadMore();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);

    final tmdb = ref.read(tmdbServiceProvider);
    final results = await tmdb.discoverByGenre(
      widget.genreId,
      type: _type,
      page: _page,
      sortBy: _sortBy,
    );

    if (!mounted) return;
    setState(() {
      _items.addAll(results);
      _page++;
      _hasMore = results.isNotEmpty && results.length >= 20;
      _loading = false;
    });
  }

  void _onSortChanged(String newSort) {
    if (newSort == _sortBy) return;
    setState(() {
      _sortBy = newSort;
      _items.clear();
      _page = 1;
      _hasMore = true;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isWide = context.isExpanded;
    final crossCount = isWide ? 5 : 3;

    return Scaffold(
      backgroundColor: cs.surface,
      body: NestedScrollView(
        headerSliverBuilder: (ctx, innerBoxScrolled) => [
          SliverAppBar(
            expandedHeight: 160,
            pinned: true,
            backgroundColor: cs.surface,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => context.pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Gradient background with genre color
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          cs.primaryContainer,
                          cs.surface,
                        ],
                      ),
                    ),
                  ),
                  // Emoji watermark
                  Positioned(
                    right: -20,
                    top: -20,
                    child: Text(
                      widget.genreEmoji,
                      style: const TextStyle(fontSize: 140),
                    ).animate().fadeIn(duration: 400.ms).scale(
                      begin: const Offset(0.5, 0.5),
                      end: const Offset(1, 1),
                      duration: 500.ms,
                      curve: Curves.easeOut,
                    ),
                  ),
                  // Title
                  Positioned(
                    bottom: 56,
                    left: isWide ? AppSpacing.xxl : AppSpacing.md,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.genreEmoji,
                          style: const TextStyle(fontSize: 32),
                        ).animate().fadeIn(delay: 100.ms),
                        Text(
                          widget.genreName,
                          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: cs.onSurface,
                          ),
                        ).animate().fadeIn(delay: 150.ms).slideX(begin: -0.05, end: 0),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottom: TabBar(
              controller: _tabs,
              indicatorColor: cs.primary,
              labelColor: cs.primary,
              unselectedLabelColor: cs.onSurfaceVariant,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              tabs: const [
                Tab(text: 'Movies'),
                Tab(text: 'TV Shows'),
              ],
            ),
          ),
        ],
        body: Column(
          children: [
            // Sort row
            _SortBar(
              current: _sortBy,
              options: _sortOptions,
              onChanged: _onSortChanged,
            ),
            Expanded(
              child: _items.isEmpty && _loading
                  ? _buildSkeletonGrid(crossCount)
                  : _items.isEmpty
                      ? _buildEmpty(cs)
                      : GridView.builder(
                          controller: _scroll,
                          padding: EdgeInsets.symmetric(
                            horizontal: isWide ? AppSpacing.xxl : AppSpacing.sm,
                            vertical: AppSpacing.sm,
                          ),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossCount,
                            childAspectRatio: 0.58,
                            crossAxisSpacing: AppSpacing.sm,
                            mainAxisSpacing: AppSpacing.sm,
                          ),
                          itemCount: _items.length + (_hasMore ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            if (i >= _items.length) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(AppSpacing.lg),
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              );
                            }
                            return MediaCard(
                              media: _items[i],
                              onTap: () => context.push(
                                '/details/${_items[i].mediaType == MediaType.movie ? 'movie' : 'tv'}/${_items[i].id}',
                              ),
                            ).animate(delay: Duration(milliseconds: (i % 20) * 30))
                              .fadeIn(duration: 300.ms)
                              .slideY(begin: 0.1, end: 0, duration: 300.ms);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonGrid(int crossCount) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.sm),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossCount,
        childAspectRatio: 0.58,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
      ),
      itemCount: 12,
      itemBuilder: (_, __) => ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: Container(color: Theme.of(context).colorScheme.surfaceContainer),
      ).animate(onPlay: (c) => c.repeat())
        .shimmer(duration: 1200.ms, color: Theme.of(context).colorScheme.surfaceContainerHigh),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(widget.genreEmoji, style: const TextStyle(fontSize: 64)),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No ${widget.genreName} content found',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

// ─── Sort Bar ─────────────────────────────────────────────────────────────────

class _SortBar extends StatelessWidget {
  final String current;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;

  const _SortBar({
    required this.current,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: context.isExpanded ? AppSpacing.xxl : AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
        itemCount: options.length,
        itemBuilder: (ctx, i) {
          final (value, label) = options[i];
          final selected = current == value;
          return GestureDetector(
            onTap: () => onChanged(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(
                  color: selected ? cs.primary : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
