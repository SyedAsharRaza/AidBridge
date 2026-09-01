import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/mesh.dart';
import 'app/router.dart';
import 'ui/design_tokens.dart';
import 'ui/strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  await container.read(identityProvider.notifier).load(); // identity BEFORE routes: no auth flapping
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