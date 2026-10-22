import 'media_item.dart';

enum JobState { pending, hashing, uploading, verifying, done, failed, skipped }

enum FailureKind {
  transient, // e.g., network timeout, disconnects
  permanent, // e.g., asset too large, destination out of storage space
}

/// Pure helper function defining valid transitions within the backup state machine.
bool canTransition(JobState from, JobState to) {
  switch (from) {
    case JobState.pending:
      return to == JobState.hashing || to == JobState.skipped;

    // In-flight states can go back to pending (crash recovery or cancel).
    case JobState.hashing:
      return to == JobState.uploading ||
          to == JobState.failed ||
          to == JobState.skipped ||
          to == JobState.pending;

    case JobState.uploading:
      return to == JobState.verifying ||
          to == JobState.failed ||
          to == JobState.skipped ||
          to == JobState.pending;

    case JobState.verifying:
      return to == JobState.done ||
          to == JobState.failed ||
          to == JobState.pending;

    case JobState.failed:
      // Retry: failed jobs re-queue as pending
      return to == JobState.pending;

    case JobState.skipped:
    case JobState.done:
      // Terminal states cannot transition anywhere else
      return false;
  }
}

class BackupJob {
  final MediaItem item;
  final JobState state;
  // Incremented each time the job enters `hashing`
  final int attempts;
  // Format: <user-id>/<yyyy>/<fileName>
  final String remotePath;
  // Set after hashing is complete
  final String? sha256;
  // Required when state is failed or skipped, null otherwise
  final String? reason;
  // Required when state is failed, null otherwise
  final FailureKind? failureKind;

  // Asserts catch invalid jobs (e.g. bad SQLite rows) in debug builds and tests.
  const BackupJob({
    required this.item,
    required this.state,
    required this.attempts,
    required this.remotePath,
    this.sha256,
    this.reason,
    this.failureKind,
  }) : assert(attempts >= 0),
       assert(
         (state == JobState.failed || state == JobState.skipped) ==
             (reason != null),
         'reason is required for failed/skipped and must be null otherwise',
       ),
       assert(
         (state == JobState.failed) == (failureKind != null),
         'failureKind is required for failed and must be null otherwise',
       );

  /// Transitions the backup job to a new lifecycle state.
  /// Throws an [ArgumentError] if the transition is invalid or missing required data.
  BackupJob transitionTo(
    JobState next, {
    String? reason,
    FailureKind? kind,
    String? sha256,
  }) {
    // 1. Guard against illegal state machine transitions
    if (!canTransition(state, next)) {
      throw ArgumentError('Illegal state transition from $state to $next');
    }

    // 2. Validate state-specific data integrity rules
    if (next == JobState.failed) {
      if (reason == null || reason.isEmpty) {
        throw ArgumentError(
          'A failure reason is required when transitioning to failed state.',
        );
      }
      if (kind == null) {
        throw ArgumentError(
          'A FailureKind is required when transitioning to failed state.',
        );
      }
    }

    if (next == JobState.skipped && (reason == null || reason.isEmpty)) {
      throw ArgumentError(
        'A reason is required when transitioning to skipped state.',
      );
    }

    // 3. Calculate dynamic field adjustments
    // Increment attempts counter only when explicitly entering the 'hashing' phase
    final updatedAttempts = next == JobState.hashing ? attempts + 1 : attempts;

    // Persist previous hash value unless a new one is explicitly supplied
    final updatedSha256 = sha256 ?? this.sha256;

    // Return a fresh, immutable instance representing the updated state
    return BackupJob(
      item: item,
      state: next,
      attempts: updatedAttempts,
      remotePath: remotePath,
      sha256: updatedSha256,
      reason: next == JobState.failed || next == JobState.skipped
          ? reason
          : null,
      failureKind: next == JobState.failed ? kind : null,
    );
  }
}
