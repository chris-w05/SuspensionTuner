import 'package:flutter/material.dart';

class FftWindowPainter extends CustomPainter {
  const FftWindowPainter({
    required this.frontPoints,
    required this.rearPoints,
    required this.frontColor,
    required this.rearColor,
    required this.windowStartX,
    required this.windowEndX,
  });

  final List<Offset> frontPoints;
  final List<Offset> rearPoints;
  final Color frontColor;
  final Color rearColor;
  final double windowStartX;
  final double windowEndX;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    final Paint dimPaint = Paint()
      ..color = Colors.black.withAlpha(40)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(0, 0, windowStartX, h), dimPaint);
    canvas.drawRect(Rect.fromLTRB(windowEndX, 0, w, h), dimPaint);

    final Paint windowBorderPaint = Paint()
      ..color = Colors.blueAccent.withAlpha(180)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(
        Rect.fromLTRB(windowStartX, 0, windowEndX, h), windowBorderPaint);

    void drawTrace(List<Offset> pts, Color color) {
      if (pts.length < 2) return;
      final Paint tracePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round;
      final Path path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, tracePaint);
    }

    drawTrace(rearPoints, rearColor);
    drawTrace(frontPoints, frontColor);

    final Paint handlePaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawLine(
        Offset(windowStartX, 0), Offset(windowStartX, h), handlePaint);
    canvas.drawLine(
        Offset(windowEndX, 0), Offset(windowEndX, h), handlePaint);

    final Paint dotPaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(windowStartX, h / 2), 5, dotPaint);
    canvas.drawCircle(Offset(windowEndX, h / 2), 5, dotPaint);
  }

  @override
  bool shouldRepaint(FftWindowPainter old) =>
      old.windowStartX != windowStartX ||
      old.windowEndX != windowEndX ||
      old.frontPoints != frontPoints ||
      old.rearPoints != rearPoints;
}
