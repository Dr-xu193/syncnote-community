import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

enum StockPeriod { minute, day, week, month }

enum StockAdjustment { none, forward, backward }

enum StockScreenPreset {
  trend,
  breakout,
  oversold,
  qualityValue,
  improving,
  sectorLeader,
  highRisk,
}

enum StockReviewErrorClass { data, strategy, execution, behavior, unknown }

String stockReviewErrorLabel(String value) => switch (value) {
  'data' => '数据错误',
  'strategy' => '策略错误',
  'execution' => '执行错误',
  'behavior' => '行为偏差',
  _ => '未归因',
};

@immutable
class StockQuote {
  const StockQuote({
    required this.symbol,
    required this.code,
    required this.name,
    required this.exchange,
    required this.price,
    required this.previousClose,
    required this.open,
    required this.high,
    required this.low,
    required this.change,
    required this.changePercent,
    required this.volume,
    required this.amount,
    required this.turnoverRate,
    required this.pe,
    required this.marketCap,
    required this.industry,
    required this.provider,
    required this.providerTimestamp,
    required this.fetchedAt,
    this.tradeStatus = '',
  });

  final String symbol;
  final String code;
  final String name;
  final String exchange;
  final double price;
  final double previousClose;
  final double open;
  final double high;
  final double low;
  final double change;
  final double changePercent;
  final double volume;
  final double amount;
  final double turnoverRate;
  final double pe;
  final double marketCap;
  final String industry;
  final String provider;
  final DateTime providerTimestamp;
  final DateTime fetchedAt;
  final String tradeStatus;

  bool get isValid => code.isNotEmpty && name.isNotEmpty && price > 0;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'code': code,
    'name': name,
    'exchange': exchange,
    'price': price,
    'previousClose': previousClose,
    'open': open,
    'high': high,
    'low': low,
    'change': change,
    'changePercent': changePercent,
    'volume': volume,
    'amount': amount,
    'turnoverRate': turnoverRate,
    'pe': pe,
    'marketCap': marketCap,
    'industry': industry,
    'provider': provider,
    'providerTimestamp': providerTimestamp.toUtc().toIso8601String(),
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'tradeStatus': tradeStatus,
  };

  factory StockQuote.fromJson(Map<String, dynamic> json) => StockQuote(
    symbol: '${json['symbol'] ?? ''}',
    code: '${json['code'] ?? ''}',
    name: '${json['name'] ?? ''}',
    exchange: '${json['exchange'] ?? ''}',
    price: _double(json['price']),
    previousClose: _double(json['previousClose']),
    open: _double(json['open']),
    high: _double(json['high']),
    low: _double(json['low']),
    change: _double(json['change']),
    changePercent: _double(json['changePercent']),
    volume: _double(json['volume']),
    amount: _double(json['amount']),
    turnoverRate: _double(json['turnoverRate']),
    pe: _double(json['pe']),
    marketCap: _double(json['marketCap']),
    industry: '${json['industry'] ?? ''}',
    provider: '${json['provider'] ?? ''}',
    providerTimestamp: _date(json['providerTimestamp']),
    fetchedAt: _date(json['fetchedAt']),
    tradeStatus: '${json['tradeStatus'] ?? ''}',
  );
}

@immutable
class StockCandle {
  const StockCandle({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.amount,
  });

  final DateTime timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final double amount;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'open': open,
    'high': high,
    'low': low,
    'close': close,
    'volume': volume,
    'amount': amount,
  };

  factory StockCandle.fromJson(Map<String, dynamic> json) => StockCandle(
    timestamp: _date(json['timestamp']),
    open: _double(json['open']),
    high: _double(json['high']),
    low: _double(json['low']),
    close: _double(json['close']),
    volume: _double(json['volume']),
    amount: _double(json['amount']),
  );
}

