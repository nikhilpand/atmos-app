import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/download_model.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';

// ─── Download Screen ──────────────────────────────────────────────────────────

class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(downloadServiceProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainer,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: Text('Downloads',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            )),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: cs.primary,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: [
            Tab(text: 'Active (${service.active.length})'),
            Tab(text: 'Completed (${service.completed.length})'),
          ],
        ),
        actions: [
          if (service.completed.isNotEmpty)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant),
              color: cs.surfaceContainerHigh,
              onSelected: (v) async {
                if (v == 'clear') {
                  for (final t in service.completed) {
                    await service.deleteTask(t.id);
                  }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear completed',
                      style: TextStyle(color: cs.onSurface)),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          _StorageBar(service: service),
          Expanded(
            child: ListenableBuilder(
              listenable: service,
              builder: (context, _) {
                return TabBarView(
                  controller: _tabs,
                  children: [
                    _TaskList(tasks: service.active, service: service, showProgress: true),
                    _TaskList(tasks: service.completed, service: service, showProgress: false),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Task List ────────────────────────────────────────────────────────────────

class _TaskList extends StatelessWidget {
  final List<DownloadTask> tasks;
  final dynamic service;
  final bool showProgress;

  const _TaskList({
    required this.tasks,
    required this.service,
    required this.showProgress,
  });

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              showProgress ? Icons.downloading_rounded : Icons.download_done_rounded,
              size: 64, color: cs.onSurfaceVariant.withAlpha(76),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              showProgress ? 'No active downloads' : 'No completed downloads',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: tasks.length,
      itemBuilder: (ctx, i) => _DownloadCard(
        task: tasks[i],
        service: service,
      ),
    );
  }
}

// ─── Download Card ────────────────────────────────────────────────────────────

class _DownloadCard extends StatelessWidget {
  final DownloadTask task;
  final dynamic service;

  const _DownloadCard({
    required this.task,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.lg),
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: cs.error,
          borderRadius: AppRadius.lgAll,
        ),
        child: Icon(Icons.delete_rounded, color: cs.onError),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: cs.surfaceContainerHigh,
            title: Text('Delete Download', style: TextStyle(color: cs.onSurface)),
            content: Text('Delete "${task.displayTitle}"?',
                style: TextStyle(color: cs.onSurfaceVariant)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: cs.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Delete', style: TextStyle(color: cs.error)),
              ),
            ],
          ),
        ) ?? false;
      },
      onDismissed: (_) => service.deleteTask(task.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: AppRadius.lgAll,
          border: Border.all(
            color: task.status == DownloadStatus.downloading
                ? cs.primary.withAlpha(76)
                : task.status == DownloadStatus.paused
                    ? Colors.orange.withAlpha(76)
                    : task.status == DownloadStatus.failed
                        ? cs.error.withAlpha(76)
                        : cs.outlineVariant.withAlpha(51),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHeader(task: task, service: service),
            if (task.status != DownloadStatus.completed)
              _CardProgress(task: task),
            _CardMeta(task: task),
            if (task.status == DownloadStatus.completed && task.filePath != null)
              _PlayButton(task: task),
          ],
        ),
      ),
    );
  }
}

// ─── Card Header ──────────────────────────────────────────────────────────────

class _CardHeader extends StatelessWidget {
  final DownloadTask task;
  final dynamic service;
  const _CardHeader({required this.task, required this.service});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(children: [
        // Poster thumbnail
        ClipRRect(
          borderRadius: AppRadius.smAll,
          child: task.posterPath != null && task.posterPath!.isNotEmpty
              ? Image.network(
                  'https://image.tmdb.org/t/p/w92${task.posterPath}',
                  width: 40, height: 58, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _posterPlaceholder(cs),
                )
              : _posterPlaceholder(cs),
        ),
        const SizedBox(width: AppSpacing.md),
        // Title + status
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.displayTitle,
                style: TextStyle(
                    color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 13),
                maxLines: 2, overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              _StatusChip(status: task.status),
            ],
          ),
        ),
        // Action button
        _ActionButton(task: task, service: service),
      ]),
    );
  }

  Widget _posterPlaceholder(ColorScheme cs) => Container(
    width: 40, height: 58,
    decoration: BoxDecoration(
      color: cs.surfaceContainerHigh,
      borderRadius: AppRadius.smAll,
    ),
    child: Icon(Icons.movie_rounded, color: cs.onSurfaceVariant, size: 18),
  );
}

