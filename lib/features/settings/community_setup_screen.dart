import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncnote/core/community_config.dart';

/// Public installers start here before Firebase/AI/WebDAV initialization.
class CommunitySetupScreen extends StatefulWidget {
  const CommunitySetupScreen({super.key, this.onConfigured});
  final Future<void> Function()? onConfigured;

  @override
  State<CommunitySetupScreen> createState() => _CommunitySetupScreenState();
}

class _CommunitySetupScreenState extends State<CommunitySetupScreen> {
  static const _fields = <String, String>{
    'firebase.projectId': 'Firebase Project ID',
    'firebase.apiKey': 'Firebase API Key',
    'firebase.appId': 'Firebase App ID（当前平台）',
    'firebase.messagingSenderId': 'Firebase Messaging Sender ID',
    'firebase.authDomain': 'Firebase Auth Domain（可选）',
    'firebase.storageBucket': 'Firebase Storage Bucket（可选）',
    'google.serverClientId': 'Google Web / Server Client ID（Android 必填）',
    'google.desktopClientId': 'Google Desktop Client ID（Windows 必填）',
    'google.desktopClientSecret': 'Google Desktop Client Secret（Windows 必填）',
    'webdav.url': 'WebDAV HTTPS 地址（以 / 结尾）',
    'webdav.username': 'WebDAV 账号',
    'webdav.password': 'WebDAV 应用密码',
    'ai.deepseekApiKey': 'DeepSeek API Key',
    'ai.geminiApiKey': 'Gemini API Key（语音转写，可选）',
  };
  late final Map<String, TextEditingController> _controllers;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final path in _fields.keys)
        path: TextEditingController(text: CommunityConfig.string(path)),
    };
    if (_controllers['webdav.url']!.text.isEmpty) {
      _controllers['webdav.url']!.text = 'https://dav.jianguoyun.com/dav/';
    }
    _message = CommunityConfig.loadError;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final config = <String, dynamic>{};
    for (final entry in _controllers.entries) {
      final parts = entry.key.split('.');
      final group =
          config.putIfAbsent(parts[0], () => <String, dynamic>{})
              as Map<String, dynamic>;
      group[parts[1]] = entry.value.text.trim();
    }
    final error = CommunityConfig.validate(
      config,
      platform: defaultTargetPlatform,
    );
    if (error != null) {
      setState(() => _message = error);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    var saved = false;
    try {
      await CommunityConfig.save(config, activate: widget.onConfigured != null);
      saved = true;
      if (widget.onConfigured != null) {
        await widget.onConfigured!();
      } else if (mounted) {
        setState(() => _message = '配置已安全保存在此设备。请彻底关闭应用后重新打开，配置才会生效。');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = saved
              ? '配置已保存，但服务初始化失败。请核对 Firebase 配置和网络后重启。'
              : '配置保存失败，请检查本机安全存储是否可用。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String title, String prefix, {bool expanded = false}) =>
      ExpansionTile(
        title: Text(title),
        initiallyExpanded: expanded,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          for (final field in _fields.entries.where(
            (e) => e.key.startsWith(prefix),
          ))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: _controllers[field.key],
                autocorrect: false,
                enableSuggestions: false,
                obscureText:
                    field.key.toLowerCase().endsWith('apikey') ||
                    field.key.endsWith('Secret') ||
                    field.key.endsWith('password'),
                decoration: InputDecoration(
                  labelText: field.value,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SyncNote Community · 服务配置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('连接你自己的服务', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text(
              '社区版不提供共享账号或后台。先配置你自己的 Firebase 和 Google 登录，'
              '坚果云与 AI 按需填写。配置通过系统安全存储保存在本设备，不随笔记备份上传。'
              '详细步骤见公开仓库 docs/SETUP.md。',
            ),
            const SizedBox(height: 12),
            _section('1. Firebase（必填）', 'firebase.', expanded: true),
            _section('2. Google 登录（按当前平台填写）', 'google.', expanded: true),
            _section('3. WebDAV 云文件（可选）', 'webdav.'),
            _section('4. AI 模型（可选，费用由你的服务账号承担）', 'ai.'),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_message!, key: const ValueKey('setup-message')),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? '保存中…' : '保存配置'),
            ),
            const SizedBox(height: 16),
            const Text('请勿在 Issues、截图、日志或配置示例中发布 API Key、应用密码与私钥。'),
          ],
        ),
      ),
    ),
  );
}