@immutable
class StockSeries {
  const StockSeries({
    required this.quote,
    required this.period,
    required this.adjustment,
    required this.candles,
    required this.provider,
    required this.providerTimestamp,
    required this.fetchedAt,
    required this.dataNote,
  });

  final StockQuote quote;
  final StockPeriod period;
  final StockAdjustment adjustment;
  final List<StockCandle> candles;
  final String provider;
  final DateTime providerTimestamp;
  final DateTime fetchedAt;
  final String dataNote;
}

@immutable
class StockIndicators {
  const StockIndicators({
    required this.sma5,
    required this.sma10,
    required this.sma20,
    required this.sma60,
    required this.rsi14,
    required this.macd,
    required this.macdSignal,
    required this.macdHistogram,
    required this.bollingerUpper,
    required this.bollingerMiddle,
    required this.bollingerLower,
    required this.return5,
    required this.return20,
    required this.volatility20,
    required this.volumeRatio,
  });

  final double? sma5;
  final double? sma10;
  final double? sma20;
  final double? sma60;
  final double? rsi14;
  final double? macd;
  final double? macdSignal;
  final double? macdHistogram;
  final double? bollingerUpper;
  final double? bollingerMiddle;
  final double? bollingerLower;
  final double? return5;
  final double? return20;
  final double? volatility20;
  final double? volumeRatio;

  Map<String, dynamic> toJson() => {
    'sma5': sma5,
    'sma10': sma10,
    'sma20': sma20,
    'sma60': sma60,
    'rsi14': rsi14,
    'macd': macd,
    'macdSignal': macdSignal,
    'macdHistogram': macdHistogram,
    'bollingerUpper': bollingerUpper,
    'bollingerMiddle': bollingerMiddle,
    'bollingerLower': bollingerLower,
    'return5': return5,
    'return20': return20,
    'volatility20': volatility20,
    'volumeRatio': volumeRatio,
  };

  factory StockIndicators.fromJson(Map<String, dynamic> json) =>
      StockIndicators(
        sma5: _nullableDouble(json['sma5']),
        sma10: _nullableDouble(json['sma10']),
        sma20: _nullableDouble(json['sma20']),
        sma60: _nullableDouble(json['sma60']),
        rsi14: _nullableDouble(json['rsi14']),
        macd: _nullableDouble(json['macd']),
        macdSignal: _nullableDouble(json['macdSignal']),
        macdHistogram: _nullableDouble(json['macdHistogram']),
        bollingerUpper: _nullableDouble(json['bollingerUpper']),
        bollingerMiddle: _nullableDouble(json['bollingerMiddle']),
        bollingerLower: _nullableDouble(json['bollingerLower']),
        return5: _nullableDouble(json['return5']),
        return20: _nullableDouble(json['return20']),
        volatility20: _nullableDouble(json['volatility20']),
        volumeRatio: _nullableDouble(json['volumeRatio']),
      );
}

@immutable
class StockSectorStrength {
  const StockSectorStrength({
    required this.name,
    required this.changePercent,
    required this.leader,
  });

  final String name;
  final double changePercent;
  final String leader;
}

@immutable
class StockMarketBreadth {
  const StockMarketBreadth({
    required this.rising,
    required this.falling,
    required this.flat,
    required this.limitUp,
    required this.limitDown,
    required this.totalAmount,
  });

  final int rising;
  final int falling;
  final int flat;
  final int limitUp;
  final int limitDown;
  final double totalAmount;
}

@immutable
class StockMarketRadar {
  const StockMarketRadar({
    required this.indices,
    required this.gainers,
    required this.losers,
    required this.sectors,
    required this.breadth,
    required this.provider,
    required this.providerTimestamp,
    required this.fetchedAt,
    required this.marketStatus,
  });

  final List<StockQuote> indices;
  final List<StockQuote> gainers;
  final List<StockQuote> losers;
  final List<StockSectorStrength> sectors;
  final StockMarketBreadth breadth;
  final String provider;
  final DateTime providerTimestamp;
  final DateTime fetchedAt;
  final String marketStatus;
}

