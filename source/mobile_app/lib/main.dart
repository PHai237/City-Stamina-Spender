import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
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
  static const version = '1.0.31';
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
      'dpi=${info['densityDpi'] ?? '?'}, '
      'active=${info['activePackage'] ?? '?'}, '
      'raw=${info['rawActivePackage'] ?? '?'}, '
      'useful=${info['lastUsefulPackage'] ?? '?'}.',
    );
    return info;
  }

  Future<String> readNativeDebugLog() async {
    if (!Platform.isAndroid) return '';
    return await _channel.invokeMethod<String>('getNativeDebugLog') ?? '';
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
    File? bundleFile;
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
      final nativeLogText = await readNativeDebugLog();
      final stageDebugFiles = await _recentStageDebugFiles();
      await reportFile.writeAsString(
        _buildReport(
          deviceInfo: deviceInfo,
          accessibilityEnabled: accessibilityEnabled,
          capture: capture,
          fileLogText: fileLogText,
          nativeLogText: nativeLogText,
          stageDebugFiles: stageDebugFiles,
        ),
        flush: true,
      );
      bundleFile = await _buildDebugZip(
        baseName: 'city-stamina-mobile-diagnostics-$stamp',
        reportFile: reportFile,
        screenshotFile: screenshotFile,
        stageDebugFiles: stageDebugFiles,
      );

      log.info('Uploading diagnostics to Discord.');
      await _sendFiles(webhookUrl, [bundleFile]);
      log.info('Diagnostics uploaded to Discord.');
      return 'Diagnostics sent.';
    } finally {
      await _deleteIfExists(reportFile);
      await _deleteIfExists(screenshotFile);
      await _deleteIfExists(bundleFile);
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
    File? bundleFile;
    try {
      final deviceInfo = await getDeviceInfo();
      final accessibilityEnabled = await isAccessibilityEnabled();
      final fileLogText = await log.readLogText();
      final nativeLogText = await readNativeDebugLog();
      final stageDebugFiles = await _recentStageDebugFiles();
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
          nativeLogText: nativeLogText,
          stageDebugFiles: stageDebugFiles,
          title: 'City Stamina Mobile log report',
          screenCaptureText: 'Not requested by Send log.',
        ),
        flush: true,
      );
      bundleFile = await _buildDebugZip(
        baseName: 'city-stamina-mobile-log-$stamp',
        reportFile: reportFile,
        screenshotFile: null,
        stageDebugFiles: stageDebugFiles,
      );

      log.info('Uploading text log to Discord.');
      await _sendFiles(webhookUrl, [bundleFile]);
      log.info('Text log uploaded to Discord.');
      return 'Log sent.';
    } finally {
      await _deleteIfExists(reportFile);
      await _deleteIfExists(bundleFile);
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
    required String nativeLogText,
    List<File> stageDebugFiles = const [],
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
      ..writeln('==== STAGE DEBUG FILES ====');

    if (stageDebugFiles.isEmpty) {
      buffer.writeln('none');
    } else {
      for (final file in stageDebugFiles) {
        buffer.writeln('${p.basename(file.path)} (${file.lengthSync()} bytes)');
      }
    }

    buffer
      ..writeln('')
      ..writeln('==== SESSION LOG ====');

    for (final line in log.lines.value) {
      buffer.writeln(line);
    }
    buffer
      ..writeln('')
      ..writeln('==== FILE LOG ====')
      ..write(fileLogText.isEmpty ? 'empty\n' : fileLogText)
      ..writeln('')
      ..writeln('==== NATIVE LOG ====')
      ..write(nativeLogText.isEmpty ? 'empty\n' : nativeLogText);
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

  Future<File> _buildDebugZip({
    required String baseName,
    required File reportFile,
    required File? screenshotFile,
    required List<File> stageDebugFiles,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final zipFile = File(p.join(tempDir.path, '$baseName.zip'));
    final encoder = ZipFileEncoder()..create(zipFile.path);
    try {
      await _addFileToZip(
        encoder,
        reportFile,
        'report/${p.basename(reportFile.path)}',
      );
      if (screenshotFile != null && await screenshotFile.exists()) {
        await _addFileToZip(
          encoder,
          screenshotFile,
          'capture/${p.basename(screenshotFile.path)}',
        );
      }
      for (final file in stageDebugFiles) {
        if (await file.exists()) {
          await _addFileToZip(
            encoder,
            file,
            'stage_debug/${p.basename(file.path)}',
          );
        }
      }
    } finally {
      encoder.close();
    }
    log.info('Debug zip created: ${p.basename(zipFile.path)}.');
    return zipFile;
  }

  Future<void> _addFileToZip(
    ZipFileEncoder encoder,
    File file,
    String archivePath,
  ) async {
    encoder.addArchiveFile(
      ArchiveFile(archivePath, await file.length(), await file.readAsBytes()),
    );
  }

  Future<List<File>> _recentStageDebugFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final debugDir = Directory(p.join(dir.path, 'stage_debug'));
    if (!await debugDir.exists()) return [];

    final files = <File>[];
    await for (final entity in debugDir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('latest_stage_') ||
          name == 'latest_stage_report.txt') {
        files.add(entity);
      }
    }
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
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

class StageCheckResult {
  const StageCheckResult({
    required this.matched,
    required this.score,
    required this.threshold,
    this.x,
    this.y,
  });

  final bool matched;
  final double score;
  final double threshold;
  final int? x;
  final int? y;
}

class MobileStageDetector {
  MobileStageDetector(this.log);

  static const _stageOneOneTitleAsset =
      'assets/stage_1_1/stage_1_1_selected_title_strict.png';
  static const _threshold = 0.62;

  final MobileLogService log;

  Future<StageCheckResult> detectSelectedStageOneOne(
    File screenshotFile,
  ) async {
    final screenshotBytes = await screenshotFile.readAsBytes();
    final screenshot = img.decodeImage(screenshotBytes);
    if (screenshot == null) {
      throw StateError('Could not decode screenshot.');
    }

    final templateBytes = await rootBundle.load(_stageOneOneTitleAsset);
    final template = img.decodeImage(templateBytes.buffer.asUint8List());
    if (template == null) {
      throw StateError('Could not decode stage template.');
    }

    final titleRegion = _cropTitleRegion(screenshot);
    final normalizedTitle = img.grayscale(
      img.copyResize(
        titleRegion,
        width: 760,
        height: 80,
        interpolation: img.Interpolation.average,
      ),
    );
    final normalizedTemplate = img.grayscale(template);
    final match = _bestMatch(normalizedTitle, normalizedTemplate);
    await _writeDebugArtifacts(
      screenshotFile: screenshotFile,
      screenshot: screenshot,
      titleRegion: titleRegion,
      normalizedTitle: normalizedTitle,
      normalizedTemplate: normalizedTemplate,
      match: match,
    );
    log.info(
      'Stage 1-1 title score=${match.score.toStringAsFixed(3)} '
      'at x=${match.x} y=${match.y}.',
    );
    return StageCheckResult(
      matched: match.score >= _threshold,
      score: match.score,
      threshold: _threshold,
      x: match.x,
      y: match.y,
    );
  }

  Future<void> _writeDebugArtifacts({
    required File screenshotFile,
    required img.Image screenshot,
    required img.Image titleRegion,
    required img.Image normalizedTitle,
    required img.Image normalizedTemplate,
    required _TemplateMatch match,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final debugDir = Directory(p.join(dir.path, 'stage_debug'));
      await debugDir.create(recursive: true);
      await _clearStageDebugDir(debugDir);

      await screenshotFile.copy(
        p.join(debugDir.path, 'latest_stage_screen.png'),
      );
      await File(
        p.join(debugDir.path, 'latest_stage_title_crop.png'),
      ).writeAsBytes(img.encodePng(titleRegion), flush: true);
      await File(
        p.join(debugDir.path, 'latest_stage_title_normalized.png'),
      ).writeAsBytes(img.encodePng(normalizedTitle), flush: true);
      await File(
        p.join(debugDir.path, 'latest_stage_template.png'),
      ).writeAsBytes(img.encodePng(normalizedTemplate), flush: true);
      await File(
        p.join(debugDir.path, 'latest_stage_report.txt'),
      ).writeAsString(
        [
          'Stage 1-1 detector debug',
          'Created: ${DateTime.now().toIso8601String()}',
          'Screenshot: ${screenshot.width}x${screenshot.height}',
          'Title crop: ${titleRegion.width}x${titleRegion.height}',
          'Normalized title: ${normalizedTitle.width}x${normalizedTitle.height}',
          'Template: ${normalizedTemplate.width}x${normalizedTemplate.height}',
          'Score: ${match.score.toStringAsFixed(4)}',
          'Threshold: ${_threshold.toStringAsFixed(4)}',
          'Matched: ${match.score >= _threshold}',
          'Best x: ${match.x}',
          'Best y: ${match.y}',
        ].join('\n'),
        flush: true,
      );
      log.info('Stage debug artifacts saved.');
    } catch (error) {
      log.warn('Could not save stage debug artifacts: $error');
    }
  }

  Future<void> _clearStageDebugDir(Directory debugDir) async {
    await for (final entity in debugDir.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {
          // A stale debug file should not interrupt stage detection.
        }
      }
    }
  }

  img.Image _cropTitleRegion(img.Image image) {
    final width = image.width;
    final height = image.height;
    final left = (width * 245 / 1280).round().clamp(0, width - 1);
    final top = (height * 80 / 720).round().clamp(0, height - 1);
    final right = (width * 1005 / 1280).round().clamp(left + 1, width);
    final bottom = (height * 160 / 720).round().clamp(top + 1, height);
    return img.copyCrop(
      image,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  _TemplateMatch _bestMatch(img.Image image, img.Image template) {
    if (template.width > image.width || template.height > image.height) {
      return const _TemplateMatch(score: -1, x: 0, y: 0);
    }

    final templateValues = _grayValues(template);
    final templateMean =
        templateValues.reduce((a, b) => a + b) / templateValues.length;
    var templateVariance = 0.0;
    final centeredTemplate = List<double>.filled(templateValues.length, 0);
    for (var i = 0; i < templateValues.length; i += 1) {
      final centered = templateValues[i] - templateMean;
      centeredTemplate[i] = centered;
      templateVariance += centered * centered;
    }
    final templateStd = templateVariance == 0 ? 1.0 : templateVariance;

    var best = const _TemplateMatch(score: -1, x: 0, y: 0);
    final maxX = image.width - template.width;
    final maxY = image.height - template.height;
    for (var y = 0; y <= maxY; y += 1) {
      for (var x = 0; x <= maxX; x += 1) {
        final score = _scoreAt(
          image,
          template.width,
          template.height,
          centeredTemplate,
          templateMean,
          templateStd,
          x,
          y,
        );
        if (score > best.score) {
          best = _TemplateMatch(score: score, x: x, y: y);
        }
      }
    }
    return best;
  }

  List<double> _grayValues(img.Image image) {
    final values = List<double>.filled(image.width * image.height, 0);
    var index = 0;
    for (var y = 0; y < image.height; y += 1) {
      for (var x = 0; x < image.width; x += 1) {
        values[index] = image.getPixel(x, y).r.toDouble();
        index += 1;
      }
    }
    return values;
  }

  double _scoreAt(
    img.Image image,
    int templateWidth,
    int templateHeight,
    List<double> centeredTemplate,
    double templateMean,
    double templateStd,
    int startX,
    int startY,
  ) {
    var patchSum = 0.0;
    for (var y = 0; y < templateHeight; y += 1) {
      for (var x = 0; x < templateWidth; x += 1) {
        patchSum += image.getPixel(startX + x, startY + y).r.toDouble();
      }
    }
    final patchMean = patchSum / centeredTemplate.length;
    var numerator = 0.0;
    var patchVariance = 0.0;
    var index = 0;
    for (var y = 0; y < templateHeight; y += 1) {
      for (var x = 0; x < templateWidth; x += 1) {
        final patch = image.getPixel(startX + x, startY + y).r.toDouble();
        final centeredPatch = patch - patchMean;
        numerator += centeredPatch * centeredTemplate[index];
        patchVariance += centeredPatch * centeredPatch;
        index += 1;
      }
    }
    if (patchVariance == 0) return -1;
    return numerator / sqrt(patchVariance * templateStd);
  }
}

class _TemplateMatch {
  const _TemplateMatch({required this.score, required this.x, required this.y});

  final double score;
  final int x;
  final int y;
}

class OwnerAutomationController {
  OwnerAutomationController(this.log, this.diagnostics, this.control);

  final MobileLogService log;
  final MobileDiagnosticsService diagnostics;
  final AndroidControlController control;
  final ValueNotifier<bool> isRunning = ValueNotifier(false);
  final ValueNotifier<int> elapsedSeconds = ValueNotifier(0);
  Timer? _timer;

  Future<void> start({required String amount, required String stage}) async {
    if (isRunning.value) return;
    final parsed = int.tryParse(amount.trim());
    if (parsed == null || parsed <= 0) {
      log.warn('Enter a valid City Stamina amount.');
      await control.setControlStatus('Bad amount');
      return;
    }

    log.info('Run started. stage=$stage target=$parsed');
    await control.setControlStatus('Checking stage');

    if (stage != '1-1') {
      log.warn('Mobile runner currently supports the 1-1 screen check only.');
      await control.setControlStatus('1-1 only');
      return;
    }

    final StageCheckResult stageCheck;
    try {
      stageCheck = await _ensureStageOneOneSelected();
    } catch (error) {
      log.error('Stage 1-1 check failed: $error');
      await control.setControlStatus('Check failed');
      return;
    }
    if (!stageCheck.matched) {
      log.warn(
        'Stage 1-1 check failed. score=${stageCheck.score.toStringAsFixed(3)} '
        'threshold=${stageCheck.threshold.toStringAsFixed(3)}',
      );
      await control.setControlStatus('Find 1-1');
      return;
    }

    log.info(
      'Stage 1-1 verified. score=${stageCheck.score.toStringAsFixed(3)} '
      'at x=${stageCheck.x} y=${stageCheck.y}',
    );
    await control.setControlStatus('Stage 1-1');

    elapsedSeconds.value = 0;
    isRunning.value = true;
    log.info('Mobile automation runner paused after stage verification.');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedSeconds.value += 1;
      if (elapsedSeconds.value % 10 == 0) {
        log.info('Still running. elapsed=${elapsedSeconds.value}s');
      }
    });
  }

  Future<void> checkStageOneOne() async {
    log.info('Manual stage 1-1 check started.');
    await control.setControlStatus('Checking stage');
    try {
      final stageCheck = await _ensureStageOneOneSelected();
      if (!stageCheck.matched) {
        log.warn(
          'Manual stage 1-1 check failed. '
          'score=${stageCheck.score.toStringAsFixed(3)} '
          'threshold=${stageCheck.threshold.toStringAsFixed(3)}',
        );
        await control.setControlStatus('Find 1-1');
        return;
      }

      log.info(
        'Manual stage 1-1 check passed. '
        'score=${stageCheck.score.toStringAsFixed(3)}',
      );
      await control.setControlStatus('Stage 1-1');
    } catch (error) {
      log.error('Manual stage 1-1 check failed: $error');
      await control.setControlStatus('Check failed');
    }
  }

  Future<StageCheckResult> _verifyStageOneOne() async {
    File? screenshotFile;
    try {
      final capture = await diagnostics.captureScreen();
      final path = (capture['path'] ?? '').toString();
      if (path.isEmpty) {
        throw StateError('Screen capture returned no file path.');
      }
      screenshotFile = File(path);
      return MobileStageDetector(log).detectSelectedStageOneOne(screenshotFile);
    } finally {
      try {
        if (screenshotFile != null && await screenshotFile.exists()) {
          await screenshotFile.delete();
        }
      } catch (_) {
        // Run cleanup should not hide the stage-check result.
      }
    }
  }

  Future<StageCheckResult> _ensureStageOneOneSelected() async {
    var best = await _verifyStageOneOne();
    if (best.matched) return best;

    for (var attempt = 1; attempt <= 3; attempt += 1) {
      log.info(
        'Stage 1-1 not selected yet. '
        'score=${best.score.toStringAsFixed(3)}. '
        'Scrolling toward 1-1 attempt=$attempt.',
      );
      await control.setControlStatus('Scroll 1-1');
      await control.swipeScreenByRatio(
        startX: 0.12,
        startY: 0.28,
        endX: 0.12,
        endY: 0.72,
        durationMs: 420,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      best = await _verifyStageOneOne();
      if (best.matched) return best;
    }

    return best;
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

  Future<bool> tapScreen(double x, double y) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('tapScreen', {'x': x, 'y': y}) ??
        false;
  }

  Future<bool> swipeScreen(
    double startX,
    double startY,
    double endX,
    double endY, {
    int durationMs = 360,
  }) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('swipeScreen', {
          'startX': startX,
          'startY': startY,
          'endX': endX,
          'endY': endY,
          'durationMs': durationMs,
        }) ??
        false;
  }

  Future<bool> swipeScreenByRatio({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    int durationMs = 360,
  }) async {
    final info = await MobileDiagnosticsService(log).getDeviceInfo();
    final width = (info['screenWidth'] as num?)?.toDouble() ?? 0;
    final height = (info['screenHeight'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) {
      throw StateError('Could not read screen size for swipe.');
    }
    return swipeScreen(
      width * startX,
      height * startY,
      width * endX,
      height * endY,
      durationMs: durationMs,
    );
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
                subtitle: 'NTE - 1-1',
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
    _controlController = AndroidControlController(_log);
    _diagnostics = MobileDiagnosticsService(_log);
    _controller = OwnerAutomationController(
      _log,
      _diagnostics,
      _controlController,
    );
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
                      icon: Icons.refresh_rounded,
                      title: 'Update',
                      onTap: () async => _openAndroidDownload(context),
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

    unawaited(_startOwnerAutomation());
  }

  Future<void> _startOwnerAutomation() async {
    await _controller.start(amount: _amountController.text, stage: _stage);
    await _controlController.setControlRunning(_controller.isRunning.value);
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

    if (event['type'] == 'check' || event['type'] == 'game_check') {
      _log.info('Floating control tapped: Game.');
      unawaited(_checkGameFromNotification());
      return;
    }

    if (event['type'] == 'stage_check') {
      _log.info('Floating control tapped: Stage.');
      unawaited(_controller.checkStageOneOne());
      return;
    }

    if (event['type'] != 'toggle') return;
    final shouldRun = event['running'] == true;
    _log.info('Notification control tapped: ${shouldRun ? 'Run' : 'Stop'}.');
    if (shouldRun) {
      unawaited(
        _controller
            .start(amount: _amountController.text, stage: _stage)
            .then(
              (_) => _controlController.setControlRunning(
                _controller.isRunning.value,
              ),
            ),
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
        await _controlController.setControlStatus('Enable Access');
        return;
      }

      if (activePackage.isEmpty) {
        _log.warn('Notification check: active app is unknown.');
        await _controlController.setControlStatus('No app');
        return;
      }

      if (activePackage == 'com.example.city_stamina_mobile') {
        _log.warn('Notification check: City Stamina app is active, not NTE.');
        await _controlController.setControlStatus('Open NTE');
        return;
      }

      _log.info('Notification check: active app package=$activePackage.');
      await _controlController.setControlStatus(
        _looksLikeGamePackage(activePackage) ? 'NTE ready' : 'App active',
      );
    } catch (error) {
      _log.error('Notification check failed: $error');
      await _controlController.setControlStatus('Check failed');
    }
  }

  bool _looksLikeGamePackage(String packageName) {
    final normalized = packageName.toLowerCase();
    return normalized.contains('nte') ||
        normalized.contains('nevernes') ||
        normalized.contains('netease') ||
        normalized.contains('hotta') ||
        normalized == 'com.hottagames.nte';
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
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
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
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
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
            'AMOUNT',
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
        children: ['1-1'].map((stage) {
          final selected = value == stage;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Material(
                color: selected ? AppColors.primaryDim : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: () => onChanged(stage),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selected
                            ? AppColors.primary.withValues(alpha: 0.22)
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(6),
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
        borderRadius: BorderRadius.circular(8),
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
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: fg.withValues(alpha: 0.3), width: 1.5),
            borderRadius: BorderRadius.circular(8),
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
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: fg.withValues(alpha: 0.28), width: 1.5),
            borderRadius: BorderRadius.circular(8),
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
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
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
