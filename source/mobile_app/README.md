# City Stamina Mobile

Flutter Android app for the mobile automation shell.

Current scope:

- Mobile hub
- Owner's Selection screen
- City Stamina amount input
- Stage selector
- Run/Stop state
- Android notification Run/Stop control
- Notification action events routed back into Flutter
- Update card that opens the latest GitHub APK download
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

Manual test flow on a phone:

1. Install `City.Stamina.Mobile.apk`.
2. Open **City Stamina**.
3. Open **Owner's Selection**.
4. Enter a City Stamina amount.
5. Tap **Show notification control** and allow notifications if Android asks.
6. Open NTE.
7. Pull down the notification shade.
8. Tap the **Run** or **Stop** action and confirm the app log records it.
