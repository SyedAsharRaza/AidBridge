import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'design_tokens.dart';
import 'password_strength.dart';
import 'strings.dart';

class NgoResetPasswordScreen extends ConsumerStatefulWidget {
  final String? email;
  const NgoResetPasswordScreen({super.key, this.email});
  @override
  ConsumerState<NgoResetPasswordScreen> createState() => _NgoResetPasswordScreenState();
}

class _NgoResetPasswordScreenState extends ConsumerState<NgoResetPasswordScreen> {
  final _code = TextEditingController();
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false, _obscure = true;

  @override
  void dispose() { _code.dispose(); _pw.dispose(); _confirm.dispose(); super.dispose(); }

  Future<void> _submit(S s) async {
    final messenger = ScaffoldMessenger.of(context);
    if (_code.text.trim().isEmpty || _pw.text.isEmpty || _confirm.text.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(s.fillAllFields))); return;
    }
    if (_pw.text.length < 6) { messenger.showSnackBar(SnackBar(content: Text(s.passwordTooShort))); return; }
    if (_pw.text != _confirm.text) { messenger.showSnackBar(SnackBar(content: Text(s.passwordsDontMatch))); return; }
    setState(() => _busy = true);
    final router = GoRouter.of(context);
    try {
      await FirebaseAuth.instance.confirmPasswordReset(code: _code.text.trim(), newPassword: _pw.text);
      messenger.showSnackBar(SnackBar(content: Text(s.passwordResetSuccess)));
      router.go('/onboarding');
    } on FirebaseAuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? s.passwordResetFailed)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(s.passwordResetFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Scaffold(
      backgroundColor: AC.bg,
      appBar: AppBar(title: Text(s.resetPassword)),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.email != null) Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Text('${s.ngoEmail}: ${widget.email}', style: const TextStyle(color: AC.dim))),
          TextField(controller: _code, decoration: InputDecoration(labelText: s.resetCode, helperText: s.resetCodeHint, helperMaxLines: 3)),
          const SizedBox(height: 16),
          TextField(controller: _pw, obscureText: _obscure, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: s.newPassword,
                  suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure)))),
          const SizedBox(height: 6),
          PasswordStrengthBar(password: _pw.text),
          const SizedBox(height: 16),
          TextField(controller: _confirm, obscureText: _obscure, decoration: InputDecoration(labelText: s.confirmPassword)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : () => _submit(s), child: Text(_busy ? '…' : s.resetPasswordBtn)),
        ]),
      )),
    );
  }
}