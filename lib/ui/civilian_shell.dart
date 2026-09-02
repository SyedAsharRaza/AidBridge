import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/mesh.dart';
import '../protocol/packet.dart';
import 'alerts_screen.dart';
import 'design_tokens.dart';
import 'settings_screen.dart';
import 'sos_screen.dart';
import 'strings.dart';

class CivilianShell extends ConsumerStatefulWidget {
  const CivilianShell({super.key});
  @override
  ConsumerState<CivilianShell> createState() => _CivilianShellState();
}

class _CivilianShellState extends ConsumerState<CivilianShell> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  String? _shownAlertId;
  bool _alertOpen = false; // one takeover at a time — never stack dialogs on a burst

  @override
  void initState() {
    super.initState();
    Future.microtask(() async { // mesh auto-breaths after onboarding; identity persisted => no re-onboarding (go_router law)
      if (!ref.read(meshProvider).transportUp) await ref.read(meshProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final alert = ref.watch(meshProvider.select((m) => m.alertPacket));
    if (alert != null && alert.id != _shownAlertId && !_alertOpen) {
      _shownAlertId = alert.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showTakeover(alert));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('AIDBRIDGE'),
        bottom: TabBar(controller: _tabs, tabs: [
          Tab(text: s.tabSos, icon: const Icon(Icons.campaign)),
          Tab(text: s.tabAlerts, icon: const Icon(Icons.notifications_active)),
          Tab(text: s.tabSettings, icon: const Icon(Icons.settings_suggest)),
        ]),
      ),
      body: TabBarView(controller: _tabs, children: const [SosScreen(), AlertsScreen(), SettingsScreen()]),
    );
  }

  void _showTakeover(AidPacket p) {
    final s = ref.read(stringsProvider);
    _alertOpen = true;
    showDialog(context: context, barrierDismissible: false, barrierColor: const Color(0xF2120506),
      builder: (ctx) => Dialog.fullscreen(backgroundColor: Colors.transparent,
        child: Padding(padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_amber_rounded, color: AC.sos, size: 110),
            const SizedBox(height: 8),
            Text('🆘 ${s.incomingSos}', textAlign: TextAlign.center,
                style: const TextStyle(color: AC.sos, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 1)),
            const SizedBox(height: 14),
            Text(p.senderName, style: const TextStyle(color: AC.text, fontSize: 24, fontWeight: FontWeight.w700)),
            Text('${catIcon(p.category)} ${catName(s, p.category)}  •  ${s.viaPhones} ${p.hops} ${s.seenByN}',
                style: const TextStyle(color: AC.dim, fontSize: 16)),
            if (p.text.isNotEmpty) ...[const SizedBox(height: 8),
              Text('“${p.text}”', style: const TextStyle(color: AC.dim, fontStyle: FontStyle.italic))],
            if (p.lat != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text('📍 ${p.lat!.toStringAsFixed(5)}, ${p.lng!.toStringAsFixed(5)}',
                    style: const TextStyle(color: AC.dim))),
            if (p.phone != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text('☎ ${p.phone}', style: const TextStyle(color: AC.primary, fontSize: 18))),
            const SizedBox(height: 28),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AC.primary),
              onPressed: () => Navigator.of(ctx).pop(), // silencing happens on the ONE exit path below
              child: Text(s.stopSiren),
            ),
          ]),
        ),
      ),
    ).then((_) {
      _alertOpen = false;
      // ONE EXIT PATH: the button AND the system back gesture both land here, so a
      // back-swipe can never leave the siren screaming with no way to silence it.
      // stopSiren() also clears alertPacket, which is what stops the takeover from
      // re-opening on the next rebuild. (_shownAlertId is deliberately NOT reset:
      // one takeover per packet id, forever.)
      ref.read(meshProvider.notifier).stopSiren();
    });
  }
}

String catIcon(SosCategory? c) => switch (c) {
  SosCategory.medical => '🏥', SosCategory.waterFood => '💧',
  SosCategory.rescue => '🆘', SosCategory.custom => '✏️', _ => '🆘' };
String catName(S s, SosCategory? c) => switch (c) {
  SosCategory.medical => s.catMedical, SosCategory.waterFood => s.catWater,
  SosCategory.rescue => s.catRescue, SosCategory.custom => s.catCustom, _ => s.catRescue };