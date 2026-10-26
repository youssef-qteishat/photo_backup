# Photo Backup

An iOS app (Flutter) that backs up your photos and videos to **Supabase Storage running locally on your Mac**. It simulates the phone-to-drive flow of apps like SanDisk's. Backups are:

- **Incremental:** only new or changed files are copied.
- **Verified:** a file counts as backed up only after its SHA-256 matches.
- **Resumable:** it survives the app being killed, the network dropping, and iOS backgrounding.
- **Controllable:** you can pause, resume and cancel.

- Design and rules: [SPEC.md](SPEC.md)
- Project write-up and demo script: [demo.md](demo.md)

iOS only. Android is out of scope.

---

## Prerequisites

| Tool | Check | Notes |
| --- | --- | --- |
| macOS + Xcode (with the iOS platform) | `open -a Simulator` | Run `sudo xcodebuild -runFirstLaunch` once after installing. |
| Flutter SDK | `flutter doctor` | Xcode must show a green check. Android/Chrome warnings are fine. Developed on Flutter 3.47. |
| CocoaPods | `pod --version` | `brew install cocoapods` |
| Docker Desktop | `docker ps` | Must be running before you start Supabase. |
| Supabase CLI | `supabase --version` | `brew install supabase/tap/supabase` |

## 1. Get the code

```bash
git clone <this-repo-url> photo_backup
cd photo_backup
flutter pub get
```

Run every command below from this project root.

## 2. Start local Supabase

```bash
supabase start
```

The first run downloads the containers, which takes a few minutes. When it finishes it prints the **API URL**, **Studio URL** and keys. Run `supabase status` to see them again.

`supabase start` also sets up everything the app needs:

- **The private `backups` bucket**, created from [supabase/config.toml](supabase/config.toml), with a 4 GiB per-file limit that simulates FAT32.
- **The storage policy** from [supabase/migrations/](supabase/migrations/): each signed-in user can only read and write under their own `<user-id>/` folder.

### Create a test user

The app signs in as one test user.

1. Open Studio at http://127.0.0.1:54323.
2. Go to **Authentication → Users → Add user → Create new user**.
3. Enter an email and password, and tick **Auto Confirm User**.

These go in your env file next.

## 3. Create your env files

The app reads its settings at **build time** from an env file passed with `--dart-define-from-file`. Example files are provided; copy them and fill in your values:

```bash
cp env/simulator.env.example env/simulator.env
cp env/device.env.example env/device.env
```

| Key | Value |
| --- | --- |
| `SUPABASE_URL` | Simulator: `http://127.0.0.1:54321`. iPhone: `http://<your-Mac's-Wi-Fi-IP>:54321` (see below). |
| `SUPABASE_ANON_KEY` | The **Publishable** / anon key printed by `supabase status`. Never use the secret / service-role key. |
| `TEST_EMAIL`, `TEST_PASSWORD` | The test user you created above. |
| `SUPABASE_BUCKET` | Optional. Defaults to `backups`. |

Get your Mac's Wi-Fi IP with:

```bash
ipconfig getifaddr en0
```

It changes when you switch networks, so update `env/device.env` when it does.

`env/*.env` is git-ignored. Don't commit real keys or passwords.

## 4. Run on the iOS Simulator

```bash
open -a Simulator
flutter run -d "iPhone 16" --dart-define-from-file=env/simulator.env
```

Use any simulator name from `flutter devices`.

1. **Add test media:** drag photos and videos from Finder onto the Simulator window. Include one large video so the progress bar has something to show.
2. **Allow photo access** when prompted.
3. **Tap "Back up now".** The files appear in Studio under **Storage → backups → `<user-id>/<year>/`**.

While it's running: `r` hot reloads, `R` hot restarts, and `q` quits.

## 5. Run on your iPhone

**One-time setup:**

1. **Signing:** run `open ios/Runner.xcworkspace`. Under **Runner → Signing & Capabilities**, tick *Automatically manage signing* and pick your team; a free Apple ID works. If the bundle ID is taken, change it to something unique.
2. **Developer Mode:** plug the phone in, tap **Trust**, and turn on **Settings → Privacy & Security → Developer Mode**. The phone restarts.
3. **Same network:** the Mac and the iPhone must be on the **same Wi-Fi network**.

**Run it:**

```bash
flutter devices                      # find your iPhone's ID
flutter run -d <IPHONE_ID> --dart-define-from-file=env/device.env
```

- **First install:** if iOS says "untrusted developer", trust your Apple ID under **Settings → General → VPN & Device Management**, then run again.
- **Local Network prompt:** tap **Allow**. The app needs it to reach Supabase on your Mac.
- **Launching:** always start the app with `flutter run`. Opening it from the home-screen icon starts it without your env file (debug builds). Free-account installs also expire after about 7 days; run `flutter run` again to reinstall.

## 6. Run the tests

```bash
flutter analyze
flutter test
```

`flutter test` runs fully offline, with a fake destination and in-memory SQLite. The two Supabase integration tests are skipped.

To run those against your local Supabase:

```bash
supabase start
flutter test --tags integration --dart-define-from-file=env/simulator.env
```

They clean up after themselves.

---

## Troubleshooting

The app shows a red **"Can't reach the backup server"** banner with the cause.

| Message | Fix |
| --- | --- |
| `SUPABASE_URL / SUPABASE_ANON_KEY missing` | You ran without the env file. Add `--dart-define-from-file=env/<simulator\|device>.env`. Hot reload/restart doesn't pick up env changes: quit (`q`) and run again. |
| `TEST_EMAIL / TEST_PASSWORD missing` | Add both to the env file you're using. |
| `Connection refused` / `TimeoutException` | Supabase isn't running (`supabase start`). Or, on iPhone: the IP in `env/device.env` is wrong, the phone is on a different Wi-Fi, Local Network access was denied (**Settings → Privacy & Security → Local Network**), or the macOS firewall is blocking Docker. |
| `Invalid login credentials` | The test user doesn't exist (for example, after the local database was reset) or the password is wrong. Recreate it in Studio. |
| Photos screen says access is needed | Grant access under **Settings → Privacy & Security → Photos → Photo Backup**. |

Useful Supabase commands:

```bash
supabase status   # URLs and keys
supabase stop     # stop containers (data is kept)
```
