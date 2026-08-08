@echo off
setlocal
cd /d "%~dp0"

flutter --version >nul 2>&1
if errorlevel 1 (
  echo Flutter was not found. Install Flutter first, then run this file again.
  pause
  exit /b 1
)

echo Building Android APK...
flutter pub get
if errorlevel 1 (
  echo flutter pub get failed.
  pause
  exit /b 1
)

flutter build apk --release
if errorlevel 1 (
  echo Android APK build failed.
  pause
  exit /b 1
)

copy /Y "build\app\outputs\flutter-apk\app-release.apk" "..\..\City.Stamina.Mobile.apk" >nul
echo Done: City.Stamina.Mobile.apk
pause
