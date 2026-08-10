using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace CityStamina.Avalonia.ViewModels;

public partial class MainViewModel : ViewModelBase
{
    public const string AppVersion = "1.2.29";
    private const string LatestManifestUrl = "https://raw.githubusercontent.com/PHai237/City-Stamina-Spender/main/latest.json";
    private const string StageOneNine = "Stage 1-9";
    private const string StageOneOne = "Stage 1-1";
    private const int MaxUiLogLines = 14;
    private const long DiscordDebugPackageBudgetBytes = 6_500_000L;
    private const long DiscordUploadLimitBytes = 7_500_000L;
    private const int DiscordDebugPackageMaxFilesPerFolder = 35;

    private sealed record AutomationModule(string Id, string Name, string Category, bool IsReady);
    private sealed record UpdateManifest(string? Version, string? Url, string? Notes);
    private sealed record ToolCommand(string FileName, string Arguments, bool UsesPythonSource);

    private readonly List<AutomationModule> _modules =
    [
        new("owners_selection", "Owner's Selection", "Games", true),
    ];

    private readonly string _rootDir;
    private readonly string _dataDir;
    private readonly string _ownerToolDir;
    private readonly string _ownerToolPath;
    private readonly string _ownerToolExePath;
    private readonly string _wrapperLogPath;
    private readonly string _updateDebugLogPath;
    private readonly string _updatePendingPath;
    private readonly bool _preferPythonSource;
    private readonly Queue<string> _uiLogLines = new();
    private readonly object _debugLogLock = new();
    private Process? _ownerProcess;
    private readonly Stopwatch _runStopwatch = new();
    private System.Timers.Timer? _elapsedTimer;
    private bool _stopRequested;
    private bool _automationReachedTarget;
    private int _sessionSpent;
    private int _currentProcessSpent;
    private int _runsToday;
    private string _latestDownloadUrl = "";
    private string _lastUiLogLine = "";

    public MainViewModel()
    {
        (_rootDir, _dataDir) = FindApplicationDirectories();
        _ownerToolDir = Path.Combine(EmbeddedAppData.GetOwnersSelectionDir(_dataDir), "_tool");
        _ownerToolPath = Path.Combine(_ownerToolDir, "stage_1_9.py");
        _ownerToolExePath = Path.Combine(_ownerToolDir, "OwnerSelectionTool.exe");
        _wrapperLogPath = Path.Combine(_ownerToolDir, "wrapper_debug", "run.log");
        _updateDebugLogPath = Path.Combine(EmbeddedAppData.LocalRoot, "update_debug.log");
        _updatePendingPath = Path.Combine(EmbeddedAppData.LocalRoot, "update_pending.txt");
        _preferPythonSource = IsDevelopmentLayout(_dataDir);
        RefreshHubMetrics();
        _ = CheckUpdateAsync();
    }

    public string CurrentVersion => AppVersion;

