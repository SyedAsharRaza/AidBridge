import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app/mesh.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import '../services/bridge_service.dart';
import 'design_tokens.dart';
import 'strings.dart';

/// One incident row: local notebook OR cloud, merged by packet id.
class IncidentRow {
  final String id; final String name; final String? phone;
  final String category; final String text;
  final double? lat, lng; final int createdAt, hops;
  final PacketStatus status; final bool fromCloud;
  final AidPacket? packet;
  const IncidentRow({required this.id, required this.name, this.phone, required this.category,
    required this.text, this.lat, this.lng, required this.createdAt, required this.hops,
    required this.status, required this.fromCloud, this.packet});
}

IncidentRow _fromPacket(AidPacket p, PacketStatus st) => IncidentRow(
    id: p.id, name: p.senderName, phone: p.phone,
    category: p.category?.name ?? 'custom', text: p.text, lat: p.lat, lng: p.lng,
    createdAt: p.createdAt, hops: p.hops, status: st, fromCloud: false, packet: p);

IncidentRow _fromDoc(DocumentSnapshot d) {
  final m = d.data() as Map<String, Object?>;
  final st = m['status'] == 'resolved' ? PacketStatus.resolved : PacketStatus.active;
  return IncidentRow(id: '${m['id'] ?? d.id}', name: '${m['senderName'] ?? 'Unknown'}',
      phone: m['phone'] as String?, category: '${m['category'] ?? 'custom'}',
      text: '${m['text'] ?? ''}',
      lat: m['lat'] == null ? null : num.tryParse('${m['lat']}')?.toDouble(),
      lng: m['lng'] == null ? null : num.tryParse('${m['lng']}')?.toDouble(),
      createdAt: num.tryParse('${m['createdAt']}')?.toInt() ?? 0,
      hops: num.tryParse('${m['hops']}')?.toInt() ?? 0, status: st, fromCloud: true);
}

/// Live global feed straight from Firestore (empty when bridge/Firebase offline).
final cloudIncidentsProvider = StreamProvider<List<IncidentRow>>((ref) {
  if (!ref.watch(bridgeProvider).ready) return Stream.value(const <IncidentRow>[]);
  return FirebaseFirestore.instance.collection('sos')
      .orderBy('createdAt', descending: true).snapshots()
      .map((qs) => qs.docs.map(_fromDoc).toList());
});

class NgoShell extends ConsumerStatefulWidget {
  const NgoShell({super.key});
  @override
  ConsumerState<NgoShell> createState() => _NgoShellState();
}

class _NgoShellState extends ConsumerState<NgoShell> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    Future.microtask(() async { // NGO phone also runs the mesh (offline truth + bridge duties)
      if (!ref.read(meshProvider).transportUp) await ref.read(meshProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(meshProvider);
    final ctrl = ref.read(meshProvider.notifier);
    final cloud = ref.watch(cloudIncidentsProvider).value ?? const <IncidentRow>[];

    // MERGE by id: local notebook (offline truth) + cloud (global truth). Prefer cloud fields,
    // but engine's cancel law wins on status; 48h -> expired everywhere.
    final now = DateTime.now().toUtc();
    final merged = <String, IncidentRow>{};
    for (final p in ctrl.engine.notebook.where((p) => p.type == PacketType.sos)) {
      merged[p.id] = _fromPacket(p, _status(ctrl, p, now));
    }
    for (final r in cloud) {
      final local = merged[r.id];
      final status = (local?.status == PacketStatus.resolved || r.status == PacketStatus.resolved)
          ? PacketStatus.resolved
          : _expired(r.createdAt, now) ? PacketStatus.expired : PacketStatus.active;
      merged[r.id] = IncidentRow(id: r.id, name: r.name, phone: r.phone ?? local?.phone,
          category: r.category, text: r.text.isNotEmpty ? r.text : (local?.text ?? ''),
          lat: r.lat ?? local?.lat, lng: r.lng ?? local?.lng, createdAt: r.createdAt,
          hops: r.hops, status: status, fromCloud: true);
    }
    final incidents = merged.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('AIDBRIDGE COMMAND'),
        actions: [TextButton(
            onPressed: () async { // role = view swap only; mesh keeps breathing (no 8009 dance)
              await ref.read(identityProvider.notifier).setRole('civilian');
              if (context.mounted) context.go('/civilian');
            },
            child: const Text('CIVILIAN VIEW', style: TextStyle(color: AC.primary))),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(text: 'INCIDENTS', icon: Icon(Icons.crisis_alert)),
          Tab(text: 'MAP', icon: Icon(Icons.map)),
          Tab(text: 'BRIDGE', icon: Icon(Icons.settings_input_antenna)),
        ]),
      ),
      body: TabBarView(controller: _tabs, children: [
        _IncidentsTab(incidents: incidents),
        _MapTab(incidents: incidents),
        _BridgeTab(mesh: m, bridge: ref.watch(bridgeProvider)),
      ]),
    );
  }

  PacketStatus _status(MeshController ctrl, AidPacket p, DateTime now) =>
      ctrl.engine.statusOf(p, now);
  bool _expired(int epochSec, DateTime now) => epochSec > 0 &&
      now.difference(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true)) > kPacketLifetime;
}

