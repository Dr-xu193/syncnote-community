import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/screens/stock_agent_experiment_screen.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_indicator_engine.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';
import 'package:syncnote/features/exploration/services/stock_plan_runner.dart';
import 'package:syncnote/features/exploration/services/stock_order_draft_service.dart';
import 'package:syncnote/features/exploration/services/stock_quant_runner.dart';
import 'package:syncnote/features/exploration/services/stock_shadow_runner.dart';
import 'package:syncnote/features/exploration/services/stock_evidence_validator.dart';
import 'package:syncnote/features/exploration/services/stock_research_repository.dart';
import 'package:syncnote/features/exploration/widgets/stock_kline_chart.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:uuid/uuid.dart';

class StockResearchScreen extends StatefulWidget {
  const StockResearchScreen({
    super.key,
    this.gateway,
    this.repository,
    this.ai,
    this.quantRunner,
    this.planRunner,
    this.shadowRunner,
  });

  final StockMarketGateway? gateway;
  final StockResearchRepository? repository;
  final ExplorationAiService? ai;
  final StockQuantRunner? quantRunner;
  final StockPlanRunner? planRunner;
  final StockShadowRunner? shadowRunner;

  @override
  State<StockResearchScreen> createState() => _StockResearchScreenState();
}

class _StockResearchScreenState extends State<StockResearchScreen> {
  late final StockMarketGateway _gateway;
  late final StockResearchRepository _repository;
  late final ExplorationAiService _ai;
  late final StockQuantRunner _quantRunner;
  late final StockPlanRunner _planRunner;
  final _orderDraftService = const StockOrderDraftService();
  late final StockShadowRunner _shadowRunner;
  late final bool _ownsGateway;
  late final bool _ownsAi;
  final _searchController = TextEditingController();
  StreamSubscription<List<StockWatchItem>>? _watchSubscription;
  StreamSubscription<List<StockSavedFilter>>? _filterSubscription;
  StreamSubscription<List<StockResearchReport>>? _reportSubscription;
  StreamSubscription<List<StockQuantReport>>? _quantReportSubscription;
  StreamSubscription<StockPortfolio?>? _portfolioSubscription;
  StreamSubscription<List<StockPlanRecord>>? _planSubscription;
  StreamSubscription<List<StockOrderDraftBatch>>? _orderDraftSubscription;
  StreamSubscription<StockMonitorSnapshot?>? _monitorSubscription;

