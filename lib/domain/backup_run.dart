import 'package:photo_backup/domain/backup_job.dart';

class BackupRun {
  // history screen
  final DateTime startedAt;
  final DateTime? finishedAt;
  final Map<JobState, int> counts;
  final int bytesTransferred;

  // Copies counts so a stored run can't change later.
  BackupRun({
    required this.startedAt,
    required this.finishedAt,
    required Map<JobState, int> counts,
    required this.bytesTransferred,
  }) : counts = Map.unmodifiable(counts);
}