// ---------- TAB 1: INCIDENTS ----------
class _IncidentsTab extends ConsumerWidget {
  final List<IncidentRow> incidents;
  const _IncidentsTab({required this.incidents});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (incidents.isEmpty) {
      return const Center(child: Text('No incidents in sight.\n(connect victims via mesh or internet)',
          textAlign: TextAlign.center, style: TextStyle(color: AC.dim)));
    }
    final active = incidents.where((r) => r.status == PacketStatus.active).length;
    return Column(children: [
      Container(width: double.infinity, color: AC.surface,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          child: Text('⚠ $active ACTIVE   •   ${incidents.length} total   •   ☁ live Firestore feed ⋯ local notebook merged',
              style: const TextStyle(color: AC.dim, fontSize: 12))),
      Expanded(child: ListView.separated(
        padding: const EdgeInsets.all(10), itemCount: incidents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (ctx, i) {
          final r = incidents[i];
          final color = r.status == PacketStatus.active ? AC.sos
              : (r.status == PacketStatus.resolved ? AC.safe : AC.mute);
          return InkWell(
            onTap: () => showIncidentSheet(ctx, r),
            borderRadius: BorderRadius.circular(AR.r12),
            child: Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12),
                  border: Border.all(color: AC.border)),
              child: Row(children: [
                Text(catIcon(r.category), style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.name, style: const TextStyle(color: AC.text, fontWeight: FontWeight.w800, fontSize: 16)),
                  Text('${timeAgo(r.createdAt)} • via ${r.hops} • ${r.fromCloud ? "☁ cloud" : "📻 local"}${r.lat != null ? " • 📍" : ""}',
                      style: const TextStyle(color: AC.dim, fontSize: 12)),
                ])),
                statusChip(r.status),
              ]),
            ),
          );
        },
      )),
    ]);
  }
}

// ---------- TAB 2: COMMAND MAP ----------
class _MapTab extends StatelessWidget {
  final List<IncidentRow> incidents;
  const _MapTab({required this.incidents});
  @override
  Widget build(BuildContext context) {
    final withCoords = incidents.where((r) => r.lat != null && r.lng != null).toList();
    final center = withCoords.isNotEmpty
        ? LatLng(withCoords.first.lat!, withCoords.first.lng!)
        : const LatLng(24.8607, 67.0011); // Karachi fallback — grid center, not magic
    return Stack(children: [
      FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 11),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.aidbridge.aidbridge'),
          MarkerLayer(markers: [for (final r in withCoords) _pin(r)]),
        ],
      ),
      Positioned(top: 10, left: 10, right: 10, child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r8),
            border: Border.all(color: AC.border)),
        child: Text('📍 ${withCoords.length} located incidents  •  tiles: OpenStreetMap (needs internet)',
            style: const TextStyle(color: AC.dim, fontSize: 12), textAlign: TextAlign.center),
      )),
    ]);
  }

  Marker _pin(IncidentRow r) => Marker(
    point: LatLng(r.lat!, r.lng!), width: 130, height: 62,
    child: Builder(builder: (ctx) => GestureDetector(
      onTap: () => showIncidentSheet(ctx, r), // MAP INTERACTION LAW: pin -> bottom sheet
      child: Column(children: [
        Icon(Icons.location_pin, size: 34,
            color: r.status == PacketStatus.active ? AC.sos
                : (r.status == PacketStatus.resolved ? AC.safe : AC.mute)),
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AC.border)),
            child: Text(r.name, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AC.text, fontSize: 11, fontWeight: FontWeight.w700))),
      ]),
    )),
  );
}

