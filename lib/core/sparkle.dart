import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Four-point "AI spark" mark drawn with a smooth gradient.
/// When [active] (the assistant is thinking / streaming) it gently breathes and
/// rotates; otherwise it rests perfectly still.
class AiSparkle extends StatefulWidget {
  final double size;
  final bool active;
  const AiSparkle({super.key, this.size = 22, this.active = false});

  @override
  State<AiSparkle> createState() => _AiSparkleState();
}

class _AiSparkleState extends State<AiSparkle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(AiSparkle old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      // Finish the current turn smoothly instead of snapping back.
      _c.animateTo(1, curve: Curves.easeOut).whenComplete(() {
        if (mounted && !widget.active) _c.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          final on = widget.active &&
              !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
          final pulse = on ? 1 + 0.12 * math.sin(t * math.pi * 2) : 1.0;
          return Transform.rotate(
            angle: on ? t * math.pi / 2 : 0,
            child: Transform.scale(
              scale: pulse,
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _SparklePainter(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = s / 2;
    final q = s * 0.07; // how pinched the waist is (smaller = sharper points)
    final path = Path()
      ..moveTo(c, 0)
      ..quadraticBezierTo(c + q, c - q, s, c)
      ..quadraticBezierTo(c + q, c + q, c, s)
      ..quadraticBezierTo(c - q, c + q, 0, c)
      ..quadraticBezierTo(c - q, c - q, c, 0)
      ..close();
    final paint = Paint()
      ..isAntiAlias = true
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4F8CFF), Color(0xFF9B72F2), Color(0xFFE5688C)],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
