import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/civilian_shell.dart';
import '../ui/onboarding.dart';
import '../ui/ngo_shell.dart';
import '../ui/splash_screen.dart';
import '../ui/how_it_works_screen.dart';
import '../ui/ngo_forgot_password.dart';
import '../ui/ngo_reset_password.dart';
import 'mesh.dart' show identityProvider;

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    // GUARD LAW: '/ngo' requires BOTH a locally-completed NGO identity AND a live Firebase
    // session — losing either (fresh install, signed out, cache wipe) bounces to onboarding
    // instead of showing a half-authenticated command dashboard.
    redirect: (context, state) {
      if (state.matchedLocation == '/ngo') {
        final id = ref.read(identityProvider);
        final signedIn = FirebaseAuth.instance.currentUser != null;
        if (id?.role != 'ngo' || !signedIn) return '/onboarding';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/how-it-works/:role', builder: (_, state) =>
          HowItWorksScreen(role: state.pathParameters['role'] ?? 'civilian')),
      GoRoute(path: '/civilian', builder: (_, _) => const CivilianShell()),
      GoRoute(path: '/ngo', builder: (_, _) => const NgoShell()),
      GoRoute(path: '/ngo-forgot-password', builder: (_, _) => const NgoForgotPasswordScreen()),
      GoRoute(path: '/ngo-reset-password', builder: (_, state) =>
          NgoResetPasswordScreen(email: state.extra as String?)),
    ],
  );
});