import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  static const version = '1.0.20';
  static const androidApkUrl =
      'https://github.com/PHai237/City-Stamina-Spender/releases/latest/download/City.Stamina.Mobile.apk';
}

class MobileLogService {
  MobileLogService._();

  static final MobileLogService instance = MobileLogService._();
  static const _maxLogBytes = 256 * 1024;
  static const _trimmedLogBytes = 128 * 1024;

  final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>([]);
  File? _logFile;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory(p.join(dir.path, 'logs'));
    await logDir.create(recursive: true);
    _logFile = File(p.join(logDir.path, 'mobile.log'));
    await _rotateIfNeeded();
    info('Mobile app started');
  }

  Future<String> readLogText() async {
    await init();
    final file = _logFile;
    if (file == null || !await file.exists()) return '';
    return file.readAsString();
  }

  void info(String message) => _write('INFO', message);

  void warn(String message) => _write('WARN', message);

  void error(String message) => _write('ERROR', message);

  void _write(String level, String message) {
    final stamp = DateTime.now().toIso8601String();
    final line = '$stamp [$level] $message';
    final next = [...lines.value, line];
    lines.value = next.length > 24 ? next.sublist(next.length - 24) : next;
    final file = _logFile;
    if (file != null) {
      unawaited(_appendToFile(file, line));
    }
  }

  Future<void> _appendToFile(File file, String line) async {
    try {
      await file.writeAsString('$line\n', mode: FileMode.append, flush: false);
      await _rotateIfNeeded();
    } catch (_) {
      // Logging must never interrupt the app.
    }
  }

  Future<void> _rotateIfNeeded() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return;
    final length = await file.length();
    if (length <= _maxLogBytes) return;

    final bytes = await file.readAsBytes();
    final keepStart = bytes.length > _trimmedLogBytes
        ? bytes.length - _trimmedLogBytes
        : 0;
    final kept = bytes.sublist(keepStart);
    await file.writeAsBytes([
      ...utf8.encode(
        '--- log trimmed at ${DateTime.now().toIso8601String()} ---\n',
      ),
      ...kept,
    ], flush: true);
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

class MobileDiagnosticsService {
  MobileDiagnosticsService(this.log);

  static const _channel = MethodChannel('city_stamina_mobile/control');
  final MobileLogService log;

