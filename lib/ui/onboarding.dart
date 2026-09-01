import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app/mesh.dart';
import 'design_tokens.dart';
import 'strings.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 28),
            const Icon(Icons.radar, color: AC.primary, size: 64),
            const SizedBox(height: 10),
            const Center(child: Text('AIDBRIDGE', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 4, color: AC.text))),
            Center(child: Text(s.appTagline, style: const TextStyle(color: AC.dim), textAlign: TextAlign.center)),
            const SizedBox(height: 28),
            TextField(controller: _name, maxLength: 20, decoration: InputDecoration(labelText: '${s.callSign} *')),
            const SizedBox(height: 8),
            TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: s.phoneOpt)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r8), border: Border.all(color: AC.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [const Icon(Icons.info_outline, color: AC.primary, size: 18), const SizedBox(width: 8),
                  Expanded(child: Text(s.consent, style: const TextStyle(color: AC.dim, fontSize: 13)))]),
                const SizedBox(height: 8),
                Row(children: [const Icon(Icons.bluetooth_connected, color: AC.safe, size: 18), const SizedBox(width: 8),
                  Expanded(child: Text(s.radiosNote, style: const TextStyle(color: AC.dim, fontSize: 13)))]),
              ]),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : () async {
                if (_name.text.trim().isEmpty) return;
                setState(() => _busy = true);
                final id = ref.read(identityProvider.notifier);
                await id.setName(_name.text);
                await id.setPhone(_phone.text);
                await id.setRole('civilian');
                await id.completeOnboarding();
                if (mounted) context.go('/civilian');
              },
              child: Text(_busy ? '…' : s.startApp),
            ),
          ]),
        ),
      ),
    );
  }
}