@immutable
class StockWatchItem {
  const StockWatchItem({
    required this.id,
    required this.quote,
    required this.reason,
    required this.riskCondition,
    required this.pendingEvent,
    required this.tags,
    required this.followPrice,
    required this.createdAt,
    required this.updatedAt,
    required this.reviewAt,
    this.reviewResult = '',
  });

  final String id;
  final StockQuote quote;
  final String reason;
  final String riskCondition;
  final String pendingEvent;
  final List<String> tags;
  final double followPrice;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime reviewAt;
  final String reviewResult;

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'quote': quote.toJson(),
    'reason': reason,
    'riskCondition': riskCondition,
    'pendingEvent': pendingEvent,
    'tags': tags,
    'followPrice': followPrice,
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'updatedAt': Timestamp.fromDate(updatedAt.toUtc()),
    'reviewAt': Timestamp.fromDate(reviewAt.toUtc()),
    'reviewResult': reviewResult,
  };

  factory StockWatchItem.fromFirestore(Map<String, dynamic> json) =>
      StockWatchItem(
        id: '${json['id'] ?? ''}',
        quote: StockQuote.fromJson(
          Map<String, dynamic>.from(json['quote'] as Map? ?? const {}),
        ),
        reason: '${json['reason'] ?? ''}',
        riskCondition: '${json['riskCondition'] ?? ''}',
        pendingEvent: '${json['pendingEvent'] ?? ''}',
        tags: List<String>.from(json['tags'] as List? ?? const []),
        followPrice: _double(json['followPrice']),
        createdAt: _date(json['createdAt']),
        updatedAt: _date(json['updatedAt']),
        reviewAt: _date(json['reviewAt']),
        reviewResult: '${json['reviewResult'] ?? ''}',
      );
}

@immutable
class StockSavedFilter {
  const StockSavedFilter({
    required this.id,
    required this.name,
    required this.preset,
    required this.parameters,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final StockScreenPreset preset;
  final Map<String, dynamic> parameters;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'name': name,
    'preset': preset.name,
    'parameters': parameters,
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'updatedAt': Timestamp.fromDate(updatedAt.toUtc()),
  };

  factory StockSavedFilter.fromFirestore(Map<String, dynamic> json) =>
      StockSavedFilter(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        preset: StockScreenPreset.values.firstWhere(
          (value) => value.name == json['preset'],
          orElse: () => StockScreenPreset.trend,
        ),
        parameters: Map<String, dynamic>.from(
          json['parameters'] as Map? ?? const {},
        ),
        createdAt: _date(json['createdAt']),
        updatedAt: _date(json['updatedAt']),
      );
}

@immutable
class StockResearchReport {
  const StockResearchReport({
    required this.id,
    required this.quote,
    required this.indicators,
    required this.analysis,
    required this.sources,
    required this.model,
    required this.estimatedCostUsd,
    required this.createdAt,
    required this.dataTimestamp,
    required this.reviewAt,
    required this.linkedNoteId,
    required this.userConclusion,
    required this.reviewResult,
    required this.archived,
    required this.archiveUrl,
    required this.archiveSha256,
    this.reviewErrorClass = '',
  });

  final String id;
  final StockQuote quote;
  final StockIndicators indicators;
  final Map<String, dynamic> analysis;
  final List<String> sources;
  final String model;
  final double estimatedCostUsd;
  final DateTime createdAt;
  final DateTime dataTimestamp;
  final DateTime reviewAt;
  final String linkedNoteId;
  final String userConclusion;
  final String reviewResult;
  final bool archived;
  final String archiveUrl;
  final String archiveSha256;
  final String reviewErrorClass;

  String get summary => '${analysis['summary'] ?? analysis['thesis'] ?? ''}';

