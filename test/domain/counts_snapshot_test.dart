import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/domain/backup_job.dart';
import 'package:photo_backup/domain/backup_progress.dart';
import 'package:photo_backup/domain/backup_run.dart';

void main() {
  test('BackupProgress counts are a frozen snapshot', () {
    final live = {JobState.done: 1};
    final progress = BackupProgress(
      bytesDone: 10,
      bytesTotal: 100,
      currentFile: 'IMG_0001.HEIC',
      counts: live,
    );

    live[JobState.done] = 2;
    expect(progress.counts[JobState.done], 1);
    expect(() => progress.counts[JobState.failed] = 1, throwsUnsupportedError);
  });

  test('BackupRun counts are a frozen snapshot', () {
    final live = {JobState.done: 1};
    final run = BackupRun(
      startedAt: DateTime(2026, 1, 1),
      finishedAt: null,
      counts: live,
      bytesTransferred: 0,
    );

    live[JobState.done] = 2;
    expect(run.counts[JobState.done], 1);
    expect(() => run.counts[JobState.failed] = 1, throwsUnsupportedError);
  });
}
