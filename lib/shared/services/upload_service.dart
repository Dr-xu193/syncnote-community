import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:syncnote/core/community_config.dart';

class WebdavInventory {
  const WebdavInventory({
    required this.fileCount,
    required this.totalBytes,
    required this.folderCount,
    required this.filesByFolder,
  });

  final int fileCount;
  final int totalBytes;
  final int folderCount;
  final Map<String, int> filesByFolder;
}

class UploadService {
  UploadService._();
  static final UploadService instance = UploadService._();

  String get _webdavUrl {
    final value = CommunityConfig.string('webdav.url');
    final url = value.isEmpty ? 'https://dav.jianguoyun.com/dav/' : value;
    return url.endsWith('/') ? url : '$url/';
  }

  String get _username => CommunityConfig.string('webdav.username');
  String get _password => CommunityConfig.string('webdav.password');

  String get _authHeader {
    if (_username.isEmpty || _password.isEmpty) {
      throw StateError('请先在社区版服务配置中填写自己的 WebDAV 账号和应用密码');
    }
    final credentials = '$_username:$_password';
    final bytes = utf8.encode(credentials);
    return 'Basic ${base64.encode(bytes)}';
  }

  /// Reads the remote SyncNote tree without downloading file contents.
  ///
  /// The WebDAV `PROPFIND` response exposes only metadata, so this audit does
  /// not create a local copy and has a much smaller transfer cost than a full
  /// backup.
  Future<WebdavInventory> auditRemoteInventory() async {
    final client = http.Client();
    final root = Uri.parse('${_webdavUrl}SyncNote_Attachments/');
    final pending = <Uri>[root];
    final visitedFolders = <String>{};
    final files = <String, _WebdavEntry>{};
    try {
      while (pending.isNotEmpty) {
        final folder = pending.removeLast();
        if (!visitedFolders.add(folder.toString())) continue;
        if (visitedFolders.length > 500) {
          throw const WebdavDownloadException('坚果云目录过多，已停止容量审计');
        }
        final entries = await _readWebdavDirectory(client, folder);
        for (final entry in entries) {
          final target = root.resolve(entry.href);
          if (target.toString() == folder.toString()) continue;
          if (entry.isCollection) {
            pending.add(target);
          } else {
            files[target.toString()] = entry;
          }
        }
      }
      return _inventoryFromEntries(
        files.values,
        folderCount: visitedFolders.length,
      );
    } finally {
      client.close();
    }
  }

