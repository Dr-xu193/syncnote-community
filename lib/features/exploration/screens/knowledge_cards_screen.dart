import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_repository.dart';

class KnowledgeCardsScreen extends StatefulWidget {
  const KnowledgeCardsScreen({super.key});

  @override
  State<KnowledgeCardsScreen> createState() => _KnowledgeCardsScreenState();
}

class _KnowledgeCardsScreenState extends State<KnowledgeCardsScreen> {
  List<KnowledgeCardItem> _items = const [];
  Set<String> _seen = {};
  int _index = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ExplorationRepository.instance.loadKnowledge();
    final seen = await ExplorationStateStore.instance.loadSeenKnowledge();
    final now = DateTime.now();
    final dailyIndex = items.isEmpty
        ? 0
        : (now.year * 372 + now.month * 31 + now.day) % items.length;
    if (!mounted) return;
    setState(() {
      _items = items;
      _seen = seen;
      _index = dailyIndex;
      _loading = false;
    });
  }

  Future<void> _markSeen() async {
    if (_items.isEmpty) return;
    final term = _items[_index].term;
    await ExplorationStateStore.instance.markKnowledgeSeen(term);
    if (!mounted) return;
    setState(() => _seen.add(term));
  }

  void _move(int delta) {
    if (_items.isEmpty) return;
    setState(() {
      _index = (_index + delta) % _items.length;
      if (_index < 0) _index += _items.length;
    });
  }

  void _random() {
    if (_items.length < 2) return;
    var next = _index;
    final random = math.Random();
    while (next == _index) {
      next = random.nextInt(_items.length);
    }
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('知识卡片')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(child: Text('知识数据加载失败'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final item = _items[_index];
                final isSeen = _seen.contains(item.term);
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Text(
                                '第 ${_index + 1} / ${_items.length} 条',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const Spacer(),
                              Chip(
                                avatar: Icon(
                                  isSeen
                                      ? Icons.check_circle_rounded
                                      : Icons.auto_awesome_rounded,
                                  size: 18,
                                ),
                                label: Text(isSeen ? '已经学过' : '今日发现'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: SingleChildScrollView(
                                padding: EdgeInsets.symmetric(
                                  horizontal: constraints.maxWidth >= 720
                                      ? 42
                                      : 22,
                                  vertical: 30,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.term,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w900,
                                          ),
                                    ),
                                    const SizedBox(height: 22),
                                    SelectableText(
                                      item.content,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(height: 1.75),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            alignment: WrapAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _move(-1),
                                icon: const Icon(Icons.chevron_left_rounded),
                                label: const Text('上一条'),
                              ),
                              FilledButton.icon(
                                onPressed: isSeen ? null : _markSeen,
                                icon: const Icon(Icons.done_rounded),
                                label: Text(isSeen ? '已完成阅读' : '标记为已读'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _random,
                                icon: const Icon(Icons.casino_outlined),
                                label: const Text('换一条'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _move(1),
                                icon: const Icon(Icons.chevron_right_rounded),
                                label: const Text('下一条'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
