import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/media_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/media_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
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
            Future.delayed(const Duration(milliseconds: 400), () {
              if (_controller.text == v && mounted) {
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
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off_rounded,
                            size: 64, color: cs.onSurfaceVariant),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'No results for "$query"',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return GridView.builder(
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
                );
              },
            ),
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
