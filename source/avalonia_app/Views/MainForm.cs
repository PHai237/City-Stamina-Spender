using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;
using CityStamina.Avalonia.ViewModels;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace CityStamina.Avalonia.Views;

public sealed class MainForm : Form
{
    private const int WhKeyboardLl = 13;
    private const int WmKeydown = 0x0100;
    private const int WmSyskeydown = 0x0104;
    private const uint VkF5 = 0x74;

    private readonly MainViewModel _viewModel;
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill };
    private readonly LowLevelKeyboardProc _keyboardProc;
    private bool _webReady;
    private IntPtr _keyboardHook;

    public MainForm(MainViewModel viewModel)
    {
        _viewModel = viewModel;
        _keyboardProc = KeyboardHookCallback;
        Text = "City Stamina Spender";
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new System.Drawing.Size(960, 640);
        MinimumSize = Size;
        MaximumSize = Size;

        Controls.Add(_webView);
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        Load += OnLoad;
        FormClosed += (_, _) =>
        {
            if (_keyboardHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_keyboardHook);
                _keyboardHook = IntPtr.Zero;
            }
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        };
    }

    private async void OnLoad(object? sender, EventArgs e)
    {
        await _webView.EnsureCoreWebView2Async();
        _webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        _webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
        _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;

        var indexPath = FindWebUiIndexPath();
        _webView.CoreWebView2.Navigate(new Uri(indexPath).AbsoluteUri);
        InstallKeyboardHook();
    }

    private void InstallKeyboardHook()
    {
        _keyboardHook = SetWindowsHookEx(
            WhKeyboardLl,
            _keyboardProc,
            GetModuleHandle(null),
            0
        );

        if (_keyboardHook == IntPtr.Zero)
        {
            _viewModel.ReportHotkey($"F5 hotkey failed: {Marshal.GetLastWin32Error()}");
            return;
        }

        _viewModel.ReportHotkey("F5 hotkey ready.");
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        _webReady = true;
        PostState();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (IsDisposed)
        {
            return;
        }

        if (InvokeRequired)
        {
            BeginInvoke(() =>
            {
                PostState();
            });
            return;
        }

        PostState();
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var document = JsonDocument.Parse(e.WebMessageAsJson);
        var root = document.RootElement;
        if (!root.TryGetProperty("type", out var typeElement))
        {
            return;
        }

        var type = typeElement.GetString() ?? "";
        switch (type)
        {
            case "openOwner":
                ExecuteIfPossible(_viewModel.OpenOwnerCommand);
                break;
            case "back":
                ExecuteIfPossible(_viewModel.BackToHubCommand);
                break;
            case "checkUpdate":
                ExecuteIfPossible(_viewModel.CheckUpdateCommand);
                break;
            case "update":
                ExecuteIfPossible(_viewModel.UpdateCommand);
                break;
            case "setSearch":
                _viewModel.SearchQuery = root.GetProperty("value").GetString() ?? "";
                break;
            case "setStage":
                _viewModel.SelectedStage = root.GetProperty("value").GetString() ?? "Stage 1-9";
                break;
            case "setTarget":
                _viewModel.TargetStamina = root.GetProperty("value").GetString() ?? "";
                break;
            case "run":
                var amount = root.TryGetProperty("amount", out var amountElement)
                    ? amountElement.GetString() ?? ""
                    : _viewModel.TargetStamina;
                _viewModel.TargetStamina = amount;
                if (_viewModel.RunCommand.CanExecute(amount))
                {
                    _viewModel.RunCommand.Execute(amount);
                }
                break;
            case "stop":
                ExecuteIfPossible(_viewModel.StopCommand);
                break;
        }
    }

    private static void ExecuteIfPossible(System.Windows.Input.ICommand command)
    {
        if (command.CanExecute(null))
        {
            command.Execute(null);
        }
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (
            nCode >= 0
            && (wParam == WmKeydown || wParam == WmSyskeydown)
            && (uint)Marshal.ReadInt32(lParam) == VkF5
        )
        {
            if (!IsDisposed)
            {
                BeginInvoke(ToggleRunFromHotkey);
            }
            return 1;
        }

        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private void ToggleRunFromHotkey()
    {
        if (_viewModel.IsRunning)
        {
            _viewModel.ReportHotkey("F5: Stop.");
            ExecuteIfPossible(_viewModel.StopCommand);
            return;
        }

        if (!_viewModel.IsDetailVisible)
        {
            _viewModel.ReportHotkey("F5: Open Owner's Selection first.");
            return;
        }

        var amount = _viewModel.TargetStamina;
        if (_viewModel.RunCommand.CanExecute(amount))
        {
            _viewModel.ReportHotkey("F5: Run.");
            _viewModel.RunCommand.Execute(amount);
            return;
        }

        _viewModel.ReportHotkey("F5: Enter target amount first.");
    }

    private void PostState()
    {
        if (!_webReady || _webView.CoreWebView2 is null)
        {
            return;
        }

        var state = new
        {
            title = _viewModel.Title,
            selectedStage = _viewModel.SelectedStage,
            stageOptions = _viewModel.StageOptions,
            targetStamina = _viewModel.TargetStamina,
            spentSoFar = _viewModel.SpentSoFar,
            elapsed = _viewModel.Elapsed,
            ordersDetected = _viewModel.OrdersDetected,
            ordersDone = _viewModel.OrdersDone,
            calibrationStatus = _viewModel.CalibrationStatus,
            logText = _viewModel.LogText,
            searchQuery = _viewModel.SearchQuery,
            automationCount = _viewModel.AutomationCount,
            readyModulesCount = _viewModel.ReadyModulesCount,
            runningNowCount = _viewModel.RunningNowCount,
            runsTodayCount = _viewModel.RunsTodayCount,
            gamesCount = _viewModel.GamesCount,
            isHubVisible = _viewModel.IsHubVisible,
            isDetailVisible = _viewModel.IsDetailVisible,
            isRunning = _viewModel.IsRunning,
            currentVersion = _viewModel.CurrentVersion,
            latestVersion = _viewModel.LatestVersion,
            updateState = _viewModel.UpdateState,
            updateMessage = _viewModel.UpdateMessage,
            updateProgress = _viewModel.UpdateProgress,
            isUpdateAvailable = _viewModel.IsUpdateAvailable,
        };

        var json = JsonSerializer.Serialize(state);
        _webView.CoreWebView2.PostWebMessageAsJson(json);
    }

    private static string FindWebUiIndexPath()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var nestedIndexPath = Path.Combine(directory.FullName, "app_data", "web_ui", "index.html");
            if (File.Exists(nestedIndexPath))
            {
                return nestedIndexPath;
            }

            var indexPath = Path.Combine(directory.FullName, "web_ui", "index.html");
            if (File.Exists(indexPath))
            {
                return indexPath;
            }

            var sourceIndexPath = Path.Combine(directory.FullName, "source", "web_ui", "index.html");
            if (File.Exists(sourceIndexPath))
            {
                return sourceIndexPath;
            }

            directory = directory.Parent;
        }

        var embeddedIndexPath = Path.Combine(EmbeddedAppData.LocalDataDir, "web_ui", "index.html");
        if (File.Exists(embeddedIndexPath))
        {
            return embeddedIndexPath;
        }

        return Path.Combine(Directory.GetCurrentDirectory(), "web_ui", "index.html");
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelKeyboardProc lpfn,
        IntPtr hMod,
        uint dwThreadId
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
