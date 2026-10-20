## Commands

All commands run from the project root (`~/dev/photo_backup`) unless noted.

### Local Supabase (Docker Desktop must be running)

```bash
supabase start            # start local stack; prints URLs and keys
supabase status           # show URLs and keys again
supabase stop             # stop containers (data is kept)
supabase migration new <name>   # create a new SQL migration file
supabase migration up     # apply pending migrations (keeps data)
supabase migration list   # check which migrations are applied
```

Studio (web dashboard): http://127.0.0.1:54323
After editing `supabase/config.toml`: `supabase stop` then `supabase start`.

### Run the app

```bash
open -a Simulator                                       # launch iOS Simulator
flutter run -d "iPhone 16" --dart-define-from-file=env/simulator.env
flutter run -d <IPHONE_ID> --dart-define-from-file=env/device.env
flutter devices                                         # list device IDs
```

While running: `r` hot reload, `R` hot restart, `q` quit.
iPhone: Mac and phone on the same Wi-Fi; launch through `flutter run`,
not the home-screen icon (debug builds).

### Quality checks (run before every commit)

```bash
flutter analyze           # static analysis / lints
dart format .             # format all Dart files
flutter test              # unit + widget tests (no network)
```

### Dependencies and cleanup

```bash
flutter pub get           # install packages after editing pubspec.yaml
flutter pub add <pkg>     # add a package
flutter clean && flutter pub get   # reset build state
cd ios && pod install && cd ..     # refresh iOS native deps if a build fails
```

### Rules for Claude Code

- Run `flutter analyze` and `flutter test` after every change; fix failures before finishing.
- Do NOT run `flutter run`: it is interactive and long-running. Ask me to run it.
- Do NOT run `supabase db reset` (wipes local data) or `supabase stop --no-backup`.
- Never read, print, or commit `.env` or `env/*.env`.
- Never use the secret/service key in app code; only `SUPABASE_ANON_KEY`.
