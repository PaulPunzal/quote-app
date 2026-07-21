import 'package:flutter/material.dart';

/// Shown in place of an ambient tab (morning/evening) before its
/// unlock time, so nothing is spoiled early.
class LockedPlaceholder extends StatelessWidget {
  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback onExplore;

  const LockedPlaceholder({
    super.key,
    required this.label,
    required this.hint,
    required this.icon,
    required this.onExplore,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: const Color(0xFFD8C3AE)),
            const SizedBox(height: 16),
            Text(
              'Your $label reflection is waiting',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                fontFamily: 'Georgia',
                color: Color(0xFF3B2E28),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A6F5C)),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: onExplore,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF8A6F5C),
              ),
              child: const Text('Explore reflections instead'),
            ),
          ],
        ),
      ),
    );
  }
}
