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

  static final _glyph = Path()
    ..fillType = PathFillType.evenOdd
    ..moveTo(18.450, 16.581)
    ..lineTo(15.289, 16.581)
    ..lineTo(15.289, 18.468)
    ..lineTo(13.726, 18.468)
    ..lineTo(13.726, 16.581)
    ..lineTo(10.769, 16.581)
    ..lineTo(10.769, 15.018)
    ..lineTo(13.726, 15.018)
    ..lineTo(13.726, 14.117)
    ..lineTo(11.034, 14.117)
    ..lineTo(11.034, 8.311)
    ..lineTo(12.476, 8.311)
    ..cubicTo(12.220, 7.918, 11.975, 7.582, 11.743, 7.301)
    ..lineTo(12.969, 6.544)
    ..cubicTo(13.377, 6.977, 13.762, 7.441, 14.123, 7.938)
    ..lineTo(13.510, 8.311)
    ..lineTo(15.030, 8.311)
    ..cubicTo(15.471, 7.698, 15.866, 7.105, 16.214, 6.532)
    ..lineTo(17.645, 7.217)
    ..cubicTo(17.368, 7.586, 17.080, 7.950, 16.779, 8.311)
    ..lineTo(17.993, 8.311)
    ..lineTo(17.993, 14.117)
    ..lineTo(15.289, 14.117)
    ..lineTo(15.289, 15.018)
    ..lineTo(18.450, 15.018)
    ..close()
    ..moveTo(16.503, 9.585)
    ..lineTo(15.289, 9.585)
    ..lineTo(15.289, 10.619)
    ..lineTo(16.503, 10.619)
    ..close()
    ..moveTo(12.524, 10.619)
    ..lineTo(13.726, 10.619)
    ..lineTo(13.726, 9.585)
    ..lineTo(12.524, 9.585)
    ..close()
    ..moveTo(15.289, 12.843)
    ..lineTo(16.503, 12.843)
    ..lineTo(16.503, 11.797)
    ..lineTo(15.289, 11.797)
    ..close()
    ..moveTo(12.524, 12.843)
    ..lineTo(13.726, 12.843)
    ..lineTo(13.726, 11.797)
    ..lineTo(12.524, 11.797)
    ..close()
    ..moveTo(6.550, 7.181)
    ..lineTo(10.300, 7.181)
    ..lineTo(10.300, 11.364)
    ..lineTo(8.305, 11.364)
    ..lineTo(8.149, 12.758)
    ..lineTo(10.264, 12.758)
    ..lineTo(10.228, 14.453)
    ..cubicTo(10.188, 16.096, 10.145, 17.003, 10.099, 17.173)
    ..cubicTo(10.053, 17.343, 9.943, 17.553, 9.768, 17.804)
    ..cubicTo(9.594, 18.054, 9.261, 18.208, 8.768, 18.264)
    ..cubicTo(8.275, 18.320, 7.640, 18.348, 6.863, 18.348)
    ..cubicTo(6.814, 17.875, 6.718, 17.338, 6.574, 16.737)
    ..cubicTo(7.055, 16.769, 7.508, 16.785, 7.932, 16.785)
    ..cubicTo(8.157, 16.785, 8.331, 16.734, 8.455, 16.632)
    ..cubicTo(8.579, 16.530, 8.653, 16.374, 8.675, 16.163)
    ..cubicTo(8.697, 15.953, 8.726, 15.259, 8.762, 14.081)
    ..lineTo(6.586, 14.081)
    ..lineTo(6.911, 10.042)
    ..lineTo(8.846, 10.042)
    ..lineTo(8.846, 8.515)
    ..lineTo(6.550, 8.515)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 28, size.height / 28);
    const center = Offset(12.5, 12.5);
    const badgeCenter = Offset(21.5, 18.45);
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
          ..addOval(Rect.fromCircle(center: badgeCenter, radius: 6.3)),
      );
    }
    canvas.drawCircle(center, 11, stroke);
    canvas.drawPath(_glyph, Paint()..color = color);
    canvas.restore();

    if (!enabled) {
      stroke.strokeWidth = 1.5;
      canvas.drawCircle(badgeCenter, 4.1, stroke);
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
