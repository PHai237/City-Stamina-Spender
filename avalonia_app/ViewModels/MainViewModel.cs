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
    public const string AppVersion = "1.2.0";
    private const string LatestManifestUrl = "https://raw.githubusercontent.com/PHai237/City-Stamina-Spender/main/latest.json";
    private const string StageOneNine = "Stage 1-9";
    private const string StageOneOne = "Stage 1-1";

    private sealed record AutomationModule(string Id, string Name, string Category, bool IsReady);
    private sealed record UpdateManifest(string? Version, string? Url, string? Notes);

    private readonly List<AutomationModule> _modules =
    [
        new("owners_selection", "Owner's Selection", "Games", true),
    ];

    private readonly string _rootDir;
    private readonly string _dataDir;
    private readonly string _ownerToolDir;
    private readonly string _ownerToolPath;
    private readonly string _ownerToolExePath;
    private readonly string _requirementsPath;
    private Process? _ownerProcess;
    private readonly Stopwatch _runStopwatch = new();
    private System.Timers.Timer? _elapsedTimer;
    private int _sessionSpent;
    private int _currentRunSpent;
    private int _runsToday;
    private string _latestDownloadUrl = "";

    public MainViewModel()
    {
        (_rootDir, _dataDir) = FindApplicationDirectories();
        _ownerToolDir = Path.Combine(_dataDir, "owners_selection", "_tool");
        _ownerToolPath = Path.Combine(_ownerToolDir, "stage_1_9.py");
        _ownerToolExePath = Path.Combine(_ownerToolDir, "OwnerSelectionTool.exe");
        _requirementsPath = Path.Combine(_dataDir, "owners_selection", "requirements.txt");
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

        if (SelectedStage == StageOneOne)
        {
            SetRunLog($"Run 1: 0/{FormatAmount(amount)} City Stamina");
            AppendLog("  Line 1: Stage 1-1 coffee automation is not wired yet.");
            AppendLog("  Line 2: Internal rule ready: 2-3 cups per order.");
            return;
        }

        IsRunning = true;
        _runsToday++;
        RefreshHubMetrics();
        _currentRunSpent = 0;
        SpentSoFar = FormatAmount(_sessionSpent);
        StartElapsedTimer();

        try
        {
            SetRunLog("Checking dependencies...");
            if (!File.Exists(_ownerToolExePath) && !File.Exists(_ownerToolPath))
            {
                AppendLog("Owner's Selection tool was not found.");
                return;
            }

            if (!await DependenciesReadyAsync(logWhenReady: false))
            {
                AppendLog("Dependency check failed.");
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
            if (!await PrepareSupportEmployeeAsync())
            {
                AppendLog("Support Employee check failed.");
                return;
            }

            _ownerProcess = StartOwnerProcess(amount, skipSupportEmployeeCheck: true);

            if (_ownerProcess.StandardOutput is null)
            {
                AppendLog("Stopped.");
                return;
            }

            while (await _ownerProcess.StandardOutput.ReadLineAsync() is { } line)
            {
                HandleAutomationLine(line);
            }

            await _ownerProcess.WaitForExitAsync();
            if (_ownerProcess.ExitCode == 0)
            {
                AppendLog("Completed.");
            }
            else
            {
                AppendLog("Stopped.");
            }
        }
        catch (Exception ex)
        {
            AppendLog($"Stopped. {ex.Message}");
        }
        finally
        {
            _ownerProcess?.Dispose();
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

        AppendLog("Stopped.");
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
            var extractDir = Path.Combine(tempDir, "extract");
            var zipPath = Path.Combine(tempDir, "update.zip");
            Directory.CreateDirectory(extractDir);

            using var client = CreateHttpClient();
            await using (var source = await client.GetStreamAsync(_latestDownloadUrl))
            await using (var target = File.Create(zipPath))
            {
                await source.CopyToAsync(target);
            }

            ZipFile.ExtractToDirectory(zipPath, extractDir, overwriteFiles: true);
            var sourceDir = FindExtractedUpdateDirectory(extractDir);
            var scriptPath = WriteUpdaterScript(tempDir, sourceDir);

            var currentExe = Path.Combine(_rootDir, "City Stamina Spender.exe");
            var args =
                "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptPath) +
                " -Source " + Quote(sourceDir) +
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
            CreateNoWindow = true,
        };

        return Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start process.");
    }

    private Process StartOwnerProcess(int amount, bool skipSupportEmployeeCheck)
    {
        var skipSupportArg = skipSupportEmployeeCheck ? " --skip-support-employee-check" : "";
        if (File.Exists(_ownerToolExePath))
        {
            return StartProcess(
                _ownerToolExePath,
                amount.ToString(CultureInfo.InvariantCulture) + skipSupportArg,
                _ownerToolDir
            );
        }

        return StartProcess(
            "python",
            $"-u \"{_ownerToolPath}\" {amount.ToString(CultureInfo.InvariantCulture)}{skipSupportArg}",
            _ownerToolDir
        );
    }

    private async Task<bool> PrepareSupportEmployeeAsync()
    {
        if (File.Exists(_ownerToolExePath))
        {
            return await RunProcessToLogAsync(
                _ownerToolExePath,
                "--prepare-support-only",
                _ownerToolDir,
                logOutput: true
            ) == 0;
        }

        if (!File.Exists(_ownerToolPath))
        {
            return false;
        }

        return await RunProcessToLogAsync(
            "python",
            $"-u \"{_ownerToolPath}\" --prepare-support-only",
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
        while (await process.StandardOutput.ReadLineAsync() is { } line)
        {
            if (logOutput)
            {
                AppendLog(line);
            }
        }

        var errors = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        if (process.ExitCode != 0 && !string.IsNullOrWhiteSpace(errors))
        {
            AppendLog(errors.Trim());
        }

        return process.ExitCode;
    }

    private async Task<(int ExitCode, string Text)> CaptureProcessOutputAsync(
        string fileName,
        string arguments,
        string workingDirectory)
    {
        using var process = StartProcess(fileName, arguments, workingDirectory);
        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return (process.ExitCode, string.IsNullOrWhiteSpace(stdout) ? stderr : stdout);
    }

    private async Task<bool> DependenciesReadyAsync(bool logWhenReady)
    {
        if (File.Exists(_ownerToolExePath))
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
        if (Regex.IsMatch(line, @"^Run\s+\d+:", RegexOptions.IgnoreCase))
        {
            SetRunLog(line);
        }
        else
        {
            AppendLog(line);
        }

        UpdateSpentFromLog(line);
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
        LogText = message + Environment.NewLine;
    }

    private void AppendLog(string message)
    {
        LogText += message + Environment.NewLine;
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

    private static string WriteUpdaterScript(string tempDir, string sourceDir)
    {
        var scriptPath = Path.Combine(tempDir, "apply_update.ps1");
        var script = """
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
        _ = sourceDir;
        return scriptPath;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static (string RootDir, string DataDir) FindApplicationDirectories()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var nestedDataDir = Path.Combine(directory.FullName, "app_data");
            if (File.Exists(Path.Combine(nestedDataDir, "owners_selection", "_tool", "stage_1_9.py")))
            {
                return (directory.FullName, nestedDataDir);
            }

            if (File.Exists(Path.Combine(directory.FullName, "owners_selection", "_tool", "stage_1_9.py")))
            {
                return (directory.FullName, directory.FullName);
            }

            directory = directory.Parent;
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
