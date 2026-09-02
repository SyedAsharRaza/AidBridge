import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'design_tokens.dart';
import 'strings.dart';

class HowItWorksScreen extends ConsumerWidget {
  final String role; // 'civilian' | 'ngo'
  const HowItWorksScreen({super.key, required this.role});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final isNgo = role == 'ngo';
    final title = isNgo ? s.howItWorksNgoTitle : s.howItWorksCivilianTitle;
    final points = isNgo ? s.ngoHowPoints : s.civilianHowPoints;
    final icon = isNgo ? Icons.health_and_safety : Icons.person_pin_circle;

    return Scaffold(
      backgroundColor: AC.bg,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 12),
                Icon(icon, color: AC.primary, size: 48),
                const SizedBox(height: 12),
                Text(title, textAlign: TextAlign.center,
                    style: const TextStyle(color: AC.text, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                const SizedBox(height: 24),
                for (final p in points) _point(p),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: FilledButton(
              onPressed: () => context.go(isNgo ? '/ngo' : '/civilian'),
              child: Text(s.howItWorksContinue),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _point(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Icon(Icons.circle, color: AC.primary, size: 8),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: const TextStyle(color: AC.dim, fontSize: 15, height: 1.4))),
    ]),
  );
}