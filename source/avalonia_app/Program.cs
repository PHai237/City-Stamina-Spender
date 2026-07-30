using System;
using System.Windows.Forms;
using CityStamina.Avalonia.ViewModels;
using CityStamina.Avalonia.Views;

namespace CityStamina.Avalonia;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        EmbeddedAppData.EnsureAvailable(MainViewModel.AppVersion);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm(new MainViewModel()));
    }
}
