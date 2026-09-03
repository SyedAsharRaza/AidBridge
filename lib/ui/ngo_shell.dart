/*
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: unused_import
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import '../app/mesh.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import 'civilian_shell.dart' show dialPhone;
import 'design_tokens.dart';
import 'settings_screen.dart';
import 'strings.dart';
import 'package:geocoding/geocoding.dart' as geocoding;


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

const int kCloudFeedLimit = 200;

final cloudIncidentsProvider = StreamProvider<List<IncidentRow>>((ref) {
  if (!ref.watch(bridgeReadyProvider)) return Stream.value(const <IncidentRow>[]);
  return FirebaseFirestore.instance.collection('sos')
      .orderBy('createdAt', descending: true).limit(kCloudFeedLimit).snapshots()
      .map((qs) {
        final out = <IncidentRow>[];
        for (final d in qs.docs) {
          try { out.add(_fromDoc(d)); } catch (_) {}
        }
        return out;
      });
});

class NgoShell extends ConsumerStatefulWidget {
  const NgoShell({super.key});
  @override
  ConsumerState<NgoShell> createState() => _NgoShellState();
}

class _NgoShellState extends ConsumerState<NgoShell> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!ref.read(meshProvider).transportUp) await ref.read(meshProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider);
    final ctrl = ref.read(meshProvider.notifier);
    final cloudAsync = ref.watch(cloudIncidentsProvider);
    final cloud = cloudAsync.value ?? const <IncidentRow>[];

    final now = DateTime.now().toUtc();
    final merged = <String, IncidentRow>{};
    if (ctrl.engineReady) {
      for (final p in ctrl.engine.notebook.where((p) => p.type == PacketType.sos)) {
        merged[p.id] = _fromPacket(p, _status(ctrl, p, now));
      }
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
        title: Row(children: [
          Text(s.ngoCommandTitle),
          const SizedBox(width: 8),
          Text('• ${ref.watch(identityProvider)?.name ?? ""}',
              style: const TextStyle(fontSize: 13, color: AC.dim, fontWeight: FontWeight.normal)),
        ]),
        bottom: TabBar(controller: _tabs, tabs: [
          Tab(text: s.tabIncidents, icon: const Icon(Icons.crisis_alert)),
          Tab(text: s.tabMap, icon: const Icon(Icons.map)),
          Tab(text: s.tabBridge, icon: const Icon(Icons.settings_input_antenna)),
          Tab(text: s.tabSettings, icon: const Icon(Icons.settings_suggest)),
        ]),
      ),
      body: Column(children: [
        if (m.alertPacket != null) _SirenBar(packet: m.alertPacket!),
        Expanded(child: TabBarView(controller: _tabs, children: [
          _IncidentsTab(incidents: incidents, cloudError: cloudAsync.hasError),
          _MapTab(incidents: incidents),
          _BridgeTab(mesh: m),
          const SettingsScreen(showIdentityFields: false),
        ])),
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
  final bool cloudError;
  const _IncidentsTab({required this.incidents, required this.cloudError});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    if (incidents.isEmpty) {
      return Center(child: Text(s.noIncidents,
          textAlign: TextAlign.center, style: const TextStyle(color: AC.dim)));
    }
    final active = incidents.where((r) => r.status == PacketStatus.active).length;
    return Column(children: [
      Container(width: double.infinity, color: AC.surface,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          child: Text(s.activeSummary(active, incidents.length, cloudError: cloudError),
              style: TextStyle(color: cloudError ? AC.sos : AC.dim, fontSize: 12))),
      Expanded(child: ListView.separated(
        padding: const EdgeInsets.all(10), itemCount: incidents.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (ctx, i) {
          final r = incidents[i];
          final color = r.status == PacketStatus.active ? AC.sos
              : (r.status == PacketStatus.resolved ? AC.safe : AC.mute);
          return InkWell(
            onTap: () => showIncidentSheet(ctx, r, s),
            borderRadius: BorderRadius.circular(AR.r12),
            child: Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r12),
                  border: Border.all(color: color.withValues(alpha: 0.45))),
              child: Row(children: [
                Text(catIcon(r.category), style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.name, style: const TextStyle(color: AC.text, fontWeight: FontWeight.w800, fontSize: 16)),
                  Text('${timeAgo(r.createdAt)} • ${s.viaPhones} ${r.hops} • ${r.fromCloud ? s.cloudSrcShort : s.localSrcShort}${r.lat != null ? " • 📍" : ""}',
                      style: const TextStyle(color: AC.dim, fontSize: 12)),
                ])),
                statusChip(r.status, s),
              ]),
            ),
          );
        },
      )),
    ]);
  }
}

// ---------- TAB 2: COMMAND MAP ----------
class _MapTab extends ConsumerWidget {
  final List<IncidentRow> incidents;
  const _MapTab({required this.incidents});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final withCoords = incidents.where((r) => r.lat != null && r.lng != null).toList();
    final center = withCoords.isNotEmpty
        ? LatLng(withCoords.first.lat!, withCoords.first.lng!)
        : const LatLng(24.8607, 67.0011);
    return Stack(children: [
      FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 11),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.aidbridge.aidbridge'),
          MarkerLayer(markers: [for (final r in withCoords) _pin(r, s)]),
        ],
      ),
      Positioned(top: 10, left: 10, right: 10, child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: AC.surface, borderRadius: BorderRadius.circular(AR.r8),
            border: Border.all(color: AC.border)),
        child: Text(s.locatedIncidents(withCoords.length),
            style: const TextStyle(color: AC.dim, fontSize: 12), textAlign: TextAlign.center),
      )),
    ]);
  }

  Marker _pin(IncidentRow r, S s) => Marker(
    point: LatLng(r.lat!, r.lng!), width: 130, height: 62,
    child: Builder(builder: (ctx) => GestureDetector(
      onTap: () => showIncidentSheet(ctx, r, s),
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
class _BridgeTab extends ConsumerStatefulWidget {
  final MeshState mesh;
  const _BridgeTab({required this.mesh});
  @override
  ConsumerState<_BridgeTab> createState() => _BridgeTabState();
}

class _BridgeTabState extends ConsumerState<_BridgeTab> {
  bool _clearing = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final ready = ref.watch(bridgeReadyProvider);
    final bridge = ref.read(bridgeProvider);
    final mesh = widget.mesh;
    return ListView(padding: const EdgeInsets.all(16), children: [
    _row(s.bridgeReadyLabel, ready ? s.bridgeReadyStatus : bridge.status, ready ? AC.safe : AC.mute),
    _row(s.meshLabel, mesh.transportUp ? s.onlineLabel : s.offlineLabel, mesh.transportUp ? AC.safe : AC.mute),
    _row(s.peersConnected, '${mesh.peers}', AC.text),
    _row(s.notebookCarriedLabel, s.notebookLetters(mesh.notebookCount), AC.text),
    _row(s.dedupMemoryLabel, '${mesh.seenCount}', AC.text),
        const SizedBox(height: 10),
    Text(s.bridgeExplain, style: const TextStyle(color: AC.dim, fontSize: 13)),
    const SizedBox(height: 18),
    // NGO DASHBOARD RESET: wipes cloud + this phone's notebook. Never one stray tap away.
    OutlinedButton.icon(
      style: OutlinedButton.styleFrom(side: const BorderSide(color: AC.sos), minimumSize: const Size.fromHeight(kMinTarget)),
      onPressed: (!ready || _clearing) ? null : () => _confirmClearAll(s),
      icon: _clearing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AC.sos))
          : const Icon(Icons.delete_forever, color: AC.sos),
      label: Text(s.clearAllIncidents, style: const TextStyle(color: AC.sos, fontWeight: FontWeight.w900)),
    ),
  ]);
  }

  Future<void> _confirmClearAll(S s) async {
    final messenger = ScaffoldMessenger.of(context); // captured BEFORE the await gap
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AC.surface,
        title: Text(s.clearAllIncidents, style: const TextStyle(color: AC.text)),
        content: Text(s.clearAllIncidentsQ, style: const TextStyle(color: AC.dim)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.cancel, style: const TextStyle(color: AC.dim))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(s.erase, style: const TextStyle(color: AC.sos, fontWeight: FontWeight.w900))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _clearing = true);
    try {
      await ref.read(meshProvider.notifier).clearAllIncidents();
      messenger.showSnackBar(SnackBar(content: Text(s.allIncidentsCleared)));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

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

// ---------- INCIDENT SHEET ----------
void showIncidentSheet(BuildContext ctx, IncidentRow r, S s) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: AC.surface,
    showDragHandle: true,
    builder: (sctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text(
              catIcon(r.category),
              style: const TextStyle(fontSize: 36),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                r.name,
                style: const TextStyle(
                  color: AC.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            statusChip(r.status, s),
          ]),
          const SizedBox(height: 6),
          Text(
            '${catName(r.category, s)} • ${timeAgo(r.createdAt)} • '
                '${s.viaPhones} ${r.hops} • '
                '${r.fromCloud ? s.cloudSrc : s.localMeshSrc}',
            style: const TextStyle(color: AC.dim),
          ),

          if (r.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '“${r.text}”',
                style: const TextStyle(
                  color: AC.text,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),

          if (r.lat != null && r.lng != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _IncidentLocation(
                lat: r.lat!,
                lng: r.lng!,
                s: s,
                ctx: ctx,
              ),
            ),

          if (r.phone != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AC.safe,
                ),
                onPressed: () => dialPhone(ctx, r.phone!),
                icon: const Icon(
                  Icons.call,
                  color: Colors.black,
                ),
                label: Text(
                  '${s.callLabel} ${r.phone}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _IncidentLocation extends StatefulWidget {
  final double lat;
  final double lng;
  final S s;
  final BuildContext ctx;

  const _IncidentLocation({
    required this.lat,
    required this.lng,
    required this.s,
    required this.ctx,
  });

  @override
  State<_IncidentLocation> createState() => _IncidentLocationState();
}

class _IncidentLocationState extends State<_IncidentLocation> {
  String? _location;
  bool _loading = true;

  final geocoding.Geocoding _geocoding = geocoding.Geocoding();

  @override
  void initState() {
    super.initState();
    _reverseGeocode();
  }

  Future<void> _reverseGeocode() async {
    try {
      final placemarks = await _geocoding.placemarkFromCoordinates(
        widget.lat,
        widget.lng,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;

        final parts = [
          place.street,
          place.subLocality,
          place.locality,
          place.administrativeArea,
          place.country,
        ]
            .where((e) => e != null && e!.trim().isNotEmpty)
            .map((e) => e!.trim())
            .toSet()
            .toList();

        if (mounted) {
          setState(() {
            _location = parts.join(', ');
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AC.primary,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Finding location...',
                  style: TextStyle(
                    color: AC.dim,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

        if (_location != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AC.surface,
              borderRadius: BorderRadius.circular(AR.r8),
              border: Border.all(color: AC.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_on,
                  color: AC.primary,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Location',
                        style: TextStyle(
                          color: AC.dim,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _location!,
                        style: const TextStyle(
                          color: AC.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 8),

        // Existing coordinates + copy functionality preserved.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AC.border),
            minimumSize: const Size.fromHeight(44),
          ),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text: '${widget.lat}, ${widget.lng}',
              ),
            );

            ScaffoldMessenger.of(widget.ctx).showSnackBar(
              SnackBar(
                content: Text(widget.s.coordinatesCopied),
              ),
            );
          },
          icon: const Icon(
            Icons.copy,
            color: AC.primary,
          ),
          label: Text(
            '📍 ${widget.lat.toStringAsFixed(5)}, '
                '${widget.lng.toStringAsFixed(5)}',
            style: const TextStyle(
              color: AC.text,
            ),
          ),
        ),
      ],
    );
  }
}

Widget statusChip(PacketStatus st, S s) {
  final color = st == PacketStatus.active ? AC.sos : (st == PacketStatus.resolved ? AC.safe : AC.mute);
  final label = st == PacketStatus.active ? s.active : (st == PacketStatus.resolved ? s.resolved : s.expired);
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

class _SirenBar extends ConsumerWidget {
  final AidPacket packet;
  const _SirenBar({required this.packet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final waiting = ref.watch(meshProvider.select((m) => m.alertsWaiting));
    final cat = packet.category?.name ?? 'custom';
    return Material(
      color: AC.sos,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.incomingSos} — ${packet.senderName}${waiting > 1 ? '  (+${waiting - 1})' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            Text('${catIcon(cat)} ${catName(cat, s)}  •  ${s.viaPhones} ${packet.hops} ${s.seenByN}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ])),
          TextButton(
            onPressed: () => waiting > 1
                ? ref.read(meshProvider.notifier).dismissAlert(packet.id)
                : ref.read(meshProvider.notifier).stopSiren(),
            child: Text(waiting > 1 ? s.nextAlert : s.silence,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
          ),
        ]),
      ),
    );
  }
}

String catIcon(String c) => switch (c) {
  'medical' => '🏥', 'waterFood' => '💧', 'rescue' => '🆘', 'custom' => '✏️', _ => '🆘' };
String catName(String c, S s) => switch (c) {
  'medical' => s.catMedical, 'waterFood' => s.catWater, 'rescue' => s.catRescue, 'custom' => s.catCustom, _ => s.catCustom };
*/