// ─── Status Chip ─────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final DownloadStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, icon) = switch (status) {
      DownloadStatus.downloading || DownloadStatus.searching || DownloadStatus.converting =>
        (cs.primary, Icons.downloading_rounded),
      DownloadStatus.completed  => (Colors.green, Icons.check_circle_rounded),
      DownloadStatus.failed     => (cs.error, Icons.error_rounded),
      DownloadStatus.paused     => (Colors.orange, Icons.pause_circle_rounded),
      DownloadStatus.queued     => (cs.onSurfaceVariant, Icons.schedule_rounded),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(status.label, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}

// ─── Action Button ─────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final DownloadTask task;
  final dynamic service;
  const _ActionButton({required this.task, required this.service});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // ← C4: Failed tasks get Retry + Delete instead of just Delete
    if (task.status == DownloadStatus.failed) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: cs.primary),
          tooltip: 'Retry',
          onPressed: () => service.retryTask(task.id),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline_rounded, color: cs.error),
          tooltip: 'Remove',
          onPressed: () => _confirmDelete(context, cs),
        ),
      ]);
    }

    // Completed tasks: only delete
    if (task.status == DownloadStatus.completed) {
      return IconButton(
        icon: Icon(Icons.delete_outline_rounded, color: cs.onSurfaceVariant),
        tooltip: 'Remove',
        onPressed: () => _confirmDelete(context, cs),
      );
    }

    // Active / paused / queued: pause‒resume + delete
    final isPaused = task.status == DownloadStatus.paused;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        icon: Icon(
          isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          color: isPaused ? cs.primary : cs.onSurfaceVariant,
        ),
        tooltip: isPaused ? 'Resume' : 'Pause',
        onPressed: () {
          if (isPaused) {
            service.resumeTask(task.id);
          } else {
            service.pauseTask(task.id);
          }
        },
      ),
      IconButton(
        icon: Icon(Icons.delete_outline_rounded, color: cs.error),
        tooltip: 'Remove',
        onPressed: () => _confirmDelete(context, cs),
      ),
    ]);
  }

  void _confirmDelete(BuildContext context, ColorScheme cs) {
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: cs.surfaceContainerHigh,
        title: Text('Remove Download', style: TextStyle(color: cs.onSurface)),
        content: Text('Remove "${task.displayTitle}"?',
            style: TextStyle(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel', style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              service.deleteTask(task.id);
            },
            child: Text('Remove', style: TextStyle(color: cs.error)),
          ),
        ],
      ),
    );
  }
}

// ─── Card Progress ────────────────────────────────────────────────────────────

class _CardProgress extends StatelessWidget {
  final DownloadTask task;
  const _CardProgress({required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (task.status == DownloadStatus.failed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        child: Text(
          task.error ?? 'Unknown error',
          style: TextStyle(color: cs.error, fontSize: 12),
          maxLines: 2, overflow: TextOverflow.ellipsis,
        ),
      );
    }

    final isIndeterminate = task.status == DownloadStatus.searching ||
        task.status == DownloadStatus.converting ||
        task.status == DownloadStatus.queued;

    final isPaused = task.status == DownloadStatus.paused;
    final isActive = task.status == DownloadStatus.downloading;

    // Progress bar colour
    final barColor = isPaused ? Colors.orange : cs.primary;

    // Primary label: downloaded / total (percentage)
    final pct  = isIndeterminate ? '' : '${(task.progress * 100).toStringAsFixed(0)}%';
    final main = switch (task.status) {
      DownloadStatus.searching  => 'Finding sources...',
      DownloadStatus.converting => 'Converting...',
      DownloadStatus.queued     => 'Queued',
      DownloadStatus.paused     =>
          'Paused  •  ${task.downloadedFormatted} / ${task.totalFormatted}  ($pct)',
      _                         =>
          '${task.downloadedFormatted} / ${task.totalFormatted}  ($pct)',
    };

    // Secondary row: speed + ETA (only while actively downloading)
    final speed = isActive ? task.speedFormatted : '';
    final eta   = isActive ? task.etaFormatted   : '';
    final showSecondary = speed.isNotEmpty || eta.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: AppRadius.xsAll,
          child: LinearProgressIndicator(
            value: isIndeterminate ? null : task.progress,
            backgroundColor: cs.surfaceContainerHigh,
            valueColor: AlwaysStoppedAnimation(barColor),
            minHeight: 5,
          ),
        ),
        const SizedBox(height: 5),
        // Primary label
        Text(
          main,
          style: TextStyle(
            color: isPaused ? Colors.orange : cs.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
        // Speed + ETA row (only while downloading)
        if (showSecondary) ...[
          const SizedBox(height: 3),
          Row(children: [
            if (speed.isNotEmpty) ...[
              Icon(Icons.speed_rounded, size: 11, color: cs.primary),
              const SizedBox(width: 3),
              Text(speed,
                  style: TextStyle(
                      color: cs.primary, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
            ],
            if (eta.isNotEmpty) ...[
              Icon(Icons.timer_outlined, size: 11, color: cs.onSurfaceVariant),
              const SizedBox(width: 3),
              Text(eta,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
            ],
          ]),
        ],
      ]),
    );
  }
}

// ─── Card Meta ────────────────────────────────────────────────────────────────

class _CardMeta extends StatelessWidget {
  final DownloadTask task;
  const _CardMeta({required this.task});

