import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'design_tokens.dart';

class NgoStubScreen extends StatelessWidget {
  const NgoStubScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('NGO COMMAND — Batch-6')),
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.radar, color: AC.primary, size: 72),
      const SizedBox(height: 12),
      const Text('Dashboard under construction.', style: TextStyle(color: AC.dim)),
      const SizedBox(height: 18),
      FilledButton(onPressed: () => context.go('/civilian'), child: const Text('BACK TO CIVILIAN')),
    ])),
  );
}