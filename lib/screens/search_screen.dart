import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/media_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/media_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  // B7: Timer-based debouncer — cancels the previous timer on each keystroke
  // preventing multiple concurrent API requests during fast typing.
  Timer? _debounce;
  // P13: Track active type filter
  MediaType? _filterType; // null = All

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _navigateToDetails(TmdbMedia media) {
    context.push(
      '/details/${media.mediaType == MediaType.movie ? 'movie' : 'tv'}/${media.id}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider(query));
    final cs = Theme.of(context).colorScheme;
    final hPad = context.isExpanded ? AppSpacing.xxl : AppSpacing.md;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        // Remove back button if it's rendered within the shell context or use standard back
        leading: Focus(
          child: IconButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            icon: const Icon(Icons.arrow_back_rounded),
            color: cs.onSurface,
          ),
        ),
        title: TextField(
          controller: _controller,
          focusNode: _searchFocus,
          onChanged: (v) {
            // B7: Cancel any pending debounce and restart — no leaked futures
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 380), () {
              if (mounted) {
                ref.read(searchQueryProvider.notifier).state = v;
              }
            });
          },
          decoration: InputDecoration(
            hintText: 'Search movies, shows...',
            prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
            suffixIcon: query.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear_rounded, color: cs.onSurfaceVariant),
                    onPressed: () {
                      _controller.clear();
                      ref.read(searchQueryProvider.notifier).state = '';
                    },
                  )
                : null,
            filled: true,
            fillColor: cs.surfaceContainerHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.full),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          ),
          style: Theme.of(context).textTheme.bodyLarge,
          cursorColor: cs.primary,
        ),
      ),
      body: query.isEmpty
          ? const _EmptySearch()
          : results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text(
                  'Error: $e',
                  style: TextStyle(color: cs.error),
                ),
              ),
              data: (allItems) {
                // P13: Apply type filter
                final items = _filterType == null
                    ? allItems
                    : allItems.where((m) => m.mediaType == _filterType).toList();

                return Column(
                  children: [
                    // P13: Type filter chips
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _FilterChip(
                              label: 'All (${allItems.length})',
                              selected: _filterType == null,
                              onSelected: (_) => setState(() => _filterType = null),
                            ),
                            const SizedBox(width: 8),
                            _FilterChip(
                              label: 'Movies (${allItems.where((m) => m.mediaType == MediaType.movie).length})',
                              selected: _filterType == MediaType.movie,
                              onSelected: (_) => setState(() => _filterType = MediaType.movie),
                            ),
                            const SizedBox(width: 8),
                            _FilterChip(
                              label: 'TV Shows (${allItems.where((m) => m.mediaType == MediaType.tv).length})',
                              selected: _filterType == MediaType.tv,
                              onSelected: (_) => setState(() => _filterType = MediaType.tv),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (items.isEmpty)
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.search_off_rounded,
                                  size: 64, color: cs.onSurfaceVariant),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                _filterType == null
                                    ? 'No results for "$query"'
                                    : 'No ${_filterType == MediaType.movie ? 'movies' : 'TV shows'} for "$query"',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: GridView.builder(
                          padding: EdgeInsets.all(hPad),
                          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: context.isExpanded ? 220.0 : 145.0,
                            childAspectRatio: 2 / 3.1,
                            crossAxisSpacing: AppSpacing.sm,
                            mainAxisSpacing: AppSpacing.sm,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            return MediaCard(
                              media: items[i],
                              autofocus: i == 0,
                              onTap: () => _navigateToDetails(items[i]),
                            ).animate().fadeIn(duration: 400.ms, delay: (i * 30).ms, curve: AppMotion.emphasizedDecelerate).scaleXY(begin: 0.9, end: 1, duration: 400.ms, delay: (i * 30).ms, curve: AppMotion.emphasizedCurve);
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

// ─── Filter Chip ───────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;
  const _FilterChip({required this.label, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      selectedColor: cs.secondaryContainer,
      labelStyle: TextStyle(
        color: selected ? cs.onSecondaryContainer : cs.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        fontSize: 13,
      ),
      side: BorderSide(
        color: selected ? cs.secondary : cs.outlineVariant,
        width: 1,
      ),
      checkmarkColor: cs.onSecondaryContainer,
      showCheckmark: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    );
  }
}

// ─── Empty State ──────────────────────────────────────────────────────────────

class _EmptySearch extends StatelessWidget {
  const _EmptySearch();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => AtmosTheme.primaryGradient(Theme.of(context).colorScheme).createShader(bounds),
            child: const Icon(
              Icons.movie_filter_rounded,
              size: 80,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Find your next watch',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Search by title, actor, or genre',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ].animate(interval: 50.ms).fadeIn(duration: 400.ms, curve: AppMotion.emphasizedDecelerate).slideY(begin: 0.1, end: 0, duration: 400.ms, curve: AppMotion.emphasizedCurve),
      ),
    );
  }
}
