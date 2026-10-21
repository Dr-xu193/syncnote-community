import 'package:flutter/material.dart';
import 'package:syncnote/shared/services/app_lock_service.dart';

class AppLockGate extends StatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  final _pinController = TextEditingController();
  bool _loading = true;
  bool _locked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await AppLockService.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _locked = enabled;
      _loading = false;
    });
  }

  Future<void> _unlockWithDevice() async {
    final ok = await AppLockService.instance.authenticateWithDevice();
    if (!mounted) return;
    if (ok) {
      setState(() => _locked = false);
    } else {
      setState(() => _error = '系统认证不可用或已取消，请使用 PIN');
    }
  }

  Future<void> _unlockWithPin() async {
    final ok = await AppLockService.instance.verifyPin(_pinController.text);
    if (!mounted) return;
    if (ok) {
      setState(() => _locked = false);
    } else {
      setState(() => _error = 'PIN 不正确');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_locked) return widget.child;

    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text('SyncNote 已锁定', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '使用系统认证或 PIN 解锁。本设置只保存在本机。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _unlockWithDevice,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('系统认证解锁'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      errorText: _error,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _unlockWithPin(),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _unlockWithPin,
                    child: const Text('PIN 解锁'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showAppLockSettingsDialog(BuildContext context) async {
  final enabled = await AppLockService.instance.isEnabled();
  if (!context.mounted) return;

  final pinController = TextEditingController();
  final confirmController = TextEditingController();
  String? error;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('应用锁'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(enabled ? '当前已启用 App 锁。' : '设置本机 PIN 后启用 App 锁。'),
                  const SizedBox(height: 12),
                  if (!enabled) ...[
                    TextField(
                      controller: pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '新 PIN（4-12 位数字）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '确认 PIN',
                        errorText: error,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ] else
                    const Text('关闭后不会删除云端数据；PIN 哈希也会从本机清除。'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                if (enabled)
                  FilledButton(
                    onPressed: () async {
                      await AppLockService.instance.disable();
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                    child: const Text('关闭应用锁'),
                  )
                else
                  FilledButton(
                    onPressed: () async {
                      try {
                        if (pinController.text != confirmController.text) {
                          setState(() => error = '两次 PIN 不一致');
                          return;
                        }
                        await AppLockService.instance.enableWithPin(
                          pinController.text,
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      } catch (e) {
                        setState(() => error = e.toString());
                      }
                    },
                    child: const Text('启用应用锁'),
                  ),
              ],
            );
          },
        );
      },
    );
  } finally {
    pinController.dispose();
    confirmController.dispose();
  }
}
