import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/ai_service.dart';

class TaskStatsSheet extends StatelessWidget {
  const TaskStatsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: StreamBuilder<List<Task>>(
        stream: FirestoreService.instance.watchTasks(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final tasks = (snapshot.data ?? const <Task>[])
              .where((task) => task.parentId == null && !task.isArchived)
              .toList();
          if (tasks.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.query_stats_outlined,
                    size: 64,
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '暂无任务数据，无法生成统计报表。',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          }

          // Calculate stats
          final total = tasks.length;
          final completed = tasks
              .where((t) => t.status == TaskStatus.done)
              .length;
          final rate = total > 0 ? completed / total : 0.0;

          // Priority counts
          int low = 0, normal = 0, high = 0, urgent = 0;
          for (final t in tasks) {
            switch (t.priority) {
              case TaskPriority.low:
                low++;
                break;
              case TaskPriority.normal:
                normal++;
                break;
              case TaskPriority.high:
                high++;
                break;
              case TaskPriority.urgent:
                urgent++;
                break;
            }
          }

          // Last 7 days completion counts
          final now = DateTime.now();
          final List<int> weeklyCounts = List.filled(7, 0);
          final List<String> dayLabels = [];
          for (int i = 6; i >= 0; i--) {
            final day = now.subtract(Duration(days: i));
            dayLabels.add('${day.month}/${day.day}');

            // Count completed tasks on this specific calendar day
            final count = tasks.where((t) {
              if (t.status != TaskStatus.done) return false;
              final completedDate = t.effectiveCompletedAt;
              if (completedDate == null) return false;
              return completedDate.year == day.year &&
                  completedDate.month == day.month &&
                  completedDate.day == day.day;
            }).length;

            weeklyCounts[6 - i] = count;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '任务完成度统计',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Row for Circular ring chart and cards
                Row(
                  children: [
                    CustomPaint(
                      size: const Size(120, 120),
                      painter: CircularCompletionPainter(
                        percentage: rate,
                        primaryColor: theme.colorScheme.primary,
                        backgroundColor: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        textColor:
                            theme.textTheme.titleMedium?.color ?? Colors.black,
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStatCard(
                            '全部任务',
                            '$total 个',
                            Icons.list_alt,
                            Colors.blue,
                          ),
                          const SizedBox(height: 8),
                          _buildStatCard(
                            '已完成',
                            '$completed 个',
                            Icons.check_circle_outline,
                            Colors.green,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Weekly completion trend
                Text(
                  '最近 7 日完成趋势',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 180,
                  padding: const EdgeInsets.only(right: 8, top: 12),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: WeeklyLineChartPainter(
                      data: weeklyCounts,
                      labels: dayLabels,
                      primaryColor: theme.colorScheme.primary,
                      gridColor: theme.dividerColor.withValues(alpha: 0.2),
                      textColor:
                          theme.textTheme.bodySmall?.color ?? Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // Priority Distribution Bar list
                Text(
                  '任务优先级分布',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                _buildPriorityProgressBar(
                  '紧急 (Urgent)',
                  urgent,
                  total,
                  Colors.red,
                ),
                _buildPriorityProgressBar(
                  '重要 (High)',
                  high,
                  total,
                  Colors.orange,
                ),
                _buildPriorityProgressBar(
                  '普通 (Normal)',
                  normal,
                  total,
                  Colors.blue,
                ),
                _buildPriorityProgressBar('低 (Low)', low, total, Colors.green),
                _AiGrowthReportWidget(completedTasks: tasks),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPriorityProgressBar(
    String title,
    int count,
    int total,
    Color color,
  ) {
    final double pct = total > 0 ? count / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '$count 个 (${(pct * 100).toStringAsFixed(0)}%)',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class CircularCompletionPainter extends CustomPainter {
  final double percentage;
  final Color primaryColor;
  final Color backgroundColor;
  final Color textColor;

  CircularCompletionPainter({
    required this.percentage,
    required this.primaryColor,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;

    // Background circle
    final bgPaint = Paint()
      ..color = backgroundColor
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, bgPaint);

    // Active Arc
    final activePaint = Paint()
      ..color = primaryColor
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final sweepAngle = 2 * math.pi * percentage;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      activePaint,
    );

    // Text in middle
    final textSpan = TextSpan(
      text: '${(percentage * 100).toStringAsFixed(0)}%',
      style: TextStyle(
        color: textColor,
        fontSize: 22,
        fontWeight: FontWeight.bold,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant CircularCompletionPainter oldDelegate) {
    return oldDelegate.percentage != percentage;
  }
}

class WeeklyLineChartPainter extends CustomPainter {
  final List<int> data;
  final List<String> labels;
  final Color primaryColor;
  final Color gridColor;
  final Color textColor;

  WeeklyLineChartPainter({
    required this.data,
    required this.labels,
    required this.primaryColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxVal = data.reduce(math.max);
    final yMax = maxVal == 0 ? 5.0 : (maxVal * 1.2).ceilToDouble();

    // Chart margins
    final double leftPad = 24.0;
    final double bottomPad = 24.0;
    final double chartWidth = size.width - leftPad;
    final double chartHeight = size.height - bottomPad;

    // Paints
    final linePaint = Paint()
      ..color = primaryColor
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: 0.3),
          primaryColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(leftPad, 0, chartWidth, chartHeight));

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;

    // Draw horizontal grid lines and Y-axis labels
    const gridLines = 4;
    for (int i = 0; i <= gridLines; i++) {
      final y = chartHeight * i / gridLines;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);

      // Y value label
      final yVal = yMax * (gridLines - i) / gridLines;
      final textSpan = TextSpan(
        text: yVal.toStringAsFixed(0),
        style: TextStyle(color: textColor, fontSize: 9),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(leftPad - textPainter.width - 4, y - textPainter.height / 2),
      );
    }

    // Coordinates points
    final double xStep = chartWidth / 6;
    final List<Offset> points = [];

    for (int i = 0; i < 7; i++) {
      final x = leftPad + xStep * i;
      final double yRatio = data[i] / yMax;
      final y = chartHeight * (1.0 - yRatio);
      points.add(Offset(x, y));

      // Draw X-axis label
      final labelSpan = TextSpan(
        text: labels[i],
        style: TextStyle(color: textColor, fontSize: 9),
      );
      final labelPainter = TextPainter(
        text: labelSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(x - labelPainter.width / 2, size.height - labelPainter.height),
      );
    }

    // Draw bezier line and fill area
    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      // Smooth interpolation using control points
      final controlX = (p1.dx + p2.dx) / 2;
      path.cubicTo(controlX, p1.dy, controlX, p2.dy, p2.dx, p2.dy);
    }

    // Fill area path
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, chartHeight)
      ..lineTo(points.first.dx, chartHeight)
      ..close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    // Draw dots at data points
    final dotPaint = Paint()..color = primaryColor;
    final dotGlow = Paint()..color = Colors.white;
    for (final pt in points) {
      canvas.drawCircle(pt, 5.5, dotPaint);
      canvas.drawCircle(pt, 2.5, dotGlow);
    }
  }

  @override
  bool shouldRepaint(covariant WeeklyLineChartPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}

class _AiGrowthReportWidget extends StatefulWidget {
  const _AiGrowthReportWidget({required this.completedTasks});
  final List<Task> completedTasks;

  @override
  State<_AiGrowthReportWidget> createState() => _AiGrowthReportWidgetState();
}

class _AiGrowthReportWidgetState extends State<_AiGrowthReportWidget> {
  String? _growthReport;
  bool _isLoading = false;
  String? _error;

  Future<void> _generateReport() async {
    setState(() {
      _isLoading = true;
      _growthReport = null;
      _error = null;
    });

    try {
      final List<DiaryEntry> diaries = await FirestoreService.instance
          .watchDiaryEntries()
          .first;
      final oneWeekAgo = DateTime.now().subtract(const Duration(days: 7));
      final List<DiaryEntry> recentDiaries = diaries
          .where((d) => d.date.isAfter(oneWeekAgo))
          .toList();
      final recentCompletedTasks = widget.completedTasks.where((task) {
        final completedAt = task.effectiveCompletedAt;
        return completedAt != null && !completedAt.isBefore(oneWeekAgo);
      }).toList();

      final report = await AIService.instance.analyzeGrowth(
        recentCompletedTasks,
        recentDiaries,
      );

      if (mounted) {
        setState(() {
          _growthReport = report ?? '生成报告失败，请检查网络后重试。';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '错误: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(top: 24),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.1)),
      ),
      child: ExpansionTile(
        title: Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.purple, size: 20),
            const SizedBox(width: 8),
            Text(
              'AI 导师成长复盘周报',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.purple.shade800,
              ),
            ),
          ],
        ),
        subtitle: const Text('基于你本周完成的任务与心情做综合评估'),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20.0),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('AI 导师正在综合分析本周指标...'),
                  ],
                ),
              ),
            )
          else if (_growthReport != null)
            MarkdownBody(
              data: _growthReport!,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 14, height: 1.5),
                h3: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  height: 2,
                ),
              ),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red))
          else
            Center(
              child: ElevatedButton.icon(
                onPressed: _generateReport,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('一键生成成长报告'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple.shade50,
                  foregroundColor: Colors.purple.shade800,
                  elevation: 0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
