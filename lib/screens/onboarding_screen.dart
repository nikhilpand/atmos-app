import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_model.dart';
import '../services/recommendation_service.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  final RecommendationService recService;
  const OnboardingScreen({super.key, required this.recService});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;
  final _selectedGenres = <int>{};

  void _next() {
    if (_page < 2) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    // Seed the taste profile with selected genres
    for (final genreId in _selectedGenres) {
      widget.recService.recordWatch(
        tmdbId: 0,
        title: '',
        type: MediaType.movie,
        genreIds: [genreId],
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (mounted) context.go('/');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Progress dots
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _page == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _page == i ? cs.primary : cs.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                )),
              ),
            ),

            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _Page1(),
                  _Page2(),
                  _Page3(
                    selectedGenres: _selectedGenres,
                    onToggle: (id) => setState(() {
                      if (_selectedGenres.contains(id)) {
                        _selectedGenres.remove(id);
                      } else {
                        _selectedGenres.add(id);
                      }
                    }),
                  ),
                ],
              ),
            ),

            // Action buttons
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.md,
                AppSpacing.xl, AppSpacing.xl,
              ),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _page == 2 && _selectedGenres.isEmpty
                          ? null
                          : _next,
                      child: Text(_page < 2 ? 'Continue' : 'Get Started'),
                    ),
                  ),
                  if (_page < 2) ...[
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: _finish,
                      child: Text('Skip', style: TextStyle(color: cs.outline)),
                    ),
                  ],
                  if (_page == 2) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _selectedGenres.isEmpty
                          ? 'Pick at least one genre'
                          : '${_selectedGenres.length} genre${_selectedGenres.length == 1 ? '' : 's'} selected',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _selectedGenres.isEmpty ? cs.error : cs.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Page 1: Stream ────────────────────────────────────────────────────────────

class _Page1 extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('🎬', style: const TextStyle(fontSize: 80))
              .animate().scale(duration: 600.ms, curve: Curves.elasticOut),
          const SizedBox(height: AppSpacing.xl),
          ShaderMask(
            shaderCallback: (b) => AtmosTheme.primaryGradient(cs).createShader(b),
            child: Text(
              'Stream Anything.',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Every movie and show, completely free.\nNo account. No credit card. No limits.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ).animate().fadeIn(delay: 350.ms),
        ],
      ),
    );
  }
}

// ── Page 2: Download ──────────────────────────────────────────────────────────

class _Page2 extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _EngineCard(emoji: '✈️', label: 'Telegram', sub: 'CDN · 500 MB/s'),
              const SizedBox(width: AppSpacing.md),
              _EngineCard(emoji: '🎬', label: 'Streaming', sub: '10+ providers'),
            ],
          ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.1, end: 0),
          const SizedBox(height: AppSpacing.xl),
          ShaderMask(
            shaderCallback: (b) => AtmosTheme.primaryGradient(cs).createShader(b),
            child: Text(
              'Download Everything.',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Powered by Telegram CDN and 10+ streaming providers.\nDownload at full speed. Watch offline, anywhere.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ).animate().fadeIn(delay: 350.ms),
        ],
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  final String emoji, label, sub;
  const _EngineCard({required this.emoji, required this.label, required this.sub});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 140,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 36)),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text(sub, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ── Page 3: Genre Picker ──────────────────────────────────────────────────────

class _Page3 extends StatelessWidget {
  final Set<int> selectedGenres;
  final void Function(int) onToggle;

  static const _genres = [
    (28, '💥', 'Action'),
    (35, '😂', 'Comedy'),
    (18, '😢', 'Drama'),
    (27, '😱', 'Horror'),
    (878, '🚀', 'Sci-Fi'),
    (10749, '💕', 'Romance'),
    (53, '🔪', 'Thriller'),
    (16, '🎨', 'Animation'),
    (12, '🗺️', 'Adventure'),
    (99, '🎞️', 'Docs'),
    (80, '🕵️', 'Crime'),
    (14, '🧙', 'Fantasy'),
  ];

  const _Page3({required this.selectedGenres, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        children: [
          ShaderMask(
            shaderCallback: (b) => AtmosTheme.primaryGradient(cs).createShader(b),
            child: Text(
              'What do you love?',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ).animate().fadeIn(),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Pick genres to personalise your home screen',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          Expanded(
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              alignment: WrapAlignment.center,
              children: _genres.map((g) {
                final selected = selectedGenres.contains(g.$1);
                return GestureDetector(
                  onTap: () => onToggle(g.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                      border: Border.all(
                        color: selected ? cs.primary : cs.outlineVariant,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(g.$2, style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 6),
                        Text(g.$3,
                          style: TextStyle(
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? cs.onPrimaryContainer : cs.onSurface,
                          )),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
