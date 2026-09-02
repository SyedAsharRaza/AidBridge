import 'dart:convert';
import 'dart:math';
import 'packet.dart';

/// === Protocol constants — hardware-verified knobs (DO NOT silently change) ===
const int kMaxTtl = 4;        // hop budget (T11 wall tests were green at 4)
const int kMaxSeen = 500;     // dedup memory cap
const int kMaxNotebook = 200; // store-and-forward cap
const Duration kPacketLifetime = Duration(hours: 48);  // EXPIRED status
const Duration kHeartbeat = Duration(minutes: 5);      // own-SOS rebroadcast

/// THE HISTORY/ALARM LINE. A phone that joins a mesh is handed the WHOLE notebook at
/// once, so without this every letter of the last two days arrives as a fresh emergency
/// and the phone screams the moment it connects. Older letters are still stored, still
/// relayed and still listed in ALERTS — they just do not take over the screen.
/// Unknown or future timestamps count as fresh: a wrong clock must never mute a real SOS.
const Duration kSirenFreshness = Duration(minutes: 30);

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

  AidPacket? _byId(String id) {   // notebook is capped at kMaxNotebook — a linear scan is free
    for (final p in _notebook) { if (p.id == id) return p; }
    return null;
  }

  /// THE ONE TRUTH for "do I have an SOS out right now?" — newest own unresolved
  /// SOS in the notebook. UI, ghost-law and heartbeat all read THIS (never re-scan).
  AidPacket? ownActiveSos() {
    for (final p in _notebook.reversed) {
      if (p.type == PacketType.sos && p.senderId == selfId && !isResolved(p.id)) return p;
    }
    return null;
  }
  PacketStatus statusOf(AidPacket p, DateTime now) {
    if (isResolved(p.id)) return PacketStatus.resolved;
    if (p.createdAt > 0 && now.difference(DateTime.fromMillisecondsSinceEpoch(p.createdAt * 1000, isUtc: true)) > kPacketLifetime) {
      return PacketStatus.expired;
    }
    return PacketStatus.active;
  }

  /// Is this letter recent enough to be an ALARM rather than a record?
  /// A packet with no usable timestamp, or one from a phone whose clock runs ahead,
  /// is treated as fresh — silence is the one failure mode we refuse to risk.
  bool sirenWorthy(AidPacket p, DateTime now) {
    if (p.createdAt <= 0) return true;
    final age = now.difference(
        DateTime.fromMillisecondsSinceEpoch(p.createdAt * 1000, isUtc: true));
    return age <= kSirenFreshness;
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
      phone: selfPhone, category: category, text: clampText(text), lat: lat, lng: lng,
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
    //
    // AN ALARM IS FOR A LIVE EMERGENCY, NOT FOR HISTORY. Three ways an inbound SOS is real
    // but must NOT take over the screen — every one of them was a field-reported false siren:
    //   • RESOLVED: its cancel is already in our notebook (outboundFor sends resolves first,
    //     so a phone joining a settled mesh learns "safe" before it hears the shout).
    //   • EXPIRED: past the 48h life — nobody is waiting on it any more.
    //   • STALE: older than kSirenFreshness, i.e. handed to us out of someone's storage.
    // Uplink follows the same truth: re-uploading a settled SOS would flip its cloud status
    // back to 'active' and re-open a closed case on the NGO dashboard.
    final status = statusOf(p, now);
    final fresh = sirenWorthy(p, now);
    final why = switch (status) {
      PacketStatus.resolved => ' — ALREADY RESOLVED, stored without an alarm',
      PacketStatus.expired => ' — EXPIRED, stored without an alarm',
      PacketStatus.active => fresh ? '' : ' — older than ${kSirenFreshness.inMinutes}min, stored without an alarm',
    };
    return EngineReaction(PacketAction.newSos, packet: p,
        siren: status == PacketStatus.active && fresh,
        uplink: status == PacketStatus.active,
        note: 'SOS from ${p.senderName} (${p.id}, ttl=${p.ttl}, hops=${p.hops})$why');
  }

  // ---------- FLUSH (the POC _doFlush, distilled) ----------
  /// Packets to hand a given endpoint RIGHT NOW: own as-is (full ttl),
  /// carried at ttl-1/hops+1, TTL wall respected, per-endpoint delivery book kept.
  ///
  /// RESOLVES TRAVEL AHEAD OF THE ALARMS THEY KILL. The notebook is insertion-ordered, so
  /// an SOS always sat in front of its own cancel — a phone joining a settled mesh heard the
  /// shout first and screamed until the very next packet corrected it. Cancels are cheap and
  /// order is free, so we hand over the endings before the beginnings.
  ///
  /// Letters past their 48h life are not offered at all: a dead SOS re-flooding every new
  /// phone for two days is pure noise, and it cannot be resolved any more.
  List<AidPacket> outboundFor(String endpointId, {DateTime? now}) {
    final t = now ?? DateTime.now().toUtc();
    final cancels = <AidPacket>[];
    final rest = <AidPacket>[];
    for (final p in List.of(_notebook)) {
      final delivered = _deliveredTo.putIfAbsent(p.id, () => {});
      if (delivered.contains(endpointId)) continue;
      if (statusOf(p, t) == PacketStatus.expired) continue;
      final mine = p.senderId == selfId;
      final candidate = mine ? p : p.forRelay();
      if (candidate.ttl < 1) continue; // hop budget spent -> storage only (T11)
      (p.type == PacketType.cancel ? cancels : rest).add(candidate);
    }
    return [...cancels, ...rest];
  }

  void markDelivered(String packetId, String endpointId) =>
      _deliveredTo.putIfAbsent(packetId, () => {}).add(endpointId); // optimistic (downgradeable)

  /// Transfer FAILURE to an endpoint: forget ALL its deliveries globally — retry on next
  /// connect; receiver dedup absorbs re-sends. (POC failure law — plugin can't map ids)
  void downgradeEndpoint(String endpointId) {
    for (final s in _deliveredTo.values) { s.remove(endpointId); }
  }

  // ---------- HEARTBEAT: my unresolved SOS re-broadcasts on a rhythm ----------
  /// Heartbeat fuel is SPENT once an SOS is resolved, expired, or evicted from the
  /// notebook. Burning it off every tick is what stops dead SOSes from re-arming
  /// delivery books forever (the duplicate-alert-on-relay scar).
  bool _sosSpent(String id, DateTime now) {
    final p = _byId(id);
    return p == null || statusOf(p, now) != PacketStatus.active;
  }

  EngineReaction? heartbeatTick(DateTime now) {
    _myActiveSos.removeWhere((id) => _sosSpent(id, now)); // every tick, cheap
    if (now.difference(_lastBeat) < kHeartbeat) return null;
    if (_myActiveSos.isEmpty) return null;
    _lastBeat = now;
    for (final id in _myActiveSos) { _deliveredTo[id] = {}; } // re-arm delivery book
    return EngineReaction(PacketAction.heartbeat,
        note: 'HEARTBEAT: re-broadcasting ${_myActiveSos.length} own SOS');
  }

  // ---------- PERSISTENCE (identity + notebook survive restarts) ----------
  /// FULL LOCAL AMNESIA — the rehearsal reset. Wipes carried letters, dedup memory,
  /// delivery books and heartbeat fuel on THIS device only; peers keep their copies.
  void clearNotebook() {
    _notebook.clear();
    _seen.clear();
    _deliveredTo.clear();
    _myActiveSos.clear();
    _lastBeat = DateTime.fromMillisecondsSinceEpoch(0);
  }

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