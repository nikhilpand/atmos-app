import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/media_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/media_card.dart';

class WatchlistScreen extends ConsumerWidget {
  const WatchlistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlistService = ref.watch(watchlistProvider);
    final items = watchlistService.items;
    final cs = Theme.of(context).colorScheme;
    final isWide = context.isExpanded;
    final cols = isWide ? 4 : 3;
    final hPad = isWide ? AppSpacing.xxl : AppSpacing.md;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('My Watchlist'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Clear all',
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: items.isEmpty
          ? const _Empty()
          : GridView.builder(
              padding: EdgeInsets.all(hPad),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisSpacing: AppSpacing.sm,
                childAspectRatio: 2 / 3,
              ),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final media = items[i];
                return MediaCard(
                  media: media,
                  onTap: () => context.push(
                    '/details/${media.mediaType == MediaType.movie ? 'movie' : 'tv'}/${media.id}',
                  ),
                );
              },
            ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear Watchlist'),
        content: const Text('Remove all bookmarked titles?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () {
              Navigator.pop(context);
              ref.read(watchlistProvider).clear();
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bookmark_border_rounded, size: 80, color: cs.outlineVariant),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Your watchlist is empty',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Tap the bookmark icon on any title\nto save it for later.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
          ),
        ],
      ),
    );
  }
}
