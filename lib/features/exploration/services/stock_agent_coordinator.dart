import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_paper_runner.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';
import 'package:uuid/uuid.dart';

class StockAgentBarBatch {
  const StockAgentBarBatch({required this.bars, this.observedAt});

  final List<Map<String, dynamic>> bars;
  final DateTime? observedAt;
}

abstract interface class StockAgentDailyBars {
  Future<StockAgentBarBatch> load({
    required DateTime asOf,
    required Map<String, dynamic> account,
  });
}

/// Only required held or pending securities are fetched. A new account has no
/// paper fills and needs no unrelated symbol's K-line to begin researching.
class ExistingStockAgentDailyBars implements StockAgentDailyBars {
  ExistingStockAgentDailyBars(this.gateway);

  final StockMarketGateway gateway;
  final _clock = ChinaMarketClock();
  final _calendar = ChinaTradingCalendar.mainland2026();

  @override
  Future<StockAgentBarBatch> load({
    required DateTime asOf,
    required Map<String, dynamic> account,
  }) async {
    final wall = _clock.toShanghaiWallTime(asOf);
    if (!_calendar.isTradingDay(wall)) {
      return const StockAgentBarBatch(bars: []);
    }
    final day = ChinaTradingCalendar.dateKey(wall);
    final codes = <String>{};
    for (final field in ['positions', 'pending']) {
      for (final item in account[field] as List? ?? const []) {
        if (item is! Map) continue;
        final instrument = item['instrument'];
        if (instrument is Map && '${instrument['code'] ?? ''}'.isNotEmpty) {
          codes.add('${instrument['code']}');
        }
      }
    }
    if (codes.isEmpty) return const StockAgentBarBatch(bars: []);
    final bars = <Map<String, dynamic>>[];
    DateTime? observedAt;
    for (final code in codes) {
      final series = await gateway.fetchSeries(
        code,
        period: StockPeriod.day,
        adjustment: StockAdjustment.none,
        limit: 90,
      );
      final quality = StockDataQuality().evaluateSeries(series);
      if (quality.shouldBlockResearch) {
        throw StateError('$code 行情质量不合格：${quality.blockingReason}');
      }
      if (series.candles.length < 2 ||
          ChinaTradingCalendar.dateKey(
                _clock.toShanghaiWallTime(series.candles.last.timestamp),
              ) !=
              day) {
        throw StateError('$code 尚无今天已完成的日线，不能模拟成交');
      }
      final sourceWall = _clock.toShanghaiWallTime(series.providerTimestamp);
      if (ChinaTradingCalendar.dateKey(sourceWall) != day ||
          sourceWall.hour < 15 ||
          series.providerTimestamp.isAfter(asOf)) {
        throw StateError('$code 行情时间不在已完成交易日内');
      }
      if (series.quote.name.toUpperCase().startsWith('N') ||
          series.quote.name.toUpperCase().startsWith('C')) {
        throw StateError('$code 新股上市天数来源不足，不能猜测涨跌停规则');
      }
      final candle = series.candles.last;
      bars.add({
        'code': code,
        'exchange': _exchange(code),
        'date': day,
        'open': candle.open,
        'high': candle.high,
        'low': candle.low,
        'close': candle.close,
        'previousClose': series.candles[series.candles.length - 2].close,
        'volume': candle.volume,
        'suspended': series.quote.tradeStatus.contains('停牌'),
        'isSt': series.quote.name.toUpperCase().contains('ST'),
      });
      if (observedAt == null || series.providerTimestamp.isAfter(observedAt)) {
        observedAt = series.providerTimestamp;
      }
    }
    return StockAgentBarBatch(bars: bars, observedAt: observedAt);
  }

  static String _exchange(String code) {
    if (code.startsWith('6')) return 'SSE';
    if (code.startsWith('0') || code.startsWith('3')) return 'SZSE';
    if (code.startsWith('4') || code.startsWith('8') || code.startsWith('9')) {
      return 'BSE';
    }
    throw StateError('无法确认股票代码 $code 的交易所');
  }
}

class StockAgentRunResult {
  const StockAgentRunResult({
    required this.experiment,
    required this.alreadyRan,
    required this.journalSaved,
    this.decision,
    this.aiError,
  });

  final StockAgentExperiment experiment;
  final bool alreadyRan;
  final bool journalSaved;
  final StockAgentDecision? decision;
  final String? aiError;
}

class StockAgentFinalization {
  const StockAgentFinalization({
    required this.experiment,
    required this.terminal,
  });

  final StockAgentExperiment experiment;
  final Map<String, dynamic> terminal;
}

