import 'package:flutter/material.dart';
import 'design_tokens.dart';

/// 0..4. Checks: length>=6, has uppercase, has digit, has special char.
int passwordScore(String pw) {
  int score = 0;
  if (pw.length >= 6) score++;
  if (RegExp(r'[A-Z]').hasMatch(pw)) score++;
  if (RegExp(r'[0-9]').hasMatch(pw)) score++;
  if (RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-]').hasMatch(pw)) score++;
  return score;
}

class PasswordStrengthBar extends StatelessWidget {
  final String password;
  const PasswordStrengthBar({super.key, required this.password});
  @override
  Widget build(BuildContext context) {
    final score = passwordScore(password);
    final color = switch (score) { 0 => AC.mute, 1 => AC.sos, 2 => Colors.orange, 3 => Colors.amber, _ => AC.safe };
    return Row(children: [
      for (int i = 0; i < 4; i++)
        Expanded(child: Container(
          margin: EdgeInsets.only(right: i == 3 ? 0 : 4),
          height: 4,
          decoration: BoxDecoration(color: i < score ? color : AC.border, borderRadius: BorderRadius.circular(2)),
        )),
    ]);
  }
}