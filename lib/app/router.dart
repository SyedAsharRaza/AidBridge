import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../ui/civilian_shell.dart';
import '../ui/onboarding.dart';
import '../ui/ngo_shell.dart';
import 'mesh.dart' show identityProvider;

final routerProvider = Provider<GoRouter>((ref) {
  final id = ref.read(identityProvider);
  // ROLE-ROUTING LAW: an onboarded NGO phone must wake up in the command center,
  // not in the civilian shell (identity is already loaded before runApp).
  final home = !(id?.onboarded ?? false)
      ? '/onboarding'
      : (id!.role == 'ngo' ? '/ngo' : '/civilian');
  return GoRouter(
    initialLocation: home,
    routes: [
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/civilian', builder: (_, _) => const CivilianShell()),
      GoRoute(path: '/ngo', builder: (_, _) => const NgoShell()),
    ],
  );
});