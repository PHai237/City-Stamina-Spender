# City Stamina Spender

<p>
  <a href="https://github.com/PHai237/City-Stamina-Spender/releases/latest/download/City.Stamina.Spender.exe">
    <img alt="Download Windows" src="https://img.shields.io/badge/Windows-Download-3ecfb2?style=for-the-badge">
  </a>
  <a href="https://github.com/PHai237/City-Stamina-Spender/releases/latest/download/City.Stamina.Mobile.apk">
    <img alt="Download Android" src="https://img.shields.io/badge/Android-APK-4b91ff?style=for-the-badge">
  </a>
</p>

## Windows

1. Click the **Windows Download** button above.
2. Open `City.Stamina.Spender.exe`.
3. Later, use the **Update** button inside the app to get new versions.

## Android

1. Click the **Android APK** button above.
2. Open the downloaded `City.Stamina.Mobile.apk` on your phone.
3. If Android asks, allow installing apps from your browser or file manager.
4. Open **City Stamina**.
5. Open **Owner's Selection**.
6. Press **Check** once so the app can check and request the required permissions.
7. Pull down the Android notification shade to enter **Amount** and use **Run** or **Stop** while NTE is open.
8. Tap **Send log** when you need to send device info and text logs to Discord. It will not request screen recording.

The Android app is still a mobile foundation build. It has the hub, Owner's
Selection screen, Run/Stop state, notification control, permission checks,
device info, text log upload, and Discord diagnostics. Full tap automation
is not wired yet.

## Discord debug upload

Create a Discord webhook in your debug channel, then put the webhook URL in
`discord_webhook.txt` next to `City.Stamina.Spender.exe` on Windows. On Android,
tap **Send log** once and paste the webhook URL in the popup. Text logs are
uploaded to Discord without screen recording. Screenshot diagnostics, when used, are deleted locally after the
upload attempt.
