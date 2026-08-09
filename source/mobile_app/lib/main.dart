import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const CityStaminaMobileApp());
}

class CityStaminaMobileApp extends StatelessWidget {
  const CityStaminaMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'City Stamina',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.primary,
          surface: AppColors.surface,
          error: AppColors.danger,
        ),
        fontFamily: 'Inter',
        useMaterial3: true,
      ),
      home: const AutomationHubPage(),
    );
  }
}

class AppColors {
  static const background = Color(0xFF0E1320);
  static const surface = Color(0xFF141B2D);
  static const panel = Color(0xFF1A2238);
  static const log = Color(0xFF090D16);
  static const primary = Color(0xFF34D399);
  static const primaryDim = Color(0xFF1A3330);
  static const danger = Color(0xFFF06060);
  static const dangerDim = Color(0xFF2E1515);
  static const blue = Color(0xFF3B6BBC);
  static const violet = Color(0xFF7C5CBF);
  static const warning = Color(0xFFF59E0B);
  static const text = Color(0xFFDCE6F5);
  static const sub = Color(0xFF8494B0);
  static const muted = Color(0xFF5A6A88);
  static const dim = Color(0xFF2A3650);
  static const border = Color(0x12FFFFFF);
}

class AppInfo {
  static const version = '1.0.4';
  static const androidApkUrl =
      'https://github.com/PHai237/City-Stamina-Spender/releases/latest/download/City.Stamina.Mobile.apk';
}

class MobileLogService {
  MobileLogService._();

  static final MobileLogService instance = MobileLogService._();

  final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>([]);
  File? _logFile;

  Future<void> init() async {
    if (_logFile != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory(p.join(dir.path, 'logs'));
    await logDir.create(recursive: true);
    _logFile = File(p.join(logDir.path, 'mobile.log'));
    if (!await _logFile!.exists()) {
      await _logFile!.writeAsString('City Stamina Mobile log\n');
    }
    info('Mobile app started');
  }

  Future<File> get logFile async {
    await init();
    return _logFile!;
  }

  void info(String message) => _write('INFO', message);

  void warn(String message) => _write('WARN', message);

  void error(String message) => _write('ERROR', message);

  void _write(String level, String message) {
    final stamp = DateTime.now().toIso8601String();
    final line = '$stamp [$level] $message';
    final next = [...lines.value, line];
    lines.value = next.length > 80 ? next.sublist(next.length - 80) : next;
    final file = _logFile;
    if (file != null) {
      file.writeAsString('$line\n', mode: FileMode.append, flush: false);
    }
  }
}

class DebugPackageService {
  DebugPackageService(this.log);

  final MobileLogService log;

  Future<bool> hasWebhookConfigured() async {
    return await _readWebhookUrl() != null;
  }

  Future<void> saveWebhookUrl(String webhookUrl) async {
    final value = _normalizeWebhookUrl(webhookUrl);
    if (!_isDiscordWebhook(value)) {
      throw const FormatException('Paste a full Discord webhook URL.');
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'discord_webhook.txt'));
    await file.writeAsString('$value\n', flush: true);
    log.info('Discord webhook saved.');
  }

  Future<String> exportToDiscord() async {
    await log.init();
    final webhookUrl = await _readWebhookUrl();
    if (webhookUrl == null) {
      throw StateError('Discord webhook is not configured.');
    }

    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '_');
    final packageFile = File(p.join(tempDir.path, 'city-stamina-mobile-debug-$stamp.txt'));
    await packageFile.writeAsString(await _buildReport(), flush: true);

