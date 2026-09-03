import 'package:aidbridge/ui/ngo_change_password.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app/mesh.dart';
import 'design_tokens.dart';
import 'strings.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  final bool showIdentityFields;
  const SettingsScreen({super.key, this.showIdentityFields = true});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController(); final _phone = TextEditingController();
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    final id = ref.read(identityProvider);
    _name.text = id?.name ?? ''; _phone.text = id?.phone ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider);
    final id = ref.watch(identityProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (widget.showIdentityFields) ...[
        TextField(controller: _name, maxLength: 20, decoration: InputDecoration(labelText: s.callSign)),
        const SizedBox(height: 8),
        TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: s.phoneOpt)),
        const SizedBox(height: 8),
        FilledButton(onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          if (_name.text.trim().isEmpty) {
            messenger.showSnackBar(SnackBar(content: Text(s.nameRequired)));
            return;
          }
          try {
            await ref.read(identityProvider.notifier).setName(_name.text.trim());
            await ref.read(identityProvider.notifier).setPhone(_phone.text.trim());
            messenger.showSnackBar(SnackBar(content: Text('${s.save} ✓')));
          } catch (_) {
            messenger.showSnackBar(SnackBar(content: Text(s.saveFailed)));
          }
        }, child: Text(s.save)),
        const SizedBox(height: 18),
      ],
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12), border: Border.all(color: AC.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.meshStatus, style: const TextStyle(color: AC.dim, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(s.meshStatusLine(m.transportUp, m.peers, m.seenCount, m.notebookCount),
              style: const TextStyle(color: AC.text)),
          const SizedBox(height: 4),
          Text('radio ID: ${id?.selfId ?? "—"}', style: const TextStyle(color: AC.mute, fontSize: 12)),
        ]),
      ),
      Text('${s.role}: ${id?.role == 'ngo' ? s.ngo : s.civilian}',
        style: const TextStyle(color: AC.dim)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(kMinTarget)),
        onPressed: () => GoRouter.of(context).go('/how-it-works/${id?.role ?? 'civilian'}'),
        icon: const Icon(Icons.help_outline, color: AC.primary),
        label: Text(s.howItWorksLink, style: const TextStyle(color: AC.text)),
      ),
      const SizedBox(height: 12),
      if (m.radioWarning != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12),
              border: Border.all(color: AC.primary)),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: AC.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(m.radioWarning!, style: const TextStyle(color: AC.dim, fontSize: 12))),
            TextButton(
              onPressed: () async {
                await ref.read(meshProvider.notifier).openRadioSettings();
                await ref.read(meshProvider.notifier).refreshRadioWarning();
              },
              child: Text(s.fixIt, style: const TextStyle(color: AC.primary, fontWeight: FontWeight.w900)),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(kMinTarget)),
        onPressed: () => ref.read(meshProvider.notifier).sirenTest(),
        icon: const Icon(Icons.volume_up, color: AC.primary),
        label: Text(s.sirenTest, style: const TextStyle(color: AC.text)),
      ),
      const SizedBox(height: 12),
      // DEMO LIFELINE: recycles radios + native state without losing the notebook.
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.primary), minimumSize: const Size.fromHeight(kMinTarget)),
        onPressed: _restarting ? null : () async {
          setState(() => _restarting = true);
          await ref.read(meshProvider.notifier).restart();
          if (mounted) setState(() => _restarting = false);
        },
        icon: _restarting
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AC.primary))
            : const Icon(Icons.refresh, color: AC.primary),
        label: Text(_restarting ? s.restartingMesh : s.restartMesh,
            style: const TextStyle(color: AC.text, fontWeight: FontWeight.w800)),
      ),
      const SizedBox(height: 12),
      // REHEARSAL RESET: wipes local state between demo runs so every run starts clean.
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(kMinTarget)),
        onPressed: () => _confirmClear(s),
        icon: const Icon(Icons.delete_sweep, color: AC.mute),
        label: Text(s.clearNotebook, style: const TextStyle(color: AC.text)),
      ),
    ]);
  }

  /// Destructive and irreversible — never one stray tap away.
  Future<void> _confirmClear(S s) async {
    final messenger = ScaffoldMessenger.of(context); // captured BEFORE the await gap
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AC.surface,
        title: Text(s.clearNotebook, style: const TextStyle(color: AC.text)),
        content: Text(s.clearNotebookQ, style: const TextStyle(color: AC.dim)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.cancel, style: const TextStyle(color: AC.dim))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(s.erase, style: const TextStyle(color: AC.sos, fontWeight: FontWeight.w900))),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(meshProvider.notifier).clearNotebook();
    messenger.showSnackBar(SnackBar(content: Text(s.notebookCleared)));
  }
}