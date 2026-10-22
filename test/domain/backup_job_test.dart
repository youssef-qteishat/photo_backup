import 'package:flutter_test/flutter_test.dart';
import 'package:photo_backup/domain/backup_job.dart';
import 'package:photo_backup/domain/media_item.dart';

final _item = MediaItem(
  assetId: 'asset-1',
  fileName: 'IMG_0001.HEIC',
  sizeBytes: 1024,
  modifiedAt: DateTime(2026, 1, 1),
  type: MediaType.photo,
);

BackupJob _job(
  JobState state, {
  String? reason,
  FailureKind? failureKind,
  String? sha256,
}) => BackupJob(
  item: _item,
  state: state,
  attempts: 0,
  remotePath: 'user-1/2026/IMG_0001.HEIC',
  reason: reason,
  failureKind: failureKind,
  sha256: sha256,
);

// Mirrors the legal-transitions table in SPEC.md.
const _legal = {
  JobState.pending: {JobState.hashing, JobState.skipped},
  JobState.hashing: {
    JobState.uploading,
    JobState.skipped,
    JobState.failed,
    JobState.pending,
  },
  JobState.uploading: {
    JobState.verifying,
    JobState.skipped,
    JobState.failed,
    JobState.pending,
  },
  JobState.verifying: {JobState.done, JobState.failed, JobState.pending},
  JobState.failed: {JobState.pending},
  JobState.done: <JobState>{},
  JobState.skipped: <JobState>{},
};

void main() {
  group('canTransition', () {
    test('matches the SPEC table for every (from, to) pair', () {
      for (final from in JobState.values) {
        for (final to in JobState.values) {
          expect(
            canTransition(from, to),
            _legal[from]!.contains(to),
            reason: '$from -> $to',
          );
        }
      }
    });

    test('a job cannot move to its own state', () {
      for (final s in JobState.values) {
        expect(canTransition(s, s), isFalse, reason: '$s');
      }
    });

    test('done and skipped have no outgoing transitions', () {
      for (final to in JobState.values) {
        expect(canTransition(JobState.done, to), isFalse);
        expect(canTransition(JobState.skipped, to), isFalse);
      }
    });
  });

  group('transitionTo', () {
    test('a done job cannot go back to uploading', () {
      expect(
        () => _job(JobState.done).transitionTo(JobState.uploading),
        throwsArgumentError,
      );
    });

    test('a failed job can go back to pending on retry', () {
      final job = _job(
        JobState.failed,
        reason: 'timeout',
        failureKind: FailureKind.transient,
      ).transitionTo(JobState.pending);
      expect(job.state, JobState.pending);
      expect(job.reason, isNull);
      expect(job.failureKind, isNull);
    });

    test('a hashing job can be skipped when the hash already exists', () {
      final job = _job(JobState.hashing)
          .transitionTo(JobState.skipped, reason: 'already on destination');
      expect(job.state, JobState.skipped);
      expect(job.reason, 'already on destination');
    });

    test('in-flight jobs can return to pending (crash recovery / cancel)', () {
      for (final s in [
        JobState.hashing,
        JobState.uploading,
        JobState.verifying,
      ]) {
        expect(_job(s).transitionTo(JobState.pending).state, JobState.pending);
      }
    });

    test('illegal transition error names both states', () {
      expect(
        () => _job(JobState.pending).transitionTo(JobState.done),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('pending'), contains('done')),
          ),
        ),
      );
    });

    test('entering failed without a reason or kind throws', () {
      final hashing = _job(JobState.hashing);
      expect(
        () =>
            hashing.transitionTo(JobState.failed, kind: FailureKind.transient),
        throwsArgumentError,
      );
      expect(
        () => hashing.transitionTo(JobState.failed, reason: 'timeout'),
        throwsArgumentError,
      );
    });

    test('entering skipped without a reason throws', () {
      expect(
        () => _job(JobState.pending).transitionTo(JobState.skipped),
        throwsArgumentError,
      );
    });

    test('attempts increments only when entering hashing', () {
      var job = _job(JobState.pending).transitionTo(JobState.hashing);
      expect(job.attempts, 1);
      job = job.transitionTo(JobState.uploading);
      expect(job.attempts, 1);
      job = job
          .transitionTo(
            JobState.failed,
            reason: 'timeout',
            kind: FailureKind.transient,
          )
          .transitionTo(JobState.pending)
          .transitionTo(JobState.hashing);
      expect(job.attempts, 2);
    });

    test('sha256 is kept unless a new one is passed', () {
      final job = _job(JobState.hashing)
          .transitionTo(JobState.uploading, sha256: 'abc');
      expect(job.transitionTo(JobState.verifying).sha256, 'abc');
    });
  });

  group('constructor', () {
    test('failed without reason or kind is rejected', () {
      expect(() => _job(JobState.failed), throwsA(isA<AssertionError>()));
      expect(
        () => _job(JobState.failed, reason: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('skipped without reason is rejected', () {
      expect(() => _job(JobState.skipped), throwsA(isA<AssertionError>()));
    });

    test('reason or kind on a non-failed state is rejected', () {
      expect(
        () => _job(JobState.pending, reason: 'x'),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => _job(
          JobState.skipped,
          reason: 'x',
          failureKind: FailureKind.permanent,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