  Future<Map<String, dynamic>> getDeviceInfo() async {
    if (!Platform.isAndroid) {
      return {'platform': Platform.operatingSystem, 'android': false};
    }
    log.info('Reading Android device info.');
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getDeviceInfo',
    );
    final info = Map<String, dynamic>.from(result ?? {});
    log.info(
      'Device info: ${info['manufacturer'] ?? ''} ${info['model'] ?? ''}, '
      '${info['screenWidth'] ?? '?'}x${info['screenHeight'] ?? '?'}, '
      'dpi=${info['densityDpi'] ?? '?'}.',
    );
    return info;
  }

  Future<bool> isAccessibilityEnabled() async {
    if (!Platform.isAndroid) return false;
    final enabled =
        await _channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    log.info('Accessibility permission: ${enabled ? 'enabled' : 'disabled'}.');
    return enabled;
  }

  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    log.info('Opening Accessibility settings.');
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<Map<String, dynamic>> captureScreen() async {
    if (!Platform.isAndroid) {
      throw StateError('Screen capture is Android-only.');
    }
    log.info('Requesting screen capture permission.');
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'captureScreen',
    );
    final capture = Map<String, dynamic>.from(result ?? {});
    log.info(
      'Screen captured: ${capture['width'] ?? '?'}x${capture['height'] ?? '?'} '
      'dpi=${capture['densityDpi'] ?? '?'}.',
    );
    return capture;
  }

  Future<void> checkScreenCapturePermission() async {
    File? screenshotFile;
    try {
      final capture = await captureScreen();
      final path = (capture['path'] ?? '').toString();
      if (path.isNotEmpty) screenshotFile = File(path);
      log.info('Screen capture permission check passed.');
    } finally {
      await _deleteIfExists(screenshotFile);
    }
  }

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

  Future<String> sendDiagnosticsToDiscord() async {
    await log.init();
    log.info('Diagnostics started.');
    final webhookUrl = await _readWebhookUrl();
    if (webhookUrl == null) {
      log.warn('Diagnostics stopped: Discord webhook is not configured.');
      throw StateError('Discord webhook is not configured.');
    }

    File? reportFile;
    File? screenshotFile;
    try {
      final deviceInfo = await getDeviceInfo();
      final accessibilityEnabled = await isAccessibilityEnabled();
      Map<String, dynamic>? capture;
      try {
        capture = await captureScreen();
        final path = (capture['path'] ?? '').toString();
        if (path.isNotEmpty) screenshotFile = File(path);
      } catch (error) {
        log.error('Screen capture failed: $error');
      }

      final tempDir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '_');
      reportFile = File(
        p.join(tempDir.path, 'city-stamina-mobile-diagnostics-$stamp.txt'),
      );
      final fileLogText = await log.readLogText();
      await reportFile.writeAsString(
        _buildReport(
          deviceInfo: deviceInfo,
          accessibilityEnabled: accessibilityEnabled,
          capture: capture,
          fileLogText: fileLogText,
        ),
        flush: true,
      );

      log.info('Uploading diagnostics to Discord.');
      await _sendFiles(webhookUrl, [
        reportFile,
        if (screenshotFile != null && await screenshotFile.exists())
          screenshotFile,
      ]);
      log.info('Diagnostics uploaded to Discord.');
      return 'Diagnostics sent.';
    } finally {
      await _deleteIfExists(reportFile);
      await _deleteIfExists(screenshotFile);
      log.info('Temporary diagnostics files deleted.');
    }
  }

  Future<String> sendLogToDiscord() async {
    await log.init();
    log.info('Text log upload started.');
    final webhookUrl = await _readWebhookUrl();
    if (webhookUrl == null) {
      log.warn('Log upload stopped: Discord webhook is not configured.');
      throw StateError('Discord webhook is not configured.');
    }

    File? reportFile;
    try {
      final deviceInfo = await getDeviceInfo();
      final accessibilityEnabled = await isAccessibilityEnabled();
      final fileLogText = await log.readLogText();
      final tempDir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '_');
      reportFile = File(
        p.join(tempDir.path, 'city-stamina-mobile-log-$stamp.txt'),
      );
      await reportFile.writeAsString(
        _buildReport(
          deviceInfo: deviceInfo,
          accessibilityEnabled: accessibilityEnabled,
          capture: null,
          fileLogText: fileLogText,
          title: 'City Stamina Mobile log report',
          screenCaptureText: 'Not requested by Send log.',
        ),
        flush: true,
      );

      log.info('Uploading text log to Discord.');
      await _sendFiles(webhookUrl, [reportFile]);
      log.info('Text log uploaded to Discord.');
      return 'Log sent.';
    } finally {
      await _deleteIfExists(reportFile);
      log.info('Temporary log file deleted.');
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
      log.warn('Created discord_webhook.txt. Add a webhook URL first.');
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
    while (normalized.isNotEmpty &&
        '>"\''.contains(normalized[normalized.length - 1])) {
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

  String _buildReport({
    required Map<String, dynamic> deviceInfo,
    required bool accessibilityEnabled,
    required Map<String, dynamic>? capture,
    required String fileLogText,
    String title = 'City Stamina Mobile diagnostics',
    String screenCaptureText = 'failed',
  }) {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('Mobile version: ${AppInfo.version}')
      ..writeln('Created: ${DateTime.now().toIso8601String()}')
      ..writeln(
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('Accessibility enabled: $accessibilityEnabled')
      ..writeln('')
      ..writeln('==== DEVICE ====')
      ..writeln(const JsonEncoder.withIndent('  ').convert(deviceInfo))
      ..writeln('')
      ..writeln('==== SCREEN CAPTURE ====')
      ..writeln(
        capture == null
            ? screenCaptureText
            : const JsonEncoder.withIndent('  ').convert(capture),
      )
      ..writeln('')
      ..writeln('==== SESSION LOG ====');

    for (final line in log.lines.value) {
      buffer.writeln(line);
    }
    buffer
      ..writeln('')
      ..writeln('==== FILE LOG ====')
      ..write(fileLogText.isEmpty ? 'empty\n' : fileLogText);
    return buffer.toString();
  }

  Future<void> _sendFiles(String webhookUrl, List<File> files) async {
    final request = http.MultipartRequest('POST', Uri.parse(webhookUrl));
    request.fields['payload_json'] = jsonEncode({
      'content':
          'City Stamina Mobile diagnostics | ${DateTime.now().toIso8601String()}',
    });
    for (var i = 0; i < files.length; i += 1) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'files[$i]',
          files[i].path,
          filename: p.basename(files[i].path),
        ),
      );
    }

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Discord upload failed: ${response.statusCode} $body',
      );
    }
  }

  Future<void> _deleteIfExists(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temporary diagnostics cleanup must not hide the useful upload result.
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
    await _channel.invokeMethod<void>('setControlRunning', {
      'running': running,
    });
  }

  Future<void> setControlAmount(String amount) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setControlAmount', {'amount': amount});
  }

  Future<void> setControlStatus(String status) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setControlStatus', {'status': status});
  }

  Future<bool> canDrawOverlays() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
  }

  Future<void> openOverlaySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openOverlaySettings');
    log.info('Opened floating control permission settings.');
  }

  Future<void> startFloatingControl() async {
    if (!Platform.isAndroid) {
      log.warn('Floating control is Android-only.');
      return;
    }
    await _channel.invokeMethod<void>('startFloating');
    log.info('Floating control started.');
  }

  Future<void> stopFloatingControl() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopFloating');
    log.info('Floating control stopped.');
  }
}

