import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'design_tokens.dart';
import 'strings.dart';

class NgoForgotPasswordScreen extends ConsumerStatefulWidget {
  const NgoForgotPasswordScreen({super.key});
  @override
  ConsumerState<NgoForgotPasswordScreen> createState() => _NgoForgotPasswordScreenState();
}

class _NgoForgotPasswordScreenState extends ConsumerState<NgoForgotPasswordScreen> {
  final _email = TextEditingController();
  bool _sent = false, _busy = false;
  int _secondsLeft = 0;
  Timer? _timer;

  @override
  void dispose() { _timer?.cancel(); _email.dispose(); super.dispose(); }

  void _startCooldown() {
    setState(() => _secondsLeft = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft <= 1) { t.cancel(); setState(() => _secondsLeft = 0); }
      else { setState(() => _secondsLeft -= 1); }
    });
  }

  Future<void> _sendCode(S s) async {
    final messenger = ScaffoldMessenger.of(context);
    if (_email.text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(s.fillAllFields))); return;
    }
    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _email.text.trim());
      setState(() => _sent = true);
      _startCooldown();
    } on FirebaseAuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? s.sendCodeFailed)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(s.sendCodeFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _mmss {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final sec = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      backgroundColor: AC.bg,
      appBar: AppBar(title: Text(s.forgotPassword)),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.forgotPasswordHint, style: const TextStyle(color: AC.dim)),
          const SizedBox(height: 16),
          TextField(controller: _email, enabled: !_sent, keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: s.ngoEmail)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (_sent
                ? () => GoRouter.of(context).go('/ngo-reset-password', extra: _email.text.trim())
                : () => _sendCode(s)),
            child: Text(_busy ? '…' : (_sent ? s.verify : s.sendCode)),
          ),
          const SizedBox(height: 14),
          if (_sent) Center(
            child: _secondsLeft > 0
                ? Text('${s.resendIn} $_mmss', style: const TextStyle(color: AC.dim))
                : TextButton(onPressed: () => _sendCode(s), child: Text(s.resendCode)),
          ),
        ]),
      )),
    );
  }
}