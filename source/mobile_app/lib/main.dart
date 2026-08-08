import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
          surface: AppColors.panel,
          error: AppColors.danger,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const AutomationHubPage(),
    );
  }
}

class AppColors {
  static const background = Color(0xFF07111F);
  static const panel = Color(0xFF101C31);
  static const card = Color(0xFF172642);
  static const cardAlt = Color(0xFF0D1728);
  static const primary = Color(0xFF36D6A7);
  static const blue = Color(0xFF4B91FF);
  static const danger = Color(0xFFFF6969);
  static const text = Color(0xFFF7FAFF);
  static const muted = Color(0xFFA7B5D1);
  static const border = Color(0xFF2B3A58);
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
    final value = webhookUrl.trim();
    if (!_isDiscordWebhook(value)) {
      throw StateError('Invalid Discord webhook URL.');
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
    if (_isDiscordWebhook(envWebhook)) return envWebhook;

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
      final value = line.trim();
      if (_isDiscordWebhook(value)) return value;
    }
    return null;
  }

  bool _isDiscordWebhook(String value) {
    return value.startsWith('https://discord.com/api/webhooks/') ||
        value.startsWith('https://discordapp.com/api/webhooks/');
  }

  Future<String> _buildReport() async {
    final buffer = StringBuffer()
      ..writeln('City Stamina Mobile debug report')
      ..writeln('Version: 1.0.0')
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

class OwnerAutomationController {
  OwnerAutomationController(this.log);

  final MobileLogService log;
  final ValueNotifier<bool> isRunning = ValueNotifier(false);
  Timer? _timer;
  int _seconds = 0;

  void start({required String amount, required String stage}) {
    if (isRunning.value) return;
    final parsed = int.tryParse(amount.trim());
    if (parsed == null || parsed <= 0) {
      log.warn('Enter a valid City Stamina amount.');
      return;
    }

    _seconds = 0;
    isRunning.value = true;
    log.info('Run started. stage=$stage target=$parsed');
    log.info('Overlay controller is not wired yet.');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _seconds += 1;
      if (_seconds % 10 == 0) {
        log.info('Still running. elapsed=${_seconds}s');
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
  }
}

class AndroidOverlayController {
  AndroidOverlayController(this.log);

  static const _channel = MethodChannel('city_stamina_mobile/overlay');
  final MobileLogService log;

  Future<bool> canDrawOverlays() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
  }

  Future<void> openOverlaySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openOverlaySettings');
    log.info('Opened Android overlay permission settings.');
  }

  Future<void> startOverlay() async {
    if (!Platform.isAndroid) {
      log.warn('Floating button is Android-only.');
      return;
    }
    await _channel.invokeMethod<void>('startOverlay');
    log.info('Floating button started.');
  }

  Future<void> stopOverlay() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopOverlay');
    log.info('Floating button stopped.');
  }

  Future<void> setRunning(bool running) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setRunning', {'running': running});
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 420;
            return Padding(
              padding: EdgeInsets.all(compact ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _AppHeader(title: 'Automation Hub', subtitle: 'Mobile 1.0.0'),
                  const SizedBox(height: 18),
                  _AutomationCard(
                    title: 'NTE',
                    subtitle: "Owner's Selection",
                    status: 'Ready',
                    icon: Icons.bolt_rounded,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const OwnerSelectionPage()),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  _AutomationCard(
                    title: 'Debug',
                    subtitle: 'Send mobile logs to Discord',
                    status: 'Tool',
                    icon: Icons.bug_report_rounded,
                    onTap: () async {
                      await _sendDebugPackage(context);
                    },
                  ),
                  const Spacer(),
                  _LogPreview(log: _log),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _sendDebugPackage(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final debugService = DebugPackageService(_log);
    try {
      if (!await debugService.hasWebhookConfigured()) {
        if (!context.mounted) return;
        final webhookUrl = await _askWebhookUrl(context);
        if (!context.mounted) return;
        if (webhookUrl == null) {
          _log.warn('Debug upload canceled because webhook is not configured.');
          return;
        }
        await debugService.saveWebhookUrl(webhookUrl);
      }
      _log.info('Sending mobile debug package...');
      final message = await debugService.exportToDiscord();
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Debug failed: $error')));
    }
  }

  Future<String?> _askWebhookUrl(BuildContext context) async {
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
}

class OwnerSelectionPage extends StatefulWidget {
  const OwnerSelectionPage({super.key});

  @override
  State<OwnerSelectionPage> createState() => _OwnerSelectionPageState();
}

class _OwnerSelectionPageState extends State<OwnerSelectionPage> {
  final _log = MobileLogService.instance;
  late final OwnerAutomationController _controller;
  late final AndroidOverlayController _overlayController;
  final _amountController = TextEditingController();
  String _stage = '1-9';
  bool _overlayVisible = false;
  bool _overlayPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _controller = OwnerAutomationController(_log);
    _overlayController = AndroidOverlayController(_log);
    unawaited(_refreshOverlayPermission());
  }

  @override
  void dispose() {
    _controller.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BackHeader(onBack: () => Navigator.of(context).pop()),
              const SizedBox(height: 14),
              const _AppHeader(title: "Owner's Selection", subtitle: 'NTE automation'),
              const SizedBox(height: 18),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _amountController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                      decoration: const InputDecoration(
                        labelText: 'City Stamina',
                        hintText: 'Amount',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: '1-9', label: Text('1-9')),
                        ButtonSegment(value: '1-1', label: Text('1-1')),
                      ],
                      selected: {_stage},
                      onSelectionChanged: (value) => setState(() => _stage = value.first),
                    ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<bool>(
                      valueListenable: _controller.isRunning,
                      builder: (context, running, _) {
                        return FilledButton.icon(
                          onPressed: () {
                            if (running) {
                              _controller.stop();
                              unawaited(_overlayController.setRunning(false));
                            } else {
                              _controller.start(
                                amount: _amountController.text,
                                stage: _stage,
                              );
                              unawaited(_overlayController.setRunning(true));
                            }
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: running ? AppColors.danger : AppColors.primary,
                            foregroundColor: running ? Colors.white : Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          icon: Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                          label: Text(running ? 'Stop' : 'Run'),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _toggleOverlay,
                      icon: Icon(_overlayVisible ? Icons.visibility_off_rounded : Icons.open_in_new_rounded),
                      label: Text(_overlayVisible ? 'Hide floating button' : 'Show floating button'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _overlayPermissionGranted
                          ? 'Floating permission is ready.'
                          : 'Floating permission is needed on Android.',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _LogPanel(log: _log)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshOverlayPermission() async {
    final granted = await _overlayController.canDrawOverlays();
    if (!mounted) return;
    setState(() => _overlayPermissionGranted = granted);
  }

  Future<void> _toggleOverlay() async {
    try {
      if (_overlayVisible) {
        await _overlayController.stopOverlay();
        if (!mounted) return;
        setState(() => _overlayVisible = false);
        return;
      }

      final granted = await _overlayController.canDrawOverlays();
      if (!granted) {
        await _overlayController.openOverlaySettings();
        if (!mounted) return;
        setState(() => _overlayPermissionGranted = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enable Draw over other apps, then return here.')),
        );
        return;
      }

      await _overlayController.startOverlay();
      await _overlayController.setRunning(_controller.isRunning.value);
      if (!mounted) return;
      setState(() {
        _overlayPermissionGranted = true;
        _overlayVisible = true;
      });
    } catch (error) {
      _log.error('Floating button failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Floating button failed: $error')),
      );
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
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 0),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(color: AppColors.blue, fontSize: 15, fontWeight: FontWeight.w700),
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
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: onBack,
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text('Hub'),
      ),
    );
  }
}

class _AutomationCard extends StatelessWidget {
  const _AutomationCard({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String status;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.blue.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppColors.text),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: AppColors.muted)),
                  ],
                ),
              ),
              _StatusPill(status),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
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
    return _Panel(
      child: ValueListenableBuilder<List<String>>(
        valueListenable: log.lines,
        builder: (context, lines, _) {
          final visible = lines.reversed.take(24).toList().reversed;
          return SingleChildScrollView(
            reverse: true,
            child: Text(
              visible.map(_formatLine).join('\n'),
              style: const TextStyle(
                color: AppColors.text,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatLine(String line) {
    final marker = line.indexOf('] ');
    return marker >= 0 ? line.substring(marker + 2) : line;
  }
}