class StockAgentCoordinator {
  StockAgentCoordinator({
    required this.paper,
    required this.memory,
    required this.ai,
    required this.bars,
    this.id = StockAgentCoordinator.experimentId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const experimentId = 'ai-paper-1000-first-month';

  final StockAgentPaperRunner paper;
  final StockAgentMemoryService memory;
  final StockAgentDecisionService ai;
  final StockAgentDailyBars bars;
  final String id;
  final DateTime Function() _clock;
  bool _running = false;

  Future<StockAgentExperiment?> load() => memory.loadExperiment(id);

  Future<StockAgentExperiment> start() async {
    if (!paper.canRunLocally) {
      throw UnsupportedError('只能从 Windows 启动 1000 元 AI 虚拟账户');
    }
    if (await load() != null) throw StateError('这场 30 天实验已经存在');
    final now = _clock().toUtc();
    final response = await paper.start(experimentId: id, startedAt: now);
    final account = Map<String, dynamic>.from(response['state'] as Map);
    final experiment = StockAgentExperiment(
      id: id,
      startedAt: DateTime.parse('${account['startedAt']}'),
      endsAt: DateTime.parse('${account['endsAt']}'),
      version: 0,
      account: account,
      memory: const {'entries': [], 'pinnedEventIds': [], 'summary': ''},
      updatedAt: now,
    );
    await memory.createExperiment(experiment);
    return experiment;
  }

  Future<StockAgentRunResult> runToday() async {
    if (!paper.canRunLocally) {
      throw UnsupportedError('Android 只能查看 AI 模拟操盘结果');
    }
    if (_running) throw StateError('AI 操盘程序正在运行中');
    _running = true;
    String? leaseOwner;
    try {
      final now = _clock().toUtc();
      final wall = ChinaMarketClock().toShanghaiWallTime(now);
      if (wall.hour < 15) throw StateError('当天日线尚未完成，请在北京时间 15:00 后运行');
      final day = ChinaTradingCalendar.dateKey(wall);
      var experiment = await load();
      if (experiment == null) throw StateError('请先创建 1000 元虚拟实验');
      if (experiment.status != 'active') {
        throw StateError('实验已暂停或结束，本次不会调用 AI');
      }
      if (!now.isBefore(experiment.endsAt)) {
        throw StateError('30 天实验已到期，不能再生成新的 AI 交易决定');
      }
      leaseOwner = const Uuid().v4();
      final claimed = await memory.claimRun(
        id,
        day,
        leaseOwner,
        now.add(const Duration(minutes: 30)),
      );
      if (!claimed) {
        leaseOwner = null;
        throw StateError('另一台 Windows 实例正在运行今日 AI 模拟账户');
      }
      experiment = await _recordMissedDays(experiment, day, now);
      if (experiment.account['lastProcessedDay'] == day) {
        final saved = await _ensureJournal(experiment, day);
        return StockAgentRunResult(
          experiment: experiment,
          alreadyRan: true,
          journalSaved: saved,
        );
      }
      final input = await bars.load(asOf: now, account: experiment.account);
      final preview = await paper.step(
        state: experiment.account,
        asOf: now,
        marketObservedAt: input.observedAt,
        bars: input.bars,
        intents: const [],
      );
      final previewState = Map<String, dynamic>.from(preview['state'] as Map);
      final context = await memory.buildContext(
        experimentId: id,
        currentCodes: _heldCodes(previewState),
      );
      final previewEvents = (preview['events'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) =>
                _paperEventToMemoryEvent(Map<String, dynamic>.from(item), day),
          )
          .toList(growable: false);
      final enriched = StockAgentMemoryContext(
        experiment: context.experiment.copyWith(account: previewState),
        recent: [...previewEvents, ...context.recent],
        relevant: context.relevant,
        sourceEventIds: [
          ...previewEvents.map((item) => item.id),
          ...context.sourceEventIds,
        ],
      );
      StockAgentDecision? decision;
      String? aiError;
      try {
        decision = await ai.decide(asOf: now, memory: enriched);
      } catch (error) {
        aiError = '$error';
      }
      final finalStep = decision == null
          ? preview
          : await paper.step(
              state: experiment.account,
              asOf: now,
              marketObservedAt: input.observedAt,
              bars: input.bars,
              intents: _intentsFor(decision, experiment.account, now, day),
            );
      final closing = Map<String, dynamic>.from(finalStep['state'] as Map);
      final cycleId = 'cycle-$day';
      final detail = <String, dynamic>{
        'openingAccount': experiment.account,
        'closingAccount': closing,
        'paperEvents': finalStep['events'],
        if (decision != null) 'decision': decision.toJson(),
        if (aiError case final String error) 'aiError': error,
      };
      final event = StockAgentEvent(
        id: cycleId,
        experimentId: id,
        logicalDay: day,
        kind: 'daily_cycle',
        occurredAt: now,
        recordedAt: now,
        sourceObservedAt: input.observedAt,
        detail: detail,
        codes: {
          ..._heldCodes(experiment.account),
          ...?decision?.targets.map((item) => item.code),
        }.toList()..sort(),
        tags: const ['每日决策'],
      );
      final nextMemory = _updatedMemory(
        experiment.memory,
        decision,
        cycleId,
        now,
      );
      detail['memoryAtClose'] = nextMemory;
      final saved = await memory.recordEvent(
        event: event,
        nextAccount: closing,
        nextMemory: nextMemory,
        expectedVersion: experiment.version,
      );
      final journalSaved = await _ensureJournal(saved, day);
      return StockAgentRunResult(
        experiment: saved,
        alreadyRan: false,
        journalSaved: journalSaved,
        decision: decision,
        aiError: aiError,
      );
    } finally {
      if (leaseOwner != null) {
        try {
          await memory.releaseRun(id, leaseOwner);
        } catch (_) {
          // The lease expires even if a release request temporarily fails.
        }
      }
      _running = false;
    }
  }

  /// Recover only factual non-running days after the deadline, then value the
  /// existing account. Missing last-session quotes remain explicitly missing.
  Future<StockAgentFinalization> finalize() async {
    if (!paper.canRunLocally) {
      throw UnsupportedError('只能在 Windows 完成模拟账户期末核算');
    }
    if (_running) throw StateError('AI 模拟账户正在运行中');
    _running = true;
    String? leaseOwner;
    try {
      final now = _clock().toUtc();
      var experiment = await load();
      if (experiment == null) throw StateError('股票实验不存在');
      if (now.isBefore(experiment.endsAt)) {
        throw StateError('30 天尚未结束，不能生成正式期末核算');
      }
      leaseOwner = const Uuid().v4();
      if (!await memory.claimRun(
        id,
        'final',
        leaseOwner,
        now.add(const Duration(minutes: 30)),
      )) {
        leaseOwner = null;
        throw StateError('另一台 Windows 实例正在处理股票实验');
      }
      final endDay = ChinaTradingCalendar.dateKey(
        ChinaMarketClock().toShanghaiWallTime(experiment.endsAt),
      );
      experiment = await _recordMissedDays(experiment, endDay, now);
      final terminal = await paper.finish(state: experiment.account, asOf: now);
      return StockAgentFinalization(experiment: experiment, terminal: terminal);
    } finally {
      if (leaseOwner != null) {
        try {
          await memory.releaseRun(id, leaseOwner);
        } catch (_) {}
      }
      _running = false;
    }
  }

  Future<bool> _ensureJournal(
    StockAgentExperiment experiment,
    String day,
  ) async {
    final index = await memory.loadDayIndex(id, day);
    if (index?.sealed == true) return true;
    final events = await memory.loadDayEvents(id, day);
    final cycle = events
        .where(
          (item) => item.kind == 'daily_cycle' || item.kind == 'missed_cycle',
        )
        .firstOrNull;
    if (cycle == null) return false;
    final opening = Map<String, dynamic>.from(
      cycle.detail['openingAccount'] as Map? ?? const {},
    );
    final closing = Map<String, dynamic>.from(
      cycle.detail['closingAccount'] as Map? ?? experiment.account,
    );
    final memoryAtClose = Map<String, dynamic>.from(
      cycle.detail['memoryAtClose'] as Map? ?? experiment.memory,
    );
    await memory.writeDay(
      experimentId: id,
      logicalDay: day,
      openingAccount: opening,
      closingAccount: closing,
      memoryAtClose: memoryAtClose,
      seal: true,
    );
    return true;
  }

  /// Record days when this Windows app did not run, without inventing prices,
  /// decisions or fills. The actual paper engine cancels stale pending orders
  /// and records missed market sessions when the next real cycle advances.
  Future<StockAgentExperiment> _recordMissedDays(
    StockAgentExperiment experiment,
    String currentDay,
    DateTime recordedAt,
  ) async {
    final firstDay = ChinaTradingCalendar.dateKey(
      ChinaMarketClock().toShanghaiWallTime(experiment.startedAt),
    );
    final lastProcessed = '${experiment.account['lastProcessedDay'] ?? ''}';
    final afterDay = lastProcessed.isEmpty ? firstDay : lastProcessed;
    var cursor = DateTime.parse('${afterDay}T00:00:00Z');
    if (lastProcessed.isNotEmpty) cursor = cursor.add(const Duration(days: 1));
    while (ChinaTradingCalendar.dateKey(cursor).compareTo(currentDay) < 0) {
      final missedDay = ChinaTradingCalendar.dateKey(cursor);
      final existing = await memory.loadDayIndex(id, missedDay);
      if (existing?.sealed != true) {
        final events = await memory.loadDayEvents(id, missedDay);
        if (!events.any((item) => item.id == 'missed-$missedDay')) {
          final event = StockAgentEvent(
            id: 'missed-$missedDay',
            experimentId: id,
            logicalDay: missedDay,
            kind: 'missed_cycle',
            occurredAt: recordedAt,
            recordedAt: recordedAt,
            detail: {
              'delayedRecovery': true,
              'reason': 'Windows 应用在该日没有运行；没有生成 AI 决策或模拟成交',
              'openingAccount': experiment.account,
              'closingAccount': experiment.account,
              'memoryAtClose': experiment.memory,
            },
            codes: _heldCodes(experiment.account),
            tags: const ['未运行日'],
          );
          experiment = await memory.recordEvent(
            event: event,
            nextAccount: experiment.account,
            nextMemory: experiment.memory,
            expectedVersion: experiment.version,
          );
        }
        await _ensureJournal(experiment, missedDay);
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return experiment;
  }

  static List<String> _heldCodes(Map<String, dynamic> account) {
    final codes = <String>{};
    for (final field in ['positions', 'pending']) {
      for (final item in account[field] as List? ?? const []) {
        if (item is! Map || item['instrument'] is! Map) continue;
        final code = '${(item['instrument'] as Map)['code'] ?? ''}';
        if (code.isNotEmpty) codes.add(code);
      }
    }
    return codes.toList()..sort();
  }

  static List<Map<String, dynamic>> _intentsFor(
    StockAgentDecision decision,
    Map<String, dynamic> prior,
    DateTime now,
    String day,
  ) {
    if (decision.mode == 'hold') return const [];
    final targets = <String, StockAgentTarget>{
      for (final item in decision.targets)
        '${item.code}.${item.exchange}': item,
    };
    for (final field in ['positions', 'pending']) {
      for (final item in prior[field] as List? ?? const []) {
        if (item is! Map || item['instrument'] is! Map) continue;
        final instrument = item['instrument'] as Map;
        final code = '${instrument['code'] ?? ''}';
        final exchange = '${instrument['exchange'] ?? ''}';
        targets.putIfAbsent(
          '$code.$exchange',
          () => StockAgentTarget(
            code: code,
            exchange: exchange,
            targetWeight: 0,
            reason: '完整目标组合中未保留该旧持仓',
          ),
        );
      }
    }
    return targets.values
        .map(
          (item) => {
            'intentId': '$day-${item.code}-${item.exchange}',
            'instrument': {'code': item.code, 'exchange': item.exchange},
            'targetWeight': item.targetWeight,
            'submittedAt': now.toIso8601String(),
          },
        )
        .toList(growable: false);
  }

  StockAgentEvent _paperEventToMemoryEvent(
    Map<String, dynamic> raw,
    String day,
  ) {
    final detail = Map<String, dynamic>.from(raw['detail'] as Map? ?? const {});
    final code = '${detail['instrument'] ?? ''}'.split('.').first;
    return StockAgentEvent(
      id: '${raw['eventId'] ?? ''}',
      experimentId: id,
      logicalDay: day,
      kind: '${raw['kind'] ?? ''}',
      occurredAt: DateTime.parse('${raw['occurredAt']}'),
      recordedAt: DateTime.parse('${raw['recordedAt']}'),
      sourceObservedAt: DateTime.tryParse('${raw['sourceObservedAt'] ?? ''}'),
      detail: detail,
      codes: RegExp(r'^\d{6}$').hasMatch(code) ? [code] : const [],
    );
  }

  static Map<String, dynamic> _updatedMemory(
    Map<String, dynamic> old,
    StockAgentDecision? decision,
    String cycleId,
    DateTime now,
  ) {
    if (decision == null) return old;
    final entries = List<Map<String, dynamic>>.from(
      (old['entries'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
    entries.add(
      StockAgentMemoryEntry(
        id: 'thought-$cycleId',
        kind: 'hypothesis',
        content: decision.whyNow,
        sourceEventIds: [cycleId],
        updatedAt: now,
      ).toJson(),
    );
    final pinned = <String>{
      cycleId,
      ...List<String>.from(old['pinnedEventIds'] as List? ?? const []),
    }.take(5).toList();
    return {
      ...old,
      'entries': entries,
      'pinnedEventIds': pinned,
      'summary': decision.researchMemo.length > 1200
          ? decision.researchMemo.substring(0, 1200)
          : decision.researchMemo,
    };
  }
}
