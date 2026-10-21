import 'package:flutter/material.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_runtime.dart';

class StockAgentExperimentScreen extends StatefulWidget {
  const StockAgentExperimentScreen({super.key, this.controller});

  final StockAgentExperimentController? controller;

  @override
  State<StockAgentExperimentScreen> createState() =>
      _StockAgentExperimentScreenState();
}

class _StockAgentExperimentScreenState
    extends State<StockAgentExperimentScreen> {
  late final StockAgentExperimentController _controller;
  StockAgentExperiment? _experiment;
  List<StockAgentDayIndex> _days = const [];
  List<Map<String, dynamic>> _reports = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? StockAgentRuntime.instance;
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final experiment = await _controller.load();
      final days = experiment == null
          ? <StockAgentDayIndex>[]
          : await _controller.listDays();
      final reports = experiment == null
          ? <Map<String, dynamic>>[]
          : await _controller.listReports();
      days.sort((a, b) => b.logicalDay.compareTo(a.logicalDay));
      if (!mounted) return;
      setState(() {
        _experiment = experiment;
        _days = days;
        _reports = reports;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDay(StockAgentDayIndex index) async {
    try {
      final journal = await _controller.readDay(index.logicalDay);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${index.logicalDay} · 原始操盘日记'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 610),
            child: SingleChildScrollView(
              child: _JournalDetail(journal: journal),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '日记读取或校验失败：$error');
    }
  }

  Future<void> _openReport(String periodId) async {
    try {
      final report = await _controller.readReport(periodId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            periodId == 'month'
                ? '30 天期末报告'
                : '${periodId.replaceFirst('week-', '第')} 周报告',
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 610),
            child: SingleChildScrollView(
              child: _ReportDetail(
                report: report,
                onOpenDay: (day) {
                  final matching = _days
                      .where((item) => item.logicalDay == day)
                      .firstOrNull;
                  if (matching == null) return;
                  Navigator.of(context).pop();
                  _openDay(matching);
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '报告读取或校验失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 1000 元 · 30 天模拟实验')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  if (_error != null) ...[
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(_error!),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_experiment == null)
                    _buildIntroduction(context)
                  else
                    _buildAccount(context),
                  const SizedBox(height: 14),
                  if (_experiment != null) ...[
                    _buildReportSection(context),
                    const SizedBox(height: 14),
                    Text('逐日操盘过程', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    if (_days.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('尚无日记。第一次研究和云端封存完成后会显示在这里。'),
                        ),
                      )
                    else
                      for (final day in _days)
                        Card(
                          child: ListTile(
                            title: Text(day.logicalDay),
                            subtitle: Text(
                              '${day.eventIds.length} 条记录 · '
                              '${day.sealed ? '已封存并校验' : '仍在记录'} · '
                              '${(day.byteLength / 1024).toStringAsFixed(1)} KB',
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: day.archiveUrl.isEmpty
                                ? null
                                : () => _openDay(day),
                          ),
                        ),
                  ],
                  const SizedBox(height: 14),
                  const Text(
                    '只有虚拟资金，没有券商连接或真实委托。Windows 开机并保持 SyncNote 在托盘运行时可按日自动研究；彻底关闭或电脑关机期间不会补造交易。Android 仅查看同步结果。',
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildReportSection(BuildContext context) {
    final experiment = _experiment!;
    final startWall = experiment.startedAt.toUtc().add(
      const Duration(hours: 8),
    );
    final startDay = DateTime.utc(
      startWall.year,
      startWall.month,
      startWall.day,
    );
    final now = DateTime.now().toUtc();
    final saved = {
      for (final report in _reports) '${report['periodId'] ?? ''}': report,
    };
    final periods = <String>[
      for (var week = 1; week <= 5; week++)
        if (!now.isBefore(
          startDay
              .add(Duration(days: (week * 7).clamp(0, 30)))
              .subtract(const Duration(hours: 8)),
        ))
          'week-$week',
      if (!now.isBefore(experiment.endsAt)) 'month',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('周报与期末复盘', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (periods.isEmpty)
          const Text('满 7 天后可查看第一份周报；30 天结束后生成期末报告。')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final period in periods)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : saved.containsKey(period)
                      ? () => _openReport(period)
                      : !_controller.canRunLocally
                      ? null
                      : () => _perform(() async {
                          await _controller.generateReport(period);
                        }),
                  child: Text(
                    '${period == 'month' ? '30 天期末' : '第${period.split('-').last}周'}'
                    '${saved.containsKey(period) ? ' · 查看' : ' · 生成'}',
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildIntroduction(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('一次只运行一个自主实验', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          const Text(
            'AI 只拥有人民币 1000 元虚拟初始资金和 30 个自然日，自主选择研究对象、投入比例或持币，目标是提高期末扣费后的账户总值。不能追加资金，也不会操作真实股票。',
          ),
          const SizedBox(height: 14),
          if (_controller.canRunLocally)
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _perform(() async {
                      await _controller.start();
                    }),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_busy ? '启动中' : '启动 30 天虚拟实验'),
            )
          else
            const Text('请在 Windows 端启动；手机端只负责查看。'),
        ],
      ),
    ),
  );

  Widget _buildAccount(BuildContext context) {
    final experiment = _experiment!;
    final account = experiment.account;
    final elapsed = DateTime.now()
        .toUtc()
        .difference(experiment.startedAt)
        .inDays
        .clamp(0, 30);
    final positions = account['positions'] as List? ?? const [];
    final equity = account['lastEquity'] as num?;
    final ended = !DateTime.now().toUtc().isBefore(experiment.endsAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前虚拟账户', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '状态：${ended
                  ? '30 天已到期'
                  : experiment.status == 'paused'
                  ? '已暂停'
                  : '运行中'}',
            ),
            Text('现金：¥${_money(account['cash'])}    持仓：${positions.length} 只'),
            Text('最近有效权益：${equity == null ? '缺少有效报价' : '¥${_money(equity)}'}'),
            Text('已过 ${elapsed.toString()} / 30 天 · 起点 ¥1000'),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: elapsed / 30),
            if (positions.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final raw in positions.whereType<Map>())
                Text(
                  '${(raw['instrument'] as Map?)?['code'] ?? ''} · '
                  '${raw['shares'] ?? 0} 股 · 成本 ¥${_money(raw['averageCost'])}',
                ),
            ],
            if (_controller.canRunLocally && !ended) ...[
              const SizedBox(height: 15),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy || experiment.status != 'active'
                        ? null
                        : () => _perform(() async {
                            await _controller.runToday();
                          }),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(_busy ? '研究中' : '运行今日研究'),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _perform(() async {
                            await _controller.setStatus(
                              experiment.status == 'paused'
                                  ? 'active'
                                  : 'paused',
                            );
                          }),
                    child: Text(
                      experiment.status == 'paused' ? '继续实验' : '暂停实验',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _money(Object? value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? 0;
    return number.toStringAsFixed(2);
  }
}

class _JournalDetail extends StatelessWidget {
  const _JournalDetail({required this.journal});

  final Map<String, dynamic> journal;

  @override
  Widget build(BuildContext context) {
    final events = journal['events'] as List? ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('日期：${journal['logicalDay'] ?? ''}'),
        const SizedBox(height: 12),
        for (final raw in events.whereType<Map>()) ...[
          Text(
            '${raw['kind'] ?? ''} · ${raw['recordedAt'] ?? ''}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 7),
          if (raw['detail'] is Map) _eventDetail(context, raw['detail'] as Map),
          const Divider(height: 24),
        ],
      ],
    );
  }

  Widget _eventDetail(BuildContext context, Map detail) {
    final decision = detail['decision'];
    if (decision is! Map) {
      return SelectableText('${detail['aiError'] ?? detail}');
    }
    Widget paragraph(String label, Object? value) => Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: SelectableText('$label\n${value ?? ''}'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        paragraph('市场判断', decision['marketView']),
        paragraph('完整研究过程', decision['researchMemo']),
        paragraph('为什么今天这样做', decision['whyNow']),
        paragraph(
          '考虑但放弃的选择',
          (decision['alternativesRejected'] as List? ?? const []).join('；'),
        ),
        paragraph(
          '不确定性',
          (decision['uncertainties'] as List? ?? const []).join('；'),
        ),
        paragraph('次日预期', decision['nextDayExpectation']),
        paragraph('月末预期', decision['monthExpectation']),
        paragraph('虚拟目标', decision['targets']),
        paragraph('成交、拒绝与账户变化', detail['paperEvents']),
        paragraph(
          '模型和花费',
          '${decision['model'] ?? ''} · 约 \$${decision['estimatedCostUsd'] ?? 0}',
        ),
      ],
    );
  }
}

class _ReportDetail extends StatelessWidget {
  const _ReportDetail({required this.report, required this.onOpenDay});

  final Map<String, dynamic> report;
  final void Function(String day) onOpenDay;

  @override
  Widget build(BuildContext context) {
    final summary = Map<String, dynamic>.from(
      report['summary'] as Map? ?? const {},
    );
    final rows = (report['days'] as List? ?? const []).whereType<Map>();
    String money(Object? value) =>
        value is num ? '¥${value.toStringAsFixed(2)}' : '无有效价格';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${report['firstDay']} — ${report['lastDay']}'),
        const SizedBox(height: 8),
        Text(
          '现金 ${money(summary['closingCash'])} · 期末净值 ${money(summary['terminalNetValue'])}',
        ),
        Text(
          '已实现盈亏 ${money(summary['realizedPnLFromFills'])} · 未实现盈亏 ${money(summary['unrealizedPnLAfterExitFees'])}',
        ),
        Text(
          '累计费用 ${money(summary['cumulativeFees'])} · 成交 ${summary['fillCount'] ?? 0} 笔 · 拒单 ${summary['rejectionCount'] ?? 0} 笔',
        ),
        Text(
          '未运行 ${summary['missedDayCount'] ?? 0} 天 · AI 失败 ${summary['aiFailureCount'] ?? 0} 天',
        ),
        if ((summary['missingTerminalPrices'] as List? ?? const []).isNotEmpty)
          Text('缺少期末有效报价：${summary['missingTerminalPrices']}'),
        const Divider(height: 25),
        for (final row in rows)
          ListTile(
            dense: true,
            title: Text(
              '${row['logicalDay']} · ${row['status'] == 'not_run' ? '未运行' : (row['decision'] as Map?)?['whyNow'] ?? '未作买卖决定'}',
            ),
            subtitle: Text(
              '事件：${row['eventIds']} · 成交 ${(row['fills'] as List? ?? const []).length} 笔',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => onOpenDay('${row['logicalDay']}'),
          ),
        const Text('逐日完整论证、原始事件及证据请点开对应日记；虚拟业绩不是实际投资回报。'),
      ],
    );
  }
}
