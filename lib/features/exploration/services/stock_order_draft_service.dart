import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';

/// Builds brokerage-neutral drafts.  This service has no broker credentials
/// and deliberately cannot submit an order.
class StockOrderDraftService {
  const StockOrderDraftService();

  String deterministicBatchId(Map<String, dynamic> planPayload) {
    final sourceHash = '${planPayload['sourceSnapshotHash'] ?? ''}';
    final planIds =
        (planPayload['plans'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => '${item['planId'] ?? ''}')
            .toList()
          ..sort();
    final digest = sha256
        .convert(utf8.encode('$sourceHash|${planIds.join('|')}'))
        .toString();
    return 'order-${digest.substring(0, 24)}';
  }

  StockOrderDraftBatch build({
    required Map<String, dynamic> planPayload,
    required String batchId,
    DateTime? now,
    double maxNotional = 100000,
    int validityHours = 24,
  }) {
    final createdAt = (now ?? DateTime.now()).toUtc();
    if (batchId.trim().isEmpty || maxNotional <= 0 || !maxNotional.isFinite) {
      throw StateError('委托草稿参数无效');
    }
    if (validityHours <= 0 || planPayload['ready'] != true) {
      throw StateError('只有通过研究门禁的计划才能生成委托草稿');
    }
    final sourceHash = '${planPayload['sourceSnapshotHash'] ?? ''}'.trim();
    if (sourceHash.isEmpty) throw StateError('缺少研究快照哈希');
    final rawPlans = planPayload['plans'];
    if (rawPlans is! List || rawPlans.isEmpty) {
      throw StateError('计划没有可生成的分批委托');
    }
    final expiresAt = createdAt.add(Duration(hours: validityHours));
    final drafts = <StockOrderDraft>[];
    for (final rawPlan in rawPlans) {
      if (rawPlan is! Map) throw StateError('计划条目格式无效');
      final plan = Map<String, dynamic>.from(rawPlan);
      final planId = '${plan['planId'] ?? ''}'.trim();
      final candidate = plan['candidate'];
      if (planId.isEmpty || candidate is! Map) {
        throw StateError('计划候选信息不完整');
      }
      final candidateMap = Map<String, dynamic>.from(candidate);
      final instrument = '${candidateMap['instrument'] ?? ''}'.trim();
      final price = _number(candidateMap['price']);
      if (instrument.isEmpty || !price.isFinite || price <= 0) {
        throw StateError('计划候选价格无效');
      }
      final rawTranches = plan['tranches'];
      if (rawTranches is! List) continue;
      for (final rawTranche in rawTranches) {
        if (rawTranche is! Map) throw StateError('分批计划格式无效');
        final trancheMap = Map<String, dynamic>.from(rawTranche);
        final tranche = _number(trancheMap['tranche']).toInt();
        final quantity = _number(trancheMap['targetShares']).toInt();
        if (quantity == 0) continue;
        if (quantity <= 0 || quantity % 100 != 0) {
          throw StateError('委托数量必须是 100 股整手');
        }
        final key = _idempotencyKey(
          planId: planId,
          tranche: tranche,
          instrument: instrument,
          quantity: quantity,
          price: price,
          sourceHash: sourceHash,
        );
        final draft = StockOrderDraft(
          id: '$batchId-${key.substring(0, 12)}',
          batchId: batchId,
          planId: planId,
          instrument: instrument,
          side: 'buy',
          quantity: quantity,
          limitPrice: price,
          tranche: tranche,
          createdAt: createdAt,
          expiresAt: expiresAt,
          sourceSnapshotHash: sourceHash,
          idempotencyKey: key,
        );
        if (draft.notional > maxNotional) {
          throw StateError('单笔委托超过金额上限');
        }
        drafts.add(draft);
      }
    }
    if (drafts.isEmpty) throw StateError('计划没有有效整手分批');
    return StockOrderDraftBatch(
      id: batchId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      sourceSnapshotHash: sourceHash,
      drafts: List.unmodifiable(drafts),
    );
  }

  StockOrderDraftBatch confirm(
    StockOrderDraftBatch batch, {
    required String confirmationPhrase,
    DateTime? now,
    bool emergencyStop = false,
  }) {
    final current = (now ?? DateTime.now()).toUtc();
    if (confirmationPhrase.trim() != '确认草稿') {
      throw StateError('必须输入“确认草稿”才可确认');
    }
    if (batch.status != 'pending_confirmation') return batch;
    if (emergencyStop || batch.emergencyStop) {
      return cancel(batch, now: current, emergencyStop: true);
    }
    if (!current.isBefore(batch.expiresAt)) return expire(batch, now: current);
    return StockOrderDraftBatch(
      id: batch.id,
      createdAt: batch.createdAt,
      expiresAt: batch.expiresAt,
      sourceSnapshotHash: batch.sourceSnapshotHash,
      drafts: batch.drafts
          .map((item) => item.copyWith(status: 'confirmed'))
          .toList(growable: false),
      status: 'confirmed',
    );
  }

  StockOrderDraftBatch cancel(
    StockOrderDraftBatch batch, {
    DateTime? now,
    bool emergencyStop = false,
  }) {
    // Keep the time argument in the API for callers that enforce an audit
    // timestamp; state transitions themselves do not depend on wall-clock.
    now?.toUtc();
    if (batch.status != 'pending_confirmation') return batch;
    return StockOrderDraftBatch(
      id: batch.id,
      createdAt: batch.createdAt,
      expiresAt: batch.expiresAt,
      sourceSnapshotHash: batch.sourceSnapshotHash,
      drafts: batch.drafts
          .map((item) => item.copyWith(status: 'cancelled'))
          .toList(growable: false),
      status: 'cancelled',
      emergencyStop: emergencyStop,
    );
  }

  StockOrderDraftBatch expire(StockOrderDraftBatch batch, {DateTime? now}) {
    now?.toUtc();
    if (batch.status != 'pending_confirmation') return batch;
    return StockOrderDraftBatch(
      id: batch.id,
      createdAt: batch.createdAt,
      expiresAt: batch.expiresAt,
      sourceSnapshotHash: batch.sourceSnapshotHash,
      drafts: batch.drafts
          .map((item) => item.copyWith(status: 'expired'))
          .toList(growable: false),
      status: 'expired',
    );
  }

  static String _idempotencyKey({
    required String planId,
    required int tranche,
    required String instrument,
    required int quantity,
    required double price,
    required String sourceHash,
  }) {
    final raw =
        '$planId|$tranche|$instrument|$quantity|'
        '${price.toStringAsFixed(8)}|$sourceHash';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse('$value') ?? 0;
  }
}
