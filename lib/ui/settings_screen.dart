import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app/mesh.dart';
import 'design_tokens.dart';
import 'strings.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController(); final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    final id = ref.read(identityProvider);
    _name.text = id?.name ?? ''; _phone.text = id?.phone ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider);
    final id = ref.watch(identityProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _name, maxLength: 20, decoration: InputDecoration(labelText: s.callSign)),
      const SizedBox(height: 8),
      TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: s.phoneOpt)),
      const SizedBox(height: 8),
      FilledButton(onPressed: () async {
        await ref.read(identityProvider.notifier).setName(_name.text);
        await ref.read(identityProvider.notifier).setPhone(_phone.text);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.save + ' ✓')));
      }, child: Text(s.save)),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12), border: Border.all(color: AC.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.meshStatus, style: const TextStyle(color: AC.dim, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('⚡ ${m.transportUp ? "ONLINE" : "OFFLINE"}   •   PEERS ${m.peers}   •   SEEN ${m.seenCount}   •   NOTEBOOK ${m.notebookCount}',
              style: const TextStyle(color: AC.text)),
          const SizedBox(height: 4),
          Text('radio ID: ${id?.selfId ?? "—"}', style: const TextStyle(color: AC.mute, fontSize: 12)),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Text('${s.role}: ', style: const TextStyle(color: AC.dim)),
        const SizedBox(width: 8),
        Expanded(child: DropdownButtonFormField<String>(
          value: id?.role ?? 'civilian',
          decoration: const InputDecoration(),
          items: [DropdownMenuItem(value: 'civilian', child: Text(s.civilian)),
            DropdownMenuItem(value: 'ngo', child: Text(s.ngo))],
          onChanged: (v) async {
            if (v == null || v == id?.role) return;
            // LAW: role change = FULL STOP, swap identity, restart, re-route (8009 armor)
            await ref.read(meshProvider.notifier).stop();
            await ref.read(identityProvider.notifier).setRole(v);
            if (mounted) context.go(v == 'ngo' ? '/ngo' : '/civilian');
          },
        )),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Text('${s.language}: ', style: const TextStyle(color: AC.dim)),
        const SizedBox(width: 8),
        Expanded(child: DropdownButtonFormField<AppLang>(
          value: ref.watch(localeProvider),
          items: const [DropdownMenuItem(value: AppLang.en, child: Text('English')),
            DropdownMenuItem(value: AppLang.ur, child: Text('اردو'))],
          onChanged: (v) { if (v != null) ref.read(localeProvider.notifier).set(v); },
        )),
      ]),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(kMinTarget)),
        onPressed: () => ref.read(meshProvider.notifier).sirenTest(),
        icon: const Icon(Icons.volume_up, color: AC.primary),
        label: Text(s.sirenTest, style: const TextStyle(color: AC.text)),
      ),
    ]);
  }
}