import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLockService {
  AppLockService._();

  static final AppLockService instance = AppLockService._();

  static const _enabledKey = 'app_lock_enabled';
  static const _saltKey = 'app_lock_pin_salt';
  static const _hashKey = 'app_lock_pin_hash';

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
  final LocalAuthentication _auth = LocalAuthentication();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_enabledKey) ?? false;
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(_enabledKey) ?? false;
    enabled.value = value;
    return value;
  }

  Future<void> enableWithPin(String pin) async {
    _validatePin(pin);
    final prefs = await SharedPreferences.getInstance();
    final salt = _newSalt();
    await prefs.setBool(_enabledKey, true);
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_hashKey, _hashPin(pin, salt));
    enabled.value = true;
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_enabledKey);
    await prefs.remove(_saltKey);
    await prefs.remove(_hashKey);
    enabled.value = false;
  }

  Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_saltKey);
    final hash = prefs.getString(_hashKey);
    if (salt == null || hash == null) return false;
    return _hashPin(pin, salt) == hash;
  }

  Future<bool> authenticateWithDevice() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!supported && !canCheck) return false;
      return _auth.authenticate(
        localizedReason: '解锁 SyncNote',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('Device authentication unavailable: $e');
      return false;
    }
  }

  static void _validatePin(String pin) {
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw const FormatException('PIN 必须是 4 到 12 位数字');
    }
  }

  static String _newSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String _hashPin(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt:$pin')).toString();
  }
}
