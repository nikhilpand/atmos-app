import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ota_update_service.dart';

class UpdateDialog extends ConsumerStatefulWidget {
  final GithubRelease release;

  const UpdateDialog({super.key, required this.release});

  static void show(BuildContext context, GithubRelease release) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(release: release),
    );
  }

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  bool _isDownloading = false;
  bool _isInstalling = false;
  double _progress = 0.0;
  String? _error;

  void _startDownload() async {
    setState(() { _isDownloading = true; _error = null; });

    final ota = ref.read(otaUpdateProvider);
    final asset = ota.getBestAsset(widget.release);

    if (asset == null) {
      setState(() { _error = "No compatible APK found for your device."; _isDownloading = false; });
      return;
    }

    try {
      await ota.downloadAndInstall(
        asset,
        (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
              if (progress >= 1.0) _isInstalling = true;
            });
          }
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() { _error = "Update failed: $e"; _isDownloading = false; _isInstalling = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_rounded, color: cs.primary),
          const SizedBox(width: 12),
          const Text('Update Available'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Version ${widget.release.tagName} is ready to install.',
            style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Text(
                  widget.release.body.isEmpty ? 'Bug fixes and performance improvements.' : widget.release.body,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
          ],
          if (_isDownloading) ...[
            const SizedBox(height: 24),
            LinearProgressIndicator(
              value: _isInstalling ? null : _progress,
              backgroundColor: cs.primaryContainer,
              color: cs.primary,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _isInstalling ? 'Installing…' : '${(_progress * 100).toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (!_isDownloading)
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('LATER')),
        if (!_isDownloading)
          FilledButton(onPressed: _startDownload, child: const Text('UPDATE NOW')),
        if (_error != null && _isDownloading)
          FilledButton(onPressed: _startDownload, child: const Text('RETRY')),
      ],
    );
  }
}
