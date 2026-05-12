import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  final String _repo = 'nikhilpand/atmos-app';
  static const _channel = MethodChannel('com.example.atmos/install');

  /// Check for updates
  /// Returns [GithubRelease] if an update is available, null otherwise.
  Future<GithubRelease?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final release = GithubRelease.fromJson(data);
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
    // Detect architecture from platform
    final arch = _detectArch();
    
    // Try to find arch-specific APK
    if (arch.isNotEmpty) {
      for (final asset in release.assets) {
        if (asset.name.contains(arch) && asset.name.endsWith('.apk')) {
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

  String _detectArch() {
    // Use dart:io to detect architecture
    try {
      final proc = Process.runSync('getprop', ['ro.product.cpu.abi']);
      final abi = (proc.stdout as String).trim();
      if (abi.contains('arm64')) return 'arm64-v8a';
      if (abi.contains('armeabi')) return 'armeabi-v7a';
      if (abi.contains('x86_64')) return 'x86_64';
      if (abi.contains('x86')) return 'x86';
    } catch (_) {}
    return 'arm64-v8a'; // Most common default
  }

  /// Download and install APK via native FileProvider intent
  Future<void> downloadAndInstall(
    GithubAsset asset,
    void Function(double progress) onProgress,
  ) async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    final filePath = '${dir.path}/${asset.name}';
    final file = File(filePath);

    if (await file.exists()) {
      await file.delete();
    }

    final request = http.Request('GET', Uri.parse(asset.downloadUrl));
    final response = await http.Client().send(request);
    final contentLength = response.contentLength ?? 0;

    int received = 0;
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (contentLength > 0) {
        onProgress(received / contentLength);
      }
    }

    await sink.flush();
    await sink.close();

    // Install via native Android Intent + FileProvider
    await _installApk(filePath);
  }

  /// Calls native Android code to install the APK using FileProvider content:// URI
  Future<void> _installApk(String filePath) async {
    try {
      await _channel.invokeMethod('installApk', {'filePath': filePath});
    } on PlatformException catch (e) {
      debugPrint('Native install failed: ${e.message}');
      rethrow;
    }
  }
}