import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: unused_import
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart' as geocoding;

import '../app/mesh.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import 'civilian_shell.dart' show dialPhone;
import 'design_tokens.dart';
import 'settings_screen.dart';
import 'strings.dart';

class IncidentRow {
  final String id;
  final String name;
  final String? phone;
  final String category;
  final String text;
  final double? lat, lng;
  final int createdAt, hops;
  final PacketStatus status;
  final bool fromCloud;
  final AidPacket? packet;

  const IncidentRow({
    required this.id,
    required this.name,
    this.phone,
    required this.category,
    required this.text,
    this.lat,
    this.lng,
    required this.createdAt,
    required this.hops,
    required this.status,
    required this.fromCloud,
    this.packet,
  });
}

IncidentRow _fromPacket(AidPacket p, PacketStatus st) => IncidentRow(
  id: p.id,
  name: p.senderName,
  phone: p.phone,
  category: p.category?.name ?? 'custom',
  text: p.text,
  lat: p.lat,
  lng: p.lng,
  createdAt: p.createdAt,
  hops: p.hops,
  status: st,
  fromCloud: false,
  packet: p,
);

IncidentRow _fromDoc(DocumentSnapshot d) {
  final m = d.data() as Map<String, Object?>;

  final st = m['status'] == 'resolved'
      ? PacketStatus.resolved
      : PacketStatus.active;

  return IncidentRow(
    id: '${m['id'] ?? d.id}',
    name: '${m['senderName'] ?? 'Unknown'}',
    phone: m['phone'] as String?,
    category: '${m['category'] ?? 'custom'}',
    text: '${m['text'] ?? ''}',
    lat: m['lat'] == null
        ? null
        : num.tryParse('${m['lat']}')?.toDouble(),
    lng: m['lng'] == null
        ? null
        : num.tryParse('${m['lng']}')?.toDouble(),
    createdAt: num.tryParse('${m['createdAt']}')?.toInt() ?? 0,
    hops: num.tryParse('${m['hops']}')?.toInt() ?? 0,
    status: st,
    fromCloud: true,
  );
}

