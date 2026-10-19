import 'package:flutter/material.dart';

class PlayerRotationIcon extends StatelessWidget {
  const PlayerRotationIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return SizedBox.square(
      dimension: theme.size ?? 24,
      child: CustomPaint(
        painter: _RotationPainter(theme.color ?? Colors.white),
      ),
    );
  }
}

class _RotationPainter extends CustomPainter {
  const _RotationPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(7.5, 6, 9, 12),
        const Radius.circular(1.2),
      ),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(20.4, 8)
        ..lineTo(20.4, 6)
        ..quadraticBezierTo(20.4, 3.4, 17.8, 3.4)
        ..lineTo(16.2, 3.4)
        ..moveTo(3.6, 16)
        ..lineTo(3.6, 18)
        ..quadraticBezierTo(3.6, 20.6, 6.2, 20.6)
        ..lineTo(7.8, 20.6),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(14.4, 3.4)
        ..lineTo(16.6, 1.8)
        ..lineTo(16.6, 5)
        ..close()
        ..moveTo(9.6, 20.6)
        ..lineTo(7.4, 19)
        ..lineTo(7.4, 22.2)
        ..close(),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RotationPainter oldDelegate) =>
      color != oldDelegate.color;
}