  Map<String, dynamic> toPortableJson() => {
    'id': id,
    'quote': quote.toJson(),
    'indicators': indicators.toJson(),
    'analysis': analysis,
    'sources': sources,
    'model': model,
    'estimatedCostUsd': estimatedCostUsd,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'dataTimestamp': dataTimestamp.toUtc().toIso8601String(),
    'reviewAt': reviewAt.toUtc().toIso8601String(),
    'linkedNoteId': linkedNoteId,
    'userConclusion': userConclusion,
    'reviewResult': reviewResult,
    'reviewErrorClass': reviewErrorClass,
  };

  Map<String, dynamic> toFirestore() => {
    ...toPortableJson(),
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'dataTimestamp': Timestamp.fromDate(dataTimestamp.toUtc()),
    'reviewAt': Timestamp.fromDate(reviewAt.toUtc()),
    'archived': archived,
    'archiveUrl': archiveUrl,
    'archiveSha256': archiveSha256,
    if (archived) 'analysis': const <String, dynamic>{},
  };

  StockResearchReport copyWith({
    Map<String, dynamic>? analysis,
    String? linkedNoteId,
    String? userConclusion,
    String? reviewResult,
    bool? archived,
    String? archiveUrl,
    String? archiveSha256,
    String? reviewErrorClass,
  }) => StockResearchReport(
    id: id,
    quote: quote,
    indicators: indicators,
    analysis: analysis ?? this.analysis,
    sources: sources,
    model: model,
    estimatedCostUsd: estimatedCostUsd,
    createdAt: createdAt,
    dataTimestamp: dataTimestamp,
    reviewAt: reviewAt,
    linkedNoteId: linkedNoteId ?? this.linkedNoteId,
    userConclusion: userConclusion ?? this.userConclusion,
    reviewResult: reviewResult ?? this.reviewResult,
    archived: archived ?? this.archived,
    archiveUrl: archiveUrl ?? this.archiveUrl,
    archiveSha256: archiveSha256 ?? this.archiveSha256,
    reviewErrorClass: reviewErrorClass ?? this.reviewErrorClass,
  );

  factory StockResearchReport.fromJson(Map<String, dynamic> json) =>
      StockResearchReport(
        id: '${json['id'] ?? ''}',
        quote: StockQuote.fromJson(
          Map<String, dynamic>.from(json['quote'] as Map? ?? const {}),
        ),
        indicators: StockIndicators.fromJson(
          Map<String, dynamic>.from(json['indicators'] as Map? ?? const {}),
        ),
        analysis: Map<String, dynamic>.from(
          json['analysis'] as Map? ?? const {},
        ),
        sources: List<String>.from(json['sources'] as List? ?? const []),
        model: '${json['model'] ?? ''}',
        estimatedCostUsd: _double(json['estimatedCostUsd']),
        createdAt: _date(json['createdAt']),
        dataTimestamp: _date(json['dataTimestamp']),
        reviewAt: _date(json['reviewAt']),
        linkedNoteId: '${json['linkedNoteId'] ?? ''}',
        userConclusion: '${json['userConclusion'] ?? ''}',
        reviewResult: '${json['reviewResult'] ?? ''}',
        archived: json['archived'] as bool? ?? false,
        archiveUrl: '${json['archiveUrl'] ?? ''}',
        archiveSha256: '${json['archiveSha256'] ?? ''}',
        reviewErrorClass: '${json['reviewErrorClass'] ?? ''}',
      );
}

@immutable
class StockQuantReport {
  const StockQuantReport({
    required this.id,
    required this.strategyName,
    required this.provider,
    required this.trustTier,
    required this.createdAt,
    required this.report,
  });

  final String id;
  final String strategyName;
  final String provider;
  final String trustTier;
  final DateTime createdAt;
  final Map<String, dynamic> report;

