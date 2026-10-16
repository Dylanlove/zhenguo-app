import 'package:flutter/material.dart';

class PlayerDanmakuIcon extends StatelessWidget {
  const PlayerDanmakuIcon({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 28,
    child: CustomPaint(
      painter: _DanmakuPainter(
        enabled: enabled,
        color: IconTheme.of(context).color ?? Colors.white,
      ),
    ),
  );
}

class _DanmakuPainter extends CustomPainter {
  const _DanmakuPainter({required this.enabled, required this.color});

  final bool enabled;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 28, size.height / 28);
    const center = Offset(12.5, 12.5);
    const badgeCenter = Offset(22, 22);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    canvas.save();
    if (!enabled) {
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(const Rect.fromLTWH(0, 0, 28, 28))
          ..addOval(Rect.fromCircle(center: badgeCenter, radius: 6.2)),
      );
    }
    canvas.drawCircle(center, 11, stroke);
    final label = TextPainter(
      text: TextSpan(
        text: '弹',
        style: TextStyle(
          color: color,
          fontSize: 14.5,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
    label.dispose();
    canvas.restore();

    if (!enabled) {
      stroke.strokeWidth = 1.5;
      canvas.drawCircle(badgeCenter, 4.5, stroke);
      canvas.drawLine(
        badgeCenter - const Offset(2.4, 2.4),
        badgeCenter + const Offset(2.4, 2.4),
        stroke,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) =>
      enabled != oldDelegate.enabled || color != oldDelegate.color;
}
