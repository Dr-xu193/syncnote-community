import 'package:flutter/material.dart';

enum ExplorationModule { news, literature, knowledge, puzzles, stocks }

@immutable
class ExplorationModuleSpec {
  const ExplorationModuleSpec({
    required this.module,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
  });

  final ExplorationModule module;
  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
}

const explorationModuleSpecs = <ExplorationModuleSpec>[
  ExplorationModuleSpec(
    module: ExplorationModule.news,
    title: '今日新闻',
    subtitle: '权威来源 · 实时整理',
    description: '聚合经济、人工智能、国际局势与中国大陆新闻，保留来源和完整正文。',
    icon: Icons.newspaper_rounded,
  ),
  ExplorationModuleSpec(
    module: ExplorationModule.literature,
    title: '今日文献',
    subtitle: '按兴趣检索 · Flash 解读',
    description: '输入今天关注的方向，从多种学术来源筛选文献，并区分摘要解读与全文分析。',
    icon: Icons.science_rounded,
  ),
  ExplorationModuleSpec(
    module: ExplorationModule.knowledge,
    title: '知识卡片',
    subtitle: '每日学习 · 轻量积累',
    description: '从内置知识库中发现值得了解的概念，保留阅读状态并逐步建立个人知识脉络。',
    icon: Icons.lightbulb_rounded,
  ),
  ExplorationModuleSpec(
    module: ExplorationModule.puzzles,
    title: '逻辑推演',
    subtitle: '分阶段作答 · 智能裁判',
    description: '通过连续追问完成推演，查看明确的判定、理由、置信度和关卡进度。',
    icon: Icons.psychology_alt_rounded,
  ),
  ExplorationModuleSpec(
    module: ExplorationModule.stocks,
    title: '股票研究',
    subtitle: '行情探索 · 正反研究',
    description: '查看市场雷达、K 线与确定性筛选，用 Flash 形成可复盘的正反研究记录。',
    icon: Icons.candlestick_chart_rounded,
  ),
];

int explorationColumnCount(double width) {
  if (width >= 1080) return 4;
  if (width >= 660) return 2;
  return 1;
}

class KnowledgeExplorationHub extends StatelessWidget {
  const KnowledgeExplorationHub({super.key, this.onModuleSelected});

  final ValueChanged<ExplorationModule>? onModuleSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = explorationColumnCount(constraints.maxWidth);
        final horizontalPadding = constraints.maxWidth >= 900 ? 28.0 : 16.0;

        return CustomScrollView(
          key: const PageStorageKey<String>('knowledge-exploration-hub'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                12,
                horizontalPadding,
                18,
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            colors.primaryContainer,
                            colors.secondaryContainer.withValues(alpha: 0.72),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Wrap(
                        spacing: 18,
                        runSpacing: 14,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Icon(
                              Icons.explore_rounded,
                              color: colors.onPrimary,
                              size: 30,
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '探索中心',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '每天主动发现值得阅读和思考的内容；你的私人笔记仍保留在“我的知识库”中。',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                0,
                horizontalPadding,
                12,
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: Row(
                      children: [
                        Text(
                          '今日入口',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '五个栏目，一个入口',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                0,
                horizontalPadding,
                28,
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, sliverConstraints) {
                  final availableWidth = sliverConstraints.crossAxisExtent
                      .clamp(0, 1180)
                      .toDouble();
                  return SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal:
                          (sliverConstraints.crossAxisExtent - availableWidth) /
                          2,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        mainAxisExtent: columns == 1 ? 184 : 218,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final spec = explorationModuleSpecs[index];
                        return _ExplorationModuleCard(
                          spec: spec,
                          onTap: onModuleSelected == null
                              ? null
                              : () => onModuleSelected!(spec.module),
                        );
                      }, childCount: explorationModuleSpecs.length),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ExplorationModuleCard extends StatelessWidget {
  const _ExplorationModuleCard({required this.spec, this.onTap});

  final ExplorationModuleSpec spec;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(spec.icon, color: colors.primary),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                spec.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                spec.subtitle,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  spec.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