  Future<List<_WebdavEntry>> _readWebdavDirectory(
    http.Client client,
    Uri folder,
  ) async {
    final request = http.Request('PROPFIND', folder)
      ..headers.addAll({
        'Authorization': _authHeader,
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) SyncNote/1.0',
      })
      ..body = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:resourcetype/><d:getcontentlength/></d:prop>
</d:propfind>''';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final body = await response.stream.bytesToString();
    if (response.statusCode != 207 && response.statusCode != 200) {
      throw WebdavDownloadException('坚果云容量审计失败（HTTP ${response.statusCode}）');
    }
    return _parseWebdavEntries(body);
  }

  @visibleForTesting
  static WebdavInventory parseWebdavInventory(String xmlText) {
    final entries = _parseWebdavEntries(xmlText);
    return _inventoryFromEntries(
      entries.where((entry) => !entry.isCollection),
      folderCount: entries.where((entry) => entry.isCollection).length,
    );
  }

  static List<_WebdavEntry> _parseWebdavEntries(String xmlText) {
    final document = XmlDocument.parse(xmlText);
    final entries = <_WebdavEntry>[];

    String? childText(XmlElement root, String localName) {
      for (final element in root.descendants.whereType<XmlElement>()) {
        if (element.name.local == localName) return element.innerText.trim();
      }
      return null;
    }

    for (final response in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'response',
    )) {
      final href = childText(response, 'href') ?? '';
      if (href.isEmpty) continue;
      final isCollection = response.descendants.whereType<XmlElement>().any(
        (element) => element.name.local == 'collection',
      );
      final length =
          int.tryParse(childText(response, 'getcontentlength') ?? '') ?? 0;
      entries.add(
        _WebdavEntry(
          href: href,
          isCollection: isCollection || href.endsWith('/'),
          length: length,
        ),
      );
    }
    return entries;
  }

  static WebdavInventory _inventoryFromEntries(
    Iterable<_WebdavEntry> entries, {
    required int folderCount,
  }) {
    var files = 0;
    var bytes = 0;
    final byFolder = <String, int>{};
    for (final entry in entries) {
      final href = Uri.decodeFull(entry.href);
      files++;
      bytes += entry.length;
      final path = Uri.tryParse(href)?.pathSegments ?? const <String>[];
      final marker = path.indexOf('SyncNote_Attachments');
      final folder = marker >= 0 && marker + 1 < path.length
          ? path[marker + 1]
          : '其他';
      byFolder[folder] = (byFolder[folder] ?? 0) + entry.length;
    }
    return WebdavInventory(
      fileCount: files,
      totalBytes: bytes,
      folderCount: folderCount,
      filesByFolder: Map.unmodifiable(byFolder),
    );
  }

  /// Ensures that our SyncNote folders exist in Jianguoyun
  Future<void> _ensureFolderExists(String folder) async {
    try {
      final appUrl = Uri.parse('${_webdavUrl}SyncNote_Attachments/');
      final req1 = http.Request('MKCOL', appUrl)
        ..headers['Authorization'] = _authHeader
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      await http.Client().send(req1);
    } catch (_) {}

    try {
      final subUrl = Uri.parse('${_webdavUrl}SyncNote_Attachments/$folder/');
      final req2 = http.Request('MKCOL', subUrl)
        ..headers['Authorization'] = _authHeader
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      await http.Client().send(req2);
    } catch (_) {}
  }

  /// Uploads a local file to Jianguoyun WebDAV without creating a permanent
  /// application-local fallback copy.
  Future<String?> uploadFile(File file, String folder) async {
    final baseName = file.path.split(RegExp(r'[/\\]')).last;
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$baseName';

    try {
      return await uploadCloudFile(
        stream: file.openRead(),
        contentLength: await file.length(),
        remoteFileName: fileName,
        folder: folder,
      );
    } catch (e) {
      debugPrint('WebDAV upload failed without local fallback: $e');
      return null;
    }
  }

  /// Streams a file directly to WebDAV without creating an app-local copy.
  ///
  /// Unlike [uploadFile], this method deliberately has no local fallback. It
  /// is used by the cloud-file manager, where a failed upload must remain a
  /// failed upload instead of silently consuming device storage.
  Future<String> uploadCloudFile({
    required Stream<List<int>> stream,
    required int contentLength,
    required String remoteFileName,
    String contentType = 'application/octet-stream',
    String folder = 'cloud_files',
    ValueChanged<double>? onProgress,
  }) async {
    await _ensureFolderExists(folder);

    final uploadUrl = Uri.parse(
      '${_webdavUrl}SyncNote_Attachments/$folder/$remoteFileName',
    );
    final request = http.StreamedRequest('PUT', uploadUrl)
      ..contentLength = contentLength
      ..headers.addAll({
        'Authorization': _authHeader,
        'Content-Type': contentType,
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });

    final client = http.Client();
    var uploaded = 0;
    try {
      final responseFuture = client.send(request);
      await request.sink.addStream(
        stream.map((chunk) {
          uploaded += chunk.length;
          onProgress?.call(
            contentLength == 0 ? 1 : (uploaded / contentLength).clamp(0, 1),
          );
          return chunk;
        }),
      );
      await request.sink.close();
      final response = await responseFuture;
      await response.stream.drain<void>();
      if (response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 204) {
        onProgress?.call(1);
        return 'webdav://$folder/$remoteFileName';
      }
      throw WebdavUploadException('坚果云拒绝了上传请求（HTTP ${response.statusCode}）');
    } finally {
      client.close();
    }
  }

  /// Downloads a cloud file only to the path explicitly chosen by the user.
  /// No application cache or fallback copy is created.
  Future<void> downloadCloudFileTo(
    String webdavUrl,
    File destination, {
    ValueChanged<double>? onProgress,
  }) async {
    final uri = Uri.parse(webdavUrl);
    final folder = uri.host;
    final fileName = uri.pathSegments.join('/');
    if (folder.isEmpty || fileName.isEmpty) {
      throw const WebdavDownloadException('无效的云文件地址');
    }

    final downloadUrl = Uri.parse(
      '${_webdavUrl}SyncNote_Attachments/$folder/$fileName',
    );
    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', downloadUrl)
        ..headers.addAll({
          'Authorization': _authHeader,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw WebdavDownloadException('云文件下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      sink = destination.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0, 1));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      onProgress?.call(1);
    } catch (_) {
      await sink?.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Downloads into memory for Android's system save picker. The bytes are
  /// handed directly to the Storage Access Framework and are never cached by
  /// SyncNote on disk.
  Future<Uint8List> downloadCloudFileBytes(
    String webdavUrl, {
    int? maxBytes,
    ValueChanged<double>? onProgress,
  }) async {
    final uri = Uri.parse(webdavUrl);
    final folder = uri.host;
    final fileName = uri.pathSegments.join('/');
    if (folder.isEmpty || fileName.isEmpty) {
      throw const WebdavDownloadException('无效的云文件地址');
    }
    final client = http.Client();
    try {
      final request =
          http.Request(
              'GET',
              Uri.parse('${_webdavUrl}SyncNote_Attachments/$folder/$fileName'),
            )
            ..headers.addAll({
              'Authorization': _authHeader,
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw WebdavDownloadException('云文件下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength ?? 0;
      if (maxBytes != null && total > maxBytes) {
        await response.stream.drain<void>();
        throw CloudFileTooLargeException(maxBytes);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        received += chunk.length;
        if (maxBytes != null && received > maxBytes) {
          throw CloudFileTooLargeException(maxBytes);
        }
        bytes.add(chunk);
        if (total > 0) {
          onProgress?.call((received / total).clamp(0, 1));
        }
      }
      onProgress?.call(1);
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }

  /// Deletes a file from WebDAV and also deletes its local cached copy.
  Future<bool> deleteFile(String webdavUrl) async {
    if (!webdavUrl.startsWith('webdav://')) {
      debugPrint('Not a WebDAV URL, skipping deletion: $webdavUrl');
      return false;
    }

    try {
      final uri = Uri.parse(webdavUrl);
      final folder = uri.host;
      final fileName = uri.path.substring(1); // strip leading slash

      final deleteUrl = Uri.parse(
        '${_webdavUrl}SyncNote_Attachments/$folder/$fileName',
      );
      final response = await http.delete(
        deleteUrl,
        headers: {
          'Authorization': _authHeader,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('Successfully deleted file from WebDAV: $webdavUrl');

        // Delete local cached file
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final localFile = File(
            '${appDir.path}/syncnote_attachments/$folder/$fileName',
          );
          if (await localFile.exists()) {
            await localFile.delete();
            debugPrint(
              'Successfully deleted local cached file: ${localFile.path}',
            );
          }
        } catch (localEx) {
          debugPrint('Failed to delete local cached file: $localEx');
        }
        return true;
      } else {
        debugPrint(
          'WebDAV delete returned status code: ${response.statusCode}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('WebDAV delete failed: $e');
      return false;
    }
  }
}

class WebdavCacheManager {
  static final WebdavCacheManager instance = WebdavCacheManager._();
  WebdavCacheManager._();

  final Map<String, ValueNotifier<WebdavCacheState>> _stateNotifiers = {};

  ValueNotifier<WebdavCacheState> getStateNotifier(String webdavUrl) {
    final existing = _stateNotifiers[webdavUrl];
    if (existing != null) {
      return existing;
    }

    final notifier = ValueNotifier<WebdavCacheState>(
      const WebdavCacheState.loading(),
    );
    _stateNotifiers[webdavUrl] = notifier;
    _resolveAndDownload(webdavUrl, notifier);
    return notifier;
  }

  Future<String> resolveLocalPath(
    String webdavUrl, {
    bool retryOnFailure = true,
  }) async {
    final notifier = getStateNotifier(webdavUrl);
    if (notifier.value case WebdavCacheReady(:final path)) {
      return path;
    }
    if (notifier.value is WebdavCacheFailure && retryOnFailure) {
      retry(webdavUrl);
    }

    final completer = Completer<String>();
    void listener() {
      switch (notifier.value) {
        case WebdavCacheReady(:final path):
          notifier.removeListener(listener);
          completer.complete(path);
        case WebdavCacheFailure(:final message):
          notifier.removeListener(listener);
          completer.completeError(WebdavDownloadException(message));
        case WebdavCacheLoading():
          break;
      }
    }

    notifier.addListener(listener);
    listener();
    return completer.future;
  }

  void retry(String webdavUrl) {
    final notifier = _stateNotifiers.putIfAbsent(
      webdavUrl,
      () => ValueNotifier<WebdavCacheState>(const WebdavCacheState.loading()),
    );
    if (notifier.value is WebdavCacheLoading) return;
    notifier.value = const WebdavCacheState.loading();
    _resolveAndDownload(webdavUrl, notifier);
  }

  Future<void> _resolveAndDownload(
    String webdavUrl,
    ValueNotifier<WebdavCacheState> notifier,
  ) async {
    File? partialFile;
    try {
      final uri = Uri.parse(webdavUrl);
      final folder = uri.host;
      final fileName = uri.path.substring(1); // strip leading slash
      if (folder.isEmpty || fileName.isEmpty) {
        throw const FormatException('无效的 WebDAV 文件地址');
      }

      final appDir = await getApplicationDocumentsDirectory();
      final localFolderDir = Directory(
        '${appDir.path}/syncnote_attachments/$folder',
      );
      if (!await localFolderDir.exists()) {
        await localFolderDir.create(recursive: true);
      }

      final localFile = File('${localFolderDir.path}/$fileName');
      if (await localFile.exists()) {
        if (await localFile.length() > 0) {
          notifier.value = WebdavCacheState.ready(localFile.path);
          return;
        }
        await localFile.delete();
      }

      // Download from WebDAV
      final downloadUrl = Uri.parse(
        '${UploadService.instance._webdavUrl}SyncNote_Attachments/$folder/$fileName',
      );
      final response = await http
          .get(
            downloadUrl,
            headers: {
              'Authorization': UploadService.instance._authHeader,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        if (response.bodyBytes.isEmpty) {
          throw const WebdavDownloadException('云端文件内容为空');
        }
        partialFile = File('${localFile.path}.part');
        await partialFile.writeAsBytes(response.bodyBytes, flush: true);
        if (await localFile.exists()) {
          await localFile.delete();
        }
        await partialFile.rename(localFile.path);
        notifier.value = WebdavCacheState.ready(localFile.path);
      } else {
        notifier.value = WebdavCacheState.failure(
          response.statusCode == 404
              ? '云端文件不存在'
              : '下载失败（HTTP ${response.statusCode}）',
        );
      }
    } catch (e) {
      debugPrint('Failed to download WebDAV file: $e');
      if (partialFile != null && await partialFile.exists()) {
        await partialFile.delete();
      }
      notifier.value = WebdavCacheState.failure(
        e is WebdavDownloadException ? e.message : '下载超时或网络不可用',
      );
    }
  }
}

sealed class WebdavCacheState {
  const WebdavCacheState();

  const factory WebdavCacheState.loading() = WebdavCacheLoading;
  const factory WebdavCacheState.ready(String path) = WebdavCacheReady;
  const factory WebdavCacheState.failure(String message) = WebdavCacheFailure;
}

final class WebdavCacheLoading extends WebdavCacheState {
  const WebdavCacheLoading();
}

final class WebdavCacheReady extends WebdavCacheState {
  const WebdavCacheReady(this.path);

  final String path;
}

final class WebdavCacheFailure extends WebdavCacheState {
  const WebdavCacheFailure(this.message);

  final String message;
}

class WebdavDownloadException implements Exception {
  const WebdavDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WebdavUploadException implements Exception {
  const WebdavUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _WebdavEntry {
  const _WebdavEntry({
    required this.href,
    required this.isCollection,
    required this.length,
  });

  final String href;
  final bool isCollection;
  final int length;
}

class CloudFileTooLargeException implements Exception {
  const CloudFileTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => '文件超过纯内存预览上限（${maxBytes ~/ (1024 * 1024)} MB）';
}
