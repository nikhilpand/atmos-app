import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

// ─── Download Filter ──────────────────────────────────────────────────────────

enum QualityFilter {
  any('Any Quality', null, Icons.tune_rounded),
  q480('480p', '480', Icons.sd_rounded),
  q720('720p', '720', Icons.hd_rounded),
  q1080('1080p', '1080', Icons.hd_rounded),
  q4k('4K / 2160p', '4k', Icons.four_k_rounded); // '4k' matches '4K', '4K HDR', '4K DV'

  final String label;
  final String? token; // null means no filter
  final IconData icon;
  const QualityFilter(this.label, this.token, this.icon);
}

enum LanguageFilter {
  any('Any Language', null, '🌐'),
  original('Original', 'original', '⭐'),
  dual('Dual Audio', 'dual', '🔀'),
  english('English', 'english', '🇬🇧'),
  hindi('Hindi', 'hindi', '🇮🇳'),
  tamil('Tamil', 'tamil', '🇮🇳'),
  telugu('Telugu', 'telugu', '🇮🇳'),
  malayalam('Malayalam', 'malayalam', '🇮🇳'),
  kannada('Kannada', 'kannada', '🇮🇳'),
  bengali('Bengali', 'bengali', '🇮🇳'),
  punjabi('Punjabi', 'punjabi', '🇮🇳');

  final String label;
  final String? token; // null means no filter
  final String flag;
  const LanguageFilter(this.label, this.token, this.flag);
}

// ─── Filter Result ────────────────────────────────────────────────────────────

class DownloadFilters {
  final QualityFilter quality;
  final LanguageFilter language;

  const DownloadFilters({
    this.quality = QualityFilter.any,
    this.language = LanguageFilter.any,
  });

  bool get hasQualityFilter => quality != QualityFilter.any;
  bool get hasLanguageFilter => language != LanguageFilter.any;
  bool get isDefault => quality == QualityFilter.any && language == LanguageFilter.any;

  /// Extra terms to append to a search query (used as Telegram search hints).
  String get searchHint {
    final parts = <String>[];
    if (quality.token != null) parts.add(quality.token!);
    // For language, add a recognisable tag that appears in filenames
    if (language.token != null) {
      parts.add(_langSearchTerm(language));
    }
    return parts.join(' ');
  }

  String _langSearchTerm(LanguageFilter l) => switch (l) {
    LanguageFilter.dual      => 'Dual Audio',
    LanguageFilter.english   => 'English',
    LanguageFilter.hindi     => 'Hindi',
    LanguageFilter.tamil     => 'Tamil',
    LanguageFilter.telugu    => 'Telugu',
    LanguageFilter.malayalam => 'Malayalam',
    LanguageFilter.kannada   => 'Kannada',
    LanguageFilter.bengali   => 'Bengali',
    LanguageFilter.punjabi   => 'Punjabi',
    LanguageFilter.original  => '',
    LanguageFilter.any       => '',
  };

  /// Check whether a QualityOption matches the selected filters.
  bool matchesOption({required String quality, String? audioChannels}) {
    if (hasQualityFilter) {
      // Use canonical tiers to prevent false positives.
      // e.g. '720' must NOT match '1080p BluRay'.
      final resultTier  = _qualityTier(quality);
      final wantedTier  = _qualityTier(this.quality.label);
      if (resultTier != wantedTier) return false;
    }
    if (hasLanguageFilter) {
      final a = (audioChannels ?? '').toLowerCase();
      if (language == LanguageFilter.original) {
        // 'original' = NO language tag at all
        const knownLangTokens = [
          'dual', 'hindi', 'tamil', 'telugu', 'malayalam',
          'kannada', 'bengali', 'punjabi', 'english',
        ];
        if (knownLangTokens.any((l) => a.contains(l))) return false;
      } else {
        final token = language.token!.toLowerCase();
        if (!a.contains(token)) return false;
      }
    }
    return true;
  }

  /// Map any quality string → canonical pixel tier.
  ///   '1080p', '1080p BluRay', '1080p WEB-DL' → 1080
  ///   '720p', 'HD'                              → 720
  ///   '480p'                                    → 480
  ///   '4K', '4K HDR', '2160p', 'UHD'           → 2160
  ///   anything else                             → 0
  static int _qualityTier(String q) {
    final s = q.toLowerCase();
    if (s.contains('2160') || s.contains('4k') || s.contains('uhd')) return 2160;
    if (s.contains('1080')) return 1080;
    if (s.contains('720') || s.contains(' hd')) return 720;
    if (s.contains('480')) return 480;
    return 0;
  }

  DownloadFilters copyWith({QualityFilter? quality, LanguageFilter? language}) {
    return DownloadFilters(
      quality: quality ?? this.quality,
      language: language ?? this.language,
    );
  }
}

// ─── Download Filter Sheet ────────────────────────────────────────────────────

class DownloadFilterSheet extends StatefulWidget {
  final String title;
  final DownloadFilters initialFilters;
  final void Function(DownloadFilters) onConfirm;

