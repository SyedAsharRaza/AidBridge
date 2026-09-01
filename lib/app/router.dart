import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/civilian_shell.dart';
import '../ui/onboarding.dart';
import '../ui/ngo_shell.dart';
import 'mesh.dart' show identityProvider;

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: (ref.read(identityProvider)?.onboarded ?? false) ? '/civilian' : '/onboarding',
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      GoRoute(path: '/civilian', builder: (_, __) => const CivilianShell()),
      GoRoute(path: '/ngo', builder: (_, __) => const NgoShell()), // Batch-6 fills this body
    ],
  );
});