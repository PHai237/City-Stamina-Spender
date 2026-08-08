# City Stamina Mobile

Flutter Android app for the mobile automation shell.

Current scope:

- Mobile hub
- Owner's Selection screen
- City Stamina amount input
- Stage selector
- Run/Stop state
- Android floating button scaffold
- Local logs
- Discord debug upload with local temporary file cleanup

Build a release APK:

```powershell
cd source\mobile_app
flutter build apk --release
```

Or run:

```powershell
source\mobile_app\BUILD_ANDROID.bat
```

The release APK is copied to:

```text
City.Stamina.Mobile.apk
```

Upload that APK to the GitHub Release together with `City.Stamina.Spender.exe`.
