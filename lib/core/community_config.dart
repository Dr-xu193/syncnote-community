import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CommunityConfig {
  CommunityConfig._();

  static const _storage = FlutterSecureStorage();
  static const _storageKey = 'syncnote_community_services_v1';
  static Map<String, dynamic> _values = {};
  static String? loadError;

  static String string(String path) => readString(_values, path);

  static String readString(Map<String, dynamic> values, String path) {
    Object? current = values;
    for (final segment in path.split('.')) {
      if (current is! Map) return '';
      current = current[segment];
    }
    return current is String ? current.trim() : '';
  }

  static Map<String, dynamic> get values =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(_values)) as Map);

  static Future<void> load() async {
    loadError = null;
    try {
      final saved = await _storage.read(key: _storageKey);
      _values = saved == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(saved) as Map);
    } catch (_) {
      _values = {};
      loadError = '无法读取本机服务配置，请重新填写。';
    }
  }

  static bool get configured =>
      validate(_values, platform: defaultTargetPlatform) == null;

  static String? validate(
    Map<String, dynamic> values, {
    required TargetPlatform platform,
  }) {
    final requiredPaths = [
      'firebase.projectId',
      'firebase.apiKey',
      'firebase.appId',
      'firebase.messagingSenderId',
      if (platform == TargetPlatform.windows) 'google.desktopClientId',
      if (platform == TargetPlatform.windows) 'google.desktopClientSecret',
      if (platform == TargetPlatform.android) 'google.serverClientId',
    ];
    for (final path in requiredPaths) {
      final value = readString(values, path);
      if (value.isEmpty || value.startsWith('YOUR_')) {
        return '请填写 $path（使用你自己的项目配置）。';
      }
    }
    final webdav = readString(values, 'webdav.url');
    if (webdav.isNotEmpty) {
      final uri = Uri.tryParse(webdav);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        return 'WebDAV 地址必须是没有内嵌账号、查询参数的 HTTPS 地址。';
      }
    }
    return null;
  }

  static Future<void> save(
    Map<String, dynamic> values, {
    bool activate = false,
  }) async {
    await _storage.write(key: _storageKey, value: jsonEncode(values));
    if (activate) _values = values;
  }

  static FirebaseOptions get firebaseOptions => FirebaseOptions(
    apiKey: string('firebase.apiKey'),
    appId: string('firebase.appId'),
    messagingSenderId: string('firebase.messagingSenderId'),
    projectId: string('firebase.projectId'),
    authDomain: _optional('firebase.authDomain'),
    storageBucket: _optional('firebase.storageBucket'),
  );

  static String? _optional(String path) {
    final value = string(path);
    return value.isEmpty ? null : value;
  }
}
