import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'max-thinking tool loop carries reasoning and produces a cited decision',
    () async {
      final requests = <Map<String, dynamic>>[];
      final tools = _FakeStockTools();
      final ai = StockAgentAiService(
        tools: tools,
        client: MockClient((request) async {
          requests.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          if (requests.length == 1) {
            return _response(
              content: null,
              reasoning: 'I need to inspect the stock history.',
              toolCalls: [
                _toolCall('call-1', 'stock_history', {
                  'code': '600001',
                  'limit': 60,
                }),
              ],
            );
          }
          return _response(
            content: jsonEncode(
              _decision(
                mode: 'rebalance',
                targets: [
                  {
                    'code': '600001',
                    'exchange': 'SSE',
                    'targetWeight': 0.8,
                    'reason': '价格和成交量资料支持本次虚拟尝试',
                  },
                ],
                sourceIds: ['quote-1'],
              ),
            ),
          );
        }),
      );
      final result = await ai.decide(asOf: _asOf, memory: _memory());
      expect(result.mode, 'rebalance');
      expect(result.targets.single.targetWeight, 0.8);
      expect(result.sourceIds, ['quote-1']);
      expect(result.promptTokens, 2000);
      expect(result.completionTokens, 300);
      expect(tools.names, ['stock_history']);
      expect(requests, hasLength(2));
      expect(requests.first['model'], 'deepseek-flash');
      expect(requests.first['reasoning_effort'], 'max');
      expect((requests.first['thinking'] as Map)['type'], 'enabled');
      expect(requests.first, isNot(contains('temperature')));
      final secondMessages = requests.last['messages'] as List;
      expect(
        secondMessages.any(
          (item) =>
              item is Map &&
              item['reasoning_content'] ==
                  'I need to inspect the stock history.',
        ),
        isTrue,
      );
      expect(
        secondMessages.any(
          (item) =>
              item is Map &&
              item['role'] == 'tool' &&
              item['tool_call_id'] == 'call-1',
        ),
        isTrue,
      );
      ai.dispose();
    },
  );

  test('holding cash is a valid unconstrained virtual decision', () async {
    final ai = StockAgentAiService(
      tools: _FakeStockTools(),
      client: MockClient(
        (_) async => _response(
          content: jsonEncode(_decision(mode: 'rebalance', targets: [])),
        ),
      ),
    );
    final result = await ai.decide(asOf: _asOf, memory: _memory());
    expect(result.targets, isEmpty);
    expect(result.mode, 'rebalance');
    ai.dispose();
  });

  test(
    'exhausted research tools still get one final max-thinking decision',
    () async {
      final requests = <Map<String, dynamic>>[];
      final tools = _FakeStockTools();
      final ai = StockAgentAiService(
        tools: tools,
        client: MockClient((request) async {
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          requests.add(body);
          if (body.containsKey('tools')) {
            final turn = requests.length;
            return _response(
              content: null,
              reasoning: 'I need more market evidence.',
              toolCalls: [
                for (var i = 0; i < 3; i++)
                  _toolCall('call-$turn-$i', 'stock_history', {
                    'code': '600001',
                  }),
              ],
            );
          }
          return _response(
            content: jsonEncode(
              _decision(mode: 'hold', sourceIds: ['quote-1']),
            ),
          );
        }),
      );
      final result = await ai.decide(asOf: _asOf, memory: _memory());
      expect(result.mode, 'hold');
      expect(tools.names, hasLength(StockAgentAiService.maxToolCalls));
      expect(requests.last, isNot(contains('tools')));
      expect(requests.last['reasoning_effort'], 'max');
      final messages = requests.last['messages'] as List;
      expect(
        messages.whereType<Map>().any(
          (item) =>
              item['role'] == 'tool' &&
              '${item['content']}'.contains('查询额度已用完'),
        ),
        isTrue,
      );
      ai.dispose();
    },
  );

  test('invalid or fabricated virtual allocations are rejected', () async {
    final ai = StockAgentAiService(
      tools: _FakeStockTools(),
      client: MockClient(
        (_) async => _response(
          content: jsonEncode(
            _decision(
              mode: 'rebalance',
              targets: [
                {
                  'code': '600001',
                  'exchange': 'SSE',
                  'targetWeight': 1.2,
                  'reason': '试图借不存在的资金',
                },
              ],
            ),
          ),
        ),
      ),
    );
    await expectLater(
      ai.decide(asOf: _asOf, memory: _memory()),
      throwsStateError,
    );
    ai.dispose();
  });

  test('the model cannot fabricate a source ID', () async {
    final ai = StockAgentAiService(
      tools: _FakeStockTools(),
      client: MockClient(
        (_) async => _response(
          content: jsonEncode(_decision(sourceIds: ['never-seen'])),
        ),
      ),
    );
    await expectLater(
      ai.decide(asOf: _asOf, memory: _memory()),
      throwsStateError,
    );
    ai.dispose();
  });

  test('an old memory alone cannot justify a new virtual buy', () async {
    final base = _memory();
    final memory = StockAgentMemoryContext(
      experiment: base.experiment.copyWith(
        account: const {
          'initialCash': 1000,
          'cash': 500,
          'positions': [
            {'code': '600001', 'shares': 100},
          ],
        },
      ),
      recent: const [],
      relevant: const [],
      sourceEventIds: const ['old-thesis'],
    );
    final ai = StockAgentAiService(
      tools: _FakeStockTools(),
      client: MockClient(
        (_) async => _response(
          content: jsonEncode(
            _decision(
              mode: 'rebalance',
              targets: [
                {
                  'code': '600001',
                  'exchange': 'SSE',
                  'targetWeight': 0.5,
                  'reason': '只有过去日记，没有本轮新行情',
                },
              ],
              sourceIds: ['old-thesis'],
            ),
          ),
        ),
      ),
    );
    await expectLater(ai.decide(asOf: _asOf, memory: memory), throwsStateError);
    ai.dispose();
  });

  test('a cited source cannot be reused to invent a different stock', () async {
    var calls = 0;
    final ai = StockAgentAiService(
      tools: _FakeStockTools(),
      client: MockClient((_) async {
        calls++;
        if (calls == 1) {
          return _response(
            content: null,
            toolCalls: [
              _toolCall('one', 'stock_history', {'code': '600001'}),
            ],
          );
        }
        return _response(
          content: jsonEncode(
            _decision(
              mode: 'rebalance',
              targets: [
                {
                  'code': '600002',
                  'exchange': 'SSE',
                  'targetWeight': 0.5,
                  'reason': '这只并未被资料返回的股票不应通过',
                },
              ],
              sourceIds: ['quote-1'],
            ),
          ),
        );
      }),
    );
    await expectLater(
      ai.decide(asOf: _asOf, memory: _memory()),
      throwsStateError,
    );
    ai.dispose();
  });

  test('unknown tools cannot execute a side effect', () async {
    final tools = _FakeStockTools();
    final ai = StockAgentAiService(
      tools: tools,
      client: MockClient(
        (_) async => _response(
          content: null,
          toolCalls: [_toolCall('bad', 'submit_real_order', const {})],
        ),
      ),
    );
    await expectLater(
      ai.decide(asOf: _asOf, memory: _memory()),
      throwsStateError,
    );
    expect(tools.names, isEmpty);
    ai.dispose();
  });

  test(
    'future tool evidence blocks a decision before the second model call',
    () async {
      var calls = 0;
      final tools = _FakeStockTools(futureData: true);
      final ai = StockAgentAiService(
        tools: tools,
        client: MockClient((_) async {
          calls++;
          return _response(
            content: null,
            toolCalls: [
              _toolCall('future', 'stock_history', {'code': '600001'}),
            ],
          );
        }),
      );
      await expectLater(
        ai.decide(asOf: _asOf, memory: _memory()),
        throwsStateError,
      );
      expect(calls, 1);
      ai.dispose();
    },
  );

  test(
    'empty max-thinking response never downgrades to another model',
    () async {
      var calls = 0;
      final ai = StockAgentAiService(
        tools: _FakeStockTools(),
        client: MockClient((_) async {
          calls++;
          return _response(content: '');
        }),
      );
      await expectLater(
        ai.decide(asOf: _asOf, memory: _memory()),
        throwsStateError,
      );
      expect(calls, 1);
      ai.dispose();
    },
  );

  test(
    'a runaway max-thinking call stops before a trade is returned',
    () async {
      final ai = StockAgentAiService(
        tools: _FakeStockTools(),
        client: MockClient(
          (_) async => _response(
            content: jsonEncode(_decision()),
            completionTokens:
                StockAgentAiService.maxCompletionTokensPerCycle + 1,
          ),
        ),
      );
      await expectLater(
        ai.decide(asOf: _asOf, memory: _memory()),
        throwsStateError,
      );
      ai.dispose();
    },
  );
}

