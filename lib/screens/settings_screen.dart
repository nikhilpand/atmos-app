import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../providers/providers.dart';
import '../models/download_source.dart';
import '../services/telegram_service.dart';

// ─── Settings Screen ──────────────────────────────────────────────────────────

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _downloadQuality = '1080p';
  bool _wifiOnly = true;
  bool _autoDelete = false;
  int _maxConcurrent = 2;
  DownloadSource _downloadSource = DownloadSource.auto;
  bool _autoPlay = true;
  bool _rememberProvider = true;
  bool _skipIntro = false;
  bool _saveHistory = true;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    String version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = 'v${info.version} (${info.buildNumber})';
    } catch (_) {
      version = 'v2.0.0';
    }
    if (!mounted) return;
    setState(() {
      _downloadQuality   = prefs.getString('dl_quality') ?? '1080p';
      _wifiOnly          = prefs.getBool('dl_wifi_only') ?? true;
      _autoDelete        = prefs.getBool('dl_auto_delete') ?? false;
      _maxConcurrent     = prefs.getInt('dl_max_concurrent') ?? 2;
      _autoPlay          = prefs.getBool('player_autoplay') ?? true;
      _rememberProvider  = prefs.getBool('player_remember_provider') ?? true;
      _skipIntro         = prefs.getBool('player_skip_intro') ?? false;
      _saveHistory       = prefs.getBool('app_save_history') ?? true;
      _downloadSource    = DownloadSourceLabel.fromString(prefs.getString('dl_source'));
      _version           = version;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString('dl_quality', _downloadQuality),
      prefs.setBool('dl_wifi_only', _wifiOnly),
      prefs.setBool('dl_auto_delete', _autoDelete),
      prefs.setInt('dl_max_concurrent', _maxConcurrent),
      prefs.setBool('player_autoplay', _autoPlay),
      prefs.setBool('player_remember_provider', _rememberProvider),
      prefs.setBool('player_skip_intro', _skipIntro),
      prefs.setBool('app_save_history', _saveHistory),
      prefs.setString('dl_source', _downloadSource.name),
    ]);
    // ← H3: notify DownloadService immediately so settings take effect
    ref.read(downloadServiceProvider).reloadSettings();
  }

  @override
  Widget build(BuildContext context) {
    final telegram = ref.watch(telegramServiceProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          // ── Appearance ─────────────────────────────────────────────
          _SectionHeader('Appearance'),
          _AppearanceSection(ref: ref),

          // ── Download Settings ───────────────────────────────────────
          _SectionHeader('Downloads'),
          _SettingTile(
            icon: Icons.high_quality_rounded,
            title: 'Default Quality',
            subtitle: 'Preferred quality for new downloads',
            trailing: _QualityDropdown(
              value: _downloadQuality,
              onChanged: (v) { setState(() => _downloadQuality = v!); _save(); },
            ),
          ),
          _SettingTile(
            icon: Icons.wifi_rounded,
            title: 'Wi-Fi Only',
            subtitle: 'Only download when connected to Wi-Fi',
            trailing: Switch(
              value: _wifiOnly,
              onChanged: (v) { setState(() => _wifiOnly = v); _save(); },
            ),
          ),
          _SettingTile(
            icon: Icons.tune_rounded,
            title: 'Concurrent Downloads',
            subtitle: 'Max downloads at once ($_maxConcurrent)',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: _maxConcurrent > 1
                    ? () { setState(() => _maxConcurrent--); _save(); }
                    : null,
              ),
              Text('$_maxConcurrent',
                  style: Theme.of(context).textTheme.labelLarge),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _maxConcurrent < 5
                    ? () { setState(() => _maxConcurrent++); _save(); }
                    : null,
              ),
            ]),
          ),
          _SettingTile(
            icon: Icons.auto_delete_rounded,
            title: 'Auto-delete after watching',
            subtitle: 'Remove files after playing them once',
            trailing: Switch(
              value: _autoDelete,
              onChanged: (v) { setState(() => _autoDelete = v); _save(); },
            ),
          ),

          // ── Download Source ─────────────────────────────────────────
          _SectionHeader('Download Source'),
          _SettingTile(
            icon: Icons.swap_horiz_rounded,
            title: 'Source Engine',
            subtitle: _downloadSource.description,
            trailing: _SourceDropdown(
              value: _downloadSource,
              onChanged: (v) {
                setState(() => _downloadSource = v!);
                ref.read(downloadSourceProvider.notifier).state = v!;
                _save();
              },
            ),
          ),

          // ── Telegram Account ───────────────────────────────────────
          _SectionHeader('Telegram'),
          if (telegram.isLoggedIn)
            _SettingTile(
              icon: Icons.check_circle_rounded,
              title: telegram.phone ?? 'Connected',
              subtitle: 'Logged in — CDN downloads ready',
              trailing: TextButton(
                onPressed: () => telegram.logout(),
                child: Text('Logout',
                    style: TextStyle(color: cs.error)),
              ),
            )
          else
            _SettingTile(
              icon: Icons.telegram,
              title: 'Connect Telegram',
              subtitle: _getTelegramSubtitle(telegram.authState),
              onTap: () => _showTelegramLogin(context, telegram),
              trailing: Icon(Icons.chevron_right_rounded, color: cs.outline),
            ),
          _SettingTile(
            icon: Icons.info_outline_rounded,
            title: 'About Telegram Downloads',
            subtitle: 'Searches public channels for videos up to 1080p / 5 GB. Direct CDN — always fast.',
          ),
          if (telegram.isLoggedIn)
            _SettingTile(
              icon: Icons.video_library_rounded,
              title: 'Browse Telegram Channels',
              subtitle: 'Search movies & shows directly on Telegram',
              onTap: () => context.push('/telegram-browser'),
              trailing: Icon(Icons.chevron_right_rounded,
                  color: Theme.of(context).colorScheme.outline),
            ),

          // ── Player Settings ─────────────────────────────────────────
          _SectionHeader('Player'),
          _SettingTile(
            icon: Icons.source_rounded,
            title: 'Remember Last Source',
            subtitle: 'Continue with the last working provider',
            trailing: Switch(
              value: _rememberProvider,
              onChanged: (v) { setState(() => _rememberProvider = v); _save(); },
            ),
          ),
          _SettingTile(
            icon: Icons.play_circle_rounded,
            title: 'Auto-play Next Episode',
            subtitle: 'Automatically start next episode in series',
            trailing: Switch(
              value: _autoPlay,
              onChanged: (v) { setState(() => _autoPlay = v); _save(); },
            ),
          ),

          // ── App Settings ────────────────────────────────────────────
          _SectionHeader('App'),
          _SettingTile(
            icon: Icons.history_rounded,
            title: 'Save Watch History',
            subtitle: 'Track what you\'ve watched',
            trailing: Switch(
              value: _saveHistory,
              onChanged: (v) { setState(() => _saveHistory = v); _save(); },
            ),
          ),
          _SettingTile(
            icon: Icons.delete_sweep_rounded,
            title: 'Clear Watch History',
            subtitle: 'Remove all viewing history',
            onTap: () => _confirmClearHistory(context),
          ),
          _SettingTile(
            icon: Icons.storage_rounded,
            title: 'Clear Cache',
            subtitle: 'Free up space used by thumbnails',
            onTap: () => _clearCache(context),
          ),

          // ── About ───────────────────────────────────────────────────
          _SectionHeader('About'),
          _SettingTile(
            icon: Icons.info_outline_rounded,
            title: 'Version',
            subtitle: _version.isNotEmpty ? _version : 'v2.0.0',
          ),
          _SettingTile(
            icon: Icons.bolt_rounded,
            title: 'Powered by',
            subtitle: 'libtorrent 2.0 · TDLib · ffmpeg · flutter_inappwebview',
          ),

          const SizedBox(height: AppSpacing.xl),
        ].animate(interval: 20.ms).fadeIn(duration: 400.ms, curve: AppMotion.emphasizedDecelerate).slideY(begin: 0.1, end: 0, duration: 400.ms, curve: AppMotion.emphasizedCurve),
      ),
    );
  }

  String _getTelegramSubtitle(TelegramAuthState state) => switch (state) {
    TelegramAuthState.waitingForPhone => 'Tap to enter phone number',
    TelegramAuthState.waitingForOtp   => 'Waiting for OTP — tap to enter code',
    TelegramAuthState.waitingFor2fa   => 'Waiting for 2FA password',
    TelegramAuthState.error           => 'Error — tap to retry',
    _                                 => 'Required for fast CDN downloads',
  };

  void _showTelegramLogin(BuildContext context, TelegramService telegram) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TelegramLoginSheet(telegram: telegram),
    );
  }

  void _confirmClearHistory(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text('This will remove all watch history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () async {
              Navigator.pop(context);
              final hs = ref.read(historyServiceProvider);
              await hs.clearAll();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('History cleared')),
                );
              }
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearCache(BuildContext context) async {
    // ← M1: Actually evict CachedNetworkImage caches
    await CachedNetworkImage.evictFromCache('');
    // Evict Flutter image cache too
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image cache cleared ✓')),
      );
    }
  }
}