    try {
      await _sendFile(webhookUrl, packageFile);
      await packageFile.delete();
      log.info('Debug package sent to Discord and deleted locally.');
      return 'Debug package sent.';
    } catch (error) {
      log.error('Debug package upload failed: $error');
      rethrow;
    }
  }

  Future<String?> _readWebhookUrl() async {
    const envWebhook = String.fromEnvironment('DISCORD_WEBHOOK_URL');
    final normalizedEnvWebhook = _normalizeWebhookUrl(envWebhook);
    if (_isDiscordWebhook(normalizedEnvWebhook)) return normalizedEnvWebhook;

    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'discord_webhook.txt'));
    if (!await file.exists()) {
      await file.writeAsString(
        'Paste one Discord webhook URL on the next line.\n',
        flush: true,
      );
      log.warn('Created discord_webhook.txt. Add a webhook URL before uploading debug logs.');
      return null;
    }

    final lines = await file.readAsLines();
    for (final line in lines) {
      final value = _normalizeWebhookUrl(line);
      if (_isDiscordWebhook(value)) return value;
    }
    return null;
  }

  String _normalizeWebhookUrl(String value) {
    var normalized = value.trim();
    while (normalized.isNotEmpty && '<"\''.contains(normalized[0])) {
      normalized = normalized.substring(1).trimLeft();
    }
    while (normalized.isNotEmpty && '>"\''.contains(normalized[normalized.length - 1])) {
      normalized = normalized.substring(0, normalized.length - 1).trimRight();
    }
    return normalized;
  }

  bool _isDiscordWebhook(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https') return false;
    const allowedHosts = {
      'discord.com',
      'discordapp.com',
      'canary.discord.com',
      'ptb.discord.com',
    };
    return allowedHosts.contains(uri.host.toLowerCase()) &&
        uri.pathSegments.length >= 3 &&
        uri.pathSegments[0] == 'api' &&
        uri.pathSegments[1] == 'webhooks' &&
        uri.pathSegments[2].isNotEmpty;
  }

  Future<String> _buildReport() async {
    final buffer = StringBuffer()
      ..writeln('City Stamina Mobile debug report')
      ..writeln('Version: ${AppInfo.version}')
      ..writeln('Created: ${DateTime.now().toIso8601String()}')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('')
      ..writeln('==== UI LOG ====');

    for (final line in log.lines.value) {
      buffer.writeln(line);
    }

    final file = await log.logFile;
    if (await file.exists()) {
      buffer
        ..writeln('')
        ..writeln('==== FILE LOG ====')
        ..write(await file.readAsString());
    }

    return buffer.toString();
  }

  Future<void> _sendFile(String webhookUrl, File file) async {
    final request = http.MultipartRequest('POST', Uri.parse(webhookUrl));
    request.fields['payload_json'] = jsonEncode({
      'content': 'City Stamina Mobile debug package | ${DateTime.now().toIso8601String()}',
    });
    request.files.add(await http.MultipartFile.fromPath(
      'files[0]',
      file.path,
      filename: p.basename(file.path),
    ));

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Discord upload failed: ${response.statusCode} $body');
    }
  }
}

class AppUpdateService {
  AppUpdateService(this.log);

  final MobileLogService log;

  Future<void> openAndroidDownload() async {
    final uri = Uri.parse(AppInfo.androidApkUrl);
    log.info('Opening Android APK download page.');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      await Clipboard.setData(const ClipboardData(text: AppInfo.androidApkUrl));
      log.warn('Could not open browser. APK link copied to clipboard.');
      throw StateError('Could not open browser. Link copied to clipboard.');
    }
  }
}

class OwnerAutomationController {
  OwnerAutomationController(this.log);

  final MobileLogService log;
  final ValueNotifier<bool> isRunning = ValueNotifier(false);
  final ValueNotifier<int> elapsedSeconds = ValueNotifier(0);
  Timer? _timer;

  void start({required String amount, required String stage}) {
    if (isRunning.value) return;
    final parsed = int.tryParse(amount.trim());
    if (parsed == null || parsed <= 0) {
      log.warn('Enter a valid City Stamina amount.');
      return;
    }

    elapsedSeconds.value = 0;
    isRunning.value = true;
    log.info('Run started. stage=$stage target=$parsed');
    log.info('Mobile automation runner is not wired yet.');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedSeconds.value += 1;
      if (elapsedSeconds.value % 10 == 0) {
        log.info('Still running. elapsed=${elapsedSeconds.value}s');
      }
    });
  }

  void stop() {
    if (!isRunning.value) return;
    _timer?.cancel();
    _timer = null;
    isRunning.value = false;
    log.info('Stopped.');
  }

  void dispose() {
    _timer?.cancel();
    isRunning.dispose();
    elapsedSeconds.dispose();
  }
}

class AndroidControlController {
  AndroidControlController(this.log);

  static const _channel = MethodChannel('city_stamina_mobile/control');
  static const _events = EventChannel('city_stamina_mobile/control_events');
  final MobileLogService log;

  Stream<Map<String, dynamic>> get events {
    return _events.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event as Map);
    });
  }

  Future<bool> canPostNotifications() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canPostNotifications') ?? false;
  }

  Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestNotificationPermission');
    log.info('Requested Android notification permission.');
  }

  Future<void> startControlNotification() async {
    if (!Platform.isAndroid) {
      log.warn('Notification control is Android-only.');
      return;
    }
    await _channel.invokeMethod<void>('startControl');
    log.info('Notification control started.');
  }

  Future<void> stopControlNotification() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopControl');
    log.info('Notification control stopped.');
  }

  Future<void> setControlRunning(bool running) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setControlRunning', {'running': running});
  }
}

