import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/mesh.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import 'civilian_shell.dart';
import 'design_tokens.dart';
import 'strings.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider); // any mesh change re-reads the notebook (pragmatic v1)
    final ctrl = ref.read(meshProvider.notifier);
    // FIRST-FRAME LAW: no engine yet => there is genuinely nothing to read.
    // But NOT gated on transportUp: the notebook is LOCAL data. Hiding it whenever the radios
    // were down meant RESTART MESH — or one denied permission — blanked every SOS this phone
    // had already received, at exactly the moment someone needs to re-read a name or a number.
    if (!ctrl.engineReady) {
      return Center(child: Text(s.offline, style: const TextStyle(color: AC.dim)));
    }
    final sosList = ctrl.engine.notebook.where((p) => p.type == PacketType.sos).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (sosList.isEmpty) return Center(child: Text(s.noAlerts, style: const TextStyle(color: AC.dim)));

    return Column(children: [
      // The letters stay readable while the mesh is down — but say so, or a stale list looks live.
      if (!m.transportUp)
        Container(
          width: double.infinity, color: AC.surface,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          child: Text(s.offline, textAlign: TextAlign.center,
              style: const TextStyle(color: AC.mute, fontSize: 12)),
        ),
      Expanded(child: ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: sosList.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final p = sosList[i];
        final st = ctrl.engine.statusOf(p, DateTime.now().toUtc());
        final color = st == PacketStatus.active ? AC.sos : (st == PacketStatus.resolved ? AC.safe : AC.mute);
        final label = st == PacketStatus.active ? s.active : (st == PacketStatus.resolved ? s.resolved : s.expired);
        return InkWell(
          onTap: () => _detail(ctx, ref, s, p, label, color),
          borderRadius: BorderRadius.circular(AR.r12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12), border: Border.all(color: AC.border)),
            child: Row(children: [
              Text(catIcon(p.category), style: const TextStyle(fontSize: 34)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.senderName, style: const TextStyle(color: AC.text, fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text('${s.viaPhones} ${p.hops} ${s.seenByN}  •  ${timeAgo(p.createdAt, ur: s.isRtl)}',
                    style: const TextStyle(color: AC.dim, fontSize: 13)),
                if (p.phone != null) Text('☎ ${p.phone}', style: const TextStyle(color: AC.primary, fontSize: 13)),
              ])),
              Container( // STATUS — icon+text+color, never color alone (design LAW)
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AR.r8), border: Border.all(color: color)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(st == PacketStatus.active ? Icons.campaign : Icons.check_circle, color: color, size: 14),
                  const SizedBox(width: 5),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
                ]),
              ),
            ]),
          ),
        );
      },
      )),
    ]);
  }

  void _detail(BuildContext ctx, WidgetRef ref, S s, AidPacket p, String label, Color color) {
    showModalBottomSheet(context: ctx, backgroundColor: AC.surface, showDragHandle: true,
      builder: (bctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Text(catIcon(p.category), style: const TextStyle(fontSize: 40)), const SizedBox(width: 12),
            Expanded(child: Text(p.senderName, style: const TextStyle(color: AC.text, fontSize: 22, fontWeight: FontWeight.w900))),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w900))]),
          const SizedBox(height: 10),
          Text(catName(s, p.category), style: const TextStyle(color: AC.dim)),
          if (p.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
              child: Text('“${p.text}”', style: const TextStyle(color: AC.text, fontStyle: FontStyle.italic))),
          const SizedBox(height: 10),
          Text('${s.viaPhones} ${p.hops} ${s.seenByN} • ${timeAgo(p.createdAt, ur: s.isRtl)}', style: const TextStyle(color: AC.dim)),
          if (p.lat != null) Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(44)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '${p.lat}, ${p.lng}'));
                  Navigator.of(bctx).pop();
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Coordinates copied')));
                },
                icon: const Icon(Icons.copy, color: AC.primary),
                label: Text('📍 ${p.lat!.toStringAsFixed(5)}, ${p.lng!.toStringAsFixed(5)}', style: const TextStyle(color: AC.text)),
              )),
          if (p.phone != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AC.safe),
                onPressed: () => dialPhone(ctx, p.phone!),
                icon: const Icon(Icons.call, color: Colors.black),
                label: Text(p.phone!, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 17)),
              )),
        ]),
      ),
    );
  }
}