  bool get qualifiedForPlan {
    final qualification = report['qualification'];
    return qualification is Map && qualification['qualified_for_plan'] == true;
  }

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'strategyName': strategyName,
    'provider': provider,
    'trustTier': trustTier,
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    // Deliberately excludes source candles and full-market matrices.
    'report': report,
  };

  factory StockQuantReport.fromJson(Map<String, dynamic> json) =>
      StockQuantReport(
        id: '${json['id'] ?? ''}',
        strategyName: '${json['strategyName'] ?? ''}',
        provider: '${json['provider'] ?? ''}',
        trustTier: '${json['trustTier'] ?? ''}',
        createdAt: _date(json['createdAt']),
        report: Map<String, dynamic>.from(json['report'] as Map? ?? const {}),
      );
}

@immutable
class StockPortfolioPosition {
  const StockPortfolioPosition({
    required this.code,
    required this.exchange,
    required this.name,
    required this.industry,
    required this.shares,
    required this.sellableShares,
    required this.averageCost,
    required this.lastPrice,
    required this.annualVolatility,
  }) : assert(code.length == 6),
       assert(shares >= 0 && sellableShares >= 0 && sellableShares <= shares),
       assert(lastPrice > 0 && averageCost >= 0),
       assert(annualVolatility >= 0 && annualVolatility <= 5);

  final String code;
  final String exchange;
  final String name;
  final String industry;
  final int shares;
  final int sellableShares;
  final double averageCost;
  final double lastPrice;
  final double annualVolatility;

  @override
  bool operator ==(Object other) =>
      other is StockPortfolioPosition &&
      other.code == code &&
      other.exchange == exchange &&
      other.shares == shares &&
      other.lastPrice == lastPrice;

  @override
  int get hashCode => Object.hash(code, exchange, shares, lastPrice);

  Map<String, dynamic> toJson() => {
    'code': code,
    'exchange': exchange,
    'name': name,
    'industry': industry,
    'shares': shares,
    'sellableShares': sellableShares,
    'averageCost': averageCost,
    'lastPrice': lastPrice,
    'annualVolatility': annualVolatility,
  };

  factory StockPortfolioPosition.fromJson(Map<String, dynamic> json) =>
      StockPortfolioPosition(
        code: '${json['code'] ?? ''}',
        exchange: '${json['exchange'] ?? 'SSE'}',
        name: '${json['name'] ?? ''}',
        industry: '${json['industry'] ?? '未分类'}',
        shares: _int(json['shares']),
        sellableShares: _int(json['sellableShares'] ?? json['shares']),
        averageCost: _double(json['averageCost']),
        lastPrice: _double(json['lastPrice']),
        annualVolatility: _double(json['annualVolatility']) == 0
            ? 0.30
            : _double(json['annualVolatility']),
      );
}

@immutable
class StockPortfolio {
  const StockPortfolio({
    required this.equity,
    required this.cash,
    required this.asOf,
    required this.positions,
    required this.updatedAt,
  });

  final double equity;
  final double cash;
  final DateTime asOf;
  final List<StockPortfolioPosition> positions;
  final DateTime updatedAt;

  bool get isValid => equity > 0 && cash >= 0 && cash <= equity;

  Map<String, dynamic> toFirestore() => {
    'id': 'current',
    'equity': equity,
    'cash': cash,
    'asOf': Timestamp.fromDate(asOf.toUtc()),
    'positions': positions.map((item) => item.toJson()).toList(growable: false),
    'updatedAt': Timestamp.fromDate(updatedAt.toUtc()),
  };

  factory StockPortfolio.fromJson(Map<String, dynamic> json) => StockPortfolio(
    equity: _double(json['equity']),
    cash: _double(json['cash']),
    asOf: _date(json['asOf']),
    positions: (json['positions'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              StockPortfolioPosition.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false),
    updatedAt: _date(json['updatedAt']),
  );
}

@immutable
class StockPlanRecord {
  const StockPlanRecord({
    required this.id,
    required this.createdAt,
    required this.status,
    required this.payload,
  });

