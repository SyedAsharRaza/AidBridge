import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/mesh.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import 'civilian_shell.dart' show catIcon, catName;
import 'design_tokens.dart';
import 'strings.dart';

class SosScreen extends ConsumerStatefulWidget {
  const SosScreen({super.key});
  @override
  ConsumerState<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends ConsumerState<SosScreen> {
  double _hold = 0; Timer? _holdTimer; bool _fired = false;
  static const _holdMs = 1200; // press-and-hold LAW: no accidental disaster sirens

  @override
  void dispose() {
    // A periodic timer that outlives its State calls setState() on every tick forever.
    _holdTimer?.cancel();
    super.dispose();
  }

  void _startHold() {
    _fired = false;
    _holdTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      if (_fired) return;
      final next = _hold + 40 / _holdMs;
      if (next < 1) { setState(() => _hold = next); return; }
      _fired = true;
      t.cancel();
      setState(() => _hold = 0);
      HapticFeedback.heavyImpact();
      _pickCategory(); // pushing a route from INSIDE setState worked by luck, not by design
    });
  }
  void _endHold() { _holdTimer?.cancel(); if (!_fired) setState(() => _hold = 0); }

  void _pickCategory() {
    final s = ref.read(stringsProvider);
    final note = TextEditingController();
    showModalBottomSheet(context: context, backgroundColor: AC.surface, showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: note, maxLength: kMaxTextLen, maxLines: 2,
              decoration: InputDecoration(labelText: s.noteOpt)),
          const SizedBox(height: 12),
          _catTile(ctx, s, SosCategory.medical, note), _catTile(ctx, s, SosCategory.waterFood, note),
          _catTile(ctx, s, SosCategory.rescue, note), _catTile(ctx, s, SosCategory.custom, note),
        ]),
      ),
    ).whenComplete(note.dispose); // one controller per attempt — do not leak it
  }

  Widget _catTile(BuildContext ctx, S s, SosCategory c, TextEditingController note) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SizedBox(height: kMinTarget,
      child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border),
              alignment: AlignmentDirectional.centerStart),
          onPressed: () async {
            // Read the note and the messenger BEFORE the sheet route goes away.
            final text = note.text.trim();
            final messenger = ScaffoldMessenger.of(ctx);
            Navigator.of(ctx).pop();
            final refused = await ref.read(meshProvider.notifier).fireSos(category: c, text: text);
            // A refusal used to be logged and swallowed: the user held for over a second,
            // chose a category, and NOTHING happened anywhere they could see it.
            if (refused != null) {
              messenger.showSnackBar(SnackBar(content: Text(_refusalText(s, refused))));
            }
          },
          icon: Text(catIcon(c), style: const TextStyle(fontSize: 24)),
          label: Text(catName(s, c), style: const TextStyle(color: AC.text, fontSize: 17, fontWeight: FontWeight.w700)),
    ),
  ),
  );

  String _refusalText(S s, SosRefusal r) => switch (r) {
    SosRefusal.notReady => s.sosNotReady,
    SosRefusal.busy => s.sosBusy,
    SosRefusal.cooldown => s.sosCooldown,
    SosRefusal.alreadyActive => s.sosAlreadyActive,
  };

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider);
    final ctrl = ref.read(meshProvider.notifier);
    final mySos = _ownActiveSos(ctrl);
    final status = mySos == null ? null : ctrl.engine.statusOf(mySos, DateTime.now().toUtc());

    return Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // STATUS STRIP — never color alone: icon + text + number
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12), border: Border.all(color: AC.border)),
        child: Row(children: [
          Icon(m.transportUp ? Icons.cell_tower : Icons.portable_wifi_off,
              color: m.transportUp ? AC.safe : AC.mute),
          const SizedBox(width: 10),
          Expanded(child: Text(
              !m.transportUp ? s.offline
                  : mySos != null && status == PacketStatus.active
                  ? '${s.broadcasting} ${m.peers} ${s.seenByN}'
                  : '${m.peers} ${s.seenByN} • ONLINE',
              style: const TextStyle(color: AC.text, fontSize: 15))),
        ]),
      ),
      const Spacer(),
      if (m.radioWarning != null) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12),
              border: Border.all(color: AC.primary)),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: AC.primary),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.radiosOffTitle, style: const TextStyle(
                  color: AC.primary, fontWeight: FontWeight.w900, fontSize: 13)),
              Text(m.radioWarning!, style: const TextStyle(color: AC.dim, fontSize: 12)),
            ])),
            TextButton(
              onPressed: () async {
                await ctrl.openRadioSettings();
                await ctrl.refreshRadioWarning();
              },
              child: Text(s.fixIt, style: const TextStyle(
                  color: AC.primary, fontWeight: FontWeight.w900)),
            ),
          ]),
        ),
        const SizedBox(height: 8),
      ],
      centerHolder(s, active: mySos != null && status == PacketStatus.active),
      const Spacer(),
      if (mySos != null && status == PacketStatus.active)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTarget),
              side: const BorderSide(color: AC.safe, width: 2)),
          onPressed: () => ctrl.imSafe(),
          icon: const Icon(Icons.verified_user, color: AC.safe),
          label: Text(s.imSafe, style: const TextStyle(color: AC.safe, fontSize: 16, fontWeight: FontWeight.w800)),
        )
      else
        const SizedBox(height: kMinTarget),
    ]));
  }

  Widget centerHolder(S s, {bool active = false}) {
    if (active) {
      return Center(child: Container(
        width: 188, height: 188,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AC.surface,
            border: Border.all(color: AC.sos, width: 3)),
        alignment: Alignment.center,
        child: const Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_tethering, color: AC.sos, size: 46),
          SizedBox(height: 6),
          Text('SOS ACTIVE', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AC.sos, letterSpacing: 1)),
        ]),
      ));
    }
    return Center(
      child: Listener(
        onPointerDown: (_) => _startHold(),
        onPointerUp: (_) => _endHold(),
        onPointerCancel: (_) => _endHold(),
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(width: 212, height: 212,
              child: CircularProgressIndicator(value: _hold, strokeWidth: 7, color: AC.sos, backgroundColor: AC.border)),
          Container(
            width: 188, height: 188,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AC.sos,
                border: Border.all(color: const Color(0xFFFF6B6B), width: 3)),
            alignment: Alignment.center,
            child: Text(s.holdToFire, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1, color: Colors.white)),
          ),
        ]),
      ),
    );
  }

  /// FIRST-FRAME LAW: build can run before start()'s microtask creates the engine.
  /// Reads the engine's single source of truth — never re-scans the notebook itself.
  AidPacket? _ownActiveSos(MeshController ctrl) =>
      ctrl.engineReady ? ctrl.engine.ownActiveSos() : null;
}