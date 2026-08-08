# City Stamina Mobile

Flutter Android app for the mobile automation shell.

Current scope:

- Mobile hub
- Owner's Selection screen
- City Stamina amount input
- Stage selector
- Run/Stop state
- Android floating button scaffold
- Floating button events routed back into Flutter
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
5. Tap **Show floating button** and allow **Draw over other apps**.
6. Return to the app and tap **Show floating button** again.
7. Open NTE and verify the floating button stays above the game.
8. Tap the floating button and confirm the app log records Run/Stop.
