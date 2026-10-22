class ManifestEntry {
  final String assetId;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String sha256;
  final String remotePath;
  final DateTime backedUpAt;

  const ManifestEntry({
    required this.assetId,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.sha256,
    required this.remotePath,
    required this.backedUpAt,
  });
}
