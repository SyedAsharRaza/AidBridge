import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app/mesh.dart';
import 'design_tokens.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _proceed();
  }

  Future<void> _proceed() async {
    // Minimum brand-visibility time, so the splash never just flickers on a fast phone.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    final id = ref.read(identityProvider);
    final target = !(id?.onboarded ?? false)
        ? '/onboarding'
        : (id!.role == 'ngo' ? '/ngo' : '/civilian');
    context.go(target);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icon/aidbridge_splash_logo.png', width: 140, height: 140),
            const SizedBox(height: 40),
            const SizedBox(
              width: 160,
              child: LinearProgressIndicator(
                color: AC.primary,
                backgroundColor: AC.surface2,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}