  StockMarketRadar? _radar;
  List<StockQuote> _searchResults = const [];
  List<StockQuote> _screened = const [];
  List<StockWatchItem> _watchlist = const [];
  List<StockSavedFilter> _filters = const [];
  List<StockResearchReport> _reports = const [];
  List<StockQuantReport> _quantReports = const [];
  StockPortfolio? _portfolio;
  List<StockPlanRecord> _plans = const [];
  List<StockOrderDraftBatch> _orderDrafts = const [];
  StockMonitorSnapshot? _monitor;
  Map<String, dynamic>? _planPreview;
  StockOrderDraftBatch? _orderDraftPreview;
  StockQuantReport? _currentQuantReport;
  Map<String, dynamic>? _smartReport;
  StockScreenPreset _preset = StockScreenPreset.trend;
  StockQuantDataSource _quantDataSource = StockQuantDataSource.free;
  bool _loadingRadar = true;
  bool _searching = false;
  bool _screening = false;
  bool _smartResearching = false;
  bool _quantRunning = false;
  bool _orderDraftEmergencyStop = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ?? PublicChinaStockGateway();
    _repository = widget.repository ?? StockResearchRepository.instance;
    _ai = widget.ai ?? ExplorationAiService();
    _quantRunner = widget.quantRunner ?? const WindowsStockQuantRunner();
    _planRunner = widget.planRunner ?? const WindowsStockPlanRunner();
    _shadowRunner = widget.shadowRunner ?? const WindowsStockShadowRunner();
    _ownsGateway = widget.gateway == null;
    _ownsAi = widget.ai == null;
    _watchSubscription = _repository.watchWatchlist().listen((items) {
      if (mounted) setState(() => _watchlist = items);
    });
    _filterSubscription = _repository.watchFilters().listen((items) {
      if (mounted) setState(() => _filters = items);
    });
    _reportSubscription = _repository.watchReports().listen((items) {
      if (mounted) setState(() => _reports = items);
    });
    _quantReportSubscription = _repository.watchQuantReports().listen((items) {
      if (mounted) setState(() => _quantReports = items);
    });
    _portfolioSubscription = _repository.watchPortfolio().listen((portfolio) {
      if (mounted) setState(() => _portfolio = portfolio);
    });
    _planSubscription = _repository.watchPlans().listen((plans) {
      if (mounted) setState(() => _plans = plans);
    });
    _orderDraftSubscription = _repository.watchOrderDrafts().listen((drafts) {
      if (mounted) setState(() => _orderDrafts = drafts);
    });
    _monitorSubscription = _repository.watchMonitor().listen((monitor) {
      if (mounted) setState(() => _monitor = monitor);
    });
    _loadRadar();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _watchSubscription?.cancel();
    _filterSubscription?.cancel();
    _reportSubscription?.cancel();
    _quantReportSubscription?.cancel();
    _portfolioSubscription?.cancel();
    _planSubscription?.cancel();
    _orderDraftSubscription?.cancel();
    _monitorSubscription?.cancel();
    if (_ownsGateway) _gateway.dispose();
    if (_ownsAi) _ai.dispose();
    super.dispose();
  }

  Future<void> _loadRadar({bool force = false}) async {
    setState(() {
      _loadingRadar = true;
      _error = null;
    });
    try {
      final radar = await _gateway.fetchRadar(force: force);
      if (mounted) setState(() => _radar = radar);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingRadar = false);
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.length < 2) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final rows = await _gateway.search(query);
      if (mounted) setState(() => _searchResults = rows);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _runScreen() async {
    setState(() {
      _screening = true;
      _smartReport = null;
      _error = null;
    });
    try {
      final rows = await _gateway.scan(_preset, limit: 30);
      if (mounted) setState(() => _screened = rows);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _screening = false);
    }
  }

  Future<void> _runSmartResearch() async {
    setState(() {
      _smartResearching = true;
      _smartReport = null;
      _error = null;
    });
    try {
      final candidates = _screened.isEmpty
          ? await _gateway.scan(_preset, limit: 30)
          : _screened;
      if (mounted) setState(() => _screened = candidates);
      final enriched = <({StockQuote quote, StockIndicators indicators})>[];
      for (var start = 0; start < math.min(12, candidates.length); start += 4) {
        final batch = candidates.skip(start).take(4);
        final rows = await Future.wait(
          batch.map((quote) async {
            try {
              final series = await _gateway.fetchSeries(quote.code, limit: 100);
              return (
                quote: _mergeQuote(quote, series.quote),
                indicators: StockIndicatorEngine.calculate(series.candles),
              );
            } catch (_) {
              return (
                quote: quote,
                indicators: StockIndicatorEngine.calculate(const []),
              );
            }
          }),
        );
        enriched.addAll(rows);
      }
      if (enriched.isEmpty) throw StateError('没有足够的结构化候选可供研究');
      final result = await _ai.recommendStocks(
        preset: _preset,
        candidates: enriched,
      );
      if (!mounted) return;
      setState(() {
        _smartReport = {
          ...result.data,
          '_model': result.model,
          '_cost': result.estimatedCostUsd,
          '_generatedAt': DateTime.now().toIso8601String(),
        };
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _smartResearching = false);
    }
  }

  Future<void> _runQuantBacktest() async {
    if (!_quantRunner.canRunLocally) return;
    setState(() {
      _quantRunning = true;
      _currentQuantReport = null;
      _error = null;
    });
    try {
      final candidates = _screened.isEmpty
          ? await _gateway.scan(_preset, limit: 12)
          : _screened;
      if (mounted) setState(() => _screened = candidates);
      final rows = <StockQuantInputSeries>[];
      for (final quote in candidates.take(8)) {
        try {
          final pair = await Future.wait([
            _gateway.fetchSeries(
              quote.code,
              adjustment: StockAdjustment.none,
              limit: 500,
            ),
            _gateway.fetchSeries(
              quote.code,
              adjustment: StockAdjustment.forward,
              limit: 500,
            ),
          ]);
          if (pair.every((item) => item.candles.length >= 65)) {
            rows.add(
              StockQuantInputSeries(
                executionSeries: pair[0],
                signalSeries: pair[1],
              ),
            );
          }
        } catch (_) {
          // One unavailable symbol must not discard the whole snapshot.
        }
      }
      if (rows.length < 2) {
        throw StateError('至少需要两只具有 65 个交易日以上原始日线的股票');
      }
      final report = await _quantRunner.run(
        series: rows,
        preset: _preset,
        dataSource: _quantDataSource,
      );
      await _repository.saveQuantReport(report);
      if (mounted) setState(() => _currentQuantReport = report);
    } catch (error) {
      if (mounted) setState(() => _error = '量化回测失败：$error');
    } finally {
      if (mounted) setState(() => _quantRunning = false);
    }
  }

  Future<void> _saveCurrentFilter() async {
    final controller = TextEditingController(text: _presetLabel(_preset));
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存筛选器'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '筛选器名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true && controller.text.trim().isNotEmpty) {
      final now = DateTime.now();
      await _repository.saveFilter(
        StockSavedFilter(
          id: const Uuid().v4(),
          name: controller.text.trim(),
          preset: _preset,
          parameters: const {'version': 1, 'universe': 'A-share'},
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    controller.dispose();
  }

  void _openStock(StockQuote quote) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StockDetailScreen(
          initialQuote: quote,
          gateway: _gateway,
          repository: _repository,
          ai: _ai,
          initialWatchItem: _watchlist.cast<StockWatchItem?>().firstWhere(
            (item) => item?.quote.code == quote.code,
            orElse: () => null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('股票研究实验室'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '市场雷达'),
              Tab(text: '自主探索'),
              Tab(text: '关注池'),
              Tab(text: '研究记录'),
              Tab(text: '组合计划'),
              Tab(text: '模拟盘'),
            ],
          ),
        ),
        body: Column(
          children: [
            _RiskBanner(error: _error),
            Expanded(
              child: TabBarView(
                children: [
                  _buildRadar(),
                  _buildExplorer(),
                  _buildWatchlist(),
                  _buildReports(),
                  _buildPortfolio(),
                  _buildMonitor(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadar() {
    final radar = _radar;
    if (_loadingRadar && radar == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (radar == null) {
      return _RetryState(label: _error ?? '行情暂时不可用', onRetry: _loadRadar);
    }
    final breadth = radar.breadth;
    return RefreshIndicator(
      onRefresh: () => _loadRadar(force: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${radar.marketStatus} · ${DateFormat('MM-dd HH:mm:ss').format(radar.providerTimestamp)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: '刷新行情',
                onPressed: _loadingRadar ? null : () => _loadRadar(force: true),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 4
                  : constraints.maxWidth >= 520
                  ? 2
                  : 1;
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: columns == 1 ? 3.8 : 2.2,
                children: radar.indices
                    .map((quote) => _IndexCard(quote: quote))
                    .toList(growable: false),
              );
            },
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: '市场广度',
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                _MetricChip('上涨', '${breadth.rising}', Colors.red),
                _MetricChip('下跌', '${breadth.falling}', Colors.teal),
                _MetricChip('平盘', '${breadth.flat}', Colors.grey),
                _MetricChip('涨停', '${breadth.limitUp}', Colors.red),
                _MetricChip('跌停', '${breadth.limitDown}', Colors.teal),
                if (breadth.totalAmount > 0)
                  _MetricChip(
                    '成交额',
                    _money(breadth.totalAmount),
                    Colors.indigo,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 760) {
                return Column(
                  children: [
                    _RankingCard(
                      title: '涨幅前十',
                      rows: radar.gainers,
                      onTap: _openStock,
                    ),
                    const SizedBox(height: 12),
                    _RankingCard(
                      title: '跌幅前十',
                      rows: radar.losers,
                      onTap: _openStock,
                    ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _RankingCard(
                      title: '涨幅前十',
                      rows: radar.gainers,
                      onTap: _openStock,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _RankingCard(
                      title: '跌幅前十',
                      rows: radar.losers,
                      onTap: _openStock,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: '行业强弱',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: radar.sectors
                  .map(
                    (sector) => Chip(
                      label: Text(
                        '${sector.name} ${_signed(sector.changePercent)}%',
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${radar.provider}\n${PublicChinaStockGateway.providerRisk}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildExplorer() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final field = TextField(
              controller: _searchController,
              contextMenuBuilder:
                  AiContextMenuHelper.editableTextContextMenuBuilder,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                labelText: '股票名称或 6 位代码',
                hintText: '例如：贵州茅台、600519',
                border: OutlineInputBorder(),
              ),
            );
            if (constraints.maxWidth < 560) {
              return Column(
                children: [
                  field,
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _searching ? null : _search,
                      icon: const Icon(Icons.manage_search_rounded),
                      label: Text(_searching ? '搜索中' : '搜索'),
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.manage_search_rounded),
                  label: Text(_searching ? '搜索中' : '搜索'),
                ),
              ],
            );
          },
        ),
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          _QuoteGrid(rows: _searchResults, onTap: _openStock),
        ],
        const SizedBox(height: 20),
        Text('可复现筛选器', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: StockScreenPreset.values
              .map(
                (preset) => ChoiceChip(
                  label: Text(_presetLabel(preset)),
                  selected: _preset == preset,
                  onSelected: (_) => setState(() {
                    _preset = preset;
                    _screened = const [];
                    _smartReport = null;
                  }),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('免费公开源'),
              selected: _quantDataSource == StockQuantDataSource.free,
              onSelected: (_) =>
                  setState(() => _quantDataSource = StockQuantDataSource.free),
            ),
            ChoiceChip(
              label: const Text('Tushare 增强源'),
              selected: _quantDataSource == StockQuantDataSource.tushare,
              onSelected: (_) => setState(
                () => _quantDataSource = StockQuantDataSource.tushare,
              ),
            ),
          ],
        ),
        Text(
          _quantDataSource == StockQuantDataSource.free
              ? '免费源用于个人研究演练，可生成计划草稿，但不是授权行情且不能提交券商。'
              : 'Tushare 模式从本机 Token 读取数据；权限或频率不足时会明确失败。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _screening ? null : _runScreen,
              icon: const Icon(Icons.filter_alt_rounded),
              label: Text(_screening ? '筛选中' : '运行确定性筛选'),
            ),
            OutlinedButton.icon(
              onPressed: _saveCurrentFilter,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('保存筛选器'),
            ),
            FilledButton.icon(
              onPressed: _smartResearching ? null : _runSmartResearch,
              icon: const Icon(Icons.psychology_alt_rounded),
              label: Text(_smartResearching ? 'Flash 研究中' : '智能研究 · Flash'),
            ),
            if (_quantRunner.canRunLocally)
              OutlinedButton.icon(
                onPressed: _quantRunning ? null : _runQuantBacktest,
                icon: const Icon(Icons.science_outlined),
                label: Text(_quantRunning ? '本地回测中' : '多因子回测'),
              ),
          ],
        ),
        if (_filters.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: _filters
                .map(
                  (filter) => InputChip(
                    label: Text(filter.name),
                    onPressed: () => setState(() => _preset = filter.preset),
                    onDeleted: () => _repository.deleteFilter(filter.id),
                  ),
                )
                .toList(growable: false),
          ),
        ],
        if (_screened.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            '规则结果 ${_screened.length} 只（可按相同快照和规则复现）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _QuoteGrid(rows: _screened.take(30).toList(), onTap: _openStock),
        ],
        if (_smartReport != null) ...[
          const SizedBox(height: 16),
          _SmartResearchCard(
            report: _smartReport!,
            candidates: _screened,
            onOpen: _openStock,
          ),
        ],
        if (_currentQuantReport != null) ...[
          const SizedBox(height: 16),
          _QuantResearchCard(report: _currentQuantReport!),
        ],
      ],
    );
  }

  Widget _buildWatchlist() {
    if (_watchlist.isEmpty) {
      return const Center(child: Text('还没有关注股票。可从搜索、榜单或研究台加入。'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _watchlist.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _watchlist[index];
        return Card(
          child: ListTile(
            onTap: () => _openStock(item.quote),
            title: Text('${item.quote.name} ${item.quote.code}'),
            subtitle: Text(
              '${item.reason.isEmpty ? '未填写关注理由' : item.reason}\n'
              '失效条件：${item.riskCondition.isEmpty ? '未设置' : item.riskCondition} · '
              '复盘 ${DateFormat('yyyy-MM-dd').format(item.reviewAt)}',
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: '取消关注',
              onPressed: () => _repository.deleteWatchItem(item.id),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ),
        );
      },
    );
  }

  Widget _buildReports() {
    if (_reports.isEmpty && _quantReports.isEmpty) {
      return const Center(child: Text('还没有研究记录。进入单股研究台并运行 Flash 分析即可保存。'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _quantReports.length + _reports.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index < _quantReports.length) {
          return _QuantResearchCard(report: _quantReports[index]);
        }
        final report = _reports[index - _quantReports.length];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${report.quote.name} ${report.quote.code}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        Chip(label: Text(report.archived ? '坚果云归档' : '在线报告')),
                        Chip(
                          label: Text(
                            report.analysis['_evidencePassed'] == true
                                ? '证据已回验'
                                : '证据待核对',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  report.archived
                      ? '正文已压缩到坚果云；索引、知识库笔记和复盘状态仍在线。'
                      : (report.summary.isEmpty ? '结构化研究报告' : report.summary),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  '${DateFormat('yyyy-MM-dd HH:mm').format(report.createdAt)} · '
                  '${report.model} · 约 \$${report.estimatedCostUsd.toStringAsFixed(4)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (report.reviewErrorClass.isNotEmpty)
                  Text(
                    '复盘归因：${stockReviewErrorLabel(report.reviewErrorClass)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (report.analysis['_brierScore'] is num)
                  Text(
                    '预测校准 Brier：${(report.analysis['_brierScore'] as num).toStringAsFixed(3)}（越低越好）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: report.archived
                          ? () => _restoreReport(report)
                          : () => _archiveReport(report),
                      icon: Icon(
                        report.archived
                            ? Icons.unarchive_rounded
                            : Icons.archive_outlined,
                      ),
                      label: Text(report.archived ? '恢复正文' : '压缩归档'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _reviewReport(report),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('复盘'),
                    ),
                    TextButton(
                      onPressed: () => _openStock(report.quote),
                      child: const Text('打开研究台'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMonitor() {
    final snapshot = _monitor;
    if (snapshot == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildAgentEntry(),
          const SizedBox(height: 12),
          _SectionCard(
            title: '影子组合',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '尚未运行模拟盘。模拟盘会按照研究阶段的次日开盘、T+1、涨跌停、停牌、费用和成交量规则记录“如果执行”的结果，不会连接券商。',
                ),
                if (_shadowRunner.canRunLocally) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _quantRunning ? null : _runShadowMonitor,
                    icon: const Icon(Icons.play_circle_outline),
                    label: Text(_quantRunning ? '模拟运行中' : '运行一次模拟盘'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: '监控边界',
            child: const Text(
              '数据陈旧只产生提醒，不生成执行结论；止损、回撤、计划过期和逻辑失效提醒会去重，状态变化后才重新提醒。',
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildAgentEntry(),
        const SizedBox(height: 12),
        _SectionCard(
          title:
              '影子组合 · ${DateFormat('yyyy-MM-dd HH:mm').format(snapshot.asOf.toLocal())}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip('权益', _money(snapshot.equity), Colors.indigo),
                  _MetricChip(
                    '峰值',
                    _money(snapshot.peakEquity),
                    Colors.blueGrey,
                  ),
                  _MetricChip(
                    '回撤',
                    '${(snapshot.drawdown * 100).toStringAsFixed(2)}%',
                    snapshot.drawdown < 0 ? Colors.orange : Colors.green,
                  ),
                  _MetricChip(
                    '提醒',
                    '${snapshot.alerts.length}',
                    snapshot.alerts.isEmpty ? Colors.green : Colors.orange,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (snapshot.alerts.isEmpty)
                const Text('当前没有新的风险提醒。')
              else
                for (final alert in snapshot.alerts)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      alert.severity == 'critical'
                          ? Icons.error_outline
                          : Icons.info_outline,
                      color: alert.severity == 'critical'
                          ? Colors.red
                          : Colors.orange,
                    ),
                    title: Text(alert.message),
                    subtitle: Text(alert.kind),
                  ),
              if (_shadowRunner.canRunLocally) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _quantRunning ? null : _runShadowMonitor,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(_quantRunning ? '模拟运行中' : '重新运行模拟盘'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAgentEntry() => _SectionCard(
    title: 'AI 1000 元 · 30 天自主实验',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('一个 AI、一个虚拟账户、30 个自然日。她自主研究与决定；这里可以查看每天的依据、虚拟成交和云端日记。'),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const StockAgentExperimentScreen(),
            ),
          ),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('打开 AI 模拟实验'),
        ),
      ],
    ),
  );

  Widget _buildPortfolio() {
    final portfolio = _portfolio;
    final latestQuant =
        _currentQuantReport ??
        (_quantReports.isEmpty ? null : _quantReports.first);
    if (portfolio == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: '当前组合',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('尚未录入账户与持仓。组合计划会先计算现金、行业、相关性和波动风险。'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _editPortfolio,
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: const Text('录入当前组合'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _PlanGateCard(
            report: latestQuant,
            onGenerate: portfolio == null ? null : _generatePlan,
            onCreateOrderDraft: _orderDraftEmergencyStop
                ? null
                : _createOrderDraft,
            emergencyStop: _orderDraftEmergencyStop,
            onEmergencyStopChanged: (value) =>
                setState(() => _orderDraftEmergencyStop = value),
            preview: _planPreview,
          ),
          _savedPlansCard(),
          _orderDraftsCard(),
        ],
      );
    }
    final holdingsValue = portfolio.positions.fold<double>(
      0,
      (sum, item) => sum + item.shares * item.lastPrice,
    );
    final gross = portfolio.equity <= 0
        ? 0.0
        : holdingsValue / portfolio.equity;
    final cashWeight = portfolio.equity <= 0
        ? 0.0
        : portfolio.cash / portfolio.equity;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          title: '当前组合 · 风险快照',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip('总资产', _money(portfolio.equity), Colors.indigo),
                  _MetricChip(
                    '现金比例',
                    '${(cashWeight * 100).toStringAsFixed(1)}%',
                    Colors.blueGrey,
                  ),
                  _MetricChip(
                    '总敞口',
                    '${(gross * 100).toStringAsFixed(1)}%',
                    gross > 0.8 ? Colors.orange : Colors.green,
                  ),
                  _MetricChip(
                    '持仓数',
                    '${portfolio.positions.length}',
                    Colors.deepPurple,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (portfolio.positions.isEmpty)
                const Text('当前没有持仓，计划仍会保留最低现金和风险上限。')
              else
                for (final item in portfolio.positions)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${item.name.isEmpty ? item.code : item.name} ${item.code}',
                    ),
                    subtitle: Text(
                      '${item.industry} · ${item.shares} 股 · 成本 ${item.averageCost.toStringAsFixed(2)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_money(item.shares * item.lastPrice)),
                        IconButton(
                          tooltip: '移除持仓',
                          onPressed: () => _removePortfolioPosition(item),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _editPortfolio,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('更新组合快照'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addPortfolioPosition,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('添加持仓'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _PlanGateCard(
          report: latestQuant,
          onGenerate: _planRunner.canRunLocally ? _generatePlan : null,
          onCreateOrderDraft: _orderDraftEmergencyStop
              ? null
              : _createOrderDraft,
          emergencyStop: _orderDraftEmergencyStop,
          onEmergencyStopChanged: (value) =>
              setState(() => _orderDraftEmergencyStop = value),
          preview: _planPreview,
        ),
        _savedPlansCard(),
        _orderDraftsCard(),
      ],
    );
  }

  Widget _savedPlansCard() {
    if (_plans.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _SectionCard(
        title: '计划草稿记录',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _plans
              .take(10)
              .map(
                (plan) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('人工确认草稿 · ${plan.status}'),
                  subtitle: Text(
                    DateFormat(
                      'yyyy-MM-dd HH:mm',
                    ).format(plan.createdAt.toLocal()),
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  Widget _orderDraftsCard() {
    final preview = _orderDraftPreview;
    if (_orderDrafts.isEmpty && preview == null) return const SizedBox.shrink();
    final batches = [
      ?preview,
      ..._orderDrafts.where((item) => item.id != preview?.id),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _SectionCard(
        title: '人工委托草稿',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('仅保存研究计划的待确认草稿，不连接券商、不提交订单。草稿 24 小时后自动失效。'),
            const SizedBox(height: 8),
            for (final batch in batches.take(5))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '${_orderDraftStatusLabel(batch.status)} · ${batch.drafts.length} 笔 · ${_money(batch.totalNotional)}',
                ),
                subtitle: Text(
                  '到期 ${DateFormat('MM-dd HH:mm').format(batch.expiresAt.toLocal())} · 幂等键已锁定',
                ),
                trailing: batch.status == 'pending_confirmation'
                    ? Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: () => _confirmOrderDraft(batch),
                            child: const Text('人工确认'),
                          ),
                          IconButton(
                            tooltip: '紧急停止并取消',
                            onPressed: () => _cancelOrderDraft(batch),
                            icon: const Icon(Icons.stop_circle_outlined),
                          ),
                        ],
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPortfolio() async {
    final current = _portfolio;
    final equity = TextEditingController(
      text: current?.equity.toStringAsFixed(2) ?? '',
    );
    final cash = TextEditingController(
      text: current?.cash.toStringAsFixed(2) ?? '',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('录入当前组合'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: equity,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '账户总资产'),
            ),
            TextField(
              controller: cash,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '可用现金'),
            ),
            const SizedBox(height: 8),
            const Text('持仓明细将在组合计划完善后支持逐项录入。', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      final total = double.tryParse(equity.text.trim());
      final available = double.tryParse(cash.text.trim());
      if (total == null ||
          available == null ||
          total <= 0 ||
          available < 0 ||
          available > total) {
        if (mounted) setState(() => _error = '组合金额无效：现金必须不大于总资产');
      } else {
        final now = DateTime.now();
        await _repository.savePortfolio(
          StockPortfolio(
            equity: total,
            cash: available,
            asOf: now,
            positions: current?.positions ?? const [],
            updatedAt: now,
          ),
        );
      }
    }
    equity.dispose();
    cash.dispose();
  }

  Future<void> _generatePlan() async {
    final portfolio = _portfolio;
    final report =
        _currentQuantReport ??
        (_quantReports.isEmpty ? null : _quantReports.first);
    if (portfolio == null || report == null) return;
    setState(() {
      _quantRunning = true;
      _error = null;
    });
    try {
      final preview = await _planRunner.buildPlan(
        portfolio: portfolio,
        report: report,
      );
      if (preview['ready'] == true && preview['plans'] is List) {
        final now = DateTime.now();
        final record = StockPlanRecord(
          id: const Uuid().v4(),
          createdAt: now,
          status: 'draft',
          payload: preview,
        );
        await _repository.savePlan(record);
      }
      if (mounted) setState(() => _planPreview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = '买入计划生成失败：$error');
    } finally {
      if (mounted) setState(() => _quantRunning = false);
    }
  }

  Future<void> _createOrderDraft() async {
    if (_orderDraftEmergencyStop) {
      setState(() => _error = '委托草稿紧急总开关已开启');
      return;
    }
    final payload = _planPreview;
    if (payload == null || payload['ready'] != true) return;
    try {
      final batch = _orderDraftService.build(
        planPayload: payload,
        batchId: _orderDraftService.deterministicBatchId(payload),
      );
      final existing = _orderDrafts.where((item) => item.id == batch.id);
      if (existing.isNotEmpty) {
        if (mounted) {
          setState(() => _orderDraftPreview = existing.first);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该研究计划已有草稿，未重复创建')));
        }
        return;
      }
      await _repository.saveOrderDraftBatch(batch);
      if (mounted) {
        setState(() => _orderDraftPreview = batch);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已生成待人工确认草稿，未提交任何订单')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '委托草稿生成失败：$error');
    }
  }

  Future<void> _confirmOrderDraft(StockOrderDraftBatch batch) async {
    final phrase = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('人工确认委托草稿'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('这一步只会把草稿标记为“已确认”，不会连接券商，也不会提交订单。'),
            const SizedBox(height: 10),
            Text(
              '共 ${batch.drafts.length} 笔，金额 ${_money(batch.totalNotional)}。',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phrase,
              decoration: const InputDecoration(labelText: '请输入“确认草稿”'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (phrase.text.trim() != '确认草稿') return;
              Navigator.pop(context, true);
            },
            child: const Text('确认草稿'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        final updated = _orderDraftService.confirm(
          batch,
          confirmationPhrase: phrase.text,
          emergencyStop: _orderDraftEmergencyStop,
        );
        await _repository.saveOrderDraftBatch(updated);
        if (mounted) setState(() => _orderDraftPreview = updated);
      } catch (error) {
        if (mounted) setState(() => _error = '委托草稿确认失败：$error');
      }
    }
    phrase.dispose();
  }

  Future<void> _cancelOrderDraft(StockOrderDraftBatch batch) async {
    try {
      final updated = _orderDraftService.cancel(batch, emergencyStop: true);
      await _repository.saveOrderDraftBatch(updated);
      if (mounted) setState(() => _orderDraftPreview = updated);
    } catch (error) {
      if (mounted) setState(() => _error = '委托草稿取消失败：$error');
    }
  }

  Future<void> _runShadowMonitor() async {
    if (!_shadowRunner.canRunLocally) return;
    setState(() {
      _quantRunning = true;
      _error = null;
    });
    try {
      final candidates = _screened.isEmpty
          ? await _gateway.scan(_preset, limit: 8)
          : _screened;
      final rows = await Future.wait(
        candidates.take(8).map((quote) async {
          try {
            final series = await _gateway.fetchSeries(
              quote.code,
              adjustment: StockAdjustment.none,
              limit: 120,
            );
            return StockQuantInputSeries(
              executionSeries: series,
              signalSeries: series,
            );
          } catch (_) {
            return null;
          }
        }),
      );
      final usable = rows.whereType<StockQuantInputSeries>().toList(
        growable: false,
      );
      if (usable.length < 2) throw StateError('没有足够的完整日线可运行模拟盘');
      final snapshot = await _shadowRunner.run(
        series: usable,
        portfolio: _portfolio,
        plans: _plans,
        previous: _monitor,
      );
      await _repository.saveMonitor(snapshot);
      if (mounted) setState(() => _monitor = snapshot);
    } catch (error) {
      if (mounted) setState(() => _error = '模拟盘运行失败：$error');
    } finally {
      if (mounted) setState(() => _quantRunning = false);
    }
  }

  Future<void> _addPortfolioPosition() async {
    final portfolio = _portfolio;
    if (portfolio == null) return;
    final code = TextEditingController();
    final name = TextEditingController();
    final industry = TextEditingController();
    final shares = TextEditingController();
    final cost = TextEditingController();
    final price = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加持仓'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: code,
                decoration: const InputDecoration(labelText: '6 位代码'),
              ),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '股票名称'),
              ),
              TextField(
                controller: industry,
                decoration: const InputDecoration(labelText: '行业'),
              ),
              TextField(
                controller: shares,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '持有股数'),
              ),
              TextField(
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '平均成本'),
              ),
              TextField(
                controller: price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '最新价格'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      final parsedShares = int.tryParse(shares.text.trim());
      final parsedCost = double.tryParse(cost.text.trim());
      final parsedPrice = double.tryParse(price.text.trim());
      if (!RegExp(r'^\d{6}$').hasMatch(code.text.trim()) ||
          parsedShares == null ||
          parsedShares <= 0 ||
          parsedCost == null ||
          parsedCost < 0 ||
          parsedPrice == null ||
          parsedPrice <= 0) {
        if (mounted) setState(() => _error = '持仓信息无效，请检查代码、股数和价格');
      } else {
        final now = DateTime.now();
        await _repository.savePortfolio(
          StockPortfolio(
            equity: portfolio.equity,
            cash: portfolio.cash,
            asOf: now,
            positions: [
              ...portfolio.positions,
              StockPortfolioPosition(
                code: code.text.trim(),
                exchange: _portfolioExchange(code.text.trim()),
                name: name.text.trim(),
                industry: industry.text.trim().isEmpty
                    ? '未分类'
                    : industry.text.trim(),
                shares: parsedShares,
                sellableShares: parsedShares,
                averageCost: parsedCost,
                lastPrice: parsedPrice,
                annualVolatility: 0.30,
              ),
            ],
            updatedAt: now,
          ),
        );
      }
    }
    for (final controller in [code, name, industry, shares, cost, price]) {
      controller.dispose();
    }
  }

  Future<void> _removePortfolioPosition(StockPortfolioPosition position) async {
    final portfolio = _portfolio;
    if (portfolio == null) return;
    final now = DateTime.now();
    await _repository.savePortfolio(
      StockPortfolio(
        equity: portfolio.equity,
        cash: portfolio.cash,
        asOf: now,
        positions: portfolio.positions
            .where(
              (item) =>
                  item.code != position.code ||
                  item.exchange != position.exchange,
            )
            .toList(growable: false),
        updatedAt: now,
      ),
    );
  }

  Future<void> _archiveReport(StockResearchReport report) async {
    try {
      await _repository.archiveReport(report);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('报告正文已校验后压缩到坚果云。')));
    } catch (error) {
      if (mounted) setState(() => _error = '归档失败：$error');
    }
  }

  Future<void> _restoreReport(StockResearchReport report) async {
    try {
      await _repository.restoreReport(report);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('报告正文已从坚果云校验并恢复。')));
    } catch (error) {
      if (mounted) setState(() => _error = '恢复失败：$error');
    }
  }

  Future<void> _reviewReport(StockResearchReport report) async {
    final conclusion = TextEditingController(text: report.userConclusion);
    final result = TextEditingController(text: report.reviewResult);
    var errorClass = report.reviewErrorClass.isEmpty
        ? 'unknown'
        : report.reviewErrorClass;
    var outcome = report.analysis['_actualOutcome'] == true
        ? 'realized'
        : report.analysis['_actualOutcome'] == false
        ? 'not_realized'
        : 'unknown';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${report.quote.name} 研究复盘'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: conclusion,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '当时的个人判断'),
              ),
              TextField(
                controller: result,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '验证结果、正确/错误理由与遗漏因素',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: errorClass,
                decoration: const InputDecoration(labelText: '复盘归因'),
                items: const [
                  DropdownMenuItem(value: 'unknown', child: Text('未归因')),
                  DropdownMenuItem(value: 'data', child: Text('数据错误')),
                  DropdownMenuItem(value: 'strategy', child: Text('策略错误')),
                  DropdownMenuItem(value: 'execution', child: Text('执行错误')),
                  DropdownMenuItem(value: 'behavior', child: Text('行为偏差')),
                ],
                onChanged: (value) => errorClass = value ?? 'unknown',
              ),
              DropdownButtonFormField<String>(
                initialValue: outcome,
                decoration: const InputDecoration(labelText: '原判断是否兑现'),
                items: const [
                  DropdownMenuItem(value: 'unknown', child: Text('尚未确认')),
                  DropdownMenuItem(value: 'realized', child: Text('已兑现')),
                  DropdownMenuItem(value: 'not_realized', child: Text('未兑现')),
                ],
                onChanged: (value) => outcome = value ?? 'unknown',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存复盘'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _repository.updateReview(
        report,
        conclusion: conclusion.text.trim(),
        result: result.text.trim(),
        errorClass: errorClass,
        actualOutcome: outcome == 'unknown' ? null : outcome == 'realized',
      );
    }
    conclusion.dispose();
    result.dispose();
  }
}

class StockDetailScreen extends StatefulWidget {
  const StockDetailScreen({
    super.key,
    required this.initialQuote,
    required this.gateway,
    required this.repository,
    required this.ai,
    this.initialWatchItem,
  });

  final StockQuote initialQuote;
  final StockMarketGateway gateway;
  final StockResearchRepository repository;
  final ExplorationAiService ai;
  final StockWatchItem? initialWatchItem;

  @override
  State<StockDetailScreen> createState() => _StockDetailScreenState();
}

class _StockDetailScreenState extends State<StockDetailScreen> {
  late final StockDataQuality _dataQuality;
  final _evidenceValidator = const StockEvidenceValidator();
  StockPeriod _period = StockPeriod.day;
  StockAdjustment _adjustment = StockAdjustment.forward;
  StockSeries? _series;
  StockIndicators? _indicators;
  StockDataQualityReport? _quality;
  Map<String, dynamic>? _analysis;
  StockWatchItem? _watchItem;
  StockResearchReport? _savedReport;
  String _model = '';
  double _cost = 0;
  bool _loading = true;
  bool _analyzing = false;
  bool _saving = false;
  StockEvidenceValidation? _evidence;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dataQuality = StockDataQuality();
    _watchItem = widget.initialWatchItem;
    _loadSeries();
  }

  Future<void> _loadSeries() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final series = await widget.gateway.fetchSeries(
        widget.initialQuote.code,
        period: _period,
        adjustment: _period == StockPeriod.minute
            ? StockAdjustment.none
            : _adjustment,
        limit: _period == StockPeriod.minute ? 300 : 180,
      );
      final mergedSeries = StockSeries(
        quote: _mergeQuote(widget.initialQuote, series.quote),
        period: series.period,
        adjustment: series.adjustment,
        candles: series.candles,
        provider: series.provider,
        providerTimestamp: series.providerTimestamp,
        fetchedAt: series.fetchedAt,
        dataNote: series.dataNote,
      );
      final quality = _dataQuality.evaluateSeries(
        mergedSeries,
        crossSourceQuotes: [widget.initialQuote],
      );
      if (!mounted) return;
      setState(() {
        _series = mergedSeries;
        _indicators = StockIndicatorEngine.calculate(series.candles);
        _quality = quality;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _analyze() async {
    var series = _series;
    if (series == null) return;
    if (_quality?.canResearch != true) {
      setState(() {
        _error = '数据质量门禁未通过：${_quality?.blockingReason ?? '尚未完成可信校验'}';
      });
      return;
    }
    setState(() {
      _analyzing = true;
      _error = null;
      _analysis = null;
    });
    try {
      if (_period == StockPeriod.minute || series.candles.length < 60) {
        series = await widget.gateway.fetchSeries(
          widget.initialQuote.code,
          period: StockPeriod.day,
          adjustment: StockAdjustment.forward,
          limit: 180,
        );
      }
      final quote = _mergeQuote(widget.initialQuote, series.quote);
      final researchSeries = StockSeries(
        quote: quote,
        period: series.period,
        adjustment: series.adjustment,
        candles: series.candles,
        provider: series.provider,
        providerTimestamp: series.providerTimestamp,
        fetchedAt: series.fetchedAt,
        dataNote: series.dataNote,
      );
      final quality = _dataQuality.evaluateSeries(
        researchSeries,
        crossSourceQuotes: [widget.initialQuote],
      );
      if (!quality.canResearch) {
        throw StateError('数据质量门禁未通过：${quality.blockingReason}');
      }
      final indicators = StockIndicatorEngine.calculate(series.candles);
      final result = await widget.ai.analyzeStock(
        quote: quote,
        indicators: indicators,
        sourceNotes: [
          series.provider,
          series.dataNote,
          '行情时间 ${series.providerTimestamp.toIso8601String()}',
          '未提供的财务、公告、行业比较和新闻必须标记缺失',
        ],
      );
      if (!mounted) return;
      final evidence = _evidenceValidator.validate(
        quote: quote,
        indicators: indicators,
        analysis: result.data,
      );
      setState(() {
        _analysis = {
          ...result.data,
          '_evidencePassed': evidence.passed,
          '_evidenceIssues': evidence.issues,
        };
        _evidence = evidence;
        _model = result.model;
        _cost = result.estimatedCostUsd;
        _indicators = indicators;
        _quality = quality;
        _series = StockSeries(
          quote: quote,
          period: _series!.period,
          adjustment: _series!.adjustment,
          candles: _series!.candles,
          provider: _series!.provider,
          providerTimestamp: _series!.providerTimestamp,
          fetchedAt: _series!.fetchedAt,
          dataNote: _series!.dataNote,
        );
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _saveReport() async {
    final series = _series;
    final indicators = _indicators;
    final analysis = _analysis;
    if (series == null || indicators == null || analysis == null) return;
    setState(() => _saving = true);
    try {
      final horizon =
          (analysis['research_horizon_days'] as num?)?.toInt() ?? 30;
      final now = DateTime.now();
      final report = StockResearchReport(
        id: const Uuid().v4(),
        quote: series.quote,
        indicators: indicators,
        analysis: Map<String, dynamic>.from(analysis),
        sources: [series.provider],
        model: _model,
        estimatedCostUsd: _cost,
        createdAt: now,
        dataTimestamp: series.providerTimestamp,
        reviewAt: now.add(Duration(days: horizon.clamp(1, 365))),
        linkedNoteId: '',
        userConclusion: '',
        reviewResult: '',
        archived: false,
        archiveUrl: '',
        archiveSha256: '',
      );
      final saved = await widget.repository.saveReport(report);
      if (!mounted) return;
      setState(() => _savedReport = saved);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('研究报告已保存，并写入知识库笔记。')));
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editWatch() async {
    final series = _series;
    if (series == null) return;
    final reason = TextEditingController(text: _watchItem?.reason ?? '');
    final risk = TextEditingController(text: _watchItem?.riskCondition ?? '');
    final event = TextEditingController(text: _watchItem?.pendingEvent ?? '');
    final tags = TextEditingController(text: _watchItem?.tags.join('，') ?? '');
    final days = TextEditingController(
      text: _watchItem == null
          ? '30'
          : math
                .max(1, _watchItem!.reviewAt.difference(DateTime.now()).inDays)
                .toString(),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_watchItem == null ? '加入关注池' : '编辑关注'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: '关注原因'),
              ),
              TextField(
                controller: event,
                decoration: const InputDecoration(labelText: '待验证事件'),
              ),
              TextField(
                controller: risk,
                decoration: const InputDecoration(labelText: '风险/失效条件'),
              ),
              TextField(
                controller: tags,
                decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
              ),
              TextField(
                controller: days,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '多少天后复盘'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      final now = DateTime.now();
      final item = StockWatchItem(
        id: _watchItem?.id ?? series.quote.code,
        quote: series.quote,
        reason: reason.text.trim(),
        riskCondition: risk.text.trim(),
        pendingEvent: event.text.trim(),
        tags: tags.text
            .split(RegExp(r'[,，;；]+'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .take(12)
            .toList(),
        followPrice: _watchItem?.followPrice ?? series.quote.price,
        createdAt: _watchItem?.createdAt ?? now,
        updatedAt: now,
        reviewAt: now.add(
          Duration(days: (int.tryParse(days.text) ?? 30).clamp(1, 3650)),
        ),
        reviewResult: _watchItem?.reviewResult ?? '',
      );
      await widget.repository.saveWatchItem(item);
      if (mounted) setState(() => _watchItem = item);
    }
    reason.dispose();
    risk.dispose();
    event.dispose();
    tags.dispose();
    days.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.initialQuote.name} ${widget.initialQuote.code}'),
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) _RiskBanner(error: _error),
            if (series != null) _QuoteHeader(quote: series.quote),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final period in StockPeriod.values)
                  ChoiceChip(
                    label: Text(_periodLabel(period)),
                    selected: _period == period,
                    onSelected: (_) {
                      setState(() => _period = period);
                      _loadSeries();
                    },
                  ),
                if (_period != StockPeriod.minute)
                  for (final adjustment in StockAdjustment.values)
                    ChoiceChip(
                      label: Text(_adjustmentLabel(adjustment)),
                      selected: _adjustment == adjustment,
                      onSelected: (_) {
                        setState(() => _adjustment = adjustment);
                        _loadSeries();
                      },
                    ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const SizedBox(
                height: 300,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (series != null) ...[
              StockKLineChart(
                series: series,
                height: MediaQuery.sizeOf(context).width < 600 ? 280 : 360,
              ),
              const SizedBox(height: 8),
              Text(
                '${series.provider} · ${DateFormat('yyyy-MM-dd HH:mm:ss').format(ChinaMarketClock().toShanghaiWallTime(series.providerTimestamp))}（北京时间）\n${series.dataNote}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_quality != null) _StockDataQualityCard(report: _quality!),
            ],
            const SizedBox(height: 14),
            if (_indicators != null) _IndicatorPanel(indicators: _indicators!),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: series == null ? null : _editWatch,
                  icon: Icon(
                    _watchItem == null
                        ? Icons.star_border_rounded
                        : Icons.star_rounded,
                  ),
                  label: Text(_watchItem == null ? '加入关注池' : '编辑关注'),
                ),
                FilledButton.icon(
                  onPressed:
                      _analyzing ||
                          series == null ||
                          _quality?.canResearch != true
                      ? null
                      : _analyze,
                  icon: const Icon(Icons.psychology_alt_rounded),
                  label: Text(_analyzing ? 'Flash 分析中' : '正反研究 · Flash'),
                ),
                if (_analysis != null)
                  OutlinedButton.icon(
                    onPressed: _saving || _savedReport != null
                        ? null
                        : _saveReport,
                    icon: Icon(
                      _savedReport == null
                          ? Icons.save_outlined
                          : Icons.cloud_done_rounded,
                    ),
                    label: Text(
                      _savedReport == null
                          ? (_saving ? '保存中' : '保存研究记录')
                          : '已保存到知识库',
                    ),
                  ),
              ],
            ),
            if (_analysis != null) ...[
              const SizedBox(height: 16),
              _EvidenceBanner(validation: _evidence),
              const SizedBox(height: 10),
              _SingleStockReport(data: _analysis!, model: _model, cost: _cost),
            ],
            const SizedBox(height: 20),
            Text(
              '风险提示：本模块只用于个人研究和复盘，不提供证券交易、自动下单或保证性投资建议。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskBanner extends StatelessWidget {
  const _RiskBanner({this.error});
  final String? error;

  @override
  Widget build(BuildContext context) {
    final message =
        error ?? '个人研究模式：行情来自公开验证接口；所有时间、复权口径和来源均显示，正式多人发布前需切换授权 Level-1 网关。';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color:
            (error == null ? Colors.amber : Theme.of(context).colorScheme.error)
                .withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: error == null ? null : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

class _StockDataQualityCard extends StatelessWidget {
  const _StockDataQualityCard({required this.report});

  final StockDataQualityReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color, icon) = switch (report.level) {
      StockDataQualityLevel.available =>
        report.trustTier == StockDataTrustTier.authorizedResearch
            ? ('可信数据校验通过', Colors.green, Icons.verified_rounded)
            : ('结构校验通过 · 个人验证源', Colors.blue, Icons.fact_check_rounded),
      StockDataQualityLevel.stale => (
        '数据已过期',
        Colors.orange,
        Icons.schedule_rounded,
      ),
      StockDataQualityLevel.conflicted => (
        '来源或字段冲突',
        theme.colorScheme.error,
        Icons.warning_amber_rounded,
      ),
      StockDataQualityLevel.missing => (
        '关键数据缺失',
        theme.colorScheme.error,
        Icons.cloud_off_rounded,
      ),
    };
    final checkedAt = ChinaMarketClock().toShanghaiWallTime(report.checkedAt);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '来源：${report.providers.isEmpty ? '未提供' : report.providers.join(' / ')} · '
            '校验：${DateFormat('yyyy-MM-dd HH:mm:ss').format(checkedAt)}（北京时间）',
            style: theme.textTheme.bodySmall,
          ),
          if (report.issues.isNotEmpty) ...[
            const SizedBox(height: 5),
            for (final issue in report.issues.take(3))
              Text('• ${issue.message}', style: theme.textTheme.bodySmall),
          ],
          if (!report.canResearch) ...[
            const SizedBox(height: 5),
            Text(
              '门禁未通过时，Flash 研究和后续交易计划均被禁用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ] else if (!report.canCreatePlan) ...[
            const SizedBox(height: 5),
            Text(
              '当前来源可用于个人研究，但未来的正式买入计划门禁仍保持关闭。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.blue.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RetryState extends StatelessWidget {
  const _RetryState({required this.label, required this.onRetry});
  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 10),
        FilledButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class _MetricChip extends StatelessWidget {
  const _MetricChip(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      '$label $value',
      style: TextStyle(color: color, fontWeight: FontWeight.w700),
    ),
  );
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.quote});
  final StockQuote quote;

  @override
  Widget build(BuildContext context) {
    final color = quote.changePercent >= 0 ? Colors.red : Colors.teal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              quote.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              quote.price.toStringAsFixed(2),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${_signed(quote.changePercent)}%',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({
    required this.title,
    required this.rows,
    required this.onTap,
  });
  final String title;
  final List<StockQuote> rows;
  final ValueChanged<StockQuote> onTap;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: title,
    child: Column(
      children: rows
          .asMap()
          .entries
          .map((entry) {
            final quote = entry.value;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => onTap(quote),
              leading: SizedBox(width: 24, child: Text('${entry.key + 1}')),
              title: Text('${quote.name} ${quote.code}'),
              trailing: Text(
                '${_signed(quote.changePercent)}%',
                style: TextStyle(
                  color: quote.changePercent >= 0 ? Colors.red : Colors.teal,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          })
          .toList(growable: false),
    ),
  );
}

class _QuoteGrid extends StatelessWidget {
  const _QuoteGrid({required this.rows, required this.onTap});
  final List<StockQuote> rows;
  final ValueChanged<StockQuote> onTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1000
          ? 3
          : constraints.maxWidth >= 620
          ? 2
          : 1;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          mainAxisExtent: 108,
        ),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final quote = rows[index];
          return Card(
            child: InkWell(
              onTap: () => onTap(quote),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            quote.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Text(quote.code),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '${quote.price.toStringAsFixed(2)}  ${_signed(quote.changePercent)}%',
                      style: TextStyle(
                        color: quote.changePercent >= 0
                            ? Colors.red
                            : Colors.teal,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '成交额 ${_money(quote.amount)} · 换手 ${quote.turnoverRate.toStringAsFixed(2)}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _SmartResearchCard extends StatelessWidget {
  const _SmartResearchCard({
    required this.report,
    required this.candidates,
    required this.onOpen,
  });
  final Map<String, dynamic> report;
  final List<StockQuote> candidates;
  final ValueChanged<StockQuote> onOpen;

  @override
  Widget build(BuildContext context) {
    final picks = report['picks'] as List? ?? const [];
    return _SectionCard(
      title: 'Flash 优先研究对象',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${report['market_view'] ?? ''}'),
          if ((report['data_gaps'] as List? ?? const []).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('数据缺口：${(report['data_gaps'] as List).join('；')}'),
          ],
          const SizedBox(height: 8),
          for (final raw in picks.whereType<Map>())
            Builder(
              builder: (context) {
                final item = Map<String, dynamic>.from(raw);
                final code = '${item['code'] ?? ''}';
                final quote = candidates.cast<StockQuote?>().firstWhere(
                  (candidate) => candidate?.code == code,
                  orElse: () => null,
                );
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  onTap: quote == null ? null : () => onOpen(quote),
                  title: Text(
                    '${item['name'] ?? ''} $code · ${item['research_score'] ?? 0}分',
                  ),
                  subtitle: Text(
                    '${item['thesis'] ?? ''}\n'
                    '风险：${(item['risks'] as List? ?? const []).join('；')} · '
                    '置信度 ${item['confidence'] ?? 0}%',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                );
              },
            ),
          const Divider(),
          Text(
            '${report['_model'] ?? ''} · 约 \$${((report['_cost'] as num?)?.toDouble() ?? 0).toStringAsFixed(4)} · ${report['disclaimer'] ?? '仅供研究'}',
          ),
        ],
      ),
    );
  }
}

class _QuoteHeader extends StatelessWidget {
  const _QuoteHeader({required this.quote});
  final StockQuote quote;

  @override
  Widget build(BuildContext context) {
    final color = quote.changePercent >= 0 ? Colors.red : Colors.teal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 18,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              quote.name,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            Text(
              quote.price.toStringAsFixed(2),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${_signed(quote.change)}  ${_signed(quote.changePercent)}%',
              style: TextStyle(color: color),
            ),
            Text('高 ${quote.high.toStringAsFixed(2)}'),
            Text('低 ${quote.low.toStringAsFixed(2)}'),
            Text('成交额 ${_money(quote.amount)}'),
            Text('换手 ${quote.turnoverRate.toStringAsFixed(2)}%'),
            Text('PE ${quote.pe <= 0 ? '缺失' : quote.pe.toStringAsFixed(1)}'),
          ],
        ),
      ),
    );
  }
}

class _IndicatorPanel extends StatelessWidget {
  const _IndicatorPanel({required this.indicators});
  final StockIndicators indicators;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: '确定性指标',
    child: Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        _valueChip('MA5', indicators.sma5),
        _valueChip('MA20', indicators.sma20),
        _valueChip('MA60', indicators.sma60),
        _valueChip('RSI14', indicators.rsi14),
        _valueChip('MACD', indicators.macd),
        _valueChip('5日%', indicators.return5),
        _valueChip('20日%', indicators.return20),
        _valueChip('年化波动%', indicators.volatility20),
        _valueChip('量比', indicators.volumeRatio),
      ],
    ),
  );

  static Widget _valueChip(String label, double? value) => Chip(
    label: Text('$label ${value == null ? '数据不足' : value.toStringAsFixed(2)}'),
  );
}

class _EvidenceBanner extends StatelessWidget {
  const _EvidenceBanner({required this.validation});

  final StockEvidenceValidation? validation;

  @override
  Widget build(BuildContext context) {
    final value = validation;
    if (value == null) return const SizedBox.shrink();
    final passed = value.passed;
    return Card(
      color: passed
          ? Colors.green.withValues(alpha: 0.10)
          : Colors.orange.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              passed ? Icons.verified_outlined : Icons.warning_amber_outlined,
              color: passed ? Colors.green : Colors.orange,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                passed
                    ? '数值证据已按本地行情与确定性指标逐项回验。'
                    : '证据链未完整通过：${value.issues.join('；')}。该报告只能作为待核对草稿。',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SingleStockReport extends StatelessWidget {
  const _SingleStockReport({
    required this.data,
    required this.model,
    required this.cost,
  });
  final Map<String, dynamic> data;
  final String model;
  final double cost;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: 'Flash 正反研究',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${data['summary'] ?? ''}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        _listSection('技术面', [data['technical_view']]),
        _listSection('看多证据', data['bull_evidence']),
        _listSection('看空证据', data['bear_evidence']),
        _listSection('主要风险', data['risks']),
        _listSection('失效条件', data['invalidation_conditions']),
        _listSection('数据缺口', data['missing_data']),
        _listSection('待验证事实', data['unknowns']),
        _listSection('后续问题', data['follow_up_questions']),
        const Divider(),
        Text(
          '$model · 约 \$${cost.toStringAsFixed(4)} · 置信度 ${ExplorationAiService.confidencePercent(data['confidence']).toStringAsFixed(0)}%',
        ),
      ],
    ),
  );

  static Widget _listSection(String title, Object? raw) {
    final rows = raw is List
        ? raw.where((item) => '$item'.trim().isNotEmpty).toList()
        : const [];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          for (final item in rows) Text('• $item'),
        ],
      ),
    );
  }
}

class _QuantResearchCard extends StatelessWidget {
  const _QuantResearchCard({required this.report});

  final StockQuantReport report;

  @override
  Widget build(BuildContext context) {
    final data = report.report;
    final out = Map<String, dynamic>.from(
      data['out_of_sample'] as Map? ?? const {},
    );
    final qualification = Map<String, dynamic>.from(
      data['qualification'] as Map? ?? const {},
    );
    final costStress = Map<String, dynamic>.from(
      data['cost_stress'] as Map? ?? const {},
    );
    final tripleCost = Map<String, dynamic>.from(
      costStress['cost_x3'] as Map? ?? const {},
    );
    final walkForward = data['walk_forward'] as List? ?? const [];
    final reasons = List<String>.from(
      qualification['reasons'] as List? ?? const [],
    );
    final ranking = (data['latestRanking'] as List? ?? const [])
        .whereType<Map>()
        .take(5)
        .toList(growable: false);
    final qualified = report.qualifiedForPlan;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '多因子样本外报告 · ${report.strategyName}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Chip(
                  label: Text(qualified ? '计划门禁通过' : '仅研究，不生成计划'),
                  backgroundColor: qualified
                      ? Colors.green.withValues(alpha: 0.12)
                      : Colors.orange.withValues(alpha: 0.12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip(
                  '样本外收益',
                  _percent(out['total_return']),
                  _metricColor(out['total_return']),
                ),
                _MetricChip(
                  '最大回撤',
                  _percent(out['max_drawdown']),
                  Colors.orange,
                ),
                _MetricChip('Sharpe', _number(out['sharpe']), Colors.indigo),
                _MetricChip(
                  '因子覆盖',
                  _percent(data['factor_coverage']),
                  Colors.blueGrey,
                ),
                _MetricChip(
                  '三倍成本收益',
                  _percent(tripleCost['total_return']),
                  _metricColor(tripleCost['total_return']),
                ),
                _MetricChip(
                  'Walk-forward',
                  '${walkForward.length} 折',
                  Colors.deepPurple,
                ),
              ],
            ),
            if (ranking.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '最新因子排名：${ranking.map((item) => item['instrument']).join('、')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (reasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                reasons.map((item) => '• $item').join('\n'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${report.provider} · ${DateFormat('yyyy-MM-dd HH:mm').format(report.createdAt.toLocal())}\n'
              '股票池 ${data['universeSize'] ?? 0} 只 · ${data['tradingDays'] ?? 0} 个交易日 · '
              '切分日 ${data['splitDate'] ?? '—'}\n'
              'T+1、次日开盘、分板块申报数量、佣金、印花税、过户费、滑点和成交量约束均已计入。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _percent(Object? value) {
    final number = value is num ? value.toDouble() : 0.0;
    return '${(number * 100).toStringAsFixed(2)}%';
  }

  static String _number(Object? value) =>
      (value is num ? value.toDouble() : 0.0).toStringAsFixed(2);

  static Color _metricColor(Object? value) {
    final number = value is num ? value.toDouble() : 0.0;
    return number >= 0 ? Colors.red : Colors.teal;
  }
}

class _PlanGateCard extends StatelessWidget {
  const _PlanGateCard({
    required this.report,
    this.onGenerate,
    this.onCreateOrderDraft,
    required this.emergencyStop,
    required this.onEmergencyStopChanged,
    this.preview,
  });

  final StockQuantReport? report;
  final VoidCallback? onGenerate;
  final VoidCallback? onCreateOrderDraft;
  final bool emergencyStop;
  final ValueChanged<bool> onEmergencyStopChanged;
  final Map<String, dynamic>? preview;

  @override
  Widget build(BuildContext context) {
    final reasons = report == null
        ? const <String>['尚未生成第二阶段量化报告']
        : List<String>.from(
            (report!.report['qualification'] as Map? ?? const {})['reasons']
                    as List? ??
                const [],
          );
    final ready = report?.qualifiedForPlan ?? false;
    return _SectionCard(
      title: '计划门禁',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: emergencyStop,
            onChanged: onEmergencyStopChanged,
            title: const Text('委托草稿紧急总开关'),
            subtitle: Text(
              emergencyStop ? '已开启：禁止生成和确认任何委托草稿' : '已关闭：仍需逐份人工确认',
            ),
          ),
          if (report?.trustTier == 'public_personal_research')
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '当前为免费公开源：计划和委托草稿仅用于个人研究演练，禁止券商提交。',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          Row(
            children: [
              Icon(
                ready ? Icons.check_circle_outline : Icons.lock_outline,
                color: ready ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ready ? '已满足确定性条件，可生成待人工确认计划' : '当前只能研究，不能生成买入计划',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '计划必须同时满足授权主源、样本外、Walk-forward、成本压力和风险预算；任何一项失败都不会生成委托。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final reason in reasons) Text('• $reason'),
          if (ready && onGenerate != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: FilledButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('生成待人工确认计划'),
              ),
            ),
          if (preview != null && preview!['ready'] == true)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已生成 ${(preview!['plans'] as List? ?? const []).length} 份计划草稿，尚未提交任何委托。',
                ),
                if (onCreateOrderDraft != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      onPressed: onCreateOrderDraft,
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('生成待人工确认委托草稿'),
                    ),
                  ),
              ],
            ),
          if (ready)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('下一步将显示分批建仓、硬止损、时间止损和逻辑失效条件，并要求你逐批确认。'),
            ),
        ],
      ),
    );
  }
}

String _portfolioExchange(String code) {
  if (code.startsWith(RegExp(r'(4|8|92)'))) return 'BSE';
  if (code.startsWith(RegExp(r'(0|3)'))) return 'SZSE';
  return 'SSE';
}

String _presetLabel(StockScreenPreset preset) => switch (preset) {
  StockScreenPreset.trend => '趋势增强',
  StockScreenPreset.breakout => '放量突破',
  StockScreenPreset.oversold => '超跌修复',
  StockScreenPreset.qualityValue => '低估值高质量',
  StockScreenPreset.improving => '业绩改善观察',
  StockScreenPreset.sectorLeader => '行业领涨',
  StockScreenPreset.highRisk => '高风险异动',
};

String _periodLabel(StockPeriod period) => switch (period) {
  StockPeriod.minute => '分时',
  StockPeriod.day => '日',
  StockPeriod.week => '周',
  StockPeriod.month => '月',
};

String _adjustmentLabel(StockAdjustment adjustment) => switch (adjustment) {
  StockAdjustment.none => '不复权',
  StockAdjustment.forward => '前复权',
  StockAdjustment.backward => '后复权',
};

String _signed(num value) =>
    '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}';

String _orderDraftStatusLabel(String status) => switch (status) {
  'confirmed' => '已确认（未提交）',
  'cancelled' => '已取消',
  'expired' => '已过期',
  _ => '待人工确认',
};

String _money(double value) {
  if (value.abs() >= 1e12) return '${(value / 1e12).toStringAsFixed(2)}万亿';
  if (value.abs() >= 1e8) return '${(value / 1e8).toStringAsFixed(2)}亿';
  if (value.abs() >= 1e4) return '${(value / 1e4).toStringAsFixed(1)}万';
  return value.toStringAsFixed(0);
}

StockQuote _mergeQuote(StockQuote preferred, StockQuote live) => StockQuote(
  symbol: live.symbol.isEmpty ? preferred.symbol : live.symbol,
  code: live.code.isEmpty ? preferred.code : live.code,
  name: live.name == live.code || live.name.isEmpty
      ? preferred.name
      : live.name,
  exchange: live.exchange.isEmpty ? preferred.exchange : live.exchange,
  price: live.price <= 0 ? preferred.price : live.price,
  previousClose: live.previousClose <= 0
      ? preferred.previousClose
      : live.previousClose,
  open: live.open <= 0 ? preferred.open : live.open,
  high: live.high <= 0 ? preferred.high : live.high,
  low: live.low <= 0 ? preferred.low : live.low,
  // Zero change is a valid flat quote, not a missing value. Recompute from the
  // live price pair so an old non-zero snapshot can never leak into the UI.
  change: live.price > 0 && live.previousClose > 0
      ? live.price - live.previousClose
      : preferred.change,
  changePercent: live.price > 0 && live.previousClose > 0
      ? (live.price / live.previousClose - 1) * 100
      : preferred.changePercent,
  volume: live.volume <= 0 ? preferred.volume : live.volume,
  amount: live.amount <= 0 ? preferred.amount : live.amount,
  turnoverRate: live.turnoverRate <= 0
      ? preferred.turnoverRate
      : live.turnoverRate,
  pe: live.pe <= 0 ? preferred.pe : live.pe,
  marketCap: live.marketCap <= 0 ? preferred.marketCap : live.marketCap,
  industry: live.industry.isEmpty ? preferred.industry : live.industry,
  provider: '${preferred.provider} / ${live.provider}',
  providerTimestamp: live.providerTimestamp,
  fetchedAt: live.fetchedAt,
  tradeStatus: live.tradeStatus.isEmpty
      ? preferred.tradeStatus
      : live.tradeStatus,
);
