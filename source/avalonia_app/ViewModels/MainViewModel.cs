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
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace CityStamina.Avalonia.ViewModels;

public partial class MainViewModel : ViewModelBase
{
    public const string AppVersion = "1.2.3";
    private const string LatestManifestUrl = "https://raw.githubusercontent.com/PHai237/City-Stamina-Spender/main/latest.json";
    private const string StageOneNine = "Stage 1-9";
    private const string StageOneOne = "Stage 1-1";
    private const int MaxUiLogLines = 14;

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
    private readonly string _recipePlayerPath;
    private readonly string _itemRunnerPath;
    private readonly string _ownerToolExePath;
    private readonly string _wrapperLogPath;
    private readonly bool _preferPythonSource;
    private readonly Queue<string> _uiLogLines = new();
    private readonly object _debugLogLock = new();
    private Process? _ownerProcess;
    private readonly Stopwatch _runStopwatch = new();
    private System.Timers.Timer? _elapsedTimer;
    private bool _stopRequested;
    private int _sessionSpent;
    private int _currentRunSpent;
    private int _runsToday;
    private string _latestDownloadUrl = "";
    private string _lastUiLogLine = "";

    public MainViewModel()
    {
        (_rootDir, _dataDir) = FindApplicationDirectories();
        _ownerToolDir = Path.Combine(_dataDir, "owners_selection", "_tool");
        _ownerToolPath = Path.Combine(_ownerToolDir, "stage_1_9.py");
        _recipePlayerPath = Path.Combine(_ownerToolDir, "stage_1_1_recipe_player.py");
        _itemRunnerPath = Path.Combine(_ownerToolDir, "stage_1_1_item_runner.py");
        _ownerToolExePath = Path.Combine(_ownerToolDir, "OwnerSelectionTool.exe");
        _wrapperLogPath = Path.Combine(_ownerToolDir, "wrapper_debug", "run.log");
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
    private string _selectedStage = StageOneNine;

    public IReadOnlyList<string> StageOptions { get; } = [StageOneNine, StageOneOne];

    public bool IsStageOneNineSelected => SelectedStage == StageOneNine;

    public bool IsStageOneOneSelected => SelectedStage == StageOneOne;

    [ObservableProperty]
    private string _targetStamina = "";

    [ObservableProperty]
    private string _spentSoFar = "--";

    [ObservableProperty]
    private string _elapsed = "00:00";

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
        IsRunning = true;
        _runsToday++;
        RefreshHubMetrics();
        _currentRunSpent = 0;
        SpentSoFar = FormatAmount(_sessionSpent);
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

            AppendLog("Checking Support Employee...");
            if (!await PrepareSupportEmployeeAsync(SelectedStageArg))
            {
                if (!_stopRequested)
                {
                    AppendLog("Support Employee check failed.");
                }
                return;
            }

            if (_stopRequested)
            {
                return;
            }

            using var process = StartOwnerProcess(amount, SelectedStageArg, skipSupportEmployeeCheck: true);
            var exitCode = await RunTrackedProcessAsync(process, HandleAutomationLine, showErrorsInUi: true);
            if (_stopRequested)
            {
                AppendLog("Stopped.");
            }
            else if (exitCode == 0)
            {
                AppendLog("Completed.");
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
            if (_stopRequested)
            {
                AppendLog("Stopped.");
            }
            _ownerProcess = null;
            _sessionSpent += _currentRunSpent;
            _currentRunSpent = 0;
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

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task TestItemTwoAsync()
    {
        _stopRequested = false;
        IsRunning = true;
        RefreshHubMetrics();
        SetRunLog("Testing item 2 recipe...");

        try
        {
            if (!File.Exists(_recipePlayerPath))
            {
                AppendLog("Recipe player was not found.");
                return;
            }

            var exitCode = await RunProcessToLogAsync(
                "python",
                $"-u \"{_recipePlayerPath}\" white_coffee",
                _ownerToolDir,
                logOutput: true
            );

            AppendLog(exitCode == 0 ? "Item 2 test completed." : "Item 2 test stopped.");
        }
        catch (Exception ex)
        {
            AppendLog($"Item 2 test stopped. {ex.Message}");
        }
        finally
        {
            IsRunning = false;
            RefreshHubMetrics();
        }
    }

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task AutoItemOneAsync()
    {
        _stopRequested = false;
        IsRunning = true;
        RefreshHubMetrics();
        SetRunLog("Auto item 1 running...");

        try
        {
            if (!File.Exists(_itemRunnerPath))
            {
                AppendLog("Item runner was not found.");
                return;
            }

            var exitCode = await RunProcessToLogAsync(
                "python",
                $"-u \"{_itemRunnerPath}\" 1 --watch 60 --interval 0.25 --threshold 0.82",
                _ownerToolDir,
                logOutput: true
            );

            AppendLog(exitCode == 0 ? "Auto item 1 completed." : "Auto item 1 stopped.");
        }
        catch (Exception ex)
        {
            AppendLog($"Auto item 1 stopped. {ex.Message}");
        }
        finally
        {
            IsRunning = false;
            RefreshHubMetrics();
        }
    }

    [RelayCommand]
    private async Task CheckUpdateAsync()
    {
        try
        {
            UpdateState = "checking";
            UpdateMessage = "Checking for updates...";

            using var client = CreateHttpClient();
            var manifestUrl = LatestManifestUrl + "?t=" + DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
            var json = await client.GetStringAsync(manifestUrl);
            var manifest = JsonSerializer.Deserialize<UpdateManifest>(
                json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }
            );

            LatestVersion = string.IsNullOrWhiteSpace(manifest?.Version) ? AppVersion : manifest.Version.Trim();
            _latestDownloadUrl = manifest?.Url?.Trim() ?? "";

            if (CompareVersions(LatestVersion, AppVersion) > 0 && !string.IsNullOrWhiteSpace(_latestDownloadUrl))
            {
                UpdateState = "available";
                UpdateMessage = $"Version {LatestVersion} is available.";
                return;
            }

            UpdateState = "latest";
            UpdateMessage = "You are on the latest version.";
        }
        catch
        {
            UpdateState = "error";
            UpdateMessage = "Could not check updates.";
        }
    }

    [RelayCommand]
    private async Task UpdateAsync()
    {
        if (IsRunning)
        {
            UpdateState = "error";
            UpdateMessage = "Stop the automation before updating.";
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
            UpdateState = "updating";
            UpdateMessage = $"Downloading version {LatestVersion}...";

            var tempDir = Path.Combine(Path.GetTempPath(), "CityStaminaUpdate_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempDir);
            var isExeUpdate = _latestDownloadUrl.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
            var downloadPath = Path.Combine(tempDir, isExeUpdate ? "City Stamina Spender.exe" : "update.zip");

            using var client = CreateHttpClient();
            await using (var source = await client.GetStreamAsync(_latestDownloadUrl))
            await using (var target = File.Create(downloadPath))
            {
                await source.CopyToAsync(target);
            }

            string? sourceDir = null;
            if (!isExeUpdate)
            {
                var extractDir = Path.Combine(tempDir, "extract");
                Directory.CreateDirectory(extractDir);
                ZipFile.ExtractToDirectory(downloadPath, extractDir, overwriteFiles: true);
                sourceDir = FindExtractedUpdateDirectory(extractDir);
            }
            var scriptPath = WriteUpdaterScript(tempDir, isExeUpdate);

            var currentExe = Environment.ProcessPath ?? Path.Combine(_rootDir, "City Stamina Spender.exe");
            var args =
                "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath) +
                " -Source " + Quote(sourceDir ?? tempDir) +
                " -Target " + Quote(_rootDir) +
                " -Exe " + Quote(currentExe) +
                " -Pid " + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) +
                " -Temp " + Quote(tempDir);

            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell",
                Arguments = args,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = _rootDir,
            });

            Environment.Exit(0);
        }
        catch (Exception ex)
        {
            UpdateState = "error";
            UpdateMessage = "Update failed: " + ex.Message;
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
        var arguments = amount.ToString(CultureInfo.InvariantCulture) + $" --stage {stage}";
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

    private async Task<bool> PrepareSupportEmployeeAsync(string stage)
    {
        var command = ResolveOwnerCommand($"--prepare-support-only --stage {stage}");
        return await RunProcessToLogAsync(
            command.FileName,
            command.Arguments,
            _ownerToolDir,
            logOutput: true
        ) == 0;
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
            @"\bTarget reached:\s*spent\s+([\d,.]+)\s*>=",
        };

        foreach (var pattern in patterns)
        {
            var match = Regex.Match(line, pattern, RegexOptions.IgnoreCase);
            if (!match.Success)
            {
                continue;
            }

            _currentRunSpent = ParseAmount(match.Groups[1].Value);
            SpentSoFar = FormatAmount(_sessionSpent + _currentRunSpent);
            return;
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
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("City-Stamina-Spender/" + AppVersion);
        return client;
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
  [string]$Temp
)

$ErrorActionPreference = 'Stop'
Start-Sleep -Milliseconds 800
try { Wait-Process -Id $Pid -ErrorAction SilentlyContinue } catch {}

Copy-Item -LiteralPath (Join-Path $Source 'City Stamina Spender.exe') -Destination $Exe -Force
Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
Start-Sleep -Seconds 2
try { Remove-Item -LiteralPath $Temp -Recurse -Force } catch {}
"""
            : """
param(
  [string]$Source,
  [string]$Target,
  [string]$Exe,
  [int]$Pid,
  [string]$Temp
)

$ErrorActionPreference = 'Stop'
Start-Sleep -Milliseconds 800
try { Wait-Process -Id $Pid -ErrorAction SilentlyContinue } catch {}

Copy-Item -LiteralPath (Join-Path $Source 'City Stamina Spender.exe') -Destination $Target -Force
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

Start-Process -FilePath $Exe -WorkingDirectory $Target
Start-Sleep -Seconds 2
try { Remove-Item -LiteralPath $Temp -Recurse -Force } catch {}
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
            || Directory.Exists(Path.Combine(normalized, "avalonia_app"));
    }

    private static bool HasOwnerTool(string dataDir)
    {
        var toolDir = Path.Combine(dataDir, "owners_selection", "_tool");
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
