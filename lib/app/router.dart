import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/civilian_shell.dart';
import '../ui/onboarding.dart';
import '../ui/ngo_shell.dart';
import '../ui/splash_screen.dart';
import '../ui/how_it_works_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/how-it-works/:role', builder: (_, state) =>
          HowItWorksScreen(role: state.pathParameters['role'] ?? 'civilian')),
      GoRoute(path: '/civilian', builder: (_, _) => const CivilianShell()),
      GoRoute(path: '/ngo', builder: (_, _) => const NgoShell()),
    ],
  );
});