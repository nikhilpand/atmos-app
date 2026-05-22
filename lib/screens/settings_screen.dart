import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../providers/providers.dart';
import '../models/download_source.dart';
import '../services/telegram_service.dart';
import '../widgets/update_dialog.dart';

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
  DownloadSource _downloadSource = DownloadSource.telegram;
  bool _autoPlay = true;
  bool _rememberProvider = true;
  bool _skipIntro = false;
  bool _saveHistory = true;
  String _version = '';
  String _geminiApiKey = '';

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
      version = 'v3.0.0';
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
      _geminiApiKey      = prefs.getString('custom_gemini_api_key') ?? '';
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

    final width = MediaQuery.sizeOf(context).width;
    final hPad = width >= AppBreakpoints.expanded
        ? AppSpacing.xxl
        : width >= AppBreakpoints.compact
            ? AppSpacing.xl
            : AppSpacing.md;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: const Text('Settings'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: hPad),
        children: [
          // P14: Card-based section grouping for premium look
          // ── Appearance ────────────────────────────────────────────
          _SettingsCard(header: 'Appearance', children: [
            _AppearanceSection(ref: ref),
          ]),

          // ── Downloads ─────────────────────────────────────────────
          _SettingsCard(header: 'Downloads', children: [
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
          ]),

          // ── Telegram ──────────────────────────────────────────────
          _SettingsCard(header: 'Telegram', children: [
            if (telegram.isLoggedIn)
              _SettingTile(
                icon: Icons.check_circle_rounded,
                title: telegram.phone ?? 'Connected',
                subtitle: 'Logged in — CDN downloads ready',
                trailing: TextButton(
                  onPressed: () => telegram.logout(),
                  child: Text('Logout', style: TextStyle(color: cs.error)),
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
            const _SettingTile(
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
          ]),

          // ── Gemini AI ──────────────────────────────────────────────
          _SettingsCard(header: 'Gemini AI', children: [
            _SettingTile(
              icon: Icons.auto_awesome_rounded,
              title: 'API Configuration',
              subtitle: _geminiApiKey.isNotEmpty
                  ? 'Custom key configured (${_geminiApiKey.length > 10 ? '${_geminiApiKey.substring(0, 10)}...' : _geminiApiKey})'
                  : 'Not configured (using backend fallback)',
              onTap: _showGeminiKeyDialog,
              trailing: Icon(Icons.edit_rounded, color: cs.primary),
            ),
            const _SettingTile(
              icon: Icons.info_outline_rounded,
              title: 'About Gemini Integration',
              subtitle: 'Powers personalized movie recommendations, smart home screen categories, and search alias expansion.',
            ),
          ]),

          // ── Player ────────────────────────────────────────────────
          _SettingsCard(header: 'Player', children: [
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
          ]),

          // ── App ───────────────────────────────────────────────────
          _SettingsCard(header: 'App', children: [
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
          ]),

          // ── About ─────────────────────────────────────────────────
          _SettingsCard(header: 'About', children: [
            _SettingTile(
              icon: Icons.system_update_rounded,
              title: 'Check for Updates',
              subtitle: _version.isNotEmpty ? 'Current: $_version' : 'v3.0.0',
              onTap: () async {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Checking for updates...')),
                );
                final release = await ref.read(otaUpdateProvider).checkForUpdate();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                if (release != null) {
                  UpdateDialog.show(context, release);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('You are on the latest version.')),
                  );
                }
              },
            ),
            const _SettingTile(
              icon: Icons.bolt_rounded,
              title: 'Powered by',
              subtitle: 'TDLib · media_kit · Atmos Engine',
            ),
          ]),

          const SizedBox(height: AppSpacing.xl),
        ].animate(interval: 20.ms).fadeIn(duration: 400.ms, curve: AppMotion.emphasizedDecelerate).slideY(begin: 0.1, end: 0, duration: 400.ms, curve: AppMotion.emphasizedCurve),
          ),
        ),
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

  void _showGeminiKeyDialog() {
    final controller = TextEditingController(text: _geminiApiKey);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Gemini API Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter a valid Gemini API key to enable direct, high-performance personalized recommendations and search alias expansion.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'AIzaSy...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final key = controller.text.trim();
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                final prefs = await SharedPreferences.getInstance();
                if (key.isEmpty) {
                  await prefs.remove('custom_gemini_api_key');
                } else {
                  await prefs.setString('custom_gemini_api_key', key);
                }
                ref.invalidate(geminiRecommendationsProvider);
                ref.invalidate(geminiCategoriesProvider);
                setState(() {
                  _geminiApiKey = key;
                });
                navigator.pop();
                messenger.showSnackBar(
                  const SnackBar(content: Text('✅ Gemini API key updated!')),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
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
                  final isSelected = entry.seed.toARGB32() == seed.toARGB32();
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
                              ? [BoxShadow(color: entry.seed.withValues(alpha: 0.4), blurRadius: 8)]
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
  bool _forceShowPhone = false;
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

    final showPhoneInput = state == TelegramAuthState.waitingForPhone ||
        state == TelegramAuthState.uninitialized ||
        state == TelegramAuthState.error ||
        _forceShowPhone;

    int activeStep = 0;
    if (state == TelegramAuthState.waitingForPhone || showPhoneInput) {
      activeStep = 0;
    } else if (state == TelegramAuthState.waitingForOtp) {
      activeStep = 1;
    } else if (state == TelegramAuthState.waitingFor2fa) {
      activeStep = 2;
    }

    Widget buildStepIndicator(int index, String label) {
      final isActive = activeStep == index;
      final isCompleted = activeStep > index;
      final color = isActive
          ? cs.primary
          : (isCompleted ? cs.primary.withValues(alpha: 0.7) : cs.onSurfaceVariant.withValues(alpha: 0.3));

      return Expanded(
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Divider(
                    color: index == 0 ? Colors.transparent : color,
                    thickness: 2,
                  ),
                ),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isActive ? cs.primaryContainer : (isCompleted ? cs.primary : Colors.transparent),
                    border: Border.all(
                      color: isActive ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.3),
                      width: 2,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: isCompleted
                        ? Icon(Icons.check, size: 14, color: cs.onPrimary)
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isActive ? cs.onPrimaryContainer : cs.onSurfaceVariant.withValues(alpha: 0.5),
                            ),
                          ),
                  ),
                ),
                Expanded(
                  child: Divider(
                    color: index == 2 ? Colors.transparent : color,
                    thickness: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }

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
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF2AABEE), Color(0xFF229ED9)],
                ),
                borderRadius: AppRadius.mdAll,
              ),
              child: const Icon(Icons.telegram, color: Colors.white, size: 28),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Connect Telegram', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              Text('For lightning-fast CDN downloads',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
            ])),
          ]),
          const SizedBox(height: AppSpacing.lg),

          // Horizontal Progress Tracker / Stepper
          Row(
            children: [
              buildStepIndicator(0, 'Phone'),
              buildStepIndicator(1, 'OTP Code'),
              buildStepIndicator(2, '2FA Password'),
            ],
          ),
          const SizedBox(height: AppSpacing.lg + AppSpacing.xs),

          // Error banner
          if (_error != null || widget.telegram.errorMessage != null) ...[
            Container(
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.error.withValues(alpha: 0.3)),
              ),
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(children: [
                Icon(Icons.error_outline, color: cs.onErrorContainer, size: 20),
                const SizedBox(width: AppSpacing.md),
                Expanded(child: Text(
                  _error ?? widget.telegram.errorMessage!,
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13, fontWeight: FontWeight.w500),
                )),
              ]),
            ).animate().fadeIn(duration: 200.ms).slideY(begin: 0.1, end: 0),
            const SizedBox(height: AppSpacing.md),
          ],

          // Dynamic step forms
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step 1: Phone
              if (showPhoneInput) ...[
                Text('Phone Number', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]'))],
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: '+1 202 555 0100',
                    prefixIcon: Icon(Icons.phone_android, color: cs.primary),
                    filled: true,
                    fillColor: cs.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.primary, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _submitPhone,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Send Verification Code', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],

              // Step 2: OTP
              if (!showPhoneInput && state == TelegramAuthState.waitingForOtp) ...[
                Text('Enter OTP Code', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.xs),
                Text('Sent to ${widget.telegram.phone ?? _phoneController.text}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        letterSpacing: 12,
                        fontWeight: FontWeight.bold,
                        color: cs.primary,
                      ),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: InputDecoration(
                    hintText: '••••••',
                    hintStyle: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.3), letterSpacing: 12),
                    filled: true,
                    fillColor: cs.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.primary, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _submitOtp,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Verify Code', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: TextButton.icon(
                    onPressed: _loading ? null : () {
                      setState(() {
                        _forceShowPhone = true;
                        _error = null;
                      });
                    },
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Change phone number'),
                  ),
                ),
              ],

              // Step 3: 2FA
              if (!showPhoneInput && state == TelegramAuthState.waitingFor2fa) ...[
                Text('Two-Factor Password', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: 'Enter your 2FA password',
                    prefixIcon: Icon(Icons.lock_outline, color: cs.primary),
                    filled: true,
                    fillColor: cs.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.primary, width: 2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit2fa,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Submit Password', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: TextButton.icon(
                    onPressed: _loading ? null : () {
                      setState(() {
                        _forceShowPhone = true;
                        _error = null;
                      });
                    },
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Change phone number'),
                  ),
                ),
              ],
            ],
          ).animate(key: ValueKey(state)).fadeIn(duration: 250.ms).slideY(begin: 0.05, end: 0, curve: Curves.easeOut),

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
      setState(() => _forceShowPhone = false);
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
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
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
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
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

// ─── Reusable Widgets ─────────────────────────────────────────────────────────

// P14: Rounded card that groups settings tiles with an inline section header
class _SettingsCard extends StatelessWidget {
  final String header;
  final List<Widget> children;
  const _SettingsCard({required this.header, required this.children});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.xs),
            child: Text(
              header.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.primary, letterSpacing: 1.2),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: cs.surfaceContainer,
            elevation: 0,
            child: Column(children: children),
          ),
        ],
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