const int kCloudFeedLimit = 200;

final cloudIncidentsProvider = StreamProvider<List<IncidentRow>>((ref) {
  if (!ref.watch(bridgeReadyProvider)) {
    return Stream.value(const <IncidentRow>[]);
  }

  return FirebaseFirestore.instance
      .collection('sos')
      .orderBy('createdAt', descending: true)
      .limit(kCloudFeedLimit)
      .snapshots()
      .map((qs) {
    final out = <IncidentRow>[];

    for (final d in qs.docs) {
      try {
        out.add(_fromDoc(d));
      } catch (_) {}
    }

    return out;
  });
});

class NgoShell extends ConsumerStatefulWidget {
  const NgoShell({super.key});

  @override
  ConsumerState<NgoShell> createState() => _NgoShellState();
}

class _NgoShellState extends ConsumerState<NgoShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
  TabController(length: 4, vsync: this);

  @override
  void initState() {
    super.initState();

    Future.microtask(() async {
      if (!ref.read(meshProvider).transportUp) {
        await ref.read(meshProvider.notifier).start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final m = ref.watch(meshProvider);
    final ctrl = ref.read(meshProvider.notifier);
    final cloudAsync = ref.watch(cloudIncidentsProvider);
    final cloud = cloudAsync.value ?? const <IncidentRow>[];

    final now = DateTime.now().toUtc();
    final merged = <String, IncidentRow>{};

    if (ctrl.engineReady) {
      for (final p
      in ctrl.engine.notebook.where((p) => p.type == PacketType.sos)) {
        merged[p.id] = _fromPacket(
          p,
          _status(ctrl, p, now),
        );
      }
    }

    for (final r in cloud) {
      final local = merged[r.id];

      final status =
      (local?.status == PacketStatus.resolved ||
          r.status == PacketStatus.resolved)
          ? PacketStatus.resolved
          : _expired(r.createdAt, now)
          ? PacketStatus.expired
          : PacketStatus.active;

      merged[r.id] = IncidentRow(
        id: r.id,
        name: r.name,
        phone: r.phone ?? local?.phone,
        category: r.category,
        text: r.text.isNotEmpty ? r.text : (local?.text ?? ''),
        lat: r.lat ?? local?.lat,
        lng: r.lng ?? local?.lng,
        createdAt: r.createdAt,
        hops: r.hops,
        status: status,
        fromCloud: true,
      );
    }

    final incidents = merged.values.toList()
      ..sort(
            (a, b) => b.createdAt.compareTo(a.createdAt),
      );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(s.ngoCommandTitle),
            const SizedBox(width: 8),
            Text(
              '• ${ref.watch(identityProvider)?.name ?? ""}',
              style: const TextStyle(
                fontSize: 13,
                color: AC.dim,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
              text: s.tabIncidents,
              icon: const Icon(Icons.crisis_alert),
            ),
            Tab(
              text: s.tabMap,
              icon: const Icon(Icons.map),
            ),
            Tab(
              text: s.tabBridge,
              icon: const Icon(Icons.settings_input_antenna),
            ),
            Tab(
              text: s.tabSettings,
              icon: const Icon(Icons.settings_suggest),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (m.alertPacket != null)
            _SirenBar(packet: m.alertPacket!),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _IncidentsTab(
                  incidents: incidents,
                  cloudError: cloudAsync.hasError,
                ),
                _MapTab(incidents: incidents),
                _BridgeTab(mesh: m),
                const SettingsScreen(
                  showIdentityFields: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PacketStatus _status(
      MeshController ctrl,
      AidPacket p,
      DateTime now,
      ) =>
      ctrl.engine.statusOf(p, now);

  bool _expired(
      int epochSec,
      DateTime now,
      ) =>
      epochSec > 0 &&
          now.difference(
            DateTime.fromMillisecondsSinceEpoch(
              epochSec * 1000,
              isUtc: true,
            ),
          ) >
              kPacketLifetime;
}

// ---------- TAB 1: INCIDENTS ----------

class _IncidentsTab extends ConsumerWidget {
  final List<IncidentRow> incidents;
  final bool cloudError;

  const _IncidentsTab({
    required this.incidents,
    required this.cloudError,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);

    if (incidents.isEmpty) {
      return Center(
        child: Text(
          s.noIncidents,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AC.dim),
        ),
      );
    }

    final active = incidents
        .where((r) => r.status == PacketStatus.active)
        .length;

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: AC.surface,
          padding: const EdgeInsets.symmetric(
            vertical: 8,
            horizontal: 14,
          ),
          child: Text(
            s.activeSummary(
              active,
              incidents.length,
              cloudError: cloudError,
            ),
            style: TextStyle(
              color: cloudError ? AC.sos : AC.dim,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: incidents.length,
            separatorBuilder: (_, _) =>
            const SizedBox(height: 6),
            itemBuilder: (ctx, i) {
              final r = incidents[i];

              final color =
              r.status == PacketStatus.active
                  ? AC.sos
                  : (r.status == PacketStatus.resolved
                  ? AC.safe
                  : AC.mute);

              return InkWell(
                onTap: () =>
                    showIncidentSheet(ctx, r, s),
                borderRadius:
                BorderRadius.circular(AR.r12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AC.surface,
                    borderRadius:
                    BorderRadius.circular(AR.r12),
                    border: Border.all(
                      color:
                      color.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        catIcon(r.category),
                        style:
                        const TextStyle(fontSize: 30),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                          CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.name,
                              style: const TextStyle(
                                color: AC.text,
                                fontWeight:
                                FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              '${timeAgo(r.createdAt)} • '
                                  '${s.viaPhones} ${r.hops} • '
                                  '${r.fromCloud ? s.cloudSrcShort : s.localSrcShort}'
                                  '${r.lat != null ? " • 📍" : ""}',
                              style: const TextStyle(
                                color: AC.dim,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      statusChip(r.status, s),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------- TAB 2: COMMAND MAP ----------

class _MapTab extends ConsumerWidget {
  final List<IncidentRow> incidents;

  const _MapTab({
    required this.incidents,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);

    final withCoords = incidents
        .where(
          (r) => r.lat != null && r.lng != null,
    )
        .toList();

    final center = withCoords.isNotEmpty
        ? LatLng(
      withCoords.first.lat!,
      withCoords.first.lng!,
    )
        : const LatLng(24.8607, 67.0011);

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 11,
          ),
          children: [
            TileLayer(
              urlTemplate:
              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName:
              'com.aidbridge.aidbridge',
            ),
            MarkerLayer(
              markers: [
                for (final r in withCoords)
                  _pin(r, s),
              ],
            ),
          ],
        ),
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AC.surface,
              borderRadius:
              BorderRadius.circular(AR.r8),
              border: Border.all(color: AC.border),
            ),
            child: Text(
              s.locatedIncidents(
                withCoords.length,
              ),
              style: const TextStyle(
                color: AC.dim,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Marker _pin(IncidentRow r, S s) => Marker(
    point: LatLng(r.lat!, r.lng!),
    width: 130,
    height: 62,
    child: Builder(
      builder: (ctx) => GestureDetector(
        onTap: () =>
            showIncidentSheet(ctx, r, s),
        child: Column(
          children: [
            Icon(
              Icons.location_pin,
              size: 34,
              color:
              r.status == PacketStatus.active
                  ? AC.sos
                  : (r.status ==
                  PacketStatus.resolved
                  ? AC.safe
                  : AC.mute),
            ),
            Container(
              padding:
              const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: AC.surface,
                borderRadius:
                BorderRadius.circular(6),
                border: Border.all(
                  color: AC.border,
                ),
              ),
              child: Text(
                r.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AC.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------- TAB 3: BRIDGE ----------

class _BridgeTab extends ConsumerStatefulWidget {
  final MeshState mesh;

  const _BridgeTab({
    required this.mesh,
  });

  @override
  ConsumerState<_BridgeTab> createState() =>
      _BridgeTabState();
}

class _BridgeTabState
    extends ConsumerState<_BridgeTab> {
  bool _clearing = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final ready = ref.watch(bridgeReadyProvider);
    final bridge = ref.read(bridgeProvider);
    final mesh = widget.mesh;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _row(
          s.bridgeReadyLabel,
          ready
              ? s.bridgeReadyStatus
              : bridge.status,
          ready ? AC.safe : AC.mute,
        ),
        _row(
          s.meshLabel,
          mesh.transportUp
              ? s.onlineLabel
              : s.offlineLabel,
          mesh.transportUp ? AC.safe : AC.mute,
        ),
        _row(
          s.peersConnected,
          '${mesh.peers}',
          AC.text,
        ),
        _row(
          s.notebookCarriedLabel,
          s.notebookLetters(
            mesh.notebookCount,
          ),
          AC.text,
        ),
        _row(
          s.dedupMemoryLabel,
          '${mesh.seenCount}',
          AC.text,
        ),
        const SizedBox(height: 10),
        Text(
          s.bridgeExplain,
          style: const TextStyle(
            color: AC.dim,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 18),

        // NGO DASHBOARD RESET:
        // wipes cloud + this phone's notebook.
        // Never one stray tap away.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(
              color: AC.sos,
            ),
            minimumSize:
            const Size.fromHeight(kMinTarget),
          ),
          onPressed:
          (!ready || _clearing)
              ? null
              : () => _confirmClearAll(s),
          icon: _clearing
              ? const SizedBox(
            width: 18,
            height: 18,
            child:
            CircularProgressIndicator(
              strokeWidth: 2,
              color: AC.sos,
            ),
          )
              : const Icon(
            Icons.delete_forever,
            color: AC.sos,
          ),
          label: Text(
            s.clearAllIncidents,
            style: const TextStyle(
              color: AC.sos,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearAll(S s) async {
    final messenger =
    ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AC.surface,
        title: Text(
          s.clearAllIncidents,
          style: const TextStyle(
            color: AC.text,
          ),
        ),
        content: Text(
          s.clearAllIncidentsQ,
          style: const TextStyle(
            color: AC.dim,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(false),
            child: Text(
              s.cancel,
              style: const TextStyle(
                color: AC.dim,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(true),
            child: Text(
              s.erase,
              style: const TextStyle(
                color: AC.sos,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => _clearing = true);

    try {
      await ref
          .read(meshProvider.notifier)
          .clearAllIncidents();

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            s.allIncidentsCleared,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  Widget _row(
      String k,
      String v,
      Color c,
      ) =>
      Container(
        margin:
        const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AC.surface,
          borderRadius:
          BorderRadius.circular(AR.r12),
          border: Border.all(
            color: AC.border,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                k,
                style: const TextStyle(
                  color: AC.dim,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              v,
              style: TextStyle(
                color: c,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
}

// ---------- INCIDENT SHEET ----------

void showIncidentSheet(
    BuildContext ctx,
    IncidentRow r,
    S s,
    ) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: AC.surface,
    showDragHandle: true,
    builder: (sctx) => Padding(
      padding: const EdgeInsets.fromLTRB(
        20,
        0,
        20,
        26,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
        CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                catIcon(r.category),
                style:
                const TextStyle(fontSize: 36),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r.name,
                  style: const TextStyle(
                    color: AC.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              statusChip(r.status, s),
            ],
          ),

          const SizedBox(height: 6),

          Text(
            '${catName(r.category, s)} • '
                '${timeAgo(r.createdAt)} • '
                '${s.viaPhones} ${r.hops} • '
                '${r.fromCloud ? s.cloudSrc : s.localMeshSrc}',
            style: const TextStyle(
              color: AC.dim,
            ),
          ),

          if (r.text.isNotEmpty)
            Padding(
              padding:
              const EdgeInsets.only(top: 8),
              child: Text(
                '“${r.text}”',
                style: const TextStyle(
                  color: AC.text,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),

          if (r.lat != null && r.lng != null)
            Padding(
              padding:
              const EdgeInsets.only(top: 12),
              child: _IncidentLocation(
                lat: r.lat!,
                lng: r.lng!,
                s: s,
                ctx: ctx,
              ),
            ),

          if (r.phone != null)
            Padding(
              padding:
              const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AC.safe,
                ),
                onPressed: () =>
                    dialPhone(ctx, r.phone!),
                icon: const Icon(
                  Icons.call,
                  color: Colors.black,
                ),
                label: Text(
                  '${s.callLabel} ${r.phone}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

// ---------- REVERSE GEOCODING ----------

class _IncidentLocation extends StatefulWidget {
  final double lat;
  final double lng;
  final S s;
  final BuildContext ctx;

  const _IncidentLocation({
    required this.lat,
    required this.lng,
    required this.s,
    required this.ctx,
  });

  @override
  State<_IncidentLocation> createState() =>
      _IncidentLocationState();
}

class _IncidentLocationState
    extends State<_IncidentLocation> {
  String? _location;
  bool _loading = true;

  // geocoding 5.0.0 API
  final geocoding.Geocoding _geocoding =
  geocoding.Geocoding();

  @override
  void initState() {
    super.initState();
    _reverseGeocode();
  }

  Future<void> _reverseGeocode() async {
    try {
      final placemarks =
      await _geocoding.placemarkFromCoordinates(
        widget.lat,
        widget.lng,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;

        final parts = [
          place.street,
          place.subLocality,
          place.locality,
          place.administrativeArea,
          place.country,
        ]
            .whereType<String>()
            .where((e) => e.trim().isNotEmpty)
            .map((e) => e.trim())
            .toSet()
            .toList();

        if (mounted) {
          setState(() {
            _location =
            parts.isEmpty
                ? null
                : parts.join(', ');
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
      }
    } catch (e) {
      // Keep the existing coordinate functionality
      // even if reverse geocoding fails.
      debugPrint(
        'AidBridge reverse geocoding failed: $e',
      );

      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
      CrossAxisAlignment.stretch,
      children: [
        if (_loading)
          const Padding(
            padding:
            EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child:
                  CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AC.primary,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Finding location...',
                  style: TextStyle(
                    color: AC.dim,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

        if (_location != null)
          Container(
            padding:
            const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AC.surface,
              borderRadius:
              BorderRadius.circular(AR.r8),
              border: Border.all(
                color: AC.border,
              ),
            ),
            child: Row(
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_on,
                  color: AC.primary,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Location',
                        style: TextStyle(
                          color: AC.dim,
                          fontSize: 11,
                          fontWeight:
                          FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _location!,
                        style: const TextStyle(
                          color: AC.text,
                          fontSize: 14,
                          fontWeight:
                          FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 8),

        // Existing coordinates + copy functionality preserved.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(
              color: AC.border,
            ),
            minimumSize:
            const Size.fromHeight(44),
          ),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text:
                '${widget.lat}, ${widget.lng}',
              ),
            );

            ScaffoldMessenger.of(widget.ctx)
                .showSnackBar(
              SnackBar(
                content: Text(
                  widget.s.coordinatesCopied,
                ),
              ),
            );
          },
          icon: const Icon(
            Icons.copy,
            color: AC.primary,
          ),
          label: Text(
            '📍 ${widget.lat.toStringAsFixed(5)}, '
                '${widget.lng.toStringAsFixed(5)}',
            style: const TextStyle(
              color: AC.text,
            ),
          ),
        ),
      ],
    );
  }
}

Widget statusChip(
    PacketStatus st,
    S s,
    ) {
  final color =
  st == PacketStatus.active
      ? AC.sos
      : (st == PacketStatus.resolved
      ? AC.safe
      : AC.mute);

  final label =
  st == PacketStatus.active
      ? s.active
      : (st == PacketStatus.resolved
      ? s.resolved
      : s.expired);

  final icon =
  st == PacketStatus.active
      ? Icons.campaign
      : Icons.check_circle;

  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: 10,
      vertical: 6,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius:
      BorderRadius.circular(AR.r8),
      border: Border.all(
        color: color,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          color: color,
          size: 14,
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _SirenBar extends ConsumerWidget {
  final AidPacket packet;

  const _SirenBar({
    required this.packet,
  });

  @override
  Widget build(
      BuildContext context,
      WidgetRef ref,
      ) {
    final s = ref.watch(stringsProvider);
    final waiting =
    ref.watch(
      meshProvider.select(
            (m) => m.alertsWaiting,
      ),
    );

    final cat =
        packet.category?.name ?? 'custom';

    return Material(
      color: AC.sos,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          12,
          6,
          6,
          6,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment:
                CrossAxisAlignment.start,
                children: [
                  Text(
                    '${s.incomingSos} — '
                        '${packet.senderName}'
                        '${waiting > 1 ? '  (+${waiting - 1})' : ''}',
                    maxLines: 1,
                    overflow:
                    TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${catIcon(cat)} '
                        '${catName(cat, s)}  •  '
                        '${s.viaPhones} ${packet.hops} '
                        '${s.seenByN}',
                    maxLines: 1,
                    overflow:
                    TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () =>
              waiting > 1
                  ? ref
                  .read(
                meshProvider.notifier,
              )
                  .dismissAlert(
                packet.id,
              )
                  : ref
                  .read(
                meshProvider.notifier,
              )
                  .stopSiren(),
              child: Text(
                waiting > 1
                    ? s.nextAlert
                    : s.silence,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String catIcon(String c) => switch (c) {
  'medical' => '🏥',
  'waterFood' => '💧',
  'rescue' => '🆘',
  'custom' => '✏️',
  _ => '🆘'
};

String catName(String c, S s) => switch (c) {
  'medical' => s.catMedical,
  'waterFood' => s.catWater,
  'rescue' => s.catRescue,
  'custom' => s.catCustom,
  _ => s.catCustom
};