  final String id;
  final DateTime createdAt;
  final String status;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'status': status,
    'payload': payload,
  };

  factory StockPlanRecord.fromJson(Map<String, dynamic> json) =>
      StockPlanRecord(
        id: '${json['id'] ?? ''}',
        createdAt: _date(json['createdAt']),
        status: '${json['status'] ?? 'draft'}',
        payload: Map<String, dynamic>.from(json['payload'] as Map? ?? const {}),
      );
}

@immutable
class StockOrderDraft {
  const StockOrderDraft({
    required this.id,
    required this.batchId,
    required this.planId,
    required this.instrument,
    required this.side,
    required this.quantity,
    required this.limitPrice,
    required this.tranche,
    required this.createdAt,
    required this.expiresAt,
    required this.sourceSnapshotHash,
    required this.idempotencyKey,
    this.status = 'pending_confirmation',
    this.humanConfirmationRequired = true,
    this.brokerSubmissionAllowed = false,
  });

  final String id;
  final String batchId;
  final String planId;
  final String instrument;
  final String side;
  final int quantity;
  final double limitPrice;
  final int tranche;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String sourceSnapshotHash;
  final String idempotencyKey;
  final String status;
  final bool humanConfirmationRequired;
  final bool brokerSubmissionAllowed;

  bool get isPending => status == 'pending_confirmation';
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
  double get notional => quantity * limitPrice;

  Map<String, dynamic> toJson() => {
    'id': id,
    'batchId': batchId,
    'planId': planId,
    'instrument': instrument,
    'side': side,
    'quantity': quantity,
    'limitPrice': limitPrice,
    'tranche': tranche,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'sourceSnapshotHash': sourceSnapshotHash,
    'idempotencyKey': idempotencyKey,
    'status': status,
    'humanConfirmationRequired': humanConfirmationRequired,
    'brokerSubmissionAllowed': false,
  };

  StockOrderDraft copyWith({String? status}) => StockOrderDraft(
    id: id,
    batchId: batchId,
    planId: planId,
    instrument: instrument,
    side: side,
    quantity: quantity,
    limitPrice: limitPrice,
    tranche: tranche,
    createdAt: createdAt,
    expiresAt: expiresAt,
    sourceSnapshotHash: sourceSnapshotHash,
    idempotencyKey: idempotencyKey,
    status: status ?? this.status,
    humanConfirmationRequired: humanConfirmationRequired,
    brokerSubmissionAllowed: false,
  );

  Map<String, dynamic> toFirestore() => {
    ...toJson(),
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'expiresAt': Timestamp.fromDate(expiresAt.toUtc()),
  };

  factory StockOrderDraft.fromJson(Map<String, dynamic> json) =>
      StockOrderDraft(
        id: '${json['id'] ?? ''}',
        batchId: '${json['batchId'] ?? ''}',
        planId: '${json['planId'] ?? ''}',
        instrument: '${json['instrument'] ?? ''}',
        side: '${json['side'] ?? 'buy'}',
        quantity: _int(json['quantity']),
        limitPrice: _double(json['limitPrice']),
        tranche: _int(json['tranche']),
        createdAt: _date(json['createdAt']),
        expiresAt: _date(json['expiresAt']),
        sourceSnapshotHash: '${json['sourceSnapshotHash'] ?? ''}',
        idempotencyKey: '${json['idempotencyKey'] ?? ''}',
        status: '${json['status'] ?? 'pending_confirmation'}',
        humanConfirmationRequired: json['humanConfirmationRequired'] != false,
        brokerSubmissionAllowed: false,
      );
}

@immutable
class StockOrderDraftBatch {
  const StockOrderDraftBatch({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.sourceSnapshotHash,
    required this.drafts,
    this.status = 'pending_confirmation',
    this.emergencyStop = false,
  });

  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String sourceSnapshotHash;
  final List<StockOrderDraft> drafts;
  final String status;
  final bool emergencyStop;

