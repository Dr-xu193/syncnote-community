import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';

class StockKLineChart extends StatefulWidget {
  const StockKLineChart({super.key, required this.series, this.height = 330});

  final StockSeries series;
  final double height;

  @override
  State<StockKLineChart> createState() => _StockKLineChartState();
}

class _StockKLineChartState extends State<StockKLineChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final candles = widget.series.candles;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void select(Offset position) {
          if (candles.isEmpty || width <= 1) return;
          final index = (position.dx / width * candles.length).floor().clamp(
            0,
            candles.length - 1,
          );
          setState(() => _selected = index);
        }

        final selected = _selected == null ? null : candles[_selected!];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(_dateLabel(selected.timestamp, widget.series.period)),
                    Text('开 ${selected.open.toStringAsFixed(2)}'),
                    Text('高 ${selected.high.toStringAsFixed(2)}'),
                    Text('低 ${selected.low.toStringAsFixed(2)}'),
                    Text('收 ${selected.close.toStringAsFixed(2)}'),
                    Text('量 ${_compact(selected.volume)}'),
                  ],
                ),
              ),
            GestureDetector(
              onTapDown: (details) => select(details.localPosition),
              onHorizontalDragUpdate: (details) =>
                  select(details.localPosition),
              onHorizontalDragEnd: (_) => setState(() => _selected = null),
              child: CustomPaint(
                size: Size(width, widget.height),
                painter: _StockChartPainter(
                  candles: candles,
                  minute: widget.series.period == StockPeriod.minute,
                  selected: _selected,
                  rising: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xffef5350)
                      : const Color(0xffd32f2f),
                  falling: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xff26a69a)
                      : const Color(0xff00897b),
                  grid: Theme.of(context).colorScheme.outlineVariant,
                  text: Theme.of(context).colorScheme.onSurfaceVariant,
                  primary: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _dateLabel(DateTime value, StockPeriod period) {
    return period == StockPeriod.minute
        ? DateFormat('MM-dd HH:mm').format(value)
        : DateFormat('yyyy-MM-dd').format(value);
  }

  static String _compact(double value) {
    if (value.abs() >= 1e8) return '${(value / 1e8).toStringAsFixed(1)}亿';
    if (value.abs() >= 1e4) return '${(value / 1e4).toStringAsFixed(1)}万';
    return value.toStringAsFixed(0);
  }
}

class _StockChartPainter extends CustomPainter {
  const _StockChartPainter({
    required this.candles,
    required this.minute,
    required this.selected,
    required this.rising,
    required this.falling,
    required this.grid,
    required this.text,
    required this.primary,
  });

  final List<StockCandle> candles;
  final bool minute;
  final int? selected;
  final Color rising;
  final Color falling;
  final Color grid;
  final Color text;
  final Color primary;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width < 10 || size.height < 10) return;
    const labelWidth = 54.0;
    const top = 8.0;
    final priceHeight = size.height * 0.72;
    final volumeTop = priceHeight + 18;
    final volumeHeight = math.max(20.0, size.height - volumeTop - 8);
    final chartWidth = math.max(1.0, size.width - labelWidth);
    var minPrice = candles.first.low;
    var maxPrice = candles.first.high;
    var maxVolume = candles.first.volume;
    for (final candle in candles) {
      minPrice = math.min(minPrice, candle.low);
      maxPrice = math.max(maxPrice, candle.high);
      maxVolume = math.max(maxVolume, candle.volume);
    }
    final priceRange = math.max(0.000001, maxPrice - minPrice);
    final slot = chartWidth / candles.length;
    final bodyWidth = math.max(1.0, math.min(8.0, slot * 0.58));

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.7)
      ..strokeWidth = 0.8;
    for (var line = 0; line <= 4; line++) {
      final y = top + (priceHeight - top) * line / 4;
      canvas.drawLine(Offset(0, y), Offset(chartWidth, y), gridPaint);
      final price = maxPrice - priceRange * line / 4;
      final painter = TextPainter(
        text: TextSpan(
          text: price.toStringAsFixed(2),
          style: TextStyle(color: text, fontSize: 10),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: labelWidth);
      painter.paint(canvas, Offset(chartWidth + 4, y - 6));
    }

    double xFor(int index) => (index + 0.5) * slot;
    double yFor(double price) =>
        top + (maxPrice - price) / priceRange * (priceHeight - top);

    if (minute) {
      final path = Path();
      for (var index = 0; index < candles.length; index++) {
        final point = Offset(xFor(index), yFor(candles[index].close));
        if (index == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = primary
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke,
      );
    } else {
      for (var index = 0; index < candles.length; index++) {
        final candle = candles[index];
        final color = candle.close >= candle.open ? rising : falling;
        final x = xFor(index);
        final paint = Paint()
          ..color = color
          ..strokeWidth = math.max(1, bodyWidth * 0.18);
        canvas.drawLine(
          Offset(x, yFor(candle.high)),
          Offset(x, yFor(candle.low)),
          paint,
        );
        final topY = yFor(math.max(candle.open, candle.close));
        final bottomY = yFor(math.min(candle.open, candle.close));
        canvas.drawRect(
          Rect.fromLTRB(
            x - bodyWidth / 2,
            topY,
            x + bodyWidth / 2,
            math.max(topY + 1, bottomY),
          ),
          paint,
        );
      }
    }

    if (maxVolume > 0) {
      for (var index = 0; index < candles.length; index++) {
        final candle = candles[index];
        final height = candle.volume / maxVolume * volumeHeight;
        final color = candle.close >= candle.open ? rising : falling;
        canvas.drawRect(
          Rect.fromLTWH(
            xFor(index) - bodyWidth / 2,
            volumeTop + volumeHeight - height,
            bodyWidth,
            height,
          ),
          Paint()..color = color.withValues(alpha: 0.62),
        );
      }
    }

    if (selected != null && selected! >= 0 && selected! < candles.length) {
      final x = xFor(selected!);
      final y = yFor(candles[selected!].close);
      final cross = Paint()
        ..color = text.withValues(alpha: 0.8)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), cross);
      canvas.drawLine(Offset(0, y), Offset(chartWidth, y), cross);
      canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = primary);
    }
  }

  @override
  bool shouldRepaint(covariant _StockChartPainter oldDelegate) {
    return oldDelegate.candles != candles ||
        oldDelegate.minute != minute ||
        oldDelegate.selected != selected ||
        oldDelegate.primary != primary;
  }
}
