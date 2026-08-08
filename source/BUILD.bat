@echo off
setlocal
cd /d "%~dp0"

dotnet --version >nul 2>&1
if errorlevel 1 (
  echo .NET SDK was not found.
  echo Install .NET SDK first, then run BUILD.bat again.
  pause
  exit /b 1
)

python --version >nul 2>&1
if errorlevel 1 (
  echo Python was not found.
  echo Python is only needed on the developer machine to build the packaged tool.
  pause
  exit /b 1
)

python -m PyInstaller --version >nul 2>&1
if errorlevel 1 (
  echo PyInstaller was not found. Installing it now...
  python -m pip install pyinstaller
  if errorlevel 1 (
    echo Could not install PyInstaller.
    pause
    exit /b 1
  )
)

echo Building packaged Owner's Selection tool...
python -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --onefile ^
  --name OwnerSelectionTool ^
  --distpath "modules\owners_selection\_tool" ^
  --workpath "build\pyinstaller_work" ^
  --specpath "build" ^
  "modules\owners_selection\_tool\stage_1_9.py"

if errorlevel 1 (
  echo OwnerSelectionTool build failed.
  pause
  exit /b 1
)

echo Creating embedded app data bundle...
python "tools\create_app_data_bundle.py"
if errorlevel 1 (
  echo Embedded app data bundle failed.
  pause
  exit /b 1
)

echo Building City Stamina Spender...
dotnet publish "desktop_app\CityStamina.Avalonia.csproj" ^
  -c Release ^
  -r win-x64 ^
  --self-contained true ^
  -p:PublishSingleFile=true ^
  -p:IncludeNativeLibrariesForSelfExtract=true ^
  -p:DebugType=None ^
  -p:DebugSymbols=false ^
  -o "webview_publish"

if errorlevel 1 (
  echo App build failed.
  pause
  exit /b 1
)

copy /Y "webview_publish\CityStamina.Avalonia.exe" "..\City.Stamina.Spender.exe" >nul
del /Q "webview_publish\*.pdb" >nul 2>&1
del /Q "build\*.spec" >nul 2>&1

echo Done: City.Stamina.Spender.exe
echo Release layout is one file: City.Stamina.Spender.exe
pause
