import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/telegram_search_result.dart';
import '../models/download_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

// ─── Telegram Channel Browser ─────────────────────────────────────────────────
//
// Surfaces Telegram as a content-discovery layer, not just a download backend.
// User can search for public movie/show channels and browse their video files
// directly inside Atmos — no Telegram app required.

class TelegramChannelBrowserScreen extends ConsumerStatefulWidget {
  const TelegramChannelBrowserScreen({super.key});

  @override
  ConsumerState<TelegramChannelBrowserScreen> createState() =>
      _TelegramChannelBrowserScreenState();
}

class _TelegramChannelBrowserScreenState
    extends ConsumerState<TelegramChannelBrowserScreen> {
  final _searchCtrl = TextEditingController();
  List<TelegramSearchResult> _results = [];
  bool _loading = false;
  String? _error;
  String _lastQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    query = query.trim();
    if (query.isEmpty || query == _lastQuery) return;
    _lastQuery = query;

    final telegram = ref.read(telegramServiceProvider);
    if (!telegram.isLoggedIn) {
      setState(() => _error = 'Connect Telegram in Settings first');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    try {
      final results = await telegram.searchVideos(query);
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final telegram = ref.watch(telegramServiceProvider);
    final isWide = context.isExpanded;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Telegram Browser'),
        leading: const BackButton(),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? AppSpacing.xxl : AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: SearchBar(
              controller: _searchCtrl,
              hintText: 'Search movies, shows, series…',
              leading: const Icon(Icons.search_rounded),
              onSubmitted: _search,
              trailing: [
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() { _results = []; _lastQuery = ''; });
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
      body: !telegram.isLoggedIn
          ? _NotLoggedIn()
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorView(error: _error!)
                  : _results.isEmpty
                      ? _results.isEmpty && _lastQuery.isEmpty
                          ? _EmptyPrompt()
                          : _NoResults(query: _lastQuery)
                      : _ResultsGrid(results: _results),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _NotLoggedIn extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF2AABEE), Color(0xFF229ED9)],
                ),
                borderRadius: AppRadius.lgAll,
              ),
              child: const Icon(Icons.telegram, color: Colors.white, size: 44),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('Connect Telegram',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Log in with your Telegram account in Settings to search public channels for movies and shows.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Go to Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('✈️', style: TextStyle(fontSize: 64)),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Search for any movie or show\nto find it on Telegram',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  final String query;
  const _NoResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 64)),
          const SizedBox(height: AppSpacing.md),
          Text('No results for "$query"',
            style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Text('Try a different title or year',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 64, color: cs.error),
            const SizedBox(height: AppSpacing.md),
            Text('Search Error',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: cs.error, fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.sm),
            Text(error, textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

// ── Results grid ──────────────────────────────────────────────────────────────

class _ResultsGrid extends ConsumerWidget {
  final List<TelegramSearchResult> results;
  const _ResultsGrid({required this.results});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isWide = context.isExpanded;
    final hPad = isWide ? AppSpacing.xxl : AppSpacing.md;

    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: AppSpacing.sm),
      itemCount: results.length,
      itemBuilder: (ctx, i) {
        final r = results[i];
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.all(AppSpacing.md),
            leading: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: AppRadius.smAll,
              ),
              child: Center(
                child: Text(
                  r.quality.contains('1080') ? '🎬' :
                  r.quality.contains('720')  ? '📺' : '🎞️',
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
            title: Text(
              r.fileName.isNotEmpty ? r.fileName : r.caption,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.xs,
                children: [
                  _Badge(r.quality, cs.primaryContainer, cs.onPrimaryContainer),
                  if (r.videoCodec != null) _Badge(r.videoCodec!, cs.secondaryContainer, cs.onSecondaryContainer),
                  if (r.audioInfo != null) _Badge(r.audioInfo!, cs.tertiaryContainer, cs.onTertiaryContainer),
                  _Badge(_formatSize(r.fileSize), cs.surfaceContainerHigh, cs.onSurface),
                ],
              ),
            ),
            trailing: IconButton(
              icon: Icon(Icons.download_rounded, color: cs.primary),
              onPressed: () => _startDownload(ctx, ref, r),
            ),
          ),
        ).animate(delay: (i * 30).ms)
          .fadeIn(duration: 400.ms, curve: AppMotion.emphasizedDecelerate)
          .slideY(begin: 0.1, end: 0, duration: 400.ms, curve: AppMotion.emphasizedCurve);
      },
    );
  }

  void _startDownload(BuildContext context, WidgetRef ref, TelegramSearchResult r) async {
    final dl = ref.read(downloadServiceProvider);
    final cs = Theme.of(context).colorScheme;

    final quality = QualityOption(
      quality: r.quality,
      hash: '',
      sizeBytes: r.fileSize,
      type: 'telegram',
      videoCodec: r.videoCodec,
      audioChannels: r.audioInfo,
      source: 'telegram',
      telegramFileId: r.fileId,
      fileName: r.fileName,
    );

    // We don't have a TMDB ID here — use 0 as placeholder
    await dl.startDownload(
      tmdbId: 0,
      imdbId: '',
      title: r.fileName.isNotEmpty ? r.fileName : r.caption,
      mediaType: 'movie',
      quality: quality,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⬇️ Download queued: ${r.quality}'),
          backgroundColor: cs.primaryContainer,
        ),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '?';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color bg, fg;
  const _Badge(this.label, this.bg, this.fg);

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 2),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
  );
}
