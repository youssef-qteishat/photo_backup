import 'package:photo_backup/domain/backup_job.dart';

class BackupProgress {
  final int bytesDone;
  final int bytesTotal;
  final String? currentFile;
  final Map<JobState, int> counts;

  // Copies counts so a snapshot can't change after it's emitted.
  BackupProgress({
    required this.bytesDone,
    required this.bytesTotal,
    required this.currentFile,
    required Map<JobState, int> counts,
  }) : counts = Map.unmodifiable(counts);
}
