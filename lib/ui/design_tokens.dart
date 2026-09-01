import 'package:flutter/material.dart';

/// DESIGN LAW — AidBridge tokens. These values are LAW, not suggestions.
class AC {
  static const bg = Color(0xFF0F1115);
  static const surface = Color(0xFF161A22);
  static const surface2 = Color(0xFF1D2230);
  static const primary = Color(0xFFFFB800);
  static const sos = Color(0xFFFF2A2A);
  static const safe = Color(0xFF2FD07F);
  static const text = Color(0xFFECEFF6);
  static const dim = Color(0xFFB8C0D1);
  static const mute = Color(0xFF6B7280);
  static const border = Color(0xFF2A2F3A);
}

/// Radius law: 8–12, never pills. Min touch target law: 56.
class AR { static const r8 = 8.0; static const r12 = 12.0; }
const kMinTarget = 56.0;

ThemeData buildAidBridgeTheme() => ThemeData.dark(useMaterial3: true).copyWith(
  scaffoldBackgroundColor: AC.bg,
  colorScheme: const ColorScheme.dark(primary: AC.primary, error: AC.sos, surface: AC.surface),
  dividerColor: AC.border,
  textTheme: Typography.whiteMountainView.apply(fontFamily: 'SpaceGrotesk', fontFamilyFallback: const ['Gulzar']),
  inputDecorationTheme: InputDecorationTheme(
    filled: true, fillColor: AC.surface,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(AR.r8), borderSide: const BorderSide(color: AC.border)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AR.r8), borderSide: const BorderSide(color: AC.border)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AR.r8), borderSide: const BorderSide(color: AC.primary, width: 2)),
  ),
  filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
    backgroundColor: AC.primary, foregroundColor: Colors.black,
    minimumSize: const Size.fromHeight(kMinTarget),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AR.r8)),
    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
  )),
  tabBarTheme: const TabBarThemeData(indicatorColor: AC.primary, labelColor: AC.primary, unselectedLabelColor: AC.mute),
  appBarTheme: const AppBarTheme(backgroundColor: AC.surface, centerTitle: false, titleTextStyle: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.4, fontSize: 17, color: AC.text)),
  snackBarTheme: const SnackBarThemeData(backgroundColor: AC.surface2, contentTextStyle: TextStyle(color: AC.text)),
);