  const DownloadFilterSheet({
    super.key,
    required this.title,
    required this.initialFilters,
    required this.onConfirm,
  });

  /// Show the sheet; resolves with the chosen filters when the user taps Search,
  /// or null if they dismiss without confirming.
  static Future<DownloadFilters?> show(
    BuildContext context, {
    required String title,
    DownloadFilters initialFilters = const DownloadFilters(),
  }) async {
    DownloadFilters? result;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DownloadFilterSheet(
        title: title,
        initialFilters: initialFilters,
        onConfirm: (f) => result = f,
      ),
    );
    return result;
  }

  @override
  State<DownloadFilterSheet> createState() => _DownloadFilterSheetState();
}

class _DownloadFilterSheetState extends State<DownloadFilterSheet> {
  late DownloadFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF12121E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Handle
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

          // ── Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.tune_rounded,
                    color: Theme.of(context).colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Download Options',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.title,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7), fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ]),
          ),

          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 20),

          // ── Quality Section
          _SectionLabel(
            icon: Icons.hd_rounded,
            label: 'VIDEO QUALITY',
            selected: _filters.quality.label,
            isDefault: _filters.quality == QualityFilter.any,
          ),
          const SizedBox(height: 10),
          _QualityChips(
            selected: _filters.quality,
            onSelect: (q) => setState(() => _filters = _filters.copyWith(quality: q)),
          ),

          const SizedBox(height: 24),

          // ── Language Section
          _SectionLabel(
            icon: Icons.language_rounded,
            label: 'AUDIO LANGUAGE',
            selected: _filters.language.label,
            isDefault: _filters.language == LanguageFilter.any,
          ),
          const SizedBox(height: 10),
          _LanguageGrid(
            selected: _filters.language,
            onSelect: (l) => setState(() => _filters = _filters.copyWith(language: l)),
          ),

          const SizedBox(height: 28),

          // ── Action Buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              if (!_filters.isDefault)
                TextButton.icon(
                  onPressed: () => setState(() => _filters = const DownloadFilters()),
                  icon: Icon(Icons.restart_alt_rounded,
                      size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)),
                  label: Text('Reset',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7))),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onConfirm(_filters);
                },
                icon: Icon(Icons.search_rounded, size: 18),
                label: Text(
                  _filters.isDefault ? 'Search All' : 'Search with Filters',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─── Section Label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final String selected;
  final bool isDefault;

  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.selected,
    required this.isDefault,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        Icon(icon, size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
        const Spacer(),
        if (!isDefault)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(38),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(selected,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary, fontSize: 11)),
          ),
      ]),
    );
  }
}

// ─── Quality Chips (horizontal scroll) ───────────────────────────────────────

class _QualityChips extends StatelessWidget {
  final QualityFilter selected;
  final void Function(QualityFilter) onSelect;

  const _QualityChips({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        physics: const BouncingScrollPhysics(),
        children: QualityFilter.values.map((opt) {
          final isSelected = opt == selected;
          final color = _color(context, opt);
          return GestureDetector(
            onTap: () => onSelect(opt),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                gradient: isSelected
                    ? LinearGradient(colors: [
                        color,
                        color.withAlpha(140)
                      ])
                    : null,
                color: isSelected ? null : Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? color : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Text(
                opt.label,
                style: TextStyle(
                  color: isSelected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Color _color(BuildContext context, QualityFilter q) => switch (q) {
        QualityFilter.q4k => Colors.amber,
        QualityFilter.q1080 => Colors.blue,
        QualityFilter.q720 => Colors.green,
        QualityFilter.q480 => Colors.orange,
        QualityFilter.any => Theme.of(context).colorScheme.primary,
      };
}

// ─── Language Grid (wrap chips) ───────────────────────────────────────────────

class _LanguageGrid extends StatelessWidget {
  final LanguageFilter selected;
  final void Function(LanguageFilter) onSelect;

  const _LanguageGrid({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: LanguageFilter.values.map((opt) {
          final isSelected = opt == selected;
          final color = _color(context, opt);
          return GestureDetector(
            onTap: () => onSelect(opt),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withAlpha(45)
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? color.withAlpha(190)
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(opt.flag, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                Text(
                  opt.label,
                  style: TextStyle(
                    color: isSelected ? color : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ]),
            ),
          );
        }).toList(),
      ),
    );
  }

  Color _color(BuildContext context, LanguageFilter l) => switch (l) {
        LanguageFilter.any      => Theme.of(context).colorScheme.primary,
        LanguageFilter.original => Colors.amber,
        LanguageFilter.dual     => Colors.teal,
        LanguageFilter.english  => Colors.blue,
        LanguageFilter.hindi    => const Color(0xFFFF9933),
        LanguageFilter.tamil    => Colors.red,
        LanguageFilter.telugu   => Colors.deepPurple,
        LanguageFilter.malayalam => Colors.green,
        LanguageFilter.kannada  => Colors.deepOrange,
        LanguageFilter.bengali  => Colors.cyan,
        LanguageFilter.punjabi  => const Color(0xFF00B67A),
      };
}
