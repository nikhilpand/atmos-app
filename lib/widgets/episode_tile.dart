import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/media_model.dart';
import '../models/download_model.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class EpisodeTile extends StatefulWidget {
  final Episode episode;
  final bool isSelected;
  final WatchHistory? watchHistory;
  final VoidCallback onTap;
  final VoidCallback? onDownload;
  final DownloadStatus? downloadStatus;

  const EpisodeTile({
    super.key,
    required this.episode,
    required this.onTap,
    this.isSelected = false,
    this.watchHistory,
    this.onDownload,
    this.downloadStatus,
  });

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isTv = context.isExpanded;
    final progress = widget.watchHistory?.progressPercent ?? 0;

    return Focus(
      onFocusChange: (v) => setState(() => _isFocused = v),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.all(isTv ? 16 : 12),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                : _isFocused
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isSelected
                  ? Theme.of(context).colorScheme.primary
                  : _isFocused
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  // Episode thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: isTv ? 140 : 110,
                      height: isTv ? 80 : 65,
                      child: widget.episode.stillPath != null
                          ? CachedNetworkImage(
                              imageUrl: widget.episode.stillUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: 220,
                            )
                          : Container(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.play_circle_outline,
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                size: 28,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Episode info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Episode ${widget.episode.episodeNumber}',
                          style: TextStyle(
                            fontSize: isTv ? 12 : 11,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.episode.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isTv ? 15 : 13,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        if (widget.episode.runtime != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${widget.episode.runtime} min',
                            style: TextStyle(
                              fontSize: isTv ? 12 : 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Download button
                  if (widget.onDownload != null) ...[
                    IconButton(
                      icon: Icon(
                        widget.downloadStatus == DownloadStatus.completed
                            ? Icons.download_done_rounded
                            : (widget.downloadStatus == DownloadStatus.downloading ||
                                    widget.downloadStatus == DownloadStatus.queued ||
                                    widget.downloadStatus == DownloadStatus.searching ||
                                    widget.downloadStatus == DownloadStatus.converting)
                                ? Icons.downloading_rounded
                                : widget.downloadStatus == DownloadStatus.failed
                                    ? Icons.error_outline_rounded
                                    : Icons.download_rounded,
                        size: 20,
                      ),
                      color: widget.downloadStatus == DownloadStatus.completed
                          ? Colors.green
                          : (widget.downloadStatus == DownloadStatus.downloading ||
                                  widget.downloadStatus == DownloadStatus.queued ||
                                  widget.downloadStatus == DownloadStatus.searching ||
                                  widget.downloadStatus == DownloadStatus.converting)
                              ? Theme.of(context).colorScheme.primary
                              : widget.downloadStatus == DownloadStatus.failed
                                  ? Colors.red
                                  : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: widget.downloadStatus == DownloadStatus.completed
                          ? () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Episode already downloaded 💾'),
                                  behavior: SnackBarBehavior.floating,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          : widget.onDownload,
                      tooltip: widget.downloadStatus == DownloadStatus.completed
                          ? 'Downloaded'
                          : widget.downloadStatus == DownloadStatus.downloading
                              ? 'Downloading...'
                              : 'Download',
                    ),
                  ],
                  // Play icon or checkmark
                  Icon(
                    widget.watchHistory?.isFinished == true
                        ? Icons.check_circle
                        : Icons.play_arrow_rounded,
                    color: widget.watchHistory?.isFinished == true
                        ? Colors.green
                        : widget.isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    size: isTv ? 28 : 22,
                  ),
                ],
              ),
              // Progress bar — only show if there is history, progress > 2%, and not finished
              if (progress > 0.02 && widget.watchHistory != null && !widget.watchHistory!.isFinished) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                    minHeight: 3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
