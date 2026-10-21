import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/shared/services/storage_audit_service.dart';
import 'package:syncnote/shared/services/cold_archive_service.dart';

class StorageAuditScreen extends StatefulWidget {
  const StorageAuditScreen({super.key});

  @override
  State<StorageAuditScreen> createState() => _StorageAuditScreenState();
}

class _StorageAuditScreenState extends State<StorageAuditScreen> {
  StorageAuditSnapshot? _snapshot;
  BackupAuditResult? _backup;
  Object? _error;
  bool _auditing = false;
  bool _verifyingBackup = false;
  bool _findingArchives = false;
  bool _archiving = false;
  bool _testingArchiveTransport = false;
  ColdArchiveTransportAudit? _archiveTransportAudit;
  List<ColdArchiveCandidate> _candidates = const [];

  Future<void> _runAudit() async {
    setState(() {
      _auditing = true;
      _error = null;
    });
    try {
      final result = await StorageAuditService.instance.audit();
      if (mounted) setState(() => _snapshot = result);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _auditing = false);
    }
  }

  Future<void> _verifyBackup() async {
    setState(() {
      _verifyingBackup = true;
      _error = null;
    });
    try {
      final result = await StorageAuditService.instance.verifyFullBackup();
      if (mounted) setState(() => _backup = result);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _verifyingBackup = false);
    }
  }

  Future<void> _findArchiveCandidates() async {
    setState(() {
      _findingArchives = true;
      _error = null;
    });
    try {
      final result = await ColdArchiveService.instance.findCandidates();
      if (mounted) setState(() => _candidates = result);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _findingArchives = false);
    }
  }

  Future<void> _archiveCandidates() async {
    if (_candidates.isEmpty || _archiving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认冷归档？'),
        content: Text(
          '将 ${_candidates.length} 条候选正文压缩到坚果云。只有远端校验通过后才会精简 Firestore 正文；标题、标签、关系和搜索索引继续保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _archiving = true;
      _error = null;
    });
    try {
      await ColdArchiveService.instance.archiveCandidates(_candidates);
      if (!mounted) return;
      setState(() => _candidates = const []);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('冷归档已上传、校验并提交')));
      await _runAudit();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  Future<void> _restoreArchive(ColdArchiveIndexRecord record) async {
    try {
      await ColdArchiveService.instance.restoreRecord(record);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('“${record.title}”已恢复到在线数据')));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _verifyArchiveTransport() async {
    setState(() {
      _testingArchiveTransport = true;
      _error = null;
    });
    try {
      final result = await ColdArchiveService.instance.verifyRemoteTransport();
      if (mounted) setState(() => _archiveTransportAudit = result);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _testingArchiveTransport = false);
    }
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('存储与基线审计')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '这里只读取云端元数据并估算容量，不会下载文件正文或创建本地镜像。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _auditing ? null : _runAudit,
            icon: _auditing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.analytics_outlined),
            label: Text(_auditing ? '正在审计…' : '读取当前云端容量'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('操作失败：$_error'),
              ),
            ),
          ],
          if (snapshot != null) ...[
            const SizedBox(height: 16),
            _SummaryCard(
              title: 'Firestore',
              icon: Icons.storage_outlined,
              lines: [
                '${snapshot.firestoreDocuments} 个文档',
                '估算 ${_size(snapshot.estimatedFirestoreBytes)}',
                '抽样估算，不包含 Firestore 索引开销',
              ],
            ),
            const SizedBox(height: 10),
            _SummaryCard(
              title: '坚果云 SyncNote_Attachments',
              icon: Icons.cloud_outlined,
              lines: [
                '${snapshot.webdav.fileCount} 个文件',
                '共 ${_size(snapshot.webdav.totalBytes)}',
                '${snapshot.webdav.folderCount} 个目录',
              ],
            ),
            const SizedBox(height: 10),
            _SummaryCard(
              title: 'Firestore 容量参考（1 GiB）',
              icon: Icons.speed_rounded,
              lines: [
                '${(snapshot.firestoreUsageRatio() * 100).toStringAsFixed(3)}% · ${snapshot.capacityLevel()}',
                '60% 提醒、75% 建议、85% 优先归档',
                '只计算 Firestore 估算正文；不与坚果云混算',
                '坚果云当前 ${_size(snapshot.webdav.totalBytes)}，未配置总额度，不计算百分比',
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Firestore 分类',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            ...snapshot.collections.entries.map(
              (entry) => ListTile(
                dense: true,
                title: Text(entry.key),
                subtitle: Text('抽样 ${entry.value.sampledDocuments} 条'),
                trailing: Text(
                  '${entry.value.documents} 条 · ${_size(entry.value.estimatedBytes)}',
                ),
              ),
            ),
            if (snapshot.webdav.filesByFolder.isNotEmpty) ...[
              const Divider(),
              Text('坚果云分类', style: Theme.of(context).textTheme.titleMedium),
              ...snapshot.webdav.filesByFolder.entries.map(
                (entry) => ListTile(
                  dense: true,
                  title: Text(entry.key),
                  trailing: Text(_size(entry.value)),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '审计时间：${DateFormat('yyyy-MM-dd HH:mm:ss').format(snapshot.generatedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Text('冷归档', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text(
            '普通归档仍在 Firestore；这里的冷归档会把完整正文压缩到坚果云，Firestore 保留标题、日期、标签、摘要和关系。默认只建议，必须手动确认。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _findingArchives ? null : _findArchiveCandidates,
                icon: _findingArchives
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.inventory_2_outlined),
                label: const Text('检查归档建议'),
              ),
              OutlinedButton.icon(
                onPressed: _testingArchiveTransport
                    ? null
                    : _verifyArchiveTransport,
                icon: _testingArchiveTransport
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined),
                label: const Text('远端通道自检'),
              ),
              if (_candidates.isNotEmpty)
                FilledButton.icon(
                  onPressed: _archiving ? null : _archiveCandidates,
                  icon: _archiving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: Text('归档 ${_candidates.length} 条'),
                ),
            ],
          ),
          if (_archiveTransportAudit case final audit?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('临时归档上传、下载、哈希和解析均通过'),
              subtitle: Text(
                '${audit.recordCount} 条记录 · ${_size(audit.archiveBytes)} · 远端临时包已删除',
              ),
            ),
          if (!_findingArchives && _candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('尚未检查，或当前没有达到规则的候选。'),
            ),
          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._candidates
                .take(20)
                .map(
                  (item) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.archive_outlined),
                    title: Text(item.title),
                    subtitle: Text(item.reason),
                    trailing: Text(_size(item.estimatedBytes)),
                  ),
                ),
          ],
          const SizedBox(height: 12),
          StreamBuilder<List<ColdArchiveIndexRecord>>(
            stream: ColdArchiveService.instance.watchArchivedRecords(),
            builder: (context, snapshot) {
              final records = snapshot.data ?? const [];
              if (snapshot.hasError) {
                return Text('归档索引读取失败：${snapshot.error}');
              }
              if (records.isEmpty) return const Text('当前没有冷归档记录。');
              return ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('已冷归档 ${records.length} 条'),
                children: records
                    .map(
                      (record) => ListTile(
                        title: Text(record.title),
                        subtitle: Text(
                          '${record.collection} · ${DateFormat('yyyy-MM-dd').format(record.archivedAt)}',
                        ),
                        trailing: TextButton(
                          onPressed: () => _restoreArchive(record),
                          child: const Text('恢复'),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Text('完整备份自检', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text('在内存中生成并重新解析完整 ZIP，用于确认当前数据能够备份；不会保存额外本地文件。'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _verifyingBackup ? null : _verifyBackup,
            icon: _verifyingBackup
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.verified_outlined),
            label: Text(_verifyingBackup ? '正在生成并校验…' : '执行备份自检'),
          ),
          if (_backup case final result?) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: const Text('ZIP 生成与解析成功'),
                subtitle: Text(
                  '${result.preview.totalDocuments} 个文档，'
                  '${result.preview.attachmentCount} 个附件，'
                  '压缩包 ${_size(result.archiveBytes)}',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.icon,
    required this.lines,
  });

  final String title;
  final IconData icon;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 5),
                  ...lines.map((line) => Text(line)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
