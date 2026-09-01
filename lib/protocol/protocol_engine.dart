import 'dart:convert';
import 'dart:math';
import 'packet.dart';

/// === Protocol constants — hardware-verified knobs (DO NOT silently change) ===
const int kMaxTtl = 4;        // hop budget (T11 wall tests were green at 4)
const int kMaxSeen = 500;     // dedup memory cap
const int kMaxNotebook = 200; // store-and-forward cap
const Duration kPacketLifetime = Duration(hours: 48);  // EXPIRED status
const Duration kHeartbeat = Duration(minutes: 5);      // own-SOS rebroadcast

enum PacketStatus { active, resolved, expired }

/// What the UI/glue should DO with a packet the engine decided on.
class EngineReaction {
  final PacketAction action;
  final AidPacket? packet;   // packet involved
  final String? targetId;    // for cancels
  final bool siren;          // fire full alert + siren (inbound NEW sos only)
  final bool uplink;         // bridge service should upload this (sos+cancel, NEVER chat)
  final String note;         // log line
  const EngineReaction(this.action,
      {this.packet, this.targetId, this.siren = false, this.uplink = false, this.note = ''});
}

enum PacketAction { garbage, duplicate, newSos, cancel, chat, ownSos, ownCancel, ownChat, heartbeat, none }

class ProtocolEngine {
  final String selfId, selfName;
  final String? selfPhone;

