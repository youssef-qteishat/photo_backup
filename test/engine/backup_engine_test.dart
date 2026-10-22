import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/destination/backup_destination.dart';
import 'package:photo_backup/domain/backup_job.dart';
import 'package:photo_backup/domain/backup_progress.dart';
import 'package:photo_backup/domain/media_item.dart';
import 'package:photo_backup/engine/backup_engine.dart';
import 'package:photo_backup/engine/job_queue.dart';
import 'package:photo_backup/manifest/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../destination/fake_destination.dart';

const _uid = 'user-1';

class _Killed implements Exception {}

/// Fake that runs [onUpload] before each upload (count is 1-based), so a test
/// can kill the "app", pause, or cancel at an exact point.
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

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late Database db;
  late _HookedDestination dest;
  late Map<String, File> files;
  late List<Duration> sleeps;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('engine_test');
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    dest = _HookedDestination();
    files = {};
    sleeps = [];
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  /// A new engine on the shared DB: what reopening the app looks like.
  Future<BackupEngine> engine({int maxFileBytes = 4 << 30}) async =>
      BackupEngine(
        queue: await JobQueue.open(db),
        manifest: await ManifestStore.open(db),
        destination: dest,
        resolveFile: (item) async => files[item.assetId],
        userId: _uid,
        maxFileBytes: maxFileBytes,
        sleep: (d) async => sleeps.add(d),
      );

  /// Writes a real file and returns its MediaItem. Same [fill] = same content.
  Future<MediaItem> asset(
    String id, {
    int size = 10,
    int fill = 0,
    String? fileName,
  }) async {
    final file = await File('${tmp.path}/$id')
        .writeAsBytes(List.filled(size, fill));
    files[id] = file;
    return MediaItem(
      assetId: id,
      fileName: fileName ?? '$id.HEIC',
      sizeBytes: size,
      modifiedAt: DateTime(2026, 3, 1),
      type: MediaType.photo,
    );
  }

  Future<Map<String, BackupJob>> jobs() async => {
    for (final j in await (await JobQueue.open(db)).all()) j.item.assetId: j,
  };

  Iterable<String> finalPaths() =>
      dest.files.keys.where((p) => !p.endsWith('.part'));

  test('kill mid-run, restart: completes with no duplicates', () async {
    final items = [
      await asset('a', fill: 1),
      await asset('b', fill: 2),
      await asset('c', fill: 3),
    ];
    dest.onUpload = (n) {
      if (n == 2) throw _Killed();
    };

    await expectLater((await engine()).run(items), throwsA(isA<_Killed>()));
    final afterKill = await jobs();
    expect(afterKill['a']!.state, JobState.done);
    expect(afterKill['b']!.state, JobState.uploading); // stuck mid-flight
    expect(afterKill['c']!.state, JobState.pending);

    dest.onUpload = null;
    await (await engine()).run(items);

    expect(
      (await jobs()).values.map((j) => j.state),
      everyElement(JobState.done),
    );
    expect(
      finalPaths(),
      unorderedEquals([
        '$_uid/2026/a.HEIC',
        '$_uid/2026/b.HEIC',
        '$_uid/2026/c.HEIC',
      ]),
    );
    expect(dest.files.keys.where((p) => p.endsWith('.part')), isEmpty);
    expect(dest.uploadCount, 3);
    final manifest = await ManifestStore.open(db);
    for (final i in items) {
      expect(await manifest.get(i.assetId), isNotNull);
    }
  });

  test('a job is never done if verification fails', () async {
    final item = await asset('a');
    dest.corruptHashPaths.add('$_uid/2026/a.HEIC.part');

    await (await engine()).run([item]);

    final job = (await jobs())['a']!;
    expect(job.state, JobState.failed);
    expect(job.reason, contains('hash mismatch'));
    expect(await (await ManifestStore.open(db)).get('a'), isNull);
    expect(finalPaths(), isEmpty);
  });

  test('pause stops after the current job; resume continues', () async {
    final items = [
      await asset('a', fill: 1),
      await asset('b', fill: 2),
      await asset('c', fill: 3),
    ];
    final e = await engine();
    dest.onUpload = (n) {
      if (n == 1) e.pause();
    };

    final paused = await e.run(items);
    expect(paused.counts[JobState.done], 1);
    expect(paused.counts[JobState.pending], 2);

    dest.onUpload = null;
    await e.run(items);
    expect(
      (await jobs()).values.map((j) => j.state),
      everyElement(JobState.done),
    );
    expect(dest.uploadCount, 3);
  });

  test('oversize file fails with a clear reason, rest still back up', () async {
    final items = [
      await asset('a', size: 10, fill: 1),
      await asset('big', size: 100, fill: 2),
      await asset('c', size: 10, fill: 3),
    ];

    await (await engine(maxFileBytes: 50)).run(items);

    final all = await jobs();
    expect(all['big']!.state, JobState.failed);
    expect(all['big']!.failureKind, FailureKind.permanent);
    expect(all['big']!.reason, contains('exceeds'));
    expect(all['a']!.state, JobState.done);
    expect(all['c']!.state, JobState.done);
    expect(sleeps, isEmpty); // permanent: no retries
  });

  test('running twice uploads nothing the second time', () async {
    final items = [await asset('a', fill: 1), await asset('b', fill: 2)];
    await (await engine()).run(items);
    expect(dest.uploadCount, 2);

    final second = await (await engine()).run(items);
    expect(dest.uploadCount, 2);
    expect(second.bytesTransferred, 0);
  });

  test('transient errors retry 3 times (1s, 2s, 4s), then fail', () async {
    final item = await asset('a');
    dest.failAfterUploads = 0; // every upload fails transiently

    await (await engine()).run([item]);

    final job = (await jobs())['a']!;
    expect(sleeps, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
    expect(job.state, JobState.failed);
    expect(job.failureKind, FailureKind.transient);
    expect(job.attempts, 4);
  });

  test('a transient error that clears up succeeds on retry', () async {
    final item = await asset('a');
    dest.onUpload = (n) {
      if (n == 1) {
        throw const DestinationException('offline', FailureKind.transient);
      }
    };

    await (await engine()).run([item]);

    expect((await jobs())['a']!.state, JobState.done);
    expect(sleeps, const [Duration(seconds: 1)]);
  });

  test('crash recovery: in-flight jobs resume without rediscovery', () async {
    final item = await asset('a');
    final queue = await JobQueue.open(db);
    await queue.enqueue(item, '$_uid/2026/a.HEIC');
    final job = (await queue.all()).single;
    await queue.save(job.transitionTo(JobState.hashing));

    await (await engine()).run(const []); // nothing discovered this time

    expect((await jobs())['a']!.state, JobState.done);
  });

  test('renamed but identical file is not uploaded again', () async {
    final original = await asset('a', fill: 7);
    final renamed = await asset('a-copy', fill: 7);

    await (await engine()).run([original, renamed]);

    final all = await jobs();
    expect(dest.uploadCount, 1);
    expect(all['a']!.state, JobState.done);
    expect(all['a-copy']!.state, JobState.skipped);
    final alias = await (await ManifestStore.open(db)).get('a-copy');
    expect(alias!.remotePath, '$_uid/2026/a.HEIC');
  });

  test('two different assets with the same name get distinct paths', () async {
    final first = await asset('a', fill: 1, fileName: 'IMG_0001.HEIC');
    final second = await asset('b', fill: 2, fileName: 'IMG_0001.HEIC');

    await (await engine()).run([first, second]);

    expect(finalPaths(), hasLength(2));
    expect(finalPaths(), contains('$_uid/2026/IMG_0001.HEIC'));
    expect(
      finalPaths().where((p) => p != '$_uid/2026/IMG_0001.HEIC').single,
      matches(RegExp(r'^user-1/2026/IMG_0001_[0-9a-f]{8}\.HEIC$')),
    );
  });

  test('an asset that disappeared is skipped with a reason', () async {
    final item = await asset('a');
    files.remove('a');

    await (await engine()).run([item]);

    final job = (await jobs())['a']!;
    expect(job.state, JobState.skipped);
    expect(job.reason, 'asset no longer available');
  });

  test('cancel returns the in-flight job to pending and cleans up', () async {
    final items = [await asset('a', fill: 1), await asset('b', fill: 2)];
    final e = await engine();
    dest.onUpload = (_) => e.cancel();

    await e.run(items);

    final all = await jobs();
    expect(all['a']!.state, JobState.pending);
    expect(all['b']!.state, JobState.pending);
    expect(dest.files, isEmpty); // .part deleted
  });

  test('progress is by bytes, never moves backwards, ends full', () async {
    final items = [
      await asset('a', size: 10, fill: 1),
      await asset('b', size: 30, fill: 2),
    ];
    final e = await engine();
    final events = <BackupProgress>[];
    final sub = e.progress.listen(events.add);

    await e.run(items);
    await sub.cancel();

    expect(events.last.bytesTotal, 2 * 40); // hash + upload pass
    expect(events.last.bytesDone, events.last.bytesTotal);
    for (var i = 1; i < events.length; i++) {
      expect(
        events[i].bytesDone,
        greaterThanOrEqualTo(events[i - 1].bytesDone),
      );
    }
  });

  test('runs are recorded for the history screen', () async {
    await (await engine()).run([await asset('a')]);
    final runs = await (await JobQueue.open(db)).runs();
    expect(runs, hasLength(1));
    expect(runs.single.counts[JobState.done], 1);
    expect(runs.single.bytesTransferred, 10);
  });
}
