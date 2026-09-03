import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'design_tokens.dart';
import 'password_strength.dart';
import 'strings.dart';

class NgoChangePasswordScreen extends ConsumerStatefulWidget {
  const NgoChangePasswordScreen({super.key});
  @override
  ConsumerState<NgoChangePasswordScreen> createState() => _NgoChangePasswordScreenState();
}

class _NgoChangePasswordScreenState extends ConsumerState<NgoChangePasswordScreen> {
  final _current = TextEditingController();
  final _newPw = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true, _busy = false;

  @override
  void dispose() { _current.dispose(); _newPw.dispose(); _confirm.dispose(); super.dispose(); }

  Future<void> _submit(S s) async {
    final messenger = ScaffoldMessenger.of(context);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) { messenger.showSnackBar(SnackBar(content: Text(s.notSignedIn))); return; }
    if (_current.text.isEmpty || _newPw.text.isEmpty || _confirm.text.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(s.fillAllFields))); return;
    }
    if (_newPw.text.length < 6) { messenger.showSnackBar(SnackBar(content: Text(s.passwordTooShort))); return; }
    if (_newPw.text != _confirm.text) { messenger.showSnackBar(SnackBar(content: Text(s.passwordsDontMatch))); return; }
    if (_newPw.text == _current.text) { messenger.showSnackBar(SnackBar(content: Text(s.passwordMustDiffer))); return; }
    setState(() => _busy = true);
    try {
      final cred = EmailAuthProvider.credential(email: user.email!, password: _current.text);
      await user.reauthenticateWithCredential(cred); // this IS the "matches previous password" check
      await user.updatePassword(_newPw.text);
      if (mounted) { messenger.showSnackBar(SnackBar(content: Text(s.passwordResetSuccess))); Navigator.of(context).pop(); }
    } on FirebaseAuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(
          e.code == 'wrong-password' || e.code == 'invalid-credential' ? s.wrongCurrentPassword : (e.message ?? s.passwordResetFailed))));
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
          TextField(controller: _current, obscureText: _obscure, decoration: InputDecoration(labelText: s.currentPassword)),
          const SizedBox(height: 16),
          TextField(controller: _newPw, obscureText: _obscure, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: s.newPassword,
                  suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure)))),
          const SizedBox(height: 6),
          PasswordStrengthBar(password: _newPw.text),
          const SizedBox(height: 16),
          TextField(controller: _confirm, obscureText: _obscure, decoration: InputDecoration(labelText: s.confirmPassword)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : () => _submit(s), child: Text(_busy ? '…' : s.resetPasswordBtn)),
        ]),
      )),
    );
  }
}