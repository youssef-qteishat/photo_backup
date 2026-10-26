## Context

- Problem:

  It’s a smaller-scale version of Sandisk’s companion app. Main functionality is picking a source (iPhone's photos and videos) and a destination (Supabase Storage on local machine), then reliably copy everything that isn’t already backed up. The UI is simple: one screen with a progress bar, pause/resume/cancel, and a history of past runs. The reliability engineering underneath is the interesting part.

## Architecture

```text
 iPhone / iOS Simulator (Flutter app)                    Mac
┌──────────────────────────────────────────────┐         ┌──────────────────────────┐
│ UI (progress bar, controls, history)         │         │ Local Supabase (Docker)  │
│        ▲ Stream<BackupProgress>              │         │ • Auth (test user)       │
│        │                                     │         │ • Storage bucket         │
│ BackupEngine (queue + state machine)         │         │   "backups"              │
│   ├──► Discovery     (photos, PhotoKit)      │         │ • manifest.json copy     │
│   ├──► Manifest      (SQLite)                │         └──────────────────────────┘
│   ├──► Hash worker   (isolate)               │                      ▲
│   └──► BackupDestination (interface)         │                      │ HTTP
│          ├─ SupabaseDestination (real) ──────┼──────────────────────┘
│          └─ FakeDestination     (tests)      │
└──────────────────────────────────────────────┘   127.0.0.1 on Simulator,
                                                   Mac's Wi-Fi IP on iPhone
```

### Dependency rules

- UI depends only on `BackupEngine` (reads its `Stream<BackupProgress>`).
- `BackupEngine` depends on `Discovery`, `Manifest`, `HashWorker`, and the
  `BackupDestination` interface. It never imports Supabase.
- Only `SupabaseDestination` imports `supabase_flutter` or makes network calls.
- Only `PhotoDiscovery` imports `photo_manager`; the engine sees `MediaItem`s and a `FileResolver`.
- `BackupDestination` exposes `exists`, `upload(path, file, sha256:)`, `remoteHash`,
  `move` (overwrites target), `delete`, `freeSpace`, `writeManifest`, and `readManifest`.
  Failures throw `DestinationException` carrying a `FailureKind`.
- `remoteHash` returns the SHA-256 the client stored as object metadata at upload
  (Supabase can't hash server-side), so verification confirms the right object landed,
  not a server-side recomputation of its bytes.
- `SupabaseDestination.upload` streams its own multipart POST, because
  `storage_client`'s `upload()` reads the whole file into memory.
- Tests use `FakeDestination`; no test touches the network.

### Job State Diagram

```text
            ┌───────────────────── retry ───────────────────┐
            ▼                                               │
pending ─► hashing ─► uploading ─► verifying ─► done        │
   │          │           │            │                    │
   │          ├───────────┴────────────┴──► failed(reason) ─┘
   │          │           │
   └──────────┴───────────┴──► skipped(reason)

Crash recovery / cancel: hashing | uploading | verifying ─► pending
```

Legal transitions (everything else is illegal, including self-transitions):

| From        | To                                      | Why                                                           |
| ----------- | --------------------------------------- | ------------------------------------------------------------- |
| `pending`   | `hashing`                               | Job starts                                                    |
| `pending`   | `skipped`                               | Asset deleted / permission revoked before start               |
| `hashing`   | `uploading`                             | Hash computed, not on destination                             |
| `hashing`   | `skipped`                               | Same hash already on destination (incl. renamed file), or asset gone |
| `hashing`   | `failed`, `pending`                     | Error / crash recovery or cancel                              |
| `uploading` | `verifying`                             | Last chunk sent                                               |
| `uploading` | `skipped`                               | Asset deleted / permission revoked mid-upload                 |
| `uploading` | `failed`, `pending`                     | Error / crash recovery or cancel                              |
| `verifying` | `done`                                  | Remote hash matches, `.part` moved to final path              |
| `verifying` | `failed`, `pending`                     | Hash mismatch / crash recovery or cancel                      |
| `failed`    | `pending`                               | Retry (automatic or manual)                                   |

- Legal transitions live in one `canTransition(from, to)` function. Illegal transitions throw.
- `canTransition` checks states only. Retry limits are engine policy, not state-machine rules: the engine auto-retries `transient` failures up to 3 times (1s, 2s, 4s; 4 attempts in total), and never auto-retries `permanent` ones. Any `failed` job can be retried manually.
- Final states: `done` and `skipped` (no outgoing transitions). `failed` is not final.
- A job is never `done` before its hash is verified.

## Domain Model

Types live in `lib/domain/` and are plain immutable Dart (no Flutter or plugin imports).

```dart
enum MediaType { photo, video }

class MediaItem {
  final String assetId;
  final String fileName;
  final int sizeBytes;
  final DateTime modifiedAt;
  final MediaType type;
}

enum JobState { pending, hashing, uploading, verifying, done, failed, skipped }

enum FailureKind { transient, permanent } // transient = network/timeout; permanent = too large, no space

class BackupJob {
  final MediaItem item;
  final JobState state;
  final int attempts;          // incremented each time the job enters `hashing`
  final String remotePath;     // <user-id>/<yyyy>/<fileName>; `_<8hex>` before the extension if another asset holds that path
  final String? sha256;        // set after hashing
  final String? reason;        // required when state is failed or skipped, null otherwise
  final FailureKind? failureKind; // required when state is failed, null otherwise

  // Throws ArgumentError on an illegal transition, or when entering failed/skipped without a reason
  // (or failed without a kind). `sha256` is kept from the previous state unless a new one is passed.
  BackupJob transitionTo(JobState next, {String? reason, FailureKind? kind, String? sha256});
}

bool canTransition(JobState from, JobState to);

class ManifestEntry {
  final String assetId;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String sha256;
  final String remotePath;
  final DateTime backedUpAt;
}

class BackupProgress {
  final int bytesDone;
  final int bytesTotal;
  final String? currentFile;
  final Map<JobState, int> counts;
}

class BackupRun { // history screen; each stored run keeps a snapshot of its jobs
  final int? id;               // set once stored; used to load the run's jobs
  final DateTime startedAt;
  final DateTime? finishedAt;
  final Map<JobState, int> counts;
  final int bytesTransferred;
}
```

## Goals

Pipeline is 5 parts:

1. Discover every photo and video on the device.
2. Diff them against the manifest of what's already backed up.
3. Queue the new or changed files as jobs, saved to disk.
4. Transfer each job: hash it, upload it, verify it.
5. Record success in the manifest and report progress to the UI.

## Scope

- In scope:
  - The 5-stage pipeline above, with incremental diffing and crash-safe resume.
  - Two screens: Backup (progress bar, current file, pause/resume/cancel, counts) and History (past runs, failed/skipped files with reasons).
- Allowed write paths:
  - `lib/`, `test/`, `pubspec.yaml`, `ios/Runner/Info.plist`, `supabase/`
- Read-only context:
  - `SPEC.md`, `CLAUDE.md`, `photo-backup-dev-plan.md`, the rest of `ios/`

## Non-goals

- Explicitly excluded:
  - Browsable Gallery of Backed-up photos and videos
    - Files are stored in a Docker volume
  - Restore (no `list` / `download` on `BackupDestination` until it's in scope)
  - Parallel uploads (jobs run one at a time; stretch goal)
- Dependencies or contracts that must not change:
  - every backup path in your app will start with the user’s ID (Ex: <user-id>/2026/IMG_0001.HEIC)

## Acceptance Criteria

1. Discover. List everything in the source. On a phone that means asking for photo-library permission and reading assets through a plugin like photo_manager. On desktop it’s walking a folder. Each item becomes a lightweight record: an ID, the file name, size, modified date, and type.
   - Permission has three outcomes: full access, limited access (only user-selected assets are discovered and backed up; the app offers "Select more"), and denied (the app explains why and links to Settings).
   - Listing reads sizes from PhotoKit metadata and never downloads iCloud originals. Fetching the original happens inside `hashing` (after the size check); a failed fetch is a `transient` `SourceException` and is retried.
   - Live Photos: only the main image is backed up for now.

2. Diff against a manifest. This is what makes backups incremental. The app keeps a manifest of what’s already been backed up, keyed by asset ID plus size and modified time. Anything missing or changed becomes a job in this run; unchanged items are not queued at all (the `skipped` state is only for jobs that hit a reason mid-run).
   - Content hashes resolve ambiguous cases, such as a file that was renamed but not changed.
   - Renamed but unchanged (same hash as an existing manifest entry, new asset ID): skip the upload and add a manifest row pointing at the existing remote path.
   - Keep the manifest on the destination as well as on the phone (`<user-id>/manifest.json`), so a reinstalled app or a second phone can still tell what the drive already holds.
   - Rows for assets deleted from the device are kept (backups are additive). Restoring from `manifest.json` inserts only rows missing locally; local rows win on conflict.

3. Queue. Each file becomes a job with a state: pending, hashing, uploading, verifying, done, failed, or skipped. Save the queue to disk (SQLite), not just memory. Then if the app is killed mid-backup, it reopens knowing exactly where it stopped. That persistence is what makes resume work.
   - On startup, any job in `hashing`, `uploading`, or `verifying` goes back to `pending`.

4. Transfer. Copy each file as a stream of chunks, not one big read, so a 4 GB video never has to fit in memory.
   - Temp-then-rename: upload to `<path>.part`, verify the remote hash, then `storage.move()` it to the final path. An interrupted copy can never look complete.
   - Resume: restart the `.part` upload from the beginning (no byte-offset seek).
   - Verify: compare hashes after the copy, then mark the job done in the manifest.

5. Report. Hashing runs in a background isolate so the UI never freezes. Uploads stay on the main isolate, since async network I/O doesn't block it. Progress is exposed to the UI as a `Stream<BackupProgress>`.
   - Track progress in bytes, not file count, so one large video doesn’t freeze the bar at “99 of 100.”
   - Progress counts hashed + uploaded bytes (`bytesTotal = 2 × Σ sizes`), so the bar moves during hashing too; show it as a percentage.
   - Pause and cancel are flags the engine checks between steps. Pause finishes the current file, then stops pulling jobs. Cancel aborts the in-flight job, deletes its `.part` file, and returns it to `pending`.
   - Backgrounding the app (iOS suspends it) auto-pauses the backup; returning resumes it. A pause the user chose is never auto-resumed. The screen is kept awake (wakelock) only while a backup runs.

## Evidence

- Automated tests (all use `FakeDestination`, no network):
  - State machine: a done job cannot go back to uploading; a failed job can go back to pending on retry; a hashing job can be skipped when the hash already exists remotely; done and skipped have no outgoing transitions; a job can't move to its own state; illegal transitions throw; entering failed without a reason and kind throws.
  - Diff: a second run over unchanged files queues zero jobs; changing one file queues exactly one; a renamed but identical file causes no upload.
  - Hashing: a large generated file matches a known SHA-256.
  - Engine: kill mid-run, restart, and the backup completes with no duplicates.
  - Engine: a job is never marked `done` if verification fails.
  - Engine: pause stops after the current job; resume continues.
  - Engine: a file over the size limit fails with a clear reason and doesn't block the rest.
  - Engine: running twice in a row uploads nothing the second time.
  - Retries: a transient error is retried 3 times (1s/2s/4s, using a fake clock) before the job ends in `failed`.
- Integration (opt-in, needs local Supabase): `flutter test --tags integration --dart-define-from-file=env/simulator.env` uploads a `.part`, verifies its hash, moves it to the final path, and round-trips the manifest.
- Manual checks:
  - Full backup on the Simulator; files appear under `<user-id>/` in Studio.
  - Turn Wi-Fi off on the iPhone mid-job: the job fails, then succeeds on retry.
  - The progress bar keeps animating while a large video hashes.

## Open Questions

- Question: How to handle a job when Destination is full (out of storage)
  - Answer: check space before starting job (`freeSpace` is a simulated quota; local Supabase has no real one)

- Question: What happens if the network is lost mid-upload (Wi-Fi turns off)?
  - Answer: the job fails, the '.part' file is left behind, and resume picks it up

- Question: What happens if a file is larger than the bucket's `file_size_limit`?
  - Answer: detect it before the job starts and fail it permanently with a reason, rather than failing halfway through

- Question: What happens if permission is revoked or a file is deleted mid-run?
  - Answer: Skip it and record why

- Question: What happens in the event of transient errors?
  - Answer: retry with exponential backoff: 3 retries (1s, 2s, 4s), then `failed(reason)`

## Note

If this spec conflicts with a prompt, this spec wins.
