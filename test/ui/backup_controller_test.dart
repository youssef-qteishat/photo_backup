import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/domain/backup_job.dart';
import 'package:photo_backup/domain/media_item.dart';
import 'package:photo_backup/engine/backup_engine.dart';
import 'package:photo_backup/engine/job_queue.dart';
import 'package:photo_backup/manifest/manifest_store.dart';
import 'package:photo_backup/ui/backup_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../destination/fake_destination.dart';

/// Runs [onUpload] before each upload (1-based), to act mid-run.
class _HookedDestination extends FakeDestination {
  void Function(int uploadNumber)? onUpload;
  int _calls = 0;

  @override
  Future<void> upload(
    String path,
    File file, {
    required String sha256,
    void Function(int sent, int total)? onProgress,
  }) {
    onUpload?.call(++_calls);
    return super.upload(path, file, sha256: sha256, onProgress: onProgress);
  }
}

/// Completes when [c] reaches [status] (async work runs in isolates/SQLite).
Future<void> _until(BackupController c, BackupStatus status) {
  if (c.status == status) return Future.value();
  final reached = Completer<void>();
  void listener() {
    if (c.status == status && !reached.isCompleted) reached.complete();
  }

  c.addListener(listener);
  return reached.future
      .whenComplete(() => c.removeListener(listener))
      .timeout(const Duration(seconds: 10));
}

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late Database db;
  late _HookedDestination dest;
  late List<MediaItem> items;
  late Map<String, File> files;
  late List<bool> awake;
  late BackupController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('controller_test');
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    dest = _HookedDestination();
    files = {};
    items = [];
    for (final (i, id) in ['a', 'b', 'c'].indexed) {
      files[id] = await File('${tmp.path}/$id')
          .writeAsBytes(List.filled(10, i));
      items.add(
        MediaItem(
          assetId: id,
          fileName: '$id.HEIC',
          sizeBytes: 10,
          modifiedAt: DateTime(2026, 3, 1),
          type: MediaType.photo,
        ),
      );
    }
    awake = [];
    controller = BackupController(
      engine: BackupEngine(
        queue: await JobQueue.open(db),
        manifest: await ManifestStore.open(db),
        destination: dest,
        resolveFile: (item) async => files[item.assetId],
        userId: 'user-1',
        sleep: (_) async {},
      ),
      discover: () async => items,
      keepAwake: awake.add,
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<Iterable<JobState>> states() async =>
      (await (await JobQueue.open(db)).all()).map((j) => j.state);

  test(
    'start backs everything up and holds a wakelock only while running',
    () async {
      await controller.start();

      expect(controller.status, BackupStatus.idle);
      expect(controller.lastRun!.counts[JobState.done], 3);
      expect(awake, [true, false]);
    },
  );

  test('pause stops after the current file; resume finishes', () async {
    dest.onUpload = (n) {
      if (n == 1) controller.pause();
    };

    await controller.start();
    expect(controller.status, BackupStatus.paused);
    expect(controller.lastRun!.counts[JobState.done], 1);

    dest.onUpload = null;
    await controller.resume();
    expect(controller.status, BackupStatus.idle);
    expect(await states(), everyElement(JobState.done));
  });

  test('going to the background auto-pauses; coming back resumes', () async {
    dest.onUpload = (n) {
      if (n == 1) controller.onLifecycle(AppLifecycleState.paused);
    };

    await controller.start();
    expect(controller.status, BackupStatus.paused);

    dest.onUpload = null;
    controller.onLifecycle(AppLifecycleState.resumed);
    await _until(controller, BackupStatus.running);
    await _until(controller, BackupStatus.idle);
    expect(await states(), everyElement(JobState.done));
  });

  test(
    'coming back while still pausing resumes once the file is done',
    () async {
      dest.onUpload = (n) {
        if (n == 1) {
          controller.onLifecycle(AppLifecycleState.hidden);
          controller.onLifecycle(AppLifecycleState.resumed); // still pausing
        }
      };

      await controller.start();

      expect(controller.status, BackupStatus.idle);
      expect(await states(), everyElement(JobState.done));
    },
  );

  test('a user pause is not auto-resumed when the app comes back', () async {
    dest.onUpload = (n) {
      if (n == 1) controller.pause();
    };
    await controller.start();

    controller.onLifecycle(AppLifecycleState.paused);
    controller.onLifecycle(AppLifecycleState.resumed);

    expect(controller.status, BackupStatus.paused);
  });

  test('inactive (e.g. Control Center) does not pause', () async {
    dest.onUpload = (n) {
      if (n == 1) controller.onLifecycle(AppLifecycleState.inactive);
    };

    await controller.start();

    expect(controller.status, BackupStatus.idle);
    expect(controller.lastRun!.counts[JobState.done], 3);
  });

  test('cancel stops the run and leaves jobs pending', () async {
    dest.onUpload = (n) {
      if (n == 1) controller.cancel();
    };

    await controller.start();

    expect(controller.status, BackupStatus.idle);
    expect(await states(), everyElement(JobState.pending));
    expect(dest.files, isEmpty);
  });

  test('history and problems come through for the History screen', () async {
    files.remove('b'); // b disappears → skipped with a reason

    await controller.start();

    expect(await controller.history(), hasLength(1));
    final problems = await controller.problems();
    expect(problems.single.item.assetId, 'b');
    expect(problems.single.reason, 'asset no longer available');
  });

  test('each run keeps the files it handled, even after later runs', () async {
    files.remove('b');
    await controller.start(); // run 1: a, c done; b skipped
    files['b'] = await File('${tmp.path}/b2').writeAsBytes([9, 9]);
    await controller.start(); // run 2: b retried and done

    final runs = await controller.history(); // newest first
    expect(runs, hasLength(2));
    expect(runs.first.id, isNotNull);
    expect(controller.lastRun!.id, runs.first.id);

    final first = {
      for (final j in await controller.runJobs(runs.last.id!))
        j.item.assetId: j,
    };
    expect(first.keys, unorderedEquals(['a', 'b', 'c']));
    expect(first['b']!.state, JobState.skipped);
    expect(first['b']!.reason, 'asset no longer available');
    expect(first['a']!.state, JobState.done);

    final second = await controller.runJobs(runs.first.id!);
    expect(second.map((j) => (j.item.assetId, j.state)), [
      ('b', JobState.done),
    ]);
  });

  test('a run with nothing new records no files', () async {
    await controller.start();
    await controller.start();

    final runs = await controller.history();
    expect(await controller.runJobs(runs.first.id!), isEmpty);
  });
}