class AutomationHubPage extends StatefulWidget {
  const AutomationHubPage({super.key});

  @override
  State<AutomationHubPage> createState() => _AutomationHubPageState();
}

class _AutomationHubPageState extends State<AutomationHubPage> {
  final _log = MobileLogService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_log.init());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _AppHeader(title: 'Automation Hub', subtitle: 'Mobile ${AppInfo.version}'),
              const SizedBox(height: 18),
              _PrimaryAutomationCard(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OwnerSelectionPage()),
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _SmallActionCard(
                      title: 'Debug',
                      subtitle: 'Export session log',
                      color: AppColors.blue,
                      icon: Icons.bug_report_rounded,
                      onTap: () async => _sendDebugPackage(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SmallActionCard(
                      title: 'Update',
                      subtitle: 'Check for new version',
                      color: AppColors.violet,
                      icon: Icons.refresh_rounded,
                      onTap: () async => _openAndroidDownload(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const _SectionLabel('Log'),
              const SizedBox(height: 8),
              _LogPreview(log: _log),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendDebugPackage(BuildContext context) async {
    await sendMobileDebugPackage(context, _log);
  }

  Future<void> _openAndroidDownload(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppUpdateService(_log).openAndroidDownload();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $error')));
    }
  }

}

Future<void> sendMobileDebugPackage(BuildContext context, MobileLogService log) async {
  final messenger = ScaffoldMessenger.of(context);
  final debugService = DebugPackageService(log);
  try {
    if (!await debugService.hasWebhookConfigured()) {
      if (!context.mounted) return;
      final webhookUrl = await askWebhookUrl(context);
      if (!context.mounted) return;
      if (webhookUrl == null) {
        log.warn('Debug upload canceled because webhook is not configured.');
        return;
      }
      await debugService.saveWebhookUrl(webhookUrl);
    }
    log.info('Sending mobile debug package...');
    final message = await debugService.exportToDiscord();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  } catch (error) {
    log.error('Debug failed: $error');
    messenger.showSnackBar(SnackBar(content: Text('Debug failed: ${formatUserError(error)}')));
  }
}

String formatUserError(Object error) {
  if (error is FormatException) {
    return error.message;
  }
  if (error is StateError) {
    return error.message;
  }
  return error.toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('Bad state: ', '')
      .replaceFirst('FormatException: ', '');
}

Future<String?> askWebhookUrl(BuildContext context) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Discord webhook'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'https://discord.com/api/webhooks/...',
              helperText: 'Use the webhook URL, not the Discord channel link.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

class OwnerSelectionPage extends StatefulWidget {
  const OwnerSelectionPage({super.key});

  @override
  State<OwnerSelectionPage> createState() => _OwnerSelectionPageState();
}

class _OwnerSelectionPageState extends State<OwnerSelectionPage> {
  final _log = MobileLogService.instance;
  late final OwnerAutomationController _controller;
  late final AndroidControlController _controlController;
  final _amountController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _controlSubscription;
  String _stage = '1-9';
  bool _notificationControlVisible = false;
  bool _notificationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _controller = OwnerAutomationController(_log);
    _controlController = AndroidControlController(_log);
    unawaited(_refreshNotificationPermission());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_promptNotificationPermissionIfNeeded());
    });
    _controlSubscription = _controlController.events.listen(_handleControlEvent, onError: (error) {
      _log.warn('Notification control event stream stopped: $error');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _controlSubscription?.cancel();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackHeader(onBack: () => Navigator.of(context).pop()),
                  const SizedBox(height: 20),
                  const _AppHeader(title: "Owner's Selection", subtitle: 'NTE automation'),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              _AmountCard(controller: _amountController),
              const SizedBox(height: 12),
              _StageSelector(
                value: _stage,
                onChanged: (value) => setState(() => _stage = value),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<bool>(
                valueListenable: _controller.isRunning,
                builder: (context, running, _) {
                  return ValueListenableBuilder<int>(
                    valueListenable: _controller.elapsedSeconds,
                    builder: (context, elapsed, _) {
                      if (!running && elapsed == 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _MetricStrip(label: 'Elapsed', value: _formatElapsed(elapsed)),
                      );
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _controller.isRunning,
                builder: (context, running, _) {
                  return _RunButton(
                    running: running,
                    onPressed: () => _toggleRun(running),
                  );
                },
              ),
              const SizedBox(height: 12),
              _ActionRow(
                icon: _notificationControlVisible
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_active_rounded,
                title: 'Notification control',
                onTap: _toggleNotificationControl,
              ),
              const SizedBox(height: 8),
              _ActionRow(
                icon: Icons.send_rounded,
                title: 'Send debug log',
                onTap: () => sendMobileDebugPackage(context, _log),
              ),
              const SizedBox(height: 12),
              _StatusNote(
                active: _notificationPermissionGranted,
                text: _notificationPermissionGranted
                    ? 'Notification control is ready'
                    : 'Notification permission is needed',
              ),
              const SizedBox(height: 18),
              _LogSectionHeader(runningListenable: _controller.isRunning),
              const SizedBox(height: 8),
              SizedBox(height: 160, child: _LogPanel(log: _log)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleRun(bool running) {
    if (running) {
      _controller.stop();
      unawaited(_controlController.setControlRunning(false));
      return;
    }

    _controller.start(
      amount: _amountController.text,
      stage: _stage,
    );
    unawaited(_controlController.setControlRunning(_controller.isRunning.value));
  }

  String _formatElapsed(int seconds) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  }

  Future<void> _refreshNotificationPermission() async {
    final granted = await _controlController.canPostNotifications();
    if (!mounted) return;
    setState(() => _notificationPermissionGranted = granted);
    _log.info('Notification permission check: ${granted ? 'granted' : 'missing'}.');
  }

  Future<void> _promptNotificationPermissionIfNeeded() async {
    final granted = await _controlController.canPostNotifications();
    if (!mounted) return;
    setState(() => _notificationPermissionGranted = granted);
    if (granted) return;

    final openPrompt = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Notification control'),
          content: const Text(
            'Enable notifications to control Run/Stop while the game is open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow'),
            ),
          ],
        );
      },
    );

    if (openPrompt == true) {
      await _controlController.requestNotificationPermission();
      await _refreshNotificationPermission();
    }
  }

  Future<void> _toggleNotificationControl() async {
    try {
      if (_notificationControlVisible) {
        await _controlController.stopControlNotification();
        if (!mounted) return;
        setState(() => _notificationControlVisible = false);
        return;
      }

      if (!await _controlController.canPostNotifications()) {
        await _controlController.requestNotificationPermission();
        await _refreshNotificationPermission();
      }

      await _controlController.startControlNotification();
      await _controlController.setControlRunning(_controller.isRunning.value);
      if (!mounted) return;
      setState(() => _notificationControlVisible = true);
    } catch (error) {
      _log.error('Notification control failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Notification control failed: ${formatUserError(error)}')),
      );
    }
  }

  void _handleControlEvent(Map<String, dynamic> event) {
    if (event['type'] != 'toggle') return;
    final shouldRun = event['running'] == true;
    _log.info('Notification control tapped: ${shouldRun ? 'Run' : 'Stop'}.');
    if (shouldRun) {
      _controller.start(amount: _amountController.text, stage: _stage);
      unawaited(_controlController.setControlRunning(_controller.isRunning.value));
    } else {
      _controller.stop();
      unawaited(_controlController.setControlRunning(false));
    }
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _BackHeader extends StatelessWidget {
  const _BackHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onBack,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.arrow_back_rounded, size: 16),
      label: const Text('Hub', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class _PrimaryAutomationCard extends StatelessWidget {
  const _PrimaryAutomationCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconTile(icon: Icons.layers_rounded, color: AppColors.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'NTE',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.8,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          "Owner's Selection",
                          style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const _StatusPill('Ready', active: true),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 18),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const _MiniMetric(label: 'LAST RUN', value: '--'),
                  const SizedBox(width: 24),
                  const _MiniMetric(label: 'RUNS TODAY', value: '0'),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.primaryDim,
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Open',
                      style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallActionCard extends StatelessWidget {
  const _SmallActionCard({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconTile(icon: icon, color: color, size: 38),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.color, this.size = 40});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.muted,
            fontFamily: 'monospace',
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'City Stamina',
            style: TextStyle(
              color: AppColors.muted,
              fontFamily: 'monospace',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
            ),
          ),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            cursorColor: AppColors.primary,
            style: const TextStyle(color: AppColors.text, fontSize: 28, fontWeight: FontWeight.w800),
            decoration: const InputDecoration(
              hintText: 'Amount',
              hintStyle: TextStyle(color: AppColors.dim, fontSize: 28, fontWeight: FontWeight.w800),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.only(top: 8, bottom: 2),
            ),
          ),
          const Text('stamina points to spend', style: TextStyle(color: AppColors.muted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _StageSelector extends StatelessWidget {
  const _StageSelector({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      color: AppColors.panel,
      padding: const EdgeInsets.all(6),
      child: Row(
        children: ['1-9', '1-1'].map((stage) {
          final selected = value == stage;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Material(
                color: selected ? AppColors.primaryDim : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () => onChanged(stage),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selected ? AppColors.primary.withValues(alpha: 0.22) : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'Stage $stage',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? AppColors.primary : AppColors.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.text, {this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? AppColors.primaryDim : Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: active ? AppColors.primary.withValues(alpha: 0.22) : Colors.transparent),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              color: active ? AppColors.primary : AppColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({
    required this.child,
    this.color = AppColors.surface,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

class _RunButton extends StatelessWidget {
  const _RunButton({required this.running, required this.onPressed});

  final bool running;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bg = running ? AppColors.dangerDim : AppColors.primaryDim;
    final fg = running ? AppColors.danger : AppColors.primary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: fg.withValues(alpha: 0.3), width: 1.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded, color: fg, size: 19),
              const SizedBox(width: 8),
              Text(
                running ? 'Stop' : 'Run',
                style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.sub, size: 17),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: const TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusNote extends StatelessWidget {
  const _StatusNote({required this.active, required this.text});

  final bool active;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: active ? AppColors.primary : AppColors.danger,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
      ],
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.muted,
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.3,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.text,
              fontFamily: 'monospace',
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            color: AppColors.muted,
            fontFamily: 'monospace',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: AppColors.border, height: 1)),
      ],
    );
  }
}

class _RunningPill extends StatelessWidget {
  const _RunningPill();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, color: AppColors.warning, size: 7),
        SizedBox(width: 5),
        Text(
          'Running',
          style: TextStyle(
            color: AppColors.warning,
            fontFamily: 'monospace',
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _LogSectionHeader extends StatelessWidget {
  const _LogSectionHeader({required this.runningListenable});

  final ValueListenable<bool> runningListenable;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Log',
          style: TextStyle(
            color: AppColors.muted,
            fontFamily: 'monospace',
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: AppColors.border, height: 1)),
        const SizedBox(width: 8),
        ValueListenableBuilder<bool>(
          valueListenable: runningListenable,
          builder: (context, running, _) => running ? const _RunningPill() : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _LogPreview extends StatelessWidget {
  const _LogPreview({required this.log});

  final MobileLogService log;

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: 120, child: _LogPanel(log: log));
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.log});

  final MobileLogService log;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      color: AppColors.log,
      padding: const EdgeInsets.all(12),
      child: ValueListenableBuilder<List<String>>(
        valueListenable: log.lines,
        builder: (context, lines, _) {
          final visible = lines.reversed.take(24).toList().reversed;
          return SingleChildScrollView(
            reverse: true,
            child: visible.isEmpty
                ? const Text(
                    'No log output yet.',
                    style: TextStyle(color: AppColors.dim, fontFamily: 'monospace', fontSize: 11),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: visible.map(_LogLineView.new).toList(),
                  ),
          );
        },
      ),
    );
  }
}

class _LogLineView extends StatelessWidget {
  const _LogLineView(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedLogLine.parse(line);
    final color = switch (parsed.level) {
      'INFO' => AppColors.sub,
      'WARN' => AppColors.warning,
      'ERROR' => AppColors.danger,
      _ => AppColors.primary,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 47,
            child: Text(
              parsed.time,
              style: const TextStyle(color: AppColors.dim, fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              parsed.shortLevel,
              style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              parsed.message,
              style: TextStyle(
                color: parsed.level == 'INFO' ? AppColors.sub : color,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParsedLogLine {
  const _ParsedLogLine({
    required this.time,
    required this.level,
    required this.message,
  });

  final String time;
  final String level;
  final String message;

  String get shortLevel => level == 'ERROR' ? 'ERR' : level == 'INFO' ? 'INFO' : level;

  static _ParsedLogLine parse(String line) {
    final time = line.length >= 19 ? line.substring(11, 19) : '--:--:--';
    final start = line.indexOf('[');
    final end = line.indexOf('] ');
    if (start >= 0 && end > start) {
      return _ParsedLogLine(
        time: time,
        level: line.substring(start + 1, end),
        message: line.substring(end + 2),
      );
    }
    return _ParsedLogLine(time: time, level: 'INFO', message: line);
  }
}