class AutomationHubPage extends StatefulWidget {
  const AutomationHubPage({super.key});

  @override
  State<AutomationHubPage> createState() => _AutomationHubPageState();
}

class _AutomationHubPageState extends State<AutomationHubPage> {
  final _log = MobileLogService.instance;
  late final AndroidControlController _controlController;
  late final MobileDiagnosticsService _diagnostics;

  @override
  void initState() {
    super.initState();
    _controlController = AndroidControlController(_log);
    _diagnostics = MobileDiagnosticsService(_log);
    unawaited(_log.init());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureNotificationControl());
    });
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
              const _AppHeader(
                title: 'Automation Hub',
                subtitle: 'Mobile ${AppInfo.version}',
              ),
              const SizedBox(height: 18),
              _HubAutomationCard(
                title: "Owner's Selection",
                subtitle: 'NTE - 1-1 / 1-9',
                status: 'Ready',
                icon: Icons.local_cafe_rounded,
                color: AppColors.primary,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const OwnerSelectionPage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _ActionRow(
                icon: Icons.refresh_rounded,
                title: 'Update',
                onTap: () async => _openAndroidDownload(context),
              ),
              const SizedBox(height: 10),
              _ActionRow(
                icon: Icons.send_rounded,
                title: 'Send log',
                onTap: () async => _sendDiagnostics(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAndroidDownload(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppUpdateService(_log).openAndroidDownload();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $error')));
    }
  }

  Future<void> _sendDiagnostics(BuildContext context) async {
    await sendMobileLog(context, _diagnostics);
  }

  Future<void> _ensureNotificationControl() async {
    if (!await _controlController.canPostNotifications()) {
      await _controlController.requestNotificationPermission();
    }
    await _controlController.startControlNotification();
  }
}

Future<void> sendMobileDiagnostics(
  BuildContext context,
  MobileDiagnosticsService diagnostics,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (!await diagnostics.hasWebhookConfigured()) {
      if (!context.mounted) return;
      final webhookUrl = await askWebhookUrl(context);
      if (!context.mounted) return;
      if (webhookUrl == null) {
        diagnostics.log.warn('Diagnostics canceled: no webhook entered.');
        return;
      }
      await diagnostics.saveWebhookUrl(webhookUrl);
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('Capturing diagnostics...')),
    );
    final message = await diagnostics.sendDiagnosticsToDiscord();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  } catch (error) {
    diagnostics.log.error('Diagnostics failed: $error');
    messenger.showSnackBar(
      SnackBar(content: Text('Diagnostics failed: ${formatUserError(error)}')),
    );
  }
}

Future<void> sendMobileLog(
  BuildContext context,
  MobileDiagnosticsService diagnostics,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (!await diagnostics.hasWebhookConfigured()) {
      if (!context.mounted) return;
      final webhookUrl = await askWebhookUrl(context);
      if (!context.mounted) return;
      if (webhookUrl == null) {
        diagnostics.log.warn('Send log canceled: no webhook entered.');
        return;
      }
      await diagnostics.saveWebhookUrl(webhookUrl);
    }

    messenger.showSnackBar(const SnackBar(content: Text('Sending log...')));
    final message = await diagnostics.sendLogToDiscord();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  } catch (error) {
    diagnostics.log.error('Send log failed: $error');
    messenger.showSnackBar(
      SnackBar(content: Text('Send log failed: ${formatUserError(error)}')),
    );
  }
}