    [ObservableProperty]
    private string _title = "Owner's Selection";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsStageOneNineSelected))]
    [NotifyPropertyChangedFor(nameof(IsStageOneOneSelected))]
    private string _selectedStage = StageOneOne;

    public IReadOnlyList<string> StageOptions { get; } = [StageOneOne, StageOneNine];

    public bool IsStageOneNineSelected => SelectedStage == StageOneNine;

    public bool IsStageOneOneSelected => SelectedStage == StageOneOne;

    [ObservableProperty]
    private string _targetStamina = "";

    [ObservableProperty]
    private string _spentSoFar = "--";

    [ObservableProperty]
    private string _elapsed = "00:00";

    [ObservableProperty]
    private string _ordersDetected = "0 / 0";

    [ObservableProperty]
    private string _ordersDone = "0";

    [ObservableProperty]
    private string _calibrationStatus = "Not calibrated";

    [ObservableProperty]
    private string _logText = "";

    [ObservableProperty]
    private string _searchQuery = "";

    [ObservableProperty]
    private string _automationCount = "0";

    [ObservableProperty]
    private string _runningNowCount = "0";

    [ObservableProperty]
    private string _runsTodayCount = "0";

    [ObservableProperty]
    private string _readyModulesCount = "0";

    [ObservableProperty]
    private string _gamesCount = "0";

    [ObservableProperty]
    private bool _isHubVisible = true;

    [ObservableProperty]
    private bool _isDetailVisible;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RunCommand))]
    [NotifyCanExecuteChangedFor(nameof(StopCommand))]
    private bool _isRunning;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsUpdateAvailable))]
    private string _updateState = "checking";

    [ObservableProperty]
    private string _latestVersion = AppVersion;

    [ObservableProperty]
    private string _updateMessage = "Checking for updates...";

    [ObservableProperty]
    private int _updateProgress;

    public bool IsUpdateAvailable => UpdateState == "available";

    [RelayCommand(CanExecute = nameof(CanChangeMode))]
    private void SelectOwner()
    {
        Title = "Owner's Selection";
        OpenDetail();
    }

    [RelayCommand(CanExecute = nameof(CanChangeMode))]
    private void OpenOwner()
    {
        SelectOwner();
    }

    [RelayCommand(CanExecute = nameof(CanChangeMode))]
    private void BackToHub()
    {
        IsHubVisible = true;
        IsDetailVisible = false;
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task RunAsync(string? amountInput)
    {
        var rawAmount = string.IsNullOrWhiteSpace(amountInput) ? TargetStamina : amountInput;
        var staminaText = rawAmount.Trim().Replace(",", "").Replace(" ", "");
        if (!int.TryParse(staminaText, out var amount) || amount <= 0)
        {
            SetRunLog("Enter a valid City Stamina amount.");
            return;
        }

        _stopRequested = false;
        _automationReachedTarget = false;
        IsRunning = true;
        _runsToday++;
        RefreshHubMetrics();
        _currentProcessSpent = 0;
        SpentSoFar = FormatAmount(_sessionSpent);
        OrdersDetected = "0 / 0";
        OrdersDone = "0";
        if (SelectedStageArg == "1-1")
        {
            CalibrationStatus = "Waiting";
        }
        StartElapsedTimer();

        try
        {
            SetRunLog("Checking dependencies...");
            if (!OwnerToolExists())
            {
                AppendLog("Owner's Selection tool was not found.");
                return;
            }

            if (!await DependenciesReadyAsync(logWhenReady: false))
            {
                if (!_stopRequested)
                {
                    AppendLog("Dependency check failed.");
                }
                return;
            }

            if (_stopRequested)
            {
                return;
            }
            AppendLog("Dependencies are ready.");

            AppendLog("Checking game...");
            var game = FindGameWindow();
            if (game is null)
            {
                AppendLog("Game not found.");
                return;
            }

            AppendLog($"Game found: {game.Value.Width}x{game.Value.Height} ({game.Value.Title})");
            AppendLog("Starting automation...");

            if (_stopRequested)
            {
                return;
            }

            if (SelectedStageArg == "1-1")
            {
                using var calibrationProcess = StartOwnerCalibrationProcess();
                var calibrationExitCode = await RunTrackedProcessAsync(
                    calibrationProcess,
                    HandleAutomationLine,
                    showErrorsInUi: true
                );
                if (_stopRequested)
                {
                    AppendLog("Stopped.");
                    return;
                }
                if (calibrationExitCode != 0)
                {
                    AppendLog($"Calibration failed with code {calibrationExitCode}.");
                    return;
                }
            }

            using var process = StartOwnerProcess(amount, SelectedStageArg, skipSupportEmployeeCheck: true);
            var exitCode = await RunTrackedProcessAsync(process, HandleAutomationLine, showErrorsInUi: true);
            if (_stopRequested)
            {
                AppendLog("Stopped.");
            }
            else if (exitCode == 0)
            {
                if (_automationReachedTarget || SelectedStageArg == "1-1")
                {
                    AppendLog("Completed.");
                }
                else
                {
                    AppendLog("Stopped before the target was reached.");
                }
            }
            else
            {
                AppendLog($"Stopped with code {exitCode}.");
            }
        }
        catch (Exception ex)
        {
            AppendLog(_stopRequested ? "Stopped." : $"Stopped. {ex.Message}");
            WriteWrapperDebug("wrapper", ex.ToString());
        }
        finally
        {
            if (_stopRequested && _lastUiLogLine != "Stopped.")
            {
                AppendLog("Stopped.");
            }
            _ownerProcess = null;
            _sessionSpent += _currentProcessSpent;
            _currentProcessSpent = 0;
            SpentSoFar = FormatAmount(_sessionSpent);
            StopElapsedTimer();
            IsRunning = false;
            RefreshHubMetrics();
        }
    }

    [RelayCommand(CanExecute = nameof(CanStop))]
    private void Stop()
    {
        _stopRequested = true;
        try
        {
            if (_ownerProcess is { HasExited: false })
            {
                _ownerProcess.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // The process may exit between the HasExited check and Kill.
        }

        AppendLog("Stopping...");
    }

    public void ReportHotkey(string message)
    {
        AppendLog(message);
        WriteWrapperDebug("hotkey", message);
    }

    [RelayCommand]
    private async Task ExportDebugAsync()
    {
        var packagePath = "";
        try
        {
            var hasWebhook = TryReadDiscordWebhook(out var webhookUrl);
            var packageDir = Path.GetTempPath();
            if (!hasWebhook)
            {
                packageDir = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                if (string.IsNullOrWhiteSpace(packageDir) || !Directory.Exists(packageDir))
                {
                    packageDir = _rootDir;
                }
            }

            var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);
            packagePath = Path.Combine(packageDir, $"city-stamina-debug-{timestamp}.zip");
            var report = new StringBuilder();
            AppendSection(
                report,
                "SUMMARY",
                string.Join(
                    Environment.NewLine,
                    [
                        "City Stamina Spender debug report",
                        "Version: " + AppVersion,
                        "Created: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                        "Selected stage: " + SelectedStage,
                        "Target stamina: " + TargetStamina,
                        "Spent so far: " + SpentSoFar,
                        "Elapsed: " + Elapsed,
                        "Root dir: " + _rootDir,
                        "Data dir: " + _dataDir,
                        "Owner tool dir: " + _ownerToolDir,
                    ]
                )
            );
            AppendSection(report, "UI LOG", LogText);
            AppendFileSection(report, "UPDATE LOG", Path.Combine(_rootDir, "update.log"));
            AppendFileSection(report, "ROOT UPDATE DEBUG LOG", Path.Combine(_rootDir, "update_debug.log"));
            AppendFileSection(report, "UPDATE DEBUG LOG", _updateDebugLogPath);
            AppendFileSection(report, "WRAPPER LOG", _wrapperLogPath);
            AppendFileSection(report, "OWNER RUN LOG", Path.Combine(_ownerToolDir, "stage_1_9_debug", "run.log"));
            AppendFileSection(report, "STAGE 1-1 TUNING", Path.Combine(_ownerToolDir, "stage_1_1_tuning.json"));
            AppendDirectorySummary(report, "STAGE 1-9 DEBUG FILES", Path.Combine(_ownerToolDir, "stage_1_9_debug"));
            AppendDirectorySummary(report, "STAGE 1-1 DEBUG FILES", Path.Combine(_ownerToolDir, "stage_1_1_debug"));
            AppendDirectorySummary(report, "GAMEPLAY EXIT DEBUG FILES", Path.Combine(_ownerToolDir, "gameplay_exit_debug"));

            var remainingDebugBytes = DiscordDebugPackageBudgetBytes;
            using (var archive = ZipFile.Open(packagePath, ZipArchiveMode.Create))
            {
                AddTextEntry(archive, "debug-report.txt", report.ToString());
                AddFileIfExists(archive, Path.Combine(_rootDir, "update.log"), "logs/update.log");
                AddFileIfExists(archive, Path.Combine(_rootDir, "update_debug.log"), "logs/root_update_debug.log");
                AddFileIfExists(archive, _updateDebugLogPath, "logs/update_debug.log");
                AddFileIfExists(archive, _wrapperLogPath, "logs/wrapper_run.log");
                AddFileIfExists(archive, Path.Combine(_ownerToolDir, "stage_1_1_tuning.json"), "stage_1_1_tuning.json");
                AddDebugDirectoryToZip(archive, Path.Combine(_ownerToolDir, "stage_1_1_debug"), "stage_1_1_debug", ref remainingDebugBytes, DiscordDebugPackageMaxFilesPerFolder);
                AddDebugDirectoryToZip(archive, Path.Combine(_ownerToolDir, "stage_1_9_debug"), "stage_1_9_debug", ref remainingDebugBytes, DiscordDebugPackageMaxFilesPerFolder);
                AddDebugDirectoryToZip(archive, Path.Combine(_ownerToolDir, "gameplay_exit_debug"), "gameplay_exit_debug", ref remainingDebugBytes, DiscordDebugPackageMaxFilesPerFolder);
            }

            var packageSize = new FileInfo(packagePath).Length;
            WriteWrapperDebug("debug", $"Exported debug package: {packagePath} bytes={packageSize}");
            if (hasWebhook)
            {
                AppendLog($"Sending debug package to Discord ({packageSize / 1024.0 / 1024.0:0.0} MB)...");
                await SendDebugPackageToDiscordAsync(webhookUrl, packagePath);
                AppendLog("Debug package sent to Discord.");
                DeleteDebugPackage(packagePath);
            }
            else
            {
                EnsureWebhookTemplate();
                AppendLog($"No Discord webhook configured; package saved locally ({packageSize / 1024.0 / 1024.0:0.0} MB).");
            }
        }
        catch (Exception ex)
        {
            AppendLog("Debug package failed: " + ex.Message);
            WriteWrapperDebug("debug", ex.ToString());
        }
    }

    private void DeleteDebugPackage(string packagePath)
    {
        try
        {
            if (File.Exists(packagePath))
            {
                File.Delete(packagePath);
                WriteWrapperDebug("debug", "Deleted uploaded debug package: " + packagePath);
            }
        }
        catch (Exception ex)
        {
            WriteWrapperDebug("debug", "Could not delete uploaded debug package: " + ex.Message);
        }
    }

    [RelayCommand]
    private async Task CheckUpdateAsync()
    {
        try
        {
            WriteUpdateDebug("CheckUpdate started current=" + AppVersion);
            UpdateState = "checking";
            UpdateMessage = "Checking for updates...";
            UpdateProgress = 0;

            using var client = CreateHttpClient();
            var manifestUrl = LatestManifestUrl + "?t=" + DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
            var json = await client.GetStringAsync(manifestUrl);
            var manifest = JsonSerializer.Deserialize<UpdateManifest>(
                json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }
            );

            LatestVersion = string.IsNullOrWhiteSpace(manifest?.Version) ? AppVersion : manifest.Version.Trim();
            _latestDownloadUrl = manifest?.Url?.Trim() ?? "";
            WriteUpdateDebug($"CheckUpdate manifest latest={LatestVersion} url={_latestDownloadUrl}");
            if (IsRecentPendingUpdate(LatestVersion))
            {
                UpdateState = "updating";
                UpdateMessage = $"Installing version {LatestVersion}. Please wait a moment.";
                UpdateProgress = 100;
                WriteUpdateDebug("CheckUpdate blocked by recent pending update marker.");
                return;
            }

            if (CompareVersions(LatestVersion, AppVersion) > 0 && !string.IsNullOrWhiteSpace(_latestDownloadUrl))
            {
                UpdateState = "available";
                UpdateMessage = $"Version {LatestVersion} is available.";
                return;
            }

            UpdateState = "latest";
            UpdateMessage = "You are on the latest version.";
            UpdateProgress = 100;
            WriteUpdateDebug("CheckUpdate latest");
        }
        catch (Exception ex)
        {
            UpdateState = "error";
            UpdateMessage = "Could not check updates.";
            UpdateProgress = 0;
            WriteUpdateDebug("CheckUpdate failed: " + ex);
        }
    }

    [RelayCommand]
    private async Task UpdateAsync()
    {
        if (UpdateState == "updating")
        {
            WriteUpdateDebug("Update ignored because another update is running");
            return;
        }

        if (IsRunning)
        {
            UpdateState = "error";
            UpdateMessage = "Stop the automation before updating.";
            UpdateProgress = 0;
            WriteUpdateDebug("Update blocked because automation is running");
            return;
        }

        if (!IsUpdateAvailable)
        {
            await CheckUpdateAsync();
            if (!IsUpdateAvailable)
            {
                return;
            }
        }

        try
        {
            WriteUpdateDebug($"Update started current={AppVersion} latest={LatestVersion} url={_latestDownloadUrl}");
            UpdateState = "updating";
            UpdateMessage = $"Downloading version {LatestVersion}...";
            UpdateProgress = 0;

            var tempDir = Path.Combine(Path.GetTempPath(), "CityStaminaUpdate_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempDir);
            var isExeUpdate = _latestDownloadUrl.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
            var downloadPath = Path.Combine(tempDir, isExeUpdate ? "City Stamina Spender.exe" : "update.zip");
            WriteUpdateDebug($"Update temp={tempDir} isExe={isExeUpdate} downloadPath={downloadPath}");

            using var client = CreateHttpClient();
            await DownloadFileWithRetryAsync(client, _latestDownloadUrl, downloadPath, progress =>
            {
                UpdateProgress = Math.Clamp(progress, 0, 95);
                UpdateMessage = $"Downloading version {LatestVersion}: {UpdateProgress}%";
            });
            WriteUpdateDebug($"Update downloaded bytes={new FileInfo(downloadPath).Length}");

            string? sourceDir = null;
            if (!isExeUpdate)
            {
                UpdateProgress = 96;
                UpdateMessage = "Preparing update...";
                var extractDir = Path.Combine(tempDir, "extract");
                Directory.CreateDirectory(extractDir);
                ZipFile.ExtractToDirectory(downloadPath, extractDir, overwriteFiles: true);
                sourceDir = FindExtractedUpdateDirectory(extractDir);
                WriteUpdateDebug("Update extracted sourceDir=" + sourceDir);
            }
            var scriptPath = WriteUpdaterScript(tempDir, isExeUpdate);
            WriteUpdateDebug("Update script=" + scriptPath);

            var currentExe = Environment.ProcessPath ?? Path.Combine(_rootDir, "City Stamina Spender.exe");
            WriteUpdateDebug("Update currentExe=" + currentExe);
            WritePendingUpdateMarker(LatestVersion);
            var args =
                "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath) +
                " -Source " + Quote(sourceDir ?? tempDir) +
                " -Target " + Quote(_rootDir) +
                " -Exe " + Quote(currentExe) +
                " -Pid " + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) +
                " -Temp " + Quote(tempDir) +
                " -AppLog " + Quote(_updateDebugLogPath) +
                " -PendingMarker " + Quote(_updatePendingPath);
            WriteUpdateDebug("Update launching script args=" + args);

            UpdateProgress = 100;
            UpdateMessage = "Installing update...";

            Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = _rootDir,
            });

            WriteUpdateDebug("Update script launched; exiting app");
            Environment.Exit(0);
        }
        catch (Exception ex)
        {
            UpdateState = "error";
            UpdateMessage = "Update failed: " + ToUserFriendlyUpdateError(ex);
            UpdateProgress = 0;
            WriteUpdateDebug("Update failed: " + ex);
        }
    }

    private bool CanRun() => !IsRunning;

    private bool CanStop() => IsRunning;

    private bool CanChangeMode() => !IsRunning;

    private void OpenDetail()
    {
        IsHubVisible = false;
        IsDetailVisible = true;
    }

    private void RefreshHubMetrics()
    {
        AutomationCount = _modules.Count.ToString(CultureInfo.InvariantCulture);
        ReadyModulesCount = _modules.Count(module => module.IsReady).ToString(CultureInfo.InvariantCulture);
        GamesCount = _modules.Count(module => module.Category == "Games").ToString(CultureInfo.InvariantCulture);
        RunningNowCount = IsRunning ? "1" : "0";
        RunsTodayCount = _runsToday.ToString(CultureInfo.InvariantCulture);
    }

    private static Process StartProcess(string fileName, string arguments, string workingDirectory)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            CreateNoWindow = true,
        };

        return Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start process.");
    }

    private string SelectedStageArg => SelectedStage == StageOneOne ? "1-1" : "1-9";

    private bool OwnerToolExists() => File.Exists(_ownerToolPath) || File.Exists(_ownerToolExePath);

    private ToolCommand ResolveOwnerCommand(string arguments)
    {
        var sourceCommand = new ToolCommand(
            "python",
            string.IsNullOrWhiteSpace(arguments)
                ? $"-u \"{_ownerToolPath}\""
                : $"-u \"{_ownerToolPath}\" {arguments}",
            UsesPythonSource: true
        );
        var packagedCommand = new ToolCommand(
            _ownerToolExePath,
            arguments,
            UsesPythonSource: false
        );

        if (_preferPythonSource && File.Exists(_ownerToolPath))
        {
            return sourceCommand;
        }
        if (File.Exists(_ownerToolExePath))
        {
            return packagedCommand;
        }
        if (File.Exists(_ownerToolPath))
        {
            return sourceCommand;
        }

        throw new FileNotFoundException("Owner's Selection tool was not found.");
    }

    private Process StartOwnerProcess(int amount, string stage, bool skipSupportEmployeeCheck)
    {
        var arguments = amount.ToString(CultureInfo.InvariantCulture) + $" --stage {stage} --no-admin-relaunch";
        if (stage == "1-1")
        {
            arguments += " --owner-timeout 10 --verify-timeout 3 --between-cycles 1";
        }
        if (skipSupportEmployeeCheck)
        {
            arguments += " --skip-support-employee-check";
        }

        var command = ResolveOwnerCommand(arguments);
        WriteWrapperDebug(
            "wrapper",
            $"Starting owner tool mode={(command.UsesPythonSource ? "source" : "packaged")} stage={stage} amount={amount}"
        );
        return StartProcess(command.FileName, command.Arguments, _ownerToolDir);
    }

    private Process StartOwnerCalibrationProcess()
    {
        var arguments = "1 --stage 1-1 --stage-1-1-calibrate-run --no-admin-relaunch --owner-timeout 10 --verify-timeout 3 --between-cycles 1 --skip-support-employee-check";
        var command = ResolveOwnerCommand(arguments);
        WriteWrapperDebug(
            "wrapper",
            $"Starting owner calibration mode={(command.UsesPythonSource ? "source" : "packaged")} stage=1-1"
        );
        return StartProcess(command.FileName, command.Arguments, _ownerToolDir);
    }

    private async Task<int> RunProcessToLogAsync(
        string fileName,
        string arguments,
        string workingDirectory,
        bool logOutput)
    {
        using var process = StartProcess(fileName, arguments, workingDirectory);
        return await RunTrackedProcessAsync(
            process,
            line =>
            {
                if (logOutput)
                {
                    AppendLog(line);
                }
            },
            showErrorsInUi: true
        );
    }

    private async Task<int> RunTrackedProcessAsync(
        Process process,
        Action<string> stdoutHandler,
        bool showErrorsInUi)
    {
        var errors = new List<string>();
        _ownerProcess = process;
        try
        {
            var stdoutTask = PumpProcessLinesAsync(
                process.StandardOutput,
                "stdout",
                stdoutHandler
            );
            var stderrTask = PumpProcessLinesAsync(
                process.StandardError,
                "stderr",
                line => errors.Add(line)
            );

            await Task.WhenAll(stdoutTask, stderrTask, process.WaitForExitAsync());
            if (showErrorsInUi && process.ExitCode != 0 && !_stopRequested && errors.Count > 0)
            {
                AppendLog(string.Join(Environment.NewLine, errors.TakeLast(3)));
            }
            return process.ExitCode;
        }
        finally
        {
            if (ReferenceEquals(_ownerProcess, process))
            {
                _ownerProcess = null;
            }
        }
    }

    private async Task PumpProcessLinesAsync(
        StreamReader reader,
        string source,
        Action<string> handler)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            WriteWrapperDebug(source, line);
            handler(line);
        }
    }

    private async Task<bool> DependenciesReadyAsync(bool logWhenReady)
    {
        var ownerCommand = ResolveOwnerCommand("");
        if (!ownerCommand.UsesPythonSource)
        {
            if (logWhenReady)
            {
                AppendLog("Packaged tool is ready.");
            }
            return true;
        }

        var result = await RunProcessToLogAsync(
            "python",
            "-c \"import cv2, mss, numpy, PIL\"",
            _rootDir,
            logOutput: false
        );

        if (result == 0 && logWhenReady)
        {
            AppendLog("Dependencies are ready.");
        }

        return result == 0;
    }

    private void HandleAutomationLine(string line)
    {
        UpdateSpentFromLog(line);
        UpdateOrderMetricsFromLog(line);

        if (Regex.IsMatch(line, @"^Run\s+\d+:", RegexOptions.IgnoreCase))
        {
            SetRunLog(line);
            return;
        }

        var lineMatch = Regex.Match(
            line,
            @"^\s*Line\s+\d+:\s*(.+)$",
            RegexOptions.IgnoreCase
        );
        if (lineMatch.Success)
        {
            var message = lineMatch.Groups[1].Value.Trim();
            UpdateOrderMetricsFromLog(message);
            if (!IsNoisyUiLog(message))
            {
                AppendLog(message);
            }
            return;
        }

        if (line.StartsWith("ORDER_", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (line.StartsWith("CALIBRATION_", StringComparison.OrdinalIgnoreCase))
        {
            UpdateCalibrationStatusFromLog(line);
            return;
        }

        if (line.StartsWith("TUNE_", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (!IsNoisyUiLog(line))
        {
            AppendLog(line);
        }
    }

    private static bool IsNoisyUiLog(string message)
    {
        var trimmed = message.Trim();
        return string.IsNullOrWhiteSpace(trimmed)
            || trimmed.StartsWith("Scanning orders", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Detected ", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Prepared item", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Used item", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("Attempt ", StringComparison.OrdinalIgnoreCase);
    }

    private void UpdateSpentFromLog(string line)
    {
        var patterns = new[]
        {
            @"^Run\s+\d+:\s*([\d,.]+)\s*/\s*[\d,.]+\s+City Stamina",
            @"\bTotal\s+([\d,.]+)\s*/\s*[\d,.]+\s+City Stamina",
            @"\bSpent\s+([\d,.]+)\s*/\s*[\d,.]+\s+City Stamina",
            @"\bSpent\s+\d+\s+City Stamina\.\s+Total\s+([\d,.]+)\s*/\s*[\d,.]+\s+City Stamina",
            @"\bTarget reached:\s*spent\s+([\d,.]+)\s*>=",
        };

        foreach (var pattern in patterns)
        {
            var match = Regex.Match(line, pattern, RegexOptions.IgnoreCase);
            if (!match.Success)
            {
                continue;
            }

            _currentProcessSpent = Math.Max(_currentProcessSpent, ParseAmount(match.Groups[1].Value));
            SpentSoFar = FormatAmount(_sessionSpent + _currentProcessSpent);
            if (line.Contains("Target reached:", StringComparison.OrdinalIgnoreCase))
            {
                _automationReachedTarget = true;
            }
            return;
        }
    }

    private void UpdateOrderMetricsFromLog(string line)
    {
        var scanMatch = Regex.Match(
            line,
            @"Order scan:\s*(\d+)\s+NPC\s*/\s*(\d+)\s+orders",
            RegexOptions.IgnoreCase
        );
        if (scanMatch.Success)
        {
            OrdersDetected = $"{scanMatch.Groups[1].Value} / {scanMatch.Groups[2].Value}";
            return;
        }

        var directScanMatch = Regex.Match(
            line,
            @"^ORDER_SCANNING\b.*\bmatches=(\d+).*\bhandled=(\d+)",
            RegexOptions.IgnoreCase
        );
        if (directScanMatch.Success)
        {
            OrdersDetected = $"{directScanMatch.Groups[1].Value} / {directScanMatch.Groups[1].Value}";
            OrdersDone = directScanMatch.Groups[2].Value;
            return;
        }

        var doneMatch = Regex.Match(line, @"Order\s+(\d+)\s+served", RegexOptions.IgnoreCase);
        if (doneMatch.Success)
        {
            OrdersDone = doneMatch.Groups[1].Value;
            return;
        }

        var directDoneMatch = Regex.Match(line, @"^ORDER_DONE\b.*\border=(\d+)", RegexOptions.IgnoreCase);
        if (directDoneMatch.Success)
        {
            OrdersDone = directDoneMatch.Groups[1].Value;
        }
    }

    private void StartElapsedTimer()
    {
        _runStopwatch.Restart();
        _elapsedTimer ??= new System.Timers.Timer(1000) { AutoReset = true };
        _elapsedTimer.Elapsed -= OnElapsedTimerTick;
        _elapsedTimer.Elapsed += OnElapsedTimerTick;
        _elapsedTimer.Start();
        UpdateElapsed();
    }

    private void StopElapsedTimer()
    {
        _elapsedTimer?.Stop();
        _runStopwatch.Stop();
        UpdateElapsed();
    }

    private void OnElapsedTimerTick(object? sender, System.Timers.ElapsedEventArgs e)
    {
        UpdateElapsed();
    }

    private void UpdateElapsed()
    {
        var elapsed = _runStopwatch.Elapsed;
        Elapsed = $"{(int)elapsed.TotalMinutes:00}:{elapsed.Seconds:00}";
    }

    private void SetRunLog(string message)
    {
        _uiLogLines.Clear();
        _lastUiLogLine = "";
        AppendLog(message);
    }

    private void AppendLog(string message)
    {
        foreach (var rawLine in message.Replace("\r", "").Split('\n'))
        {
            var line = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(line) || line == _lastUiLogLine)
            {
                continue;
            }

            _lastUiLogLine = line;
            _uiLogLines.Enqueue(line);
            while (_uiLogLines.Count > MaxUiLogLines)
            {
                _uiLogLines.Dequeue();
            }
        }

        LogText = _uiLogLines.Count == 0
            ? ""
            : string.Join(Environment.NewLine, _uiLogLines) + Environment.NewLine;
    }

    private void WriteWrapperDebug(string source, string message)
    {
        try
        {
            lock (_debugLogLock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_wrapperLogPath)!);
                File.AppendAllText(
                    _wrapperLogPath,
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{source}] {message}{Environment.NewLine}",
                    Encoding.UTF8
                );
            }
        }
        catch
        {
            // Debug logging must never stop the automation.
        }
    }

    private void WriteUpdateDebug(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}";
        foreach (var path in new[] { _updateDebugLogPath, Path.Combine(_rootDir, "update_debug.log") })
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.AppendAllText(path, line, Encoding.UTF8);
            }
            catch
            {
                // Update logging must never stop the app.
            }
        }
    }

    private void WritePendingUpdateMarker(string version)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_updatePendingPath)!);
            File.WriteAllText(
                _updatePendingPath,
                version.Trim() + "|" + DateTime.UtcNow.Ticks.ToString(CultureInfo.InvariantCulture),
                Encoding.UTF8
            );
            WriteUpdateDebug("Pending update marker written for version=" + version);
        }
        catch (Exception ex)
        {
            WriteUpdateDebug("Could not write pending update marker: " + ex.Message);
        }
    }

    private bool IsRecentPendingUpdate(string latestVersion)
    {
        try
        {
            if (!File.Exists(_updatePendingPath))
            {
                return false;
            }

            var parts = File.ReadAllText(_updatePendingPath, Encoding.UTF8).Split('|');
            if (parts.Length < 2 || !parts[0].Equals(latestVersion.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (!long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var ticks))
            {
                return false;
            }

            var age = DateTime.UtcNow - new DateTime(ticks, DateTimeKind.Utc);
            if (age <= TimeSpan.FromMinutes(3))
            {
                return true;
            }

            try { File.Delete(_updatePendingPath); } catch { }
            WriteUpdateDebug("Expired pending update marker cleared.");
            return false;
        }
        catch (Exception ex)
        {
            WriteUpdateDebug("Could not read pending update marker: " + ex.Message);
            return false;
        }
    }

    private static void AppendSection(StringBuilder builder, string title, string content)
    {
        builder.AppendLine("==== " + title + " ====");
        builder.AppendLine(string.IsNullOrWhiteSpace(content) ? "(empty)" : content.TrimEnd());
        builder.AppendLine();
    }

    private static void AddTextEntry(ZipArchive archive, string entryName, string content)
    {
        var entry = archive.CreateEntry(NormalizeZipEntryName(entryName), CompressionLevel.Fastest);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        writer.Write(content);
    }

    private static void AddFileIfExists(ZipArchive archive, string filePath, string entryName)
    {
        if (!File.Exists(filePath))
        {
            return;
        }

        try
        {
            var fileInfo = new FileInfo(filePath);
            if (fileInfo.Length <= 0)
            {
                return;
            }

            var entry = archive.CreateEntry(NormalizeZipEntryName(entryName), CompressionLevel.Fastest);
            using var source = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var target = entry.Open();
            source.CopyTo(target);
        }
        catch
        {
            // Debug export should keep going even if one file is locked.
        }
    }

    private bool TryReadDiscordWebhook(out string webhookUrl)
    {
        webhookUrl = "";
        var envWebhook = Environment.GetEnvironmentVariable("CITY_STAMINA_DISCORD_WEBHOOK")?.Trim();
        if (IsDiscordWebhook(envWebhook))
        {
            webhookUrl = envWebhook!;
            return true;
        }

        var webhookPath = Path.Combine(_rootDir, "discord_webhook.txt");
        if (!File.Exists(webhookPath))
        {
            return false;
        }

        var text = File.ReadAllLines(webhookPath)
            .Select(line => line.Trim())
            .FirstOrDefault(line => IsDiscordWebhook(line));
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        webhookUrl = text;
        return true;
    }

    private void EnsureWebhookTemplate()
    {
        var webhookPath = Path.Combine(_rootDir, "discord_webhook.txt");
        if (File.Exists(webhookPath))
        {
            return;
        }

        try
        {
            File.WriteAllText(
                webhookPath,
                string.Join(
                    Environment.NewLine,
                    [
                        "Paste one Discord webhook URL on the next line.",
                        "Do not upload this file to GitHub.",
                        "",
                    ]
                ),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
            );
        }
        catch
        {
            // The debug export still works locally without this helper file.
        }
    }

    private static bool IsDiscordWebhook(string? value)
    {
        return !string.IsNullOrWhiteSpace(value)
            && Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && (uri.Host.Equals("discord.com", StringComparison.OrdinalIgnoreCase)
                || uri.Host.Equals("discordapp.com", StringComparison.OrdinalIgnoreCase))
            && uri.AbsolutePath.Contains("/api/webhooks/", StringComparison.OrdinalIgnoreCase);
    }

    private async Task SendDebugPackageToDiscordAsync(string webhookUrl, string packagePath)
    {
        var fileInfo = new FileInfo(packagePath);
        if (!fileInfo.Exists)
        {
            throw new FileNotFoundException("Debug package was not found.", packagePath);
        }
        if (fileInfo.Length > DiscordUploadLimitBytes)
        {
            throw new InvalidOperationException(
                $"Debug package is too large for this Discord webhook ({fileInfo.Length / 1024.0 / 1024.0:0.0} MB). Please send the zip manually."
            );
        }

        using var client = CreateHttpClient();
        using var form = new MultipartFormDataContent();
        var payload = JsonSerializer.Serialize(new
        {
            content = $"City Stamina debug package v{AppVersion} | {SelectedStage} | {DateTime.Now:yyyy-MM-dd HH:mm:ss}"
        });
        form.Add(new StringContent(payload, Encoding.UTF8, "application/json"), "payload_json");

        await using var stream = new FileStream(packagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var fileContent = new StreamContent(stream);
        fileContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/zip");
        form.Add(fileContent, "files[0]", Path.GetFileName(packagePath));

        using var response = await client.PostAsync(webhookUrl, form);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw new InvalidOperationException($"Discord upload failed: {(int)response.StatusCode} {response.ReasonPhrase} {body}");
        }
    }

    private static void AppendFileSection(StringBuilder builder, string title, string filePath, int maxChars = 180_000)
    {
        if (!File.Exists(filePath))
        {
            AppendSection(builder, title, "(missing) " + filePath);
            return;
        }

        try
        {
            var content = File.ReadAllText(filePath, Encoding.UTF8);
            if (content.Length > maxChars)
            {
                content = content[^maxChars..];
                content = "(trimmed to the latest lines)" + Environment.NewLine + content;
            }
            AppendSection(builder, title + " - " + filePath, content);
        }
        catch (Exception ex)
        {
            AppendSection(builder, title, "Could not read " + filePath + ": " + ex.Message);
        }
    }

    private static void AppendDirectorySummary(StringBuilder builder, string title, string directoryPath)
    {
        if (!Directory.Exists(directoryPath))
        {
            AppendSection(builder, title, "(missing) " + directoryPath);
            return;
        }

        try
        {
            var lines = Directory
                .EnumerateFiles(directoryPath, "*", SearchOption.AllDirectories)
                .Select(path => new FileInfo(path))
                .OrderByDescending(file => file.LastWriteTimeUtc)
                .Take(80)
                .Select(file =>
                {
                    var relative = Path.GetRelativePath(directoryPath, file.FullName);
                    return $"{file.LastWriteTime:yyyy-MM-dd HH:mm:ss} | {file.Length:N0} bytes | {relative}";
                });
            AppendSection(builder, title + " - " + directoryPath, string.Join(Environment.NewLine, lines));
        }
        catch (Exception ex)
        {
            AppendSection(builder, title, "Could not list " + directoryPath + ": " + ex.Message);
        }
    }

    private static void AddDebugDirectoryToZip(
        ZipArchive archive,
        string directoryPath,
        string entryRoot,
        ref long remainingBytes,
        int maxFiles = 120
    )
    {
        if (!Directory.Exists(directoryPath))
        {
            return;
        }

        var allowedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".txt",
            ".log",
            ".json",
            ".png",
            ".jpg",
            ".jpeg",
        };

        foreach (var file in Directory
            .EnumerateFiles(directoryPath, "*", SearchOption.AllDirectories)
            .Select(path => new FileInfo(path))
            .Where(file => allowedExtensions.Contains(file.Extension))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .Take(maxFiles))
        {
            if (remainingBytes <= 0)
            {
                break;
            }
            if (file.Length > remainingBytes)
            {
                continue;
            }

            var relative = Path.GetRelativePath(directoryPath, file.FullName);
            AddFileIfExists(archive, file.FullName, Path.Combine(entryRoot, relative));
            remainingBytes -= file.Length;
        }
    }

    private static string NormalizeZipEntryName(string entryName)
    {
        return entryName.Replace('\\', '/').TrimStart('/');
    }

    private static int ParseAmount(string value)
    {
        return int.TryParse(value.Replace(",", ""), NumberStyles.Integer, CultureInfo.InvariantCulture, out var amount)
            ? amount
            : 0;
    }

    private static string FormatAmount(int value)
    {
        return value <= 0 ? "0" : value.ToString("N0", CultureInfo.InvariantCulture);
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("City-Stamina-Spender/" + AppVersion);
        return client;
    }

    private void UpdateCalibrationStatusFromLog(string line)
    {
        if (line.StartsWith("CALIBRATION_ORDER_CROP=", StringComparison.OrdinalIgnoreCase))
        {
            CalibrationStatus = "Order crop saved";
        }
        else if (line.StartsWith("CALIBRATION_MATCHES=", StringComparison.OrdinalIgnoreCase))
        {
            var parts = line.Split('=', 2);
            var value = parts.Length == 2 ? parts[1].Trim() : "0";
            CalibrationStatus = $"Visible orders: {value}";
        }
        else if (line.StartsWith("CALIBRATION_CONFIG=", StringComparison.OrdinalIgnoreCase))
        {
            CalibrationStatus = "Ready";
        }
        else if (line.StartsWith("CALIBRATION_ERROR=", StringComparison.OrdinalIgnoreCase))
        {
            CalibrationStatus = "Failed";
        }
    }

    private static async Task DownloadFileWithRetryAsync(HttpClient client, string url, string destinationPath, Action<int>? reportProgress = null)
    {
        Exception? lastError = null;
        for (var attempt = 1; attempt <= 4; attempt++)
        {
            try
            {
                if (File.Exists(destinationPath))
                {
                    File.Delete(destinationPath);
                }

                using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
                response.EnsureSuccessStatusCode();

                var totalBytes = response.Content.Headers.ContentLength;
                long downloadedBytes = 0;
                var lastProgress = -1;
                reportProgress?.Invoke(0);

                await using var source = await response.Content.ReadAsStreamAsync();
                await using var target = new FileStream(
                    destinationPath,
                    FileMode.Create,
                    FileAccess.Write,
                    FileShare.None,
                    bufferSize: 1024 * 128,
                    useAsync: true
                );

                var buffer = new byte[1024 * 128];
                while (true)
                {
                    var bytesRead = await source.ReadAsync(buffer);
                    if (bytesRead <= 0)
                    {
                        break;
                    }

                    await target.WriteAsync(buffer.AsMemory(0, bytesRead));
                    downloadedBytes += bytesRead;

                    if (totalBytes is > 0)
                    {
                        var progress = (int)Math.Floor(downloadedBytes * 100d / totalBytes.Value);
                        if (progress != lastProgress)
                        {
                            lastProgress = progress;
                            reportProgress?.Invoke(progress);
                        }
                    }
                }

                if (new FileInfo(destinationPath).Length <= 0)
                {
                    throw new IOException("Downloaded file is empty.");
                }

                reportProgress?.Invoke(100);
                return;
            }
            catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException)
            {
                lastError = ex;
                if (attempt == 4)
                {
                    break;
                }

                reportProgress?.Invoke(0);
                await Task.Delay(TimeSpan.FromSeconds(attempt * 2));
            }
        }

        throw new IOException("Download failed after several retries. Please try again or download the latest exe from GitHub.", lastError);
    }

    private static string ToUserFriendlyUpdateError(Exception ex)
    {
        var message = ex.Message;
        if (message.Contains("forcibly closed", StringComparison.OrdinalIgnoreCase)
            || message.Contains("transport connection", StringComparison.OrdinalIgnoreCase)
            || message.Contains("connection", StringComparison.OrdinalIgnoreCase))
        {
            return "network connection was interrupted while downloading. Please try Update again, or download the latest exe from GitHub.";
        }

        return message;
    }

    private static int CompareVersions(string left, string right)
    {
        static Version Parse(string value)
        {
            var clean = value.Trim().TrimStart('v', 'V');
            return Version.TryParse(clean, out var version) ? version : new Version(0, 0, 0);
        }

        return Parse(left).CompareTo(Parse(right));
    }

    private static string FindExtractedUpdateDirectory(string extractDir)
    {
        if (File.Exists(Path.Combine(extractDir, "City Stamina Spender.exe")))
        {
            return extractDir;
        }

        foreach (var directory in Directory.EnumerateDirectories(extractDir))
        {
            if (File.Exists(Path.Combine(directory, "City Stamina Spender.exe")))
            {
                return directory;
            }
        }

        throw new InvalidOperationException("Downloaded update package is not valid.");
    }

    private static string WriteUpdaterScript(string tempDir, bool exeUpdate)
    {
        var scriptPath = Path.Combine(tempDir, "apply_update.ps1");
        var script = exeUpdate
            ? """
param(
  [string]$Source,
  [string]$Target,
  [string]$Exe,
  [int]$Pid,
  [string]$Temp,
  [string]$AppLog,
  [string]$PendingMarker
)

$ErrorActionPreference = 'Stop'
$TargetDir = Split-Path -Parent $Exe
$LogPath = Join-Path $TargetDir 'update.log'
function Write-UpdateLog([string]$Message) {
  try { Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message) -Encoding UTF8 } catch {}
  try { if ($AppLog) { Add-Content -LiteralPath $AppLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message) -Encoding UTF8 } } catch {}
}

try {
  Write-UpdateLog 'Updater started.'
  Start-Sleep -Milliseconds 800
  try { Wait-Process -Id $Pid -Timeout 30 -ErrorAction SilentlyContinue } catch {}

  $SourceExe = Join-Path $Source 'City.Stamina.Spender.exe'
  if (-not (Test-Path -LiteralPath $SourceExe)) {
    $SourceExe = Join-Path $Source 'City Stamina Spender.exe'
  }
  if (-not (Test-Path -LiteralPath $SourceExe)) {
    throw 'Downloaded exe was not found.'
  }
  $SourceLength = (Get-Item -LiteralPath $SourceExe).Length
  Write-UpdateLog ('Source exe: ' + $SourceExe + ' bytes=' + $SourceLength)

  $NewExe = $Exe + '.new'
  Copy-Item -LiteralPath $SourceExe -Destination $NewExe -Force

  $updated = $false
  for ($i = 1; $i -le 60; $i++) {
    try {
      Copy-Item -LiteralPath $NewExe -Destination $Exe -Force
      $TargetLength = (Get-Item -LiteralPath $Exe).Length
      if ($TargetLength -eq $SourceLength) {
        $updated = $true
        Write-UpdateLog ('Update copied on attempt ' + $i + '. bytes=' + $TargetLength)
        break
      }
      Write-UpdateLog ('Copy attempt ' + $i + ' size mismatch target=' + $TargetLength + ' source=' + $SourceLength)
    } catch {
      Write-UpdateLog ('Copy attempt ' + $i + ' failed: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $updated) {
    throw 'Could not replace the running exe after multiple attempts.'
  }

  try { Remove-Item -LiteralPath $NewExe -Force } catch {}
  foreach ($AltName in @('City.Stamina.Spender.exe', 'City Stamina Spender.exe')) {
    $AltExe = Join-Path $TargetDir $AltName
    if ($AltExe -ne $Exe) {
      try {
        Copy-Item -LiteralPath $SourceExe -Destination $AltExe -Force
        Write-UpdateLog ('Synced alternate exe: ' + $AltExe)
      } catch {
        Write-UpdateLog ('Alternate exe sync skipped: ' + $AltExe + ' | ' + $_.Exception.Message)
      }
    }
  }
  Start-Process -FilePath $Exe -WorkingDirectory $TargetDir
  Start-Sleep -Seconds 2
  try { Remove-Item -LiteralPath $Temp -Recurse -Force } catch {}
  try { if ($PendingMarker) { Remove-Item -LiteralPath $PendingMarker -Force } } catch {}
  Write-UpdateLog 'Updater finished.'
} catch {
  Write-UpdateLog ('Updater failed: ' + $_.Exception.Message)
  try { if ($PendingMarker) { Remove-Item -LiteralPath $PendingMarker -Force } } catch {}
  if ($SourceExe -and (Test-Path -LiteralPath $SourceExe)) {
    Write-UpdateLog 'Starting downloaded exe as fallback.'
    try { Start-Process -FilePath $SourceExe -WorkingDirectory (Split-Path -Parent $SourceExe) } catch {}
  } else {
    try { Start-Process -FilePath $Exe -WorkingDirectory $TargetDir } catch {}
  }
  exit 1
}
"""
            : """
param(
  [string]$Source,
  [string]$Target,
  [string]$Exe,
  [int]$Pid,
  [string]$Temp,
  [string]$AppLog,
  [string]$PendingMarker
)

$ErrorActionPreference = 'Stop'
$TargetDir = Split-Path -Parent $Exe
$LogPath = Join-Path $TargetDir 'update.log'
function Write-UpdateLog([string]$Message) {
  try { Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message) -Encoding UTF8 } catch {}
  try { if ($AppLog) { Add-Content -LiteralPath $AppLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message) -Encoding UTF8 } } catch {}
}

try {
  Write-UpdateLog 'Updater started.'
  Start-Sleep -Milliseconds 800
  try { Wait-Process -Id $Pid -Timeout 30 -ErrorAction SilentlyContinue } catch {}

  $SourceExe = Join-Path $Source 'City.Stamina.Spender.exe'
  if (-not (Test-Path -LiteralPath $SourceExe)) {
    $SourceExe = Join-Path $Source 'City Stamina Spender.exe'
  }
  if (-not (Test-Path -LiteralPath $SourceExe)) {
    throw 'Downloaded exe was not found.'
  }
  $SourceLength = (Get-Item -LiteralPath $SourceExe).Length
  Write-UpdateLog ('Source exe: ' + $SourceExe + ' bytes=' + $SourceLength)

  $NewExe = $Exe + '.new'
  Copy-Item -LiteralPath $SourceExe -Destination $NewExe -Force

  $updated = $false
  for ($i = 1; $i -le 60; $i++) {
    try {
      Copy-Item -LiteralPath $NewExe -Destination $Exe -Force
      $TargetLength = (Get-Item -LiteralPath $Exe).Length
      if ($TargetLength -eq $SourceLength) {
        $updated = $true
        Write-UpdateLog ('Update copied on attempt ' + $i + '. bytes=' + $TargetLength)
        break
      }
      Write-UpdateLog ('Copy attempt ' + $i + ' size mismatch target=' + $TargetLength + ' source=' + $SourceLength)
    } catch {
      Write-UpdateLog ('Copy attempt ' + $i + ' failed: ' + $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $updated) {
    throw 'Could not replace the running exe after multiple attempts.'
  }

  if (Test-Path -LiteralPath (Join-Path $Source 'app_data')) {
    Copy-Item -LiteralPath (Join-Path $Source 'app_data') -Destination $Target -Recurse -Force
  } else {
    $DataTarget = Join-Path $Target 'app_data'
    if (-not (Test-Path -LiteralPath $DataTarget)) { New-Item -ItemType Directory -Path $DataTarget | Out-Null }
    Copy-Item -LiteralPath (Join-Path $Source 'web_ui') -Destination $DataTarget -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $Source 'owners_selection') -Destination $DataTarget -Recurse -Force
    if (Test-Path -LiteralPath (Join-Path $Source 'latest.json')) {
      Copy-Item -LiteralPath (Join-Path $Source 'latest.json') -Destination $DataTarget -Force
    }
  }
  if (Test-Path -LiteralPath (Join-Path $Source 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $Source 'README.md') -Destination $Target -Force
  }

  try { Remove-Item -LiteralPath $NewExe -Force } catch {}
  foreach ($AltName in @('City.Stamina.Spender.exe', 'City Stamina Spender.exe')) {
    $AltExe = Join-Path $TargetDir $AltName
    if ($AltExe -ne $Exe) {
      try {
        Copy-Item -LiteralPath $SourceExe -Destination $AltExe -Force
        Write-UpdateLog ('Synced alternate exe: ' + $AltExe)
      } catch {
        Write-UpdateLog ('Alternate exe sync skipped: ' + $AltExe + ' | ' + $_.Exception.Message)
      }
    }
  }
  Start-Process -FilePath $Exe -WorkingDirectory $TargetDir
  Start-Sleep -Seconds 2
  try { Remove-Item -LiteralPath $Temp -Recurse -Force } catch {}
  try { if ($PendingMarker) { Remove-Item -LiteralPath $PendingMarker -Force } } catch {}
  Write-UpdateLog 'Updater finished.'
} catch {
  Write-UpdateLog ('Updater failed: ' + $_.Exception.Message)
  try { if ($PendingMarker) { Remove-Item -LiteralPath $PendingMarker -Force } } catch {}
  if ($SourceExe -and (Test-Path -LiteralPath $SourceExe)) {
    Write-UpdateLog 'Starting downloaded exe as fallback.'
    try { Start-Process -FilePath $SourceExe -WorkingDirectory (Split-Path -Parent $SourceExe) } catch {}
  } else {
    try { Start-Process -FilePath $Exe -WorkingDirectory $TargetDir } catch {}
  }
  exit 1
}
""";
        File.WriteAllText(scriptPath, script, Encoding.UTF8);
        return scriptPath;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static bool IsDevelopmentLayout(string dataDir)
    {
        var normalized = Path.TrimEndingDirectorySeparator(dataDir);
        return Path.GetFileName(normalized).Equals("source", StringComparison.OrdinalIgnoreCase)
            || Directory.Exists(Path.Combine(normalized, "desktop_app"));
    }

    private static bool HasOwnerTool(string dataDir)
    {
        var toolDir = Path.Combine(EmbeddedAppData.GetOwnersSelectionDir(dataDir), "_tool");
        return File.Exists(Path.Combine(toolDir, "stage_1_9.py"))
            || File.Exists(Path.Combine(toolDir, "OwnerSelectionTool.exe"));
    }

    private static (string RootDir, string DataDir) FindApplicationDirectories()
    {
        if (EmbeddedAppData.FindDevelopmentSourceDir() is { } sourceDir)
        {
            return (Directory.GetParent(sourceDir)?.FullName ?? Directory.GetCurrentDirectory(), sourceDir);
        }

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            // Prefer an explicit source layout while debugging, even if a stale
            // app_data folder also exists beside the repository.
            var sourceDataDir = Path.Combine(directory.FullName, "source");
            if (HasOwnerTool(sourceDataDir))
            {
                return (directory.FullName, sourceDataDir);
            }

            var nestedDataDir = Path.Combine(directory.FullName, "app_data");
            if (HasOwnerTool(nestedDataDir))
            {
                return (directory.FullName, nestedDataDir);
            }

            if (HasOwnerTool(directory.FullName))
            {
                return (directory.FullName, directory.FullName);
            }

            directory = directory.Parent;
        }

        if (EmbeddedAppData.HasUsableAppData(EmbeddedAppData.LocalDataDir))
        {
            return (Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory, EmbeddedAppData.LocalDataDir);
        }

        var current = Directory.GetCurrentDirectory();
        var currentDataDir = Path.Combine(current, "app_data");
        return Directory.Exists(currentDataDir) ? (current, currentDataDir) : (current, current);
    }

    private readonly record struct GameWindowInfo(string Title, int Width, int Height, nint Hwnd);

    private static GameWindowInfo? FindGameWindow()
    {
        ConfigureDpiAwareness();
        var candidates = new List<GameWindowInfo>();

        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd))
            {
                return true;
            }

            var title = GetWindowTitle(hwnd).Trim();
            var className = GetClassName(hwnd);
            if (string.IsNullOrWhiteSpace(title) && className != "UnrealWindow")
            {
                return true;
            }

            if (!GetClientRect(hwnd, out var rect) || !TryClientToScreen(hwnd, out var origin))
            {
                return true;
            }

            var width = rect.Right - rect.Left;
            var height = rect.Bottom - rect.Top;
            if (width < 900 || height < 500)
            {
                return true;
            }

            var aspect = width / Math.Max(1.0, height);
            if (aspect < 1.6 || aspect > 2.45)
            {
                return true;
            }

            var isNteTitle = title.Contains("nte", StringComparison.OrdinalIgnoreCase);
            var isUnrealWindow = className == "UnrealWindow";
            if (!isNteTitle && !isUnrealWindow)
            {
                return true;
            }

            candidates.Add(new GameWindowInfo(
                string.IsNullOrWhiteSpace(title) ? "NTE" : title,
                width,
                height,
                hwnd
            ));
            return true;
        }, 0);

        return candidates
            .OrderBy(item => item.Title.Equals("NTE", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenBy(item => Math.Abs(item.Height - item.Width * 720.0 / 1280.0))
            .FirstOrDefault();
    }

    private static string GetWindowTitle(nint hwnd)
    {
        var length = GetWindowTextLength(hwnd);
        if (length <= 0)
        {
            return "";
        }

        var builder = new StringBuilder(length + 1);
        _ = GetWindowText(hwnd, builder, builder.Capacity);
        return builder.ToString();
    }

    private static string GetClassName(nint hwnd)
    {
        var builder = new StringBuilder(256);
        _ = GetClassName(hwnd, builder, builder.Capacity);
        return builder.ToString();
    }

    private static void ConfigureDpiAwareness()
    {
        try
        {
            _ = SetProcessDpiAwareness(2);
        }
        catch
        {
            try
            {
                _ = SetProcessDPIAware();
            }
            catch
            {
                // DPI awareness is best effort.
            }
        }
    }

    private delegate bool EnumWindowsProc(nint hwnd, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, nint lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(nint hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(nint hwnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(nint hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint hwnd, StringBuilder className, int count);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(nint hwnd, out Rect rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(nint hwnd, ref Point point);

    private static bool TryClientToScreen(nint hwnd, out Point point)
    {
        point = new Point();
        return ClientToScreen(hwnd, ref point);
    }

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int awareness);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();
}
