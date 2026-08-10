import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      home: const OwnerSelectionPage(),
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
  static const version = '1.0.5';
  static const androidApkUrl =
      'https://github.com/PHai237/City-Stamina-Spender/releases/latest/download/City.Stamina.Mobile.apk';
}

class MobileLogService {
  MobileLogService._();

  static final MobileLogService instance = MobileLogService._();

  final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>([]);

  Future<void> init() async {
    if (lines.value.isEmpty) info('Mobile app started');
  }

  void info(String message) => _write('INFO', message);

  void warn(String message) => _write('WARN', message);

  void error(String message) => _write('ERROR', message);

  void _write(String level, String message) {
    final stamp = DateTime.now().toIso8601String();
    final line = '$stamp [$level] $message';
    final next = [...lines.value, line];
    lines.value = next.length > 24 ? next.sublist(next.length - 24) : next;
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
    await _channel.invokeMethod<void>('setControlRunning', {
      'running': running,
    });
  }

  Future<void> setControlAmount(String amount) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setControlAmount', {'amount': amount});
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
  String _stage = '1-1';
  bool _notificationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _controller = OwnerAutomationController(_log);
    _controlController = AndroidControlController(_log);
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
                        return _RunButton(
                          running: running,
                          onPressed: () => _toggleRun(running),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    _ActionRow(
                      icon: Icons.refresh_rounded,
                      title: 'Update',
                      onTap: () async => _openAndroidDownload(context),
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