// ---------- TAB 3: BRIDGE ----------
class _BridgeTab extends StatelessWidget {
  final MeshState mesh; final BridgeService bridge;
  const _BridgeTab({required this.mesh, required this.bridge});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    _row('BRIDGE', bridge.ready ? 'READY — uplinks on sight' : bridge.status, bridge.ready ? AC.safe : AC.mute),
    _row('MESH', mesh.transportUp ? 'ONLINE' : 'OFFLINE', mesh.transportUp ? AC.safe : AC.mute),
    _row('PEERS CONNECTED', '${mesh.peers}', AC.text),
    _row('NOTEBOOK CARRIED', '${mesh.notebookCount} letters', AC.text),
    _row('DEDUP MEMORY', '${mesh.seenCount}', AC.text),
    const SizedBox(height: 10),
    const Text('Any phone with internet becomes a bridge: SOS letters ride the mesh to it, '
        'then teleport to this cloud. Chat never leaves the mesh (privacy partition).',
        style: TextStyle(color: AC.dim, fontSize: 13)),
  ]);

  Widget _row(String k, String v, Color c) => Container(
    margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12),
        border: Border.all(color: AC.border)),
    child: Row(children: [
      Expanded(child: Text(k, style: const TextStyle(color: AC.dim, fontWeight: FontWeight.w700))),
      Text(v, style: TextStyle(color: c, fontWeight: FontWeight.w800)),
    ]),
  );
}

// ---------- INCIDENT SHEET (pin tap / row tap — one law, two doors) ----------
void showIncidentSheet(BuildContext ctx, IncidentRow r) {
  final color = r.status == PacketStatus.active ? AC.sos
      : (r.status == PacketStatus.resolved ? AC.safe : AC.mute);
  showModalBottomSheet(context: ctx, backgroundColor: AC.surface, showDragHandle: true,
    builder: (sctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(catIcon(r.category), style: const TextStyle(fontSize: 36)), const SizedBox(width: 10),
          Expanded(child: Text(r.name, style: const TextStyle(color: AC.text, fontSize: 20, fontWeight: FontWeight.w900))),
          statusChip(r.status),
        ]),
        const SizedBox(height: 6),
        Text('${catName(r.category)} • ${timeAgo(r.createdAt)} • via ${r.hops} phones • ${r.fromCloud ? "cloud ☁" : "local mesh 📻"}',
            style: const TextStyle(color: AC.dim)),
        if (r.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text('“${r.text}”', style: const TextStyle(color: AC.text, fontStyle: FontStyle.italic))),
        if (r.lat != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.border), minimumSize: const Size.fromHeight(44)),
              onPressed: () { Clipboard.setData(ClipboardData(text: '${r.lat}, ${r.lng}'));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Coordinates copied'))); },
              icon: const Icon(Icons.copy, color: AC.primary),
              label: Text('📍 ${r.lat!.toStringAsFixed(5)}, ${r.lng!.toStringAsFixed(5)}', style: const TextStyle(color: AC.text)),
            )),
        if (r.phone != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AC.safe),
              onPressed: () => launchUrl(Uri.parse('tel:${r.phone}')),
              icon: const Icon(Icons.call, color: Colors.black),
              label: Text('CALL ${r.phone}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900)),
            )),
      ]),
    ),
  );
}

Widget statusChip(PacketStatus st) {
  final color = st == PacketStatus.active ? AC.sos : (st == PacketStatus.resolved ? AC.safe : AC.mute);
  final label = st == PacketStatus.active ? 'ACTIVE' : (st == PacketStatus.resolved ? 'SAFE' : 'EXPIRED');
  final icon = st == PacketStatus.active ? Icons.campaign : Icons.check_circle;
  return Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AR.r8), border: Border.all(color: color)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 14), const SizedBox(width: 5),
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 12)),
    ]),
  );
}

String catIcon(String c) => switch (c) {
  'medical' => '🏥', 'waterFood' => '💧', 'rescue' => '🆘', 'custom' => '✏️', _ => '🆘' };
String catName(String c) => switch (c) {
  'medical' => 'Medical', 'waterFood' => 'Water/Food', 'rescue' => 'Rescue', 'custom' => 'Other', _ => 'Other' };