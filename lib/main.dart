import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/mesh.dart';
import 'app/router.dart';
import 'ui/design_tokens.dart';
import 'ui/strings.dart';
import 'package:firebase_core/firebase_core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(); 
  final container = ProviderContainer();
  await container.read(identityProvider.notifier).load(); // identity BEFORE routes: no auth flapping
  await container.read(bridgeProvider).init();                                          // NEW
  container.read(bridgeReadyProvider.notifier).state = container.read(bridgeProvider).ready;
  runApp(UncontrolledProviderScope(container: container, child: const AidBridgeApp()));
}

class AidBridgeApp extends ConsumerWidget {
  const AidBridgeApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final router = ref.watch(routerProvider);
    return Directionality( // RTL LAW: built-in Directionality only — never custom layouts
      textDirection: s.isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: MaterialApp.router(
        title: 'AidBridge',
        debugShowCheckedModeBanner: false,
        theme: buildAidBridgeTheme(),
        routerConfig: router,
        // The in-app language picker must reach Material's OWN widgets too, or a user reading
        // Urdu still gets English date pickers, dialog buttons and semantics labels.
        locale: Locale(s.isRtl ? 'ur' : 'en'),
        supportedLocales: const [Locale('en'), Locale('ur')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}