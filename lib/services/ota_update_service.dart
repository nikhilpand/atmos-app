import 'dart:ffi';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

final otaUpdateProvider = Provider((ref) => OtaUpdateService());

class GithubRelease {
  final String tagName;
  final String body;
  final List<GithubAsset> assets;

  GithubRelease({required this.tagName, required this.body, required this.assets});

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    return GithubRelease(
      tagName: json['tag_name'] ?? '',
      body: json['body'] ?? '',
      assets: (json['assets'] as List?)
          ?.map((a) => GithubAsset.fromJson(a as Map<String, dynamic>))
          .toList() ?? [],
    );
  }
}

class GithubAsset {
  final String name;
  final String downloadUrl;

  GithubAsset({required this.name, required this.downloadUrl});

  factory GithubAsset.fromJson(Map<String, dynamic> json) {
    return GithubAsset(
      name: json['name'] ?? '',
      downloadUrl: json['browser_download_url'] ?? '',
    );
  }
}

class OtaUpdateService {
  final Dio _dio = Dio();
  final String _repo = 'nikhilpand/atmos-app';

  /// Check for updates
  /// Returns [GithubRelease] if an update is available, null otherwise.
  Future<GithubRelease?> checkForUpdate() async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$_repo/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github.v3+json'}),
      );

      final release = GithubRelease.fromJson(response.data);
      if (release.tagName.isEmpty) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Basic semver check (e.g. v1.0.9 vs 1.0.8)
      final remoteVersionStr = release.tagName.replaceAll('v', '').split('+').first;
      final localVersionStr = currentVersion.replaceAll('v', '').split('+').first;

      if (_isRemoteNewer(remoteVersionStr, localVersionStr)) {
        return release;
      }
      return null;
    } catch (e) {
      debugPrint('Error checking for OTA update: $e');
      return null;
    }
  }

  bool _isRemoteNewer(String remote, String local) {
    final rParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final lParts = local.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    
    for (int i = 0; i < 3; i++) {
      final r = i < rParts.length ? rParts[i] : 0;
      final l = i < lParts.length ? lParts[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false; // Equal
  }

  /// Finds the best APK asset for the current architecture
  GithubAsset? getBestAsset(GithubRelease release) {
    final abi = Abi.current();
    String targetSuffix = '';

    if (abi == Abi.androidArm64) {
      targetSuffix = 'arm64-v8a';
    } else if (abi == Abi.androidArm) {
      targetSuffix = 'armeabi-v7a';
    } else if (abi == Abi.androidX64) {
      targetSuffix = 'x86_64';
    }

    // Try to find arch-specific APK
    if (targetSuffix.isNotEmpty) {
      for (final asset in release.assets) {
        if (asset.name.contains(targetSuffix) && asset.name.endsWith('.apk')) {
          return asset;
        }
      }
    }

    // Fallback to Universal APK (no arch suffix)
    for (final asset in release.assets) {
      if (asset.name.endsWith('.apk') && 
          !asset.name.contains('arm64') && 
          !asset.name.contains('armeabi') && 
          !asset.name.contains('x86')) {
        return asset;
      }
    }

    // Absolute fallback
    return release.assets.where((a) => a.name.endsWith('.apk')).firstOrNull;
  }

  /// Download and prompt installation
  Future<void> downloadAndInstall(
    GithubAsset asset,
    void Function(double progress) onProgress,
  ) async {
    try {
      final dir = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
      final filePath = '${dir.path}/${asset.name}';
      final file = File(filePath);

      if (await file.exists()) {
        await file.delete();
      }

      await _dio.download(
        asset.downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            onProgress(received / total);
          }
        },
      );

      // Open the downloaded APK
      final result = await OpenFile.open(filePath);
      debugPrint('OpenFile result: ${result.message}');
    } catch (e) {
      debugPrint('Error downloading or installing update: $e');
      rethrow;
    }
  }
}
