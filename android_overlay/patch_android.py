"""Patch the generated Android project with app permissions only.

The app uses an inbuilt app-private terminal; no Termux, Shizuku, ADB bridge,
extra native activity or external terminal permission is required.
"""

p = "android/app/src/main/AndroidManifest.xml"
s = open(p).read()
perms = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    "android.permission.RECORD_AUDIO",
    "android.permission.REQUEST_INSTALL_PACKAGES",
    # Required only when the user explicitly enables Device file access.
    "android.permission.MANAGE_EXTERNAL_STORAGE",
]
add = "".join(f'    <uses-permission android:name="{x}"/>\n' for x in perms if x not in s)
s = s.replace("<application", add + "    <application", 1)
if "usesCleartextTraffic" not in s:
    s = s.replace("<application", '<application android:usesCleartextTraffic="true"', 1)
svc = """        <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="specialUse" android:exported="false">
            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Local OpenAI-compatible proxy server"/>
        </service>
"""
if "ForegroundService" not in s:
    s = s.replace("</application>", svc + "    </application>", 1)
open(p, "w").write(s)
print("Android manifest patched for the built-in terminal and local proxy.")
