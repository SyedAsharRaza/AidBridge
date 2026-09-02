import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
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
  bool _alertOpen = false; // ONE takeover for a whole burst — it re-renders per queued victim
  bool _takeoverPending = false; // scheduled for the next frame, not yet shown
  BuildContext? _alertCtx;  // the takeover's own route context, so a remote resolve can close it

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
    // ONE dialog serves the whole queue: it re-renders itself for each victim in turn, so
    // we neither stack modals on a panicking user nor silently drop the second alarm.
    final hasAlert = ref.watch(meshProvider.select((m) => m.alertQueue.isNotEmpty));
    // _takeoverPending, not _alertOpen, is the schedule gate: _alertOpen is only set when the
    // callback RUNS, so two builds inside one frame used to queue two dialogs. The second
    // one's context overwrote _alertCtx, and closing the takeover then popped the wrong
    // route — leaving a screaming screen with a dead button on top of a silenced mesh.
    if (hasAlert && !_alertOpen && !_takeoverPending) {
      _takeoverPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showTakeover());
    }
    // The queue emptied (last one acknowledged, or every sender resolved remotely).
    // showDialog is imperative — clearing state does NOT close it — so the screaming
    // screen would stay up over a resolved emergency until someone tapped it.
    if (!hasAlert && _alertOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeTakeover());
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

  /// Closes the takeover from OUTSIDE (queue emptied). Pops the dialog's own route
  /// rather than the top of the stack, so we can never pop a screen we did not open.
  void _closeTakeover() {
    final ctx = _alertCtx;
    if (!_alertOpen || ctx == null || !ctx.mounted) return;
    Navigator.of(ctx).pop();
  }

  void _showTakeover() {
    _takeoverPending = false;
    // The queue can empty between the build that asked for this and the frame that runs it —
    // and the shell can be gone entirely (role switch, hot reload) by then.
    if (!mounted || _alertOpen || ref.read(meshProvider).alertQueue.isEmpty) return;
    _alertOpen = true;
    try {
      _openTakeover();
    } catch (e) {
      // THE FLAG MUST NEVER LATCH. If it stuck true with no dialog on screen, every later
      // alert would sound the siren with no visible way to stop it and RESTART MESH became
      // the only off switch. Release the flag, and refuse to leave an alarm nobody can end.
      _alertOpen = false;
      _alertCtx = null;
      ref.read(meshProvider.notifier).stopSiren();
      debugPrint('AidBridge: takeover could not open ($e) — siren silenced instead');
    }
  }

  void _openTakeover() {
    showDialog(context: context, barrierDismissible: false, barrierColor: const Color(0xF2120506),
      builder: (ctx) {
        _alertCtx = ctx;
        return Dialog.fullscreen(backgroundColor: Colors.transparent,
          child: Consumer(builder: (c, r, _) {
            final s = r.watch(stringsProvider);
            final q = r.watch(meshProvider.select((m) => m.alertQueue));
            if (q.isEmpty) return const SizedBox.shrink(); // emptied; the pop lands next frame
            final p = q.first;
            final more = q.length - 1;
            return Padding(padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_amber_rounded, color: AC.sos, size: 110),
            const SizedBox(height: 8),
            Text('🆘 ${s.incomingSos}', textAlign: TextAlign.center,
                style: const TextStyle(color: AC.sos, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 1)),
            // Tell the user more people are waiting, so acknowledging never feels like dismissing.
            if (more > 0) Padding(padding: const EdgeInsets.only(top: 6),
                child: Text('1 / ${q.length}',
                    style: const TextStyle(color: AC.primary, fontSize: 16, fontWeight: FontWeight.w800))),
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
              // Acknowledge THIS victim only. If others wait the siren keeps going and the
              // next one renders in place; on the last, the queue empties and we close.
              onPressed: () => r.read(meshProvider.notifier).dismissAlert(p.id),
              child: Text(more > 0 ? '${s.nextAlert} ($more)' : s.stopSiren),
            ),
          ]),
        );
          }),
      );
      },
    ).then((_) {
      _alertOpen = false;
      _alertCtx = null;
      // ONE EXIT PATH: the system back gesture lands here too. If anything is still queued
      // the takeover is gone but the siren would keep screaming with no visible control,
      // so backing out of a burst means silence everything.
      if (ref.read(meshProvider).alertQueue.isNotEmpty) {
        ref.read(meshProvider.notifier).stopSiren();
      }
    });
  }
}

String catIcon(SosCategory? c) => switch (c) {
  SosCategory.medical => '🏥', SosCategory.waterFood => '💧',
  SosCategory.rescue => '🆘', SosCategory.custom => '✏️', _ => '🆘' };
String catName(S s, SosCategory? c) => switch (c) {
  SosCategory.medical => s.catMedical, SosCategory.waterFood => s.catWater,
  SosCategory.rescue => s.catRescue, SosCategory.custom => s.catCustom, _ => s.catRescue };

/// CALL is the most consequential button in the app. launchUrl THROWS when nothing can
/// handle tel: (tablets, stripped ROMs) and that used to be an unhandled async error: the
/// rescuer tapped, nothing happened, and nothing explained why. Fail out loud, and always
/// keep the number on screen so it can still be dialled by hand.
Future<void> dialPhone(BuildContext context, String phone) async {
  final messenger = ScaffoldMessenger.of(context); // captured BEFORE the await
  try {
    if (await launchUrl(Uri.parse('tel:$phone'))) return;
    messenger.showSnackBar(SnackBar(content: Text('No dialer on this device — number: $phone')));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open the dialer — number: $phone')));
  }
}