  @override
  Widget build(BuildContext context) {
    final chips = <(IconData, String)>[
      (Icons.hd_rounded, task.quality.toUpperCase()),
      if (task.videoCodec != null) (Icons.videocam_rounded, task.videoCodec!.toUpperCase()),
      if (task.audioChannels != null) (Icons.language_rounded, task.audioChannels!),
      if (task.fileSizeBytes > 0) (Icons.sd_card_rounded, task.totalFormatted),
    ];

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
      child: Wrap(
        spacing: 6, runSpacing: 5,
        children: chips.map((c) => _MetaChip(icon: c.$1, label: c.$2)).toList(),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: cs.secondaryContainer.withAlpha(127)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: cs.onSecondaryContainer),
        const SizedBox(width: AppSpacing.xs),
        Text(label,
            style: TextStyle(
                color: cs.onSecondaryContainer, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ─── Play Button ─────────────────────────────────────────────────────────────

class _PlayButton extends StatelessWidget {
  final DownloadTask task;
  const _PlayButton({required this.task});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () async {
            if (task.filePath != null) {
              final uri = Uri.file(task.filePath!);
              if (!await launchUrl(uri)) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cannot open file')),
                  );
                }
              }
            }
          },
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Play Offline'),
        ),
      ),
    );
  }
}

// ─── Quality Picker Bottom Sheet ──────────────────────────────────────────────
// Called from details_screen.dart when user taps "Download"

class QualityPickerSheet extends StatelessWidget {
  final List<QualityOption> options;
  final String title;
  final void Function(QualityOption) onSelect;

  const QualityPickerSheet({
    super.key,
    required this.options,
    required this.title,
    required this.onSelect,
  });

  static Future<void> show(
    BuildContext context, {
    required List<QualityOption> options,
    required String title,
    required void Function(QualityOption) onSelect,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => QualityPickerSheet(
          options: options, title: title, onSelect: onSelect),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle
        Container(
          width: 40, height: 4,
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: cs.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
          child: Row(children: [
            Icon(Icons.download_rounded, color: cs.primary, size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                    color: cs.onSurface, fontWeight: FontWeight.w700, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        Divider(color: cs.outlineVariant, height: 1),
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              CircularProgressIndicator(color: cs.primary),
              const SizedBox(height: AppSpacing.md),
              Text('Searching for sources...',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ]),
          )
        else
          ...options.asMap().entries.map((e) => _QualityTile(option: e.value, onTap: () {
            Navigator.pop(context);
            onSelect(e.value);
          }).animate(delay: (e.key * 30).ms)
            .fadeIn(duration: 400.ms, curve: AppMotion.emphasizedDecelerate)
            .slideY(begin: 0.1, end: 0, duration: 400.ms, curve: AppMotion.emphasizedCurve)),
        const SizedBox(height: AppSpacing.sm),
      ]),
    );
  }
}