// ─── Appearance Section ───────────────────────────────────────────────────────

class _AppearanceSection extends StatelessWidget {
  final WidgetRef ref;
  const _AppearanceSection({required this.ref});

  @override
  Widget build(BuildContext context) {
    final cs   = Theme.of(context).colorScheme;
    final seed = ref.watch(seedColorProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.palette_rounded, color: cs.primary, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Text('Theme Color',
                    style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: kThemeSeeds.map((entry) {
                  final isSelected = entry.seed.value == seed.value;
                  return Tooltip(
                    message: entry.label,
                    child: GestureDetector(
                      onTap: () => ref
                          .read(seedColorProvider.notifier)
                          .setSeed(entry.seed),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: entry.seed,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? cs.onSurface
                                : Colors.transparent,
                            width: isSelected ? 3 : 0,
                          ),
                          boxShadow: isSelected
                              ? [BoxShadow(color: entry.seed.withAlpha(100), blurRadius: 8)]
                              : null,
                        ),
                        child: isSelected
                            ? Icon(Icons.check_rounded,
                                color: ThemeData.estimateBrightnessForColor(entry.seed) == Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                                size: 20)
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Telegram Login Bottom Sheet ────────────────────────────────────────────

class _TelegramLoginSheet extends StatefulWidget {
  final TelegramService telegram;
  const _TelegramLoginSheet({required this.telegram});

  @override
  State<_TelegramLoginSheet> createState() => _TelegramLoginSheetState();
}

class _TelegramLoginSheetState extends State<_TelegramLoginSheet> {
  final _phoneController    = TextEditingController();
  final _otpController      = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.telegram.addListener(_onAuthChange);
  }

  @override
  void dispose() {
    widget.telegram.removeListener(_onAuthChange);
    _phoneController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onAuthChange() {
    if (!mounted) return;
    setState(() {});
    if (widget.telegram.isLoggedIn) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Telegram connected! CDN downloads ready.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state     = widget.telegram.authState;
    final cs        = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2AABEE), Color(0xFF229ED9)],
                ),
                borderRadius: AppRadius.mdAll,
              ),
              child: const Icon(Icons.telegram, color: Colors.white, size: 28),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Connect Telegram', style: Theme.of(context).textTheme.titleLarge),
              Text('For lightning-fast CDN downloads',
                  style: Theme.of(context).textTheme.bodySmall),
            ])),
          ]),
          const SizedBox(height: AppSpacing.lg),

          // Error banner
          if (_error != null || widget.telegram.errorMessage != null) ...[
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Row(children: [
                  Icon(Icons.error_outline, color: cs.onErrorContainer, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(
                    _error ?? widget.telegram.errorMessage!,
                    style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
                  )),
                ]),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // Step 1: Phone
          if (state == TelegramAuthState.waitingForPhone ||
              state == TelegramAuthState.uninitialized ||
              state == TelegramAuthState.error) ...[
            Text('Phone Number', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]'))],
              decoration: const InputDecoration(hintText: '+1 202 555 0100'),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _submitPhone,
                child: _loading
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send OTP'),
              ),
            ),
          ],

          // Step 2: OTP
          if (state == TelegramAuthState.waitingForOtp) ...[
            Text('Enter OTP Code', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.xs),
            Text('Sent to ${widget.telegram.phone ?? _phoneController.text}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm + AppSpacing.xs),
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              autofocus: true,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 8),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(hintText: '• • • • • •'),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _submitOtp,
                child: _loading
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Verify'),
              ),
            ),
          ],

          // Step 3: 2FA
          if (state == TelegramAuthState.waitingFor2fa) ...[
            Text('Two-Factor Password', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _passwordController,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Enter your 2FA password'),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _submit2fa,
                child: const Text('Submit'),
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }

  Future<void> _submitPhone() async {
    final phone = _phoneController.text.replaceAll(' ', '').trim();
    if (phone.length < 8) {
      setState(() => _error = 'Enter a valid phone number');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await widget.telegram.sendPhoneNumber(phone);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitOtp() async {
    final code = _otpController.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the complete OTP code');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await widget.telegram.verifyOtp(code);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit2fa() async {
    final pwd = _passwordController.text;
    if (pwd.isEmpty) {
      setState(() => _error = 'Enter your 2FA password');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await widget.telegram.verify2fa(pwd);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ─── Reusable Widgets ─────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs + AppSpacing.xs),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs / 2,
      ),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(icon, color: cs.onPrimaryContainer, size: 18),
          ),
          title: Text(title),
          subtitle: subtitle != null ? Text(subtitle!) : null,
          trailing: trailing ??
              (onTap != null
                  ? Icon(Icons.chevron_right_rounded, color: cs.outline)
                  : null),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _QualityDropdown extends StatelessWidget {
  final String value;
  final void Function(String?) onChanged;
  const _QualityDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropdownButton<String>(
      value: value,
      dropdownColor: cs.surfaceContainerHigh,
      style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
      underline: const SizedBox.shrink(),
      items: const [
        DropdownMenuItem(value: '720p',  child: Text('720p')),
        DropdownMenuItem(value: '1080p', child: Text('1080p')),
        DropdownMenuItem(value: '2160p', child: Text('4K')),
      ],
      onChanged: onChanged,
    );
  }
}

class _SourceDropdown extends StatelessWidget {
  final DownloadSource value;
  final void Function(DownloadSource?) onChanged;
  const _SourceDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropdownButton<DownloadSource>(
      value: value,
      dropdownColor: cs.surfaceContainerHigh,
      style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
      underline: const SizedBox.shrink(),
      items: DownloadSource.values.map((s) => DropdownMenuItem(
        value: s,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(s.icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: AppSpacing.sm - AppSpacing.xs),
          Text(
            s == DownloadSource.auto     ? 'Auto'
              : s == DownloadSource.torrent ? 'Torrent'
              : 'Telegram',
            style: const TextStyle(fontSize: 13),
          ),
        ]),
      )).toList(),
      onChanged: onChanged,
    );
  }
}
