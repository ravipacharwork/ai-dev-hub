# Android setup

The CI workflow generates the Flutter Android platform files and applies the
required permissions automatically. The app now uses an **inbuilt app-private
terminal**; Termux, Shizuku, ADB and external terminal permissions are not
required.

## Local build

```bash
flutter create --platforms=android --org com.example --project-name ai_dev_hub .
python3 android_overlay/patch_android.py
flutter pub get
flutter build apk --release
```

The generated Android project should use `minSdk` 23 or higher. The patch adds
network, foreground-service, notification, microphone, file-access and APK
install permissions needed by the existing features.

## Inbuilt terminal

The terminal runs supported commands inside the app-private virtual path
`/workspace`. It cannot access Android system folders or another app's private
data. The model asks for confirmation before commands when the setting is
enabled. This is intentional: unrestricted Android shell access would require
Termux/Shizuku and would make the APK less safe, not more powerful.

## OmniRoute gateway

Only the embedded OmniRoute-style gateway is enabled. It runs on loopback and
routes requests through the configured provider key pool. Multiple keys for the
same provider are encrypted with Android Keystore-backed storage and receive
independent cooldowns, so a rate-limited key does not block the other keys.
