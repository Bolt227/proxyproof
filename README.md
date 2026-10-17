# ProxyProof – Bluetooth Attendance

```
organiser phone ──BLE adv (no pairing): [sessionId | rotating token]──► student phone
organiser phone ◄── token every few s ── server ◄── sessionId + token + RSSI + deviceId ── student phone
```

* `server/` – Node + Express + SQLite. Auth, device binding, rotating HMAC tokens, SSE live updates, CSV export, web dashboard (`server/public/index.html`).
* `app/`   – Flutter (Android). One app, two roles: Organiser (broadcasts) and Student (scans + auto-submits).

## 1. Run the server
```bash
cd server
npm install
npm start            # http://localhost:3000
```
Dashboard: open `http://localhost:3000`, log in as the seeded admin `admin@proxyproof.local` / `admin123`
(override with `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `JWT_SECRET`, `ORGANISER_CODE`, `ROTATE_SECONDS`, `RSSI_MIN` env vars).
Organiser registration in the app needs the invite code (default `ORG123`).

## 2. Run the app
```bash
cd app
flutter create --project-name proxyproof --platforms=android .   # generates android/ (keep our lib/ and pubspec.yaml)
rm -f test/widget_test.dart                                       # the generated sample test references a MyApp we don't have
flutter pub get
```
If `flutter create` replaced `lib/main.dart` with the counter sample, restore it from this repo.
Then edit `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>
<application ... android:usesCleartextTraffic="true">   <!-- dev only: plain http -->
```
In `android/app/build.gradle(.kts)` set `minSdk = 23` (or higher). Run on **two real phones** (BLE advertising does not work on emulators):
```bash
flutter run
```
In the login screen set **Server URL** to `http://<your-PC-LAN-IP>:3000` (phones and PC on the same Wi-Fi).

## 3. Demo flow
1. Phone A: register as Organiser (invite code) → *Start session & broadcast*.
2. Phone B: register as Student → keep the app open. It is marked automatically, no taps.
3. Dashboard shows the mark live; add/remove manually, close the session, export CSV.
4. Log in on a different phone with the same student account → rejected, request appears under *Device requests* for admin approval.

## How each requirement is met
| # | Requirement | Where |
|---|---|---|
| 1 | Roles + login, one device per student, switch needs admin approval | `users.device_id UNIQUE`, login mismatch → `device_requests`, admin approve/reject |
| 2 | Fixed-duration session | `POST /api/sessions` (`durationMinutes`), auto-close sweeper |
| 3 | Automatic marking | Student app scans continuously and posts as soon as it sees the session |
| 4 | Anti-proxy | HMAC token rotates every `ROTATE_SECONDS` (5 s; the current and previous window are accepted, so a code is good for 5–10 s); `X-Device-Id` must match the bound device; `UNIQUE(session, device)`; RSSI ≥ `RSSI_MIN`; rate limit; rejected attempts logged and shown on the dashboard |
| 5 | Live dashboard | SSE stream, manual add/remove, close session |
| 6 | History / % / CSV | Student *History* tab, `/api/me/attendance`, `/api/sessions/:id/export.csv`, `/api/export/summary.csv` |

## Known limits (worth stating in your submission)
* The server cannot measure RSSI itself – it is reported by the student app, so a modified client could fake it. Device binding, 5 s tokens and the audit log are what make proxying hard, not RSSI alone.
* A friend could relay a token over the internet within its 5–10 s validity; shorten `ROTATE_SECONDS` to tighten this.
* Student scanning runs while the app is in the foreground. For background scanning add a foreground service (e.g. `flutter_foreground_task`).
* The device ID is the Android ID reported by the app and sent in `X-Device-Id`; a rooted phone or a hand-written client could fake it. It stops casual proxying (sharing a login, using a friend's phone), not a determined attacker.
* `flutter_blue_plus` is pinned to 1.x on purpose; 2.x adds a licence requirement for connections.
* Use HTTPS and a real `JWT_SECRET` outside development.
