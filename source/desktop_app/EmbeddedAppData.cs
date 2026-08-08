using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;

namespace CityStamina.Avalonia;

internal static class EmbeddedAppData
{
    private const string ResourceName = "CityStamina.AppData.zip";
    private const string AppDataFolderName = "app_data";

    public static string LocalRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CityStaminaSpender");

    public static string LocalDataDir => Path.Combine(LocalRoot, AppDataFolderName);

    public static void EnsureAvailable(string version)
    {
        if (FindDevelopmentSourceDir() is not null)
        {
            return;
        }

        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(ResourceName);
        if (stream is null)
        {
            return;
        }

        var markerPath = Path.Combine(LocalDataDir, ".app_data_version");
        if (HasUsableAppData(LocalDataDir) && File.Exists(markerPath))
        {
            var currentVersion = File.ReadAllText(markerPath).Trim();
            if (currentVersion == version)
            {
                return;
            }
        }

        Directory.CreateDirectory(LocalRoot);
        var tempDir = Path.Combine(LocalRoot, "app_data_" + Guid.NewGuid().ToString("N"));
        if (Directory.Exists(tempDir))
        {
            Directory.Delete(tempDir, recursive: true);
        }
        Directory.CreateDirectory(tempDir);

        try
        {
            ExtractZip(stream, tempDir);
            if (Directory.Exists(LocalDataDir))
            {
                Directory.Delete(LocalDataDir, recursive: true);
            }
            Directory.Move(tempDir, LocalDataDir);
            File.WriteAllText(markerPath, version);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                Directory.Delete(tempDir, recursive: true);
            }
        }
    }

    public static string? FindDevelopmentSourceDir()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var sourceDataDir = Path.Combine(directory.FullName, "source");
            if (HasUsableAppData(sourceDataDir))
            {
                return sourceDataDir;
            }

            directory = directory.Parent;
        }

        return null;
    }

    public static bool HasUsableAppData(string dataDir)
    {
        return File.Exists(GetWebUiIndexPath(dataDir))
            && (
                File.Exists(Path.Combine(GetOwnersSelectionDir(dataDir), "_tool", "OwnerSelectionTool.exe"))
                || File.Exists(Path.Combine(GetOwnersSelectionDir(dataDir), "_tool", "stage_1_9.py"))
            );
    }

    public static string GetWebUiIndexPath(string dataDir)
    {
        var packagedPath = Path.Combine(dataDir, "web_ui", "index.html");
        return File.Exists(packagedPath)
            ? packagedPath
            : Path.Combine(dataDir, "shared", "web_ui", "index.html");
    }

    public static string GetOwnersSelectionDir(string dataDir)
    {
        var packagedPath = Path.Combine(dataDir, "owners_selection");
        return Directory.Exists(packagedPath)
            ? packagedPath
            : Path.Combine(dataDir, "modules", "owners_selection");
    }

    private static void ExtractZip(Stream stream, string destinationDir)
    {
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
        foreach (var entry in archive.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
            {
                continue;
            }

            var targetPath = Path.GetFullPath(Path.Combine(destinationDir, entry.FullName));
            if (!targetPath.StartsWith(Path.GetFullPath(destinationDir), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Embedded app data contains an invalid path.");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
            entry.ExtractToFile(targetPath, overwrite: true);
        }
    }
}
