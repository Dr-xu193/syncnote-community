import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncnote/shared/services/android_integration_service.dart';

Future<void> showAndroidPermissionCenter(BuildContext context) async {
  if (kIsWeb || !Platform.isAndroid) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const _AndroidPermissionCenterDialog(),
  );
}

class _AndroidPermissionCenterDialog extends StatefulWidget {
  const _AndroidPermissionCenterDialog();

  @override
  State<_AndroidPermissionCenterDialog> createState() =>
      _AndroidPermissionCenterDialogState();
}

class _AndroidPermissionCenterDialogState
    extends State<_AndroidPermissionCenterDialog> {
  AndroidPermissionSnapshot? _snapshot;
  bool _loading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final snapshot = await AndroidIntegrationService.instance
        .getPermissionSnapshot();
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  Future<void> _open(String target) async {
    await AndroidIntegrationService.instance.openPermissionTarget(target);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _refresh();
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await AndroidIntegrationService.instance.triggerImmediateAlarmSync(
      reason: 'permission_center',
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已提交后台闹钟重建任务')));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final unmet = snapshot == null
        ? const <_PermissionItem>[]
        : _unmet(snapshot);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.admin_panel_settings_outlined),
          SizedBox(width: 8),
          Text('Android 权限中心'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (snapshot == null)
                    const Text('无法读取权限状态，请在手机系统设置中检查 SyncNote 权限。')
                  else if (unmet.isEmpty)
                    const _AllGoodPanel()
                  else ...[
                    const Text('以下权限会影响后台闹钟、锁屏弹窗或声音。只显示当前未满足项：'),
                    const SizedBox(height: 12),
                    ...unmet.map(
                      (item) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.warning_amber_rounded),
                          title: Text(item.title),
                          subtitle: Text(item.description),
                          trailing: TextButton(
                            onPressed: () => _open(item.target),
                            child: const Text('去设置'),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _syncing ? null : _syncNow,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.alarm_on_outlined),
                    label: const Text('立即重建本机任务闹钟'),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: _refresh, child: const Text('刷新')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  List<_PermissionItem> _unmet(AndroidPermissionSnapshot snapshot) {
    final items = <_PermissionItem>[];
    if (!snapshot.notifications) {
      items.add(
        const _PermissionItem(
          title: '通知权限',
          description: '没有通知权限时，闹钟无法弹出系统通知。',
          target: 'notifications',
        ),
      );
    }
    if (!snapshot.exactAlarms) {
      items.add(
        const _PermissionItem(
          title: '精确闹钟',
          description: '没有精确闹钟权限时，Android 可能延迟提醒。',
          target: 'exactAlarms',
        ),
      );
    }
    if (!snapshot.fullScreenIntent) {
      items.add(
        const _PermissionItem(
          title: '全屏通知',
          description: '没有全屏通知权限时，锁屏弹窗可能无法显示。',
          target: 'fullScreenIntent',
        ),
      );
    }
    if (!snapshot.notificationPolicy) {
      items.add(
        const _PermissionItem(
          title: '勿扰模式访问',
          description: '没有勿扰访问时，勿扰模式下可能没有声音。',
          target: 'notificationPolicy',
        ),
      );
    }
    if (!snapshot.ignoringBatteryOptimizations) {
      items.add(
        const _PermissionItem(
          title: '电池优化',
          description: '系统电池优化可能限制后台补偿任务。',
          target: 'battery',
        ),
      );
    }
    return items;
  }
}

class _AllGoodPanel extends StatelessWidget {
  const _AllGoodPanel();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.green),
            SizedBox(width: 12),
            Expanded(child: Text('当前关键权限均已满足。')),
          ],
        ),
      ),
    );
  }
}

class _PermissionItem {
  const _PermissionItem({
    required this.title,
    required this.description,
    required this.target,
  });

  final String title;
  final String description;
  final String target;
}