  double get totalNotional =>
      drafts.fold<double>(0, (total, item) => total + item.notional);

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'sourceSnapshotHash': sourceSnapshotHash,
    'status': status,
    'emergencyStop': emergencyStop,
    'brokerSubmissionAllowed': false,
    'drafts': drafts.map((item) => item.toJson()).toList(growable: false),
  };

  Map<String, dynamic> toFirestore() => {
    ...toJson(),
    'createdAt': Timestamp.fromDate(createdAt.toUtc()),
    'expiresAt': Timestamp.fromDate(expiresAt.toUtc()),
    'drafts': drafts.map((item) => item.toFirestore()).toList(growable: false),
  };

  factory StockOrderDraftBatch.fromJson(Map<String, dynamic> json) {
    final raw = json['drafts'] as List? ?? const [];
    return StockOrderDraftBatch(
      id: '${json['id'] ?? ''}',
      createdAt: _date(json['createdAt']),
      expiresAt: _date(json['expiresAt']),
      sourceSnapshotHash: '${json['sourceSnapshotHash'] ?? ''}',
      drafts: raw
          .whereType<Map>()
          .map(
            (item) => StockOrderDraft.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
      status: '${json['status'] ?? 'pending_confirmation'}',
      emergencyStop: json['emergencyStop'] == true,
    );
  }
}

@immutable
class StockMonitorAlert {
  const StockMonitorAlert({
    required this.kind,
    required this.severity,
    required this.message,
    required this.occurredAt,
  });

  final String kind;
  final String severity;
  final String message;
  final DateTime occurredAt;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'severity': severity,
    'message': message,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
  };

  factory StockMonitorAlert.fromJson(Map<String, dynamic> json) =>
      StockMonitorAlert(
        kind: '${json['kind'] ?? ''}',
        severity: '${json['severity'] ?? 'info'}',
        message: '${json['message'] ?? ''}',
        occurredAt: _date(json['occurredAt']),
      );
}

@immutable
class StockMonitorSnapshot {
  const StockMonitorSnapshot({
    required this.asOf,
    required this.equity,
    required this.peakEquity,
    required this.drawdown,
    required this.alerts,
    required this.updatedAt,
  });

  final DateTime asOf;
  final double equity;
  final double peakEquity;
  final double drawdown;
  final List<StockMonitorAlert> alerts;
  final DateTime updatedAt;

  Map<String, dynamic> toPortableJson() => {
    'asOf': asOf.toUtc().toIso8601String(),
    'equity': equity,
    'peakEquity': peakEquity,
    'drawdown': drawdown,
    'alerts': alerts.map((item) => item.toJson()).toList(growable: false),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toFirestore() => {
    'id': 'current',
    'asOf': Timestamp.fromDate(asOf.toUtc()),
    'equity': equity,
    'peakEquity': peakEquity,
    'drawdown': drawdown,
    'alerts': alerts.map((item) => item.toJson()).toList(growable: false),
    'updatedAt': Timestamp.fromDate(updatedAt.toUtc()),
  };

  factory StockMonitorSnapshot.fromJson(Map<String, dynamic> json) =>
      StockMonitorSnapshot(
        asOf: _date(json['asOf']),
        equity: _double(json['equity']),
        peakEquity: _double(json['peakEquity']),
        drawdown: _double(json['drawdown']),
        alerts: (json['alerts'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  StockMonitorAlert.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList(growable: false),
        updatedAt: _date(json['updatedAt']),
      );
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}

int _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

double? _nullableDouble(Object? value) {
  if (value == null) return null;
  final parsed = _double(value);
  return parsed.isFinite ? parsed : null;
}

DateTime _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }
  return DateTime.tryParse('$value') ?? DateTime.fromMillisecondsSinceEpoch(0);
}
