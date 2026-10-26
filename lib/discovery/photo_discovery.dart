import 'dart:io';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../domain/backup_job.dart';
import '../domain/media_item.dart';
import '../domain/source_exception.dart';

enum LibraryAccess { full, limited, denied }

/// The only code that talks to the photo library (PhotoKit via
/// photo_manager). Everything else sees plain [MediaItem]s and [File]s.
class PhotoDiscovery {
  static const _pageSize = 500;

  const PhotoDiscovery();

  /// Prompts on first call; afterwards returns the current setting.
  Future<LibraryAccess> requestAccess() async =>
      switch (await PhotoManager.requestPermissionExtend()) {
        PermissionState.authorized => LibraryAccess.full,
        PermissionState.limited => LibraryAccess.limited,
        _ => LibraryAccess.denied, // denied, restricted, notDetermined
      };

  Future<void> openSettings() => PhotoManager.openSetting();

  /// iOS picker for adding photos in limited-access mode.
  Future<void> selectMorePhotos() => PhotoManager.presentLimited();

  /// Every photo and video the app can see. Under limited access that's only
  /// what the user picked. Sizes come from PhotoKit metadata, so listing never
  /// downloads iCloud originals.
  Future<List<MediaItem>> listAll() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // images + videos
      onlyAll: true,
      filterOption: FilterOptionGroup(
        imageOption: const FilterOption(needTitle: true),
        videoOption: const FilterOption(needTitle: true),
      ),
    );
    if (paths.isEmpty) return const [];

    final items = <MediaItem>[];
    for (var page = 0; ; page++) {
      final assets = await paths.first.getAssetListPaged(
        page: page,
        size: _pageSize,
      );
      for (final asset in assets) {
        items.add(
          MediaItem(
            assetId: asset.id,
            fileName: asset.title ?? asset.id,
            sizeBytes: await asset.fileSize,
            modifiedAt: asset.modifiedDateTime,
            type: asset.type == AssetType.video
                ? MediaType.video
                : MediaType.photo,
          ),
        );
      }
      if (assets.length < _pageSize) return items;
    }
  }

  /// The asset's original file (a cached copy), for the engine's
  /// FileResolver. Null if the asset was deleted. Throws a transient
  /// [SourceException] if the original can't be fetched (e.g. iCloud), so the
  /// engine retries it. Live Photos: only the main image is returned.
  Future<File?> originalFile(MediaItem item) async {
    final asset = await AssetEntity.fromId(item.assetId);
    if (asset == null) return null;
    try {
      final file = await asset.loadFile(isOrigin: true);
      if (file != null) return file;
    } on PlatformException catch (e) {
      throw SourceException(
        'could not fetch original: ${e.message ?? e.code}',
        FailureKind.transient,
      );
    }
    throw const SourceException(
      'could not fetch original (iCloud download failed?)',
      FailureKind.transient,
    );
  }

  /// photo_manager copies originals into the app cache; call after each run
  /// so large videos don't stay duplicated in the sandbox.
  Future<void> clearCache() => PhotoManager.clearFileCache();
}
