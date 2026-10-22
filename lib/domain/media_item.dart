enum MediaType { photo, video }

class MediaItem {
  final String assetId;
  final String fileName;
  final int sizeBytes;
  final DateTime modifiedAt;
  final MediaType type;

  // Added a standard Dart constructor
  const MediaItem({
    required this.assetId,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.type,
  });
}
