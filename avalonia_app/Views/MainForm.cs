using System;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Windows.Forms;
using CityStamina.Avalonia.ViewModels;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace CityStamina.Avalonia.Views;

public sealed class MainForm : Form
{
    private readonly MainViewModel _viewModel;
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill };
    private bool _webReady;

    public MainForm(MainViewModel viewModel)
    {
        _viewModel = viewModel;
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
        FormClosed += (_, _) => _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
    }

    private async void OnLoad(object? sender, EventArgs e)
    {
        await _webView.EnsureCoreWebView2Async();
        _webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        _webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
        _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;

        var indexPath = Path.Combine(FindRootDirectory(), "web_ui", "index.html");
        _webView.CoreWebView2.Navigate(new Uri(indexPath).AbsoluteUri);
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
            BeginInvoke(PostState);
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
            case "newAutomation":
                if (root.TryGetProperty("search", out var search))
                {
                    _viewModel.SearchQuery = search.GetString() ?? "";
                }
                ExecuteIfPossible(_viewModel.NewAutomationCommand);
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
        };

        var json = JsonSerializer.Serialize(state);
        _webView.CoreWebView2.PostWebMessageAsJson(json);
    }

    private static string FindRootDirectory()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "web_ui", "index.html")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        return Directory.GetCurrentDirectory();
    }
}
