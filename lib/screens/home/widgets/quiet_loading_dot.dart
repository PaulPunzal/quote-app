import 'package:flutter/material.dart';

/// A tiny, static loading indicator used wherever a slot's reflection
/// is still being picked. Deliberately subtle — this app avoids
/// spinner-heavy loading states.
class QuietLoadingDot extends StatelessWidget {
  const QuietLoadingDot({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 8,
      height: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFFD8C3AE),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
