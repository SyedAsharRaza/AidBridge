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
  String _role = 'civilian'; // chosen here so an NGO never has to hunt through Settings
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 28),
            Image.asset('assets/icon/aidbridge_splash_logo.png', width: 64, height: 64),
            const SizedBox(height: 10),
            const Center(child: Text('AIDBRIDGE', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 4, color: AC.text))),
            Center(child: Text(s.appTagline, style: const TextStyle(color: AC.dim), textAlign: TextAlign.center)),
            const SizedBox(height: 28),
            TextField(controller: _name, maxLength: 20, decoration: InputDecoration(labelText: '${s.callSign} *')),
            const SizedBox(height: 8),
            TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: s.phoneOpt)),
            const SizedBox(height: 14),
            Text(s.chooseRole, style: const TextStyle(color: AC.dim, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _roleTile('civilian', Icons.person_pin_circle, s.civilian, s.civilianHint),
            const SizedBox(height: 8),
            _roleTile('ngo', Icons.health_and_safety, s.ngo, s.ngoHint),
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
              onPressed: _busy ? null : () => _enter(s),
              child: Text(_busy ? '…' : s.startApp),
            ),
          ]),
        ),
      ),
    );
  }

  /// THE FRONT DOOR. Every failure path here must leave the door usable: a silent no-op or a
  /// button stuck on '…' means the user never gets into the app at all.
  Future<void> _enter(S s) async {
    final messenger = ScaffoldMessenger.of(context);
    if (_name.text.trim().isEmpty) {
      // Was a bare `return`: the button simply did nothing and never said why.
      messenger.showSnackBar(SnackBar(content: Text(s.nameRequired)));
      return;
    }
    setState(() => _busy = true);
    final router = GoRouter.of(context); // captured BEFORE the await gap
    final id = ref.read(identityProvider.notifier);
    try {
      // TRIMMED: the name becomes this phone's radio endpoint name, so stray whitespace
      // would ride along in every advertisement and every alert card.
      await id.setName(_name.text.trim());
      await id.setPhone(_phone.text.trim());
      await id.setRole(_role);
      await id.completeOnboarding();
      router.go(_role == 'ngo' ? '/ngo' : '/civilian');
    } catch (_) {
      // Without this the flag stayed true on ANY storage failure and the only way into the
      // app was disabled for the rest of the process — a permanent lockout at the door.
      messenger.showSnackBar(SnackBar(content: Text(s.saveFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _roleTile(String role, IconData icon, String title, String hint) {
    final on = _role == role;
    return InkWell(
      onTap: () => setState(() => _role = role),
      borderRadius: BorderRadius.circular(AR.r8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: on ? AC.surface2 : AC.surface,
          borderRadius: BorderRadius.circular(AR.r8),
          border: Border.all(color: on ? AC.primary : AC.border, width: on ? 2 : 1),
        ),
        child: Row(children: [
          Icon(icon, color: on ? AC.primary : AC.mute, size: 26),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(
                color: on ? AC.text : AC.dim, fontSize: 16, fontWeight: FontWeight.w800)),
            Text(hint, style: const TextStyle(color: AC.dim, fontSize: 12)),
          ])),
          // never colour alone: a check icon carries the same meaning (design LAW)
          Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
              color: on ? AC.primary : AC.mute, size: 22),
        ]),
      ),
    );
  }
}