final _asOf = DateTime.utc(2026, 9, 2, 8);

StockAgentMemoryContext _memory() => StockAgentMemoryContext(
  experiment: StockAgentExperiment(
    id: 'paper-experiment',
    startedAt: DateTime.utc(2026, 9, 1),
    endsAt: DateTime.utc(2026, 9, 30, 16),
    version: 1,
    account: const {'initialCash': 1000, 'cash': 1000, 'positions': []},
    memory: const {'pinnedEventIds': []},
    updatedAt: DateTime.utc(2026, 9, 2),
  ),
  recent: const [],
  relevant: const [],
  sourceEventIds: const [],
);

Map<String, dynamic> _decision({
  String mode = 'hold',
  List<Map<String, dynamic>> targets = const [],
  List<String> sourceIds = const [],
}) => {
  'mode': mode,
  'researchMemo': '我核对了当时可获得的行情和账户资金，比较了买入、等待及放弃。',
  'marketView': '仅对本轮可见市场资料形成判断，不假定未来收益。',
  'whyNow': '在截止前只使用现有一千元资金作虚拟决定。',
  'alternativesRejected': ['暂不采用缺乏证据的股票'],
  'uncertainties': ['免费行情可能延迟'],
  'nextDayExpectation': '下一交易日观察价格和成交量是否符合假设。',
  'monthExpectation': '月末重新检验本轮判断是否实际增加账户价值。',
  'targets': targets,
  'sourceIds': sourceIds,
};

Map<String, dynamic> _toolCall(
  String id,
  String name,
  Map<String, dynamic> arguments,
) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

http.Response _response({
  required String? content,
  String? reasoning,
  List<Map<String, dynamic>> toolCalls = const [],
  int completionTokens = 150,
}) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {
            'role': 'assistant',
            'content': content,
            'reasoning_content': reasoning,
            if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
          },
        },
      ],
      'usage': {'prompt_tokens': 1000, 'completion_tokens': completionTokens},
    }),
  ),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class _FakeStockTools implements StockAgentReadTools {
  _FakeStockTools({this.futureData = false});

  final bool futureData;
  final names = <String>[];

  @override
  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> arguments, {
    required DateTime asOf,
  }) async {
    names.add(name);
    return {
      'sourceId': 'quote-1',
      'sourceObservedAt':
          (futureData
                  ? asOf.add(const Duration(hours: 1))
                  : asOf.subtract(const Duration(hours: 1)))
              .toIso8601String(),
      'code': arguments['code'] ?? '600001',
      'price': 9.8,
    };
  }
}
