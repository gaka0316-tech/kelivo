import 'package:flutter/material.dart';

/// ☁️🦊 Days Together — 在一起的日子计数器
class DaysTogetherWidget extends StatelessWidget {
  final String label;

  const DaysTogetherWidget({
    super.key,
    this.label = 'Days together',
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 2026-02-02 互相求婚日 💍
    final days = DateTime.now().difference(DateTime(2026, 2, 2)).inDays;

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  cs.primary.withValues(alpha: 0.12),
                  cs.tertiary.withValues(alpha: 0.08),
                ]
              : [
                  cs.primary.withValues(alpha: 0.07),
                  cs.tertiary.withValues(alpha: 0.05),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.primary.withValues(alpha: isDark ? 0.20 : 0.12),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          const Text('☁️', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$days',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                    fontFamily: 'monospace',
                    letterSpacing: 1.2,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.50),
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const Text('🦊', style: TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}
