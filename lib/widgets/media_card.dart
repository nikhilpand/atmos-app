import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/media_model.dart';
import '../theme/app_theme.dart';
import 'responsive_layout.dart';

/// A D-Pad focusable, animated poster card.
/// Works for both Mobile (touch) and TV (remote control).
class MediaCard extends StatefulWidget {
  final TmdbMedia media;
  final VoidCallback onTap;
  final double? width;
  final double? height;
  final bool autofocus;

  const MediaCard({
    super.key,
    required this.media,
    required this.onTap,
    this.width,
    this.height,
    this.autofocus = false,
  });

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isTv = context.isExpanded;
    final w = widget.width ?? (isTv ? 200.0 : 130.0);
    final h = widget.height ?? (isTv ? 290.0 : 195.0);

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _isFocused = v),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: w,
          height: h,
          transform: Matrix4.identity()
            ..scale(_isFocused ? 1.08 : 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused ? Theme.of(context).colorScheme.primary : Colors.transparent,
              width: 2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 2,
                    )
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Poster image
                CachedNetworkImage(
                  imageUrl: widget.media.posterUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 340, // TV memory management
                  errorWidget: (_, __, ___) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.movie_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                      size: 40,
                    ),
                  ),
                  placeholder: (_, __) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: const _ShimmerBox(),
                  ),
                ),
                // Bottom gradient overlay
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.55, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.85),
                        ],
                      ),
                    ),
                  ),
                ),
                // Title at bottom
                Positioned(
                  bottom: 8,
                  left: 8,
                  right: 8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.media.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isTv ? 13 : 11,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            widget.media.mediaType == MediaType.movie
                                ? Icons.movie
                                : Icons.tv,
                            size: 10,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            widget.media.year,
                            style: TextStyle(
                              fontSize: isTv ? 11 : 10,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                          if (widget.media.voteAverage > 0) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.star_rounded,
                              size: 10,
                              color: Colors.amber.shade400,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              widget.media.voteAverage.toStringAsFixed(1),
                              style: TextStyle(
                                fontSize: isTv ? 11 : 10,
                                color: Colors.amber.shade400,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Play overlay on focus
                if (_isFocused)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withOpacity(0.2),
                      child: const Center(
                        child: Icon(
                          Icons.play_circle_filled_rounded,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ).animate(target: _isFocused ? 1 : 0);
  }
}

class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox();

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.7).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surfaceContainerHigh,
              Color.lerp(Theme.of(context).colorScheme.surfaceContainerHigh, Theme.of(context).colorScheme.surfaceContainerHighest, _anim.value)!,
              Theme.of(context).colorScheme.surfaceContainerHigh,
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal scrollable row of [MediaCard]s with an M3 Expressive section header.
class MediaRow extends StatelessWidget {
  final String title;
  final List<TmdbMedia> items;
  final Function(TmdbMedia) onTap;
  final VoidCallback? onSeeAll;

  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    final isTv = context.isExpanded;
    final hPad = isTv ? 60.0 : 16.0;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Animated section header ──
        Padding(
          padding: EdgeInsets.only(left: hPad, right: hPad, bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: isTv ? 22 : 17,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  child: Text('See All',
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    )),
                ),
            ],
          ),
        ).animate().fadeIn(duration: 400.ms, curve: Curves.easeOut)
          .slideX(begin: -0.05, end: 0, duration: 400.ms, curve: Curves.easeOut),

        // ── Animated card list ──
        SizedBox(
          height: isTv ? 295 : 205,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.only(left: hPad, right: hPad),
            physics: const BouncingScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final delay = Duration(milliseconds: 60 + i * 35);
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: MediaCard(
                  media: items[i],
                  autofocus: i == 0,
                  onTap: () => onTap(items[i]),
                )
                .animate(delay: delay)
                .fadeIn(duration: 350.ms, curve: Curves.easeOut)
                .slideY(begin: 0.12, end: 0, duration: 350.ms,
                    curve: Curves.easeOut)
                .scaleXY(begin: 0.92, end: 1.0, duration: 350.ms,
                    curve: Curves.easeOut),
              );
            },
          ),
        ),
      ],
    );
  }
}