String formatUserError(Object error) {
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  if (error is PlatformException) return error.message ?? error.code;
  return error
      .toString()
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
  late final MobileDiagnosticsService _diagnostics;
  final _amountController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _controlSubscription;
  String _stage = '1-1';
  bool _notificationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _controller = OwnerAutomationController(_log);
    _controlController = AndroidControlController(_log);
    _diagnostics = MobileDiagnosticsService(_log);
    _amountController.addListener(() {
      unawaited(_controlController.setControlAmount(_amountController.text));
    });
    unawaited(_refreshNotificationPermission());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureNotificationControl());
    });
    _controlSubscription = _controlController.events.listen(
      _handleControlEvent,
      onError: (error) {
        _log.warn('Notification control event stream stopped: $error');
      },
    );
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
                  _BackToHubButton(onTap: () => Navigator.of(context).pop()),
                  const SizedBox(height: 16),
                  const _AppHeader(
                    title: "Owner's Selection",
                    subtitle: 'NTE automation',
                  ),
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
                            if (!running && elapsed == 0) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _MetricStrip(
                                label: 'Elapsed',
                                value: _formatElapsed(elapsed),
                              ),
                            );
                          },
                        );
                      },
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _controller.isRunning,
                      builder: (context, running, _) {
                        return Row(
                          children: [
                            Expanded(
                              child: _RunButton(
                                running: running,
                                onPressed: () => _toggleRun(running),
                              ),
                            ),
                            const SizedBox(width: 10),
                            _CheckButton(
                              onPressed: running
                                  ? null
                                  : () => unawaited(_checkRunPermissions()),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    _ActionRow(
                      icon: Icons.refresh_rounded,
                      title: 'Update',
                      onTap: () async => _openAndroidDownload(context),
                    ),
                    const SizedBox(height: 10),
                    _ActionRow(
                      icon: Icons.touch_app_rounded,
                      title: 'Accessibility',
                      onTap: _openAccessibilitySettings,
                    ),
                    const SizedBox(height: 10),
                    _ActionRow(
                      icon: Icons.picture_in_picture_alt_rounded,
                      title: 'Floating',
                      onTap: _openFloatingControl,
                    ),
                    const SizedBox(height: 10),
                    _ActionRow(
                      icon: Icons.send_rounded,
                      title: 'Send log',
                      onTap: () async => sendMobileLog(context, _diagnostics),
                    ),
                    const SizedBox(height: 12),
                    _StatusNote(
                      active: _notificationPermissionGranted,
                      text: _notificationPermissionGranted
                          ? 'Notification control is on'
                          : 'Notification permission is needed',
                    ),
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

    _controller.start(amount: _amountController.text, stage: _stage);
    unawaited(
      _controlController.setControlRunning(_controller.isRunning.value),
    );
  }

  Future<bool> _checkRunPermissions() async {
    final messenger = ScaffoldMessenger.of(context);
    _log.info('Manual permission check started.');

    try {
      if (!await _controlController.canPostNotifications()) {
        _log.warn('Notification permission is missing. Requesting permission.');
        await _controlController.requestNotificationPermission();
        await _refreshNotificationPermission();
      } else {
        _log.info('Notification permission is ready.');
      }

      final accessibilityReady = await _diagnostics.isAccessibilityEnabled();
      if (!accessibilityReady) {
        if (!mounted) return false;
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Accessibility required'),
              content: const Text(
                'Android needs this permission before the app can tap or read the active game screen.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Later'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Open settings'),
                ),
              ],
            );
          },
        );

        if (openSettings == true) {
          await _diagnostics.openAccessibilitySettings();
          _log.warn(
            'Run paused: enable Accessibility, then return and press Run again.',
          );
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Enable Accessibility, then return and press Run again.',
              ),
            ),
          );
        } else {
          _log.warn('Run canceled: Accessibility permission is missing.');
        }
        return false;
      }

      messenger.showSnackBar(
        const SnackBar(content: Text('Checking screen capture...')),
      );
      await _diagnostics.checkScreenCapturePermission();

      _log.info('Manual permission check passed.');
      messenger.showSnackBar(
        const SnackBar(content: Text('Permissions are ready.')),
      );
      return true;
    } catch (error) {
      _log.error('Manual permission check failed: $error');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Permission check failed: ${formatUserError(error)}'),
        ),
      );
      return false;
    }
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
    _log.info(
      'Notification permission check: ${granted ? 'granted' : 'missing'}.',
    );
  }

  Future<void> _ensureNotificationControl() async {
    final granted = await _controlController.canPostNotifications();
    if (!mounted) return;
    setState(() => _notificationPermissionGranted = granted);

    if (!granted) {
      await _controlController.requestNotificationPermission();
      await _refreshNotificationPermission();
    }

    await _controlController.setControlAmount(_amountController.text);
    await _controlController.startControlNotification();
    await _controlController.setControlRunning(_controller.isRunning.value);
    if (!mounted) return;
  }

  Future<void> _openAndroidDownload(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AppUpdateService(_log).openAndroidDownload();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $error')));
    }
  }

  Future<void> _openAccessibilitySettings() async {
    await _diagnostics.openAccessibilitySettings();
  }

  Future<void> _openFloatingControl() async {
    final messenger = ScaffoldMessenger.of(context);
    final canDraw = await _controlController.canDrawOverlays();
    _log.info('Floating permission check: ${canDraw ? 'granted' : 'missing'}.');
    if (!canDraw) {
      await _controlController.openOverlaySettings();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Enable floating permission, then tap Floating again.'),
        ),
      );
      return;
    }

    await _controlController.setControlAmount(_amountController.text);
    await _controlController.setControlRunning(_controller.isRunning.value);
    await _controlController.startFloatingControl();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Floating control is on.')),
    );
  }

  void _handleControlEvent(Map<String, dynamic> event) {
    if (event['type'] == 'amount') {
      final amount = (event['amount'] ?? '').toString();
      if (_amountController.text != amount) {
        _amountController.text = amount;
        _amountController.selection = TextSelection.collapsed(
          offset: amount.length,
        );
      }
      return;
    }

    if (event['type'] == 'check') {
      _log.info('Notification control tapped: Check.');
      unawaited(_checkGameFromNotification());
      return;
    }

    if (event['type'] != 'toggle') return;
    final shouldRun = event['running'] == true;
    _log.info('Notification control tapped: ${shouldRun ? 'Run' : 'Stop'}.');
    if (shouldRun) {
      _controller.start(amount: _amountController.text, stage: _stage);
      unawaited(
        _controlController.setControlRunning(_controller.isRunning.value),
      );
    } else {
      _controller.stop();
      unawaited(_controlController.setControlRunning(false));
    }
  }

  Future<void> _checkGameFromNotification() async {
    try {
      final info = await _diagnostics.getDeviceInfo();
      final activePackage = (info['activePackage'] ?? '').toString();
      final accessibilityReady = info['accessibilityEnabled'] == true;

      if (!accessibilityReady) {
        _log.warn('Notification check: Accessibility is disabled.');
        await _controlController.setControlStatus('Accessibility missing');
        return;
      }

      if (activePackage.isEmpty) {
        _log.warn('Notification check: active app is unknown.');
        await _controlController.setControlStatus('Game unknown');
        return;
      }

      if (activePackage == 'com.example.city_stamina_mobile') {
        _log.warn('Notification check: City Stamina app is active, not NTE.');
        await _controlController.setControlStatus('Open NTE first');
        return;
      }

      _log.info('Notification check: active app package=$activePackage.');
      await _controlController.setControlStatus('Active: $activePackage');
    } catch (error) {
      _log.error('Notification check failed: $error');
      await _controlController.setControlStatus('Check failed');
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
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _BackToHubButton extends StatelessWidget {
  const _BackToHubButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_back_rounded,
                  color: AppColors.primary,
                  size: 17,
                ),
                SizedBox(width: 7),
                Text(
                  'Hub',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HubAutomationCard extends StatelessWidget {
  const _HubAutomationCard({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String status;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.primaryDim,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.muted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
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
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
            decoration: const InputDecoration(
              hintText: 'Amount',
              hintStyle: TextStyle(
                color: AppColors.dim,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.only(top: 8, bottom: 2),
            ),
          ),
          const Text(
            'stamina points to spend',
            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
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
        children: ['1-1', '1-9'].map((stage) {
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
                        color: selected
                            ? AppColors.primary.withValues(alpha: 0.22)
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      stage,
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
              Icon(
                running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                color: fg,
                size: 19,
              ),
              const SizedBox(width: 8),
              Text(
                running ? 'Stop' : 'Run',
                style: TextStyle(
                  color: fg,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckButton extends StatelessWidget {
  const _CheckButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final fg = disabled ? AppColors.muted : AppColors.blue;
    return Material(
      color: disabled ? AppColors.panel : AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: fg.withValues(alpha: 0.28), width: 1.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fact_check_rounded, color: fg, size: 18),
                const SizedBox(width: 7),
                Text(
                  'Check',
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

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
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.muted,
                size: 18,
              ),
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
        Text(
          text,
          style: const TextStyle(color: AppColors.muted, fontSize: 11),
        ),
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