  final Set<String> _seen = {};                       // LinkedHashSet = insertion-ordered (FIFO cap)
  final List<AidPacket> _notebook = [];               // own + carried letters
  final Map<String, Set<String>> _deliveredTo = {};   // packetId -> endpoints already given (optimistic)
  final Set<String> _myActiveSos = {};                // my unresolved sos ids (heartbeat fuel)
  DateTime _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);
  final Random _rng = Random();

  ProtocolEngine({required this.selfId, required this.selfName, this.selfPhone});

  List<AidPacket> get notebook => List.unmodifiable(_notebook);
  int get seenCount => _seen.length;
  bool isResolved(String id) =>
      _notebook.any((p) => p.type == PacketType.cancel && p.targetId == id);
  PacketStatus statusOf(AidPacket p, DateTime now) {
    if (isResolved(p.id)) return PacketStatus.resolved;
    if (p.createdAt > 0 && now.difference(DateTime.fromMillisecondsSinceEpoch(p.createdAt * 1000, isUtc: true)) > kPacketLifetime) {
      return PacketStatus.expired;
    }
    return PacketStatus.active;
  }

  String _newId() {  // per-device id + timestamp + random => collisions die (T12 law)
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = _rng.nextInt(1 << 32).toRadixString(36); // MAX ALLOWED by nextInt: 2^32
    return '$selfId-$t-$r';
  }

  void _rememberSeen(String id) { // insertion-ordered cap
    if (_seen.length >= kMaxSeen) _seen.remove(_seen.first);
    _seen.add(id);
  }

  void _store(AidPacket p) {
    _notebook.add(p);
    while (_notebook.length > kMaxNotebook) {     // bounded buffer: evict oldest + its bookkeeping (POC law)
      final ev = _notebook.removeAt(0);
      _deliveredTo.remove(ev.id);
      _myActiveSos.remove(ev.id);
    }
  }

  AidPacket _origin(PacketType type,
      {SosCategory? category, String text = '', double? lat, double? lng, String? targetId}) {
    return AidPacket(
      id: _newId(), type: type, senderId: selfId, senderName: selfName,
      phone: selfPhone, category: category, text: text, lat: lat, lng: lng,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      targetId: targetId, ttl: kMaxTtl, hops: 0,
    );
  }

  // ---------- OUTBOUND (origin) ----------
  EngineReaction sendSos({required SosCategory category, String text = '', double? lat, double? lng}) {
    final p = _origin(PacketType.sos, category: category, text: text, lat: lat, lng: lng);
    _rememberSeen(p.id);            // I originated it => I've "seen" it (POC)
    _store(p);                      // own SOS ALSO enters notebook = mule #1 (fix T10)
    _deliveredTo.putIfAbsent(p.id, () => {});
    _myActiveSos.add(p.id);
    return EngineReaction(PacketAction.ownSos, packet: p, uplink: true, note: 'OWN SOS ${p.id} queued');
  }

  EngineReaction sendCancel(String targetId) {
    final p = _origin(PacketType.cancel, targetId: targetId);
    _rememberSeen(p.id); _store(p);
    _deliveredTo.putIfAbsent(p.id, () => {});
    _myActiveSos.remove(targetId);  // stops heartbeat — "I'M SAFE" travels like the SOS did
    return EngineReaction(PacketAction.ownCancel, packet: p, targetId: targetId, uplink: true,
        note: 'OWN CANCEL for $targetId');
  }

  EngineReaction sendChat(String text) {  // display-only: NOT stored, NOT relayed (privacy law)
    final p = _origin(PacketType.chat, text: text);
    _rememberSeen(p.id);
    return EngineReaction(PacketAction.ownChat, packet: p, note: 'OWN CHAT sent (no store/relay)');
  }

  // ---------- INBOUND — the single ingress funnel ----------
  EngineReaction ingest(String fromEndpointId, String rawJson, DateTime now) {
    final p = AidPacket.fromWire(rawJson);
    if (p == null) return const EngineReaction(PacketAction.garbage, note: 'GARBAGE packet dropped');
    if (p.senderId == selfId) return EngineReaction(PacketAction.duplicate, packet: p, note: 'OWN packet echoed back — ignored');
    if (_seen.contains(p.id)) return EngineReaction(PacketAction.duplicate, packet: p, note: 'DUPLICATE ignored ${p.id}');
    _rememberSeen(p.id);

    if (p.type == PacketType.chat) {   // never stored / relayed / uplinked
      return EngineReaction(PacketAction.chat, packet: p, note: 'CHAT from ${p.senderName}: ${p.text}');
    }

    _store(p);
    _deliveredTo.putIfAbsent(p.id, () => {}).add(fromEndpointId); // never echo back where it came from (POC)

    if (p.type == PacketType.cancel) {
      if (p.targetId != null) _myActiveSos.remove(p.targetId);
      return EngineReaction(PacketAction.cancel, packet: p, targetId: p.targetId,
          uplink: true, note: 'RESOLVE received for ${p.targetId} (${p.senderName} is safe)');
    }
    // sos: relay happens via flush law at glue level (outboundFor → all peers except source).
    return EngineReaction(PacketAction.newSos, packet: p, siren: true, uplink: true,
        note: 'SOS from ${p.senderName} (${p.id}, ttl=${p.ttl}, hops=${p.hops})');
  }

  // ---------- FLUSH (the POC _doFlush, distilled) ----------
  /// Packets to hand a given endpoint RIGHT NOW: own as-is (full ttl),
  /// carried at ttl-1/hops+1, TTL wall respected, per-endpoint delivery book kept.
  List<AidPacket> outboundFor(String endpointId) {
    final out = <AidPacket>[];
    for (final p in List.of(_notebook)) {
      final delivered = _deliveredTo.putIfAbsent(p.id, () => {});
      if (delivered.contains(endpointId)) continue;
      final mine = p.senderId == selfId;
      final candidate = mine ? p : p.forRelay();
      if (candidate.ttl < 1) continue; // hop budget spent -> storage only (T11)
      out.add(candidate);
    }
    return out;
  }

  void markDelivered(String packetId, String endpointId) =>
      _deliveredTo.putIfAbsent(packetId, () => {}).add(endpointId); // optimistic (downgradeable)

  /// Transfer FAILURE to an endpoint: forget ALL its deliveries globally — retry on next
  /// connect; receiver dedup absorbs re-sends. (POC failure law — plugin can't map ids)
  void downgradeEndpoint(String endpointId) {
    for (final s in _deliveredTo.values) { s.remove(endpointId); }
  }

  // ---------- HEARTBEAT: my unresolved SOS re-broadcasts on a rhythm ----------
  EngineReaction? heartbeatTick(DateTime now) {
    if (now.difference(_lastBeat) < kHeartbeat) return null;
    final alive = _myActiveSos.where((id) =>
    !isResolved(id) && now.difference(DateTime.fromMillisecondsSinceEpoch(
        _notebook.firstWhere((p) => p.id == id, orElse: () => _notebook.last).createdAt * 1000, isUtc: true)) < kPacketLifetime).toList();
    if (alive.isEmpty) return null;
    _lastBeat = now;
    for (final id in alive) { _deliveredTo[id] = {}; } // re-arm delivery book for all
    return EngineReaction(PacketAction.heartbeat, note: 'HEARTBEAT: re-broadcasting ${alive.length} own SOS');
  }

  // ---------- PERSISTENCE (identity + notebook survive restarts) ----------
  String snapshot() => jsonEncode({
    'seen': _seen.toList(),
    'notebook': _notebook.map((p) => p.toJson()).toList(),
    'deliveredTo': _deliveredTo.map((k, v) => MapEntry(k, v.toList())),
    'myActiveSos': _myActiveSos.toList(),
  });

  void restore(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return;
      _seen..clear()..addAll(List<String>.from(m['seen'] ?? const []));
      _notebook..clear()..addAll(List<dynamic>.from(m['notebook'] ?? const [])
          .map((e) => AidPacket.fromWire(jsonEncode(e)))
          .whereType<AidPacket>());
      _deliveredTo..clear()..addAll(
          (m['deliveredTo'] as Map? ?? const {}).map((k, v) => MapEntry('$k', Set<String>.from(v))));
      _myActiveSos..clear()..addAll(List<String>.from(m['myActiveSos'] ?? const []));
    } catch (_) {/* corrupt disk file = start empty, never crash */}
  }
}