class _QualityTile extends StatelessWidget {
  final QualityOption option;
  final VoidCallback onTap;
  const _QualityTile({required this.option, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final qualityColor = _getQualityColor(option.quality, cs);
    final isTelegram = option.source == 'telegram';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: qualityColor.withAlpha(38),
          borderRadius: AppRadius.smAll,
          border: Border.all(color: qualityColor.withAlpha(102)),
        ),
        child: Text(
          option.quality.split('.').first.toUpperCase(),
          style: TextStyle(
              color: qualityColor, fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ),
      title: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        // Source badge
        Container(
          margin: const EdgeInsets.only(right: AppSpacing.sm),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: isTelegram
                ? const Color(0xFF2AABEE).withAlpha(38)
                : Colors.blue.withAlpha(30),
            borderRadius: AppRadius.xsAll,
            border: Border.all(
              color: isTelegram
                  ? const Color(0xFF2AABEE).withAlpha(102)
                  : Colors.blue.withAlpha(76),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              isTelegram ? '⚡' : '🔗',
              style: const TextStyle(fontSize: 9),
            ),
            const SizedBox(width: 3),
            Text(
              isTelegram ? 'CDN' : 'P2P',
              style: TextStyle(
                color: isTelegram ? const Color(0xFF2AABEE) : Colors.blue,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ]),
        ),
        // Indexer / Channel name
        if (option.channelName != null && option.channelName!.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(right: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: AppRadius.xsAll,
            ),
            child: Text(
              option.channelName!.length > 15
                  ? '${option.channelName!.substring(0, 15)}…'
                  : option.channelName!,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
            ),
          )
        else if (option.type != null && option.type!.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(right: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: AppRadius.xsAll,
            ),
            child: Text(
              option.type!.toUpperCase(),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
            ),
          ),
        if (option.videoCodec != null)
          Text(option.videoCodec!.toUpperCase(),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Size + audio + seeder row
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Icon(Icons.sd_card_rounded, size: 12, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(option.sizeFormatted,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            if (option.audioChannels != null) ...[
              const SizedBox(width: AppSpacing.md),
              Icon(Icons.headphones_rounded, size: 12, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(option.audioChannels!,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            ],
            if (!isTelegram && option.seeders > 0) ...[
              const SizedBox(width: AppSpacing.md),
              Icon(Icons.people_rounded, size: 12, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('${option.seeders}',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            ],
            if (isTelegram) ...[
              const SizedBox(width: AppSpacing.md),
              const Icon(Icons.bolt_rounded, size: 12, color: Color(0xFF2AABEE)),
              const SizedBox(width: 2),
              const Text('Always Fast',
                  style: TextStyle(color: Color(0xFF2AABEE), fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ]),
          // Filename row
          if (option.fileName != null && option.fileName!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              option.fileName!,
              style: TextStyle(
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                fontSize: 10,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      trailing: Icon(Icons.download_rounded, color: cs.primary, size: 20),
    );
  }

  Color _getQualityColor(String quality, ColorScheme cs) {
    final q = quality.toLowerCase();
    if (q.contains('4k') || q.contains('2160')) return Colors.amber;
    if (q.contains('1080')) return Colors.blue;
    if (q.contains('720')) return Colors.green;
    if (q.contains('480')) return Colors.orange;
    return cs.onSurfaceVariant;
  }
}

// ─── Storage Usage Bar ───────────────────────────────────────────────────────

class _StorageBar extends StatefulWidget {
  final dynamic service;
  const _StorageBar({required this.service});

  @override
  State<_StorageBar> createState() => _StorageBarState();
}

class _StorageBarState extends State<_StorageBar> {
  int _usedBytes = 0;
  int _totalBytes = 1;

  @override
  void initState() {
    super.initState();
    _computeStorage();
  }

  Future<void> _computeStorage() async {
    try {
      // Sum bytes of all completed downloads
      int used = 0;
      final service = widget.service;
      for (final task in [...service.completed, ...service.active]) {
        final path = task.localPath as String?;
        if (path != null && path.isNotEmpty) {
          final f = File(path);
          if (await f.exists()) used += await f.length();
        }
        // Fallback: use stored task totalBytes if file not found
        final taskBytes = task.totalBytes as int? ?? 0;
        if (taskBytes > 0 && used == 0) used += taskBytes;
      }
      // Device storage
      final dir = Directory('/storage/emulated/0');
      int total = 32 * 1024 * 1024 * 1024; // default 32 GB
      try {
        // Try to read statfs from proc
        final result = await Process.run('df', [dir.path]);
        final lines = (result.stdout as String).split('\n');
        if (lines.length > 1) {
          final parts = lines[1].trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) total = int.tryParse(parts[1]) ?? total;
          // df gives KB
          total *= 1024;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _usedBytes = used;
          _totalBytes = total > 0 ? total : 1;
        });
      }
    } catch (_) {}
  }

  String _fmt(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ratio = (_usedBytes / _totalBytes).clamp(0.0, 1.0);
    final usedGb = _fmt(_usedBytes);
    final totalGb = _fmt(_totalBytes);
    final pct = (ratio * 100).toStringAsFixed(1);

    Color barColor = cs.primary;
    if (ratio > 0.9) {
      barColor = cs.error;
    } else if (ratio > 0.7) {
      barColor = Colors.orange;
    }

    return ListenableBuilder(
      listenable: widget.service,
      builder: (_, __) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          color: cs.surfaceContainer,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.storage_rounded, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    'Used $usedGb of $totalGb  ($pct%)',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  if (ratio > 0.8)
                    Text('⚠️ Low space',
                        style: TextStyle(fontSize: 11, color: cs.error)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  backgroundColor: cs.surfaceContainerHigh,
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  minHeight: 6,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
