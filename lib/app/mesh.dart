import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import '../transport/nearby_connections_transport.dart';
import '../transport/nearby_transport.dart';
import '../services/bridge_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class MeshIdentity {
  final String selfId;
  final String name;
  final String? phone;
  final String role;      // 'civilian' | 'ngo'
  final bool onboarded;
  const MeshIdentity(this.selfId, this.name, this.phone, {this.role = 'civilian', this.onboarded = false});
}

final identityProvider = StateNotifierProvider<IdentityStore, MeshIdentity?>((ref) => IdentityStore());
final bridgeProvider = Provider<BridgeService>((ref) => BridgeService());



class IdentityStore extends StateNotifier<MeshIdentity?> {
  IdentityStore() : super(null);
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    var id = p.getString('selfId');
    if (id == null) { id = 'dev-${Random.secure().nextInt(1 << 30).toRadixString(36)}'; await p.setString('selfId', id); }
    final name = p.getString('name') ?? 'Guardian-${id.substring(4)}';
    if (p.getString('name') == null) await p.setString('name', name);
    state = MeshIdentity(id, name, p.getString('phone'),
        role: p.getString('role') ?? 'civilian', onboarded: p.getBool('onboarded') ?? false);
  }
  Future<void> setName(String v) async => _save(name: v);
  Future<void> setPhone(String v) async => _save(phone: v.trim().isEmpty ? null : v.trim());
  Future<void> setRole(String v) async => _save(role: v);
  Future<void> completeOnboarding() async => _save(onboarded: true);
  Future<void> _save({String? name, String? phone, String? role, bool? onboarded}) async {
    if (state == null) return;
    final p = await SharedPreferences.getInstance();
    final n = (name?.trim().isEmpty ?? true) ? state!.name : name!.trim();
    final ph = phone ?? state!.phone; final r = role ?? state!.role; final ob = onboarded ?? state!.onboarded;
    await p.setString('name', n);
    if (ph == null) { await p.remove('phone'); } else { await p.setString('phone', ph); }
    await p.setString('role', r); await p.setBool('onboarded', ob);
    state = MeshIdentity(state!.selfId, n, ph, role: r, onboarded: ob);
  }
}
// ---------- MESH STATE ----------
class MeshState {
  final bool transportUp;
  final int peers, seenCount, notebookCount;
  final List<String> log;
  final AidPacket? alertPacket; // newest inbound SOS -> siren + banner
  final String? ownActiveSosId;
  const MeshState({
    this.transportUp = false, this.peers = 0, this.seenCount = 0,
    this.notebookCount = 0, this.log = const [], this.alertPacket, this.ownActiveSosId,
  });
  MeshState copyWith({bool? transportUp, int? peers, int? seenCount, int? notebookCount,
    List<String>? log, AidPacket? alertPacket, String? ownActiveSosId, bool clearAlert = false}) =>
      MeshState(
        transportUp: transportUp ?? this.transportUp, peers: peers ?? this.peers,
        seenCount: seenCount ?? this.seenCount, notebookCount: notebookCount ?? this.notebookCount,
        log: log ?? this.log, alertPacket: clearAlert ? null : (alertPacket ?? this.alertPacket),
        ownActiveSosId: ownActiveSosId ?? this.ownActiveSosId,
      );
}

final transportProvider = Provider<NearbyTransport>((ref) => NearbyConnectionsTransport());

final meshProvider = StateNotifierProvider<MeshController, MeshState>((ref) => MeshController(ref));

// ---------- THE GLUE (engine decides, glue executes, transport carries) ----------
class MeshController extends StateNotifier<MeshState> {
  final Ref ref;
  ProtocolEngine? _engine;
  StreamSubscription<TransportEvent>? _sub;
  Timer? _heartbeatTimer;
  final AudioPlayer _siren = AudioPlayer();
  final bool _sirenArmed = true;

  MeshController(this.ref) : super(const MeshState());

  ProtocolEngine get engine => _engine!;
  NearbyTransport get transport => ref.read(transportProvider);

  void _log(String m) => state = state.copyWith(
      log: [m, ...state.log].take(50).toList());

  Future<void> _persist() async {
    try {
      if (_engine == null) return;
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/aidbridge_notebook.json').writeAsString(_engine!.snapshot());
    } catch (_) {/* persistence is best-effort, never crash the mesh for it */}
  }

  /// START — FULL transport lifecycle + notebook restore. (Role-change callers MUST stop() first.)
  Future<void> start() async {
    await ref.read(identityProvider.notifier).load();
    final id = ref.read(identityProvider)!;
    _engine ??= ProtocolEngine(selfId: id.selfId, selfName: id.name, selfPhone: id.phone);
    try {
      final f = File('${(await getApplicationDocumentsDirectory()).path}/aidbridge_notebook.json');
      if (await f.exists()) _engine!.restore(await f.readAsString());
    } catch (_) {}
    _refreshCounts();
    // GHOST FIX: after a process kill the notebook remembers the SOS — so the banner must too
    for (final p in _engine!.notebook.reversed) {
      if (p.type == PacketType.sos && p.senderId == id.selfId && !_engine!.isResolved(p.id)) {
        state = state.copyWith(ownActiveSosId: p.id);
        break;
      }
    }

    _sub?.cancel();
    _sub = transport.events.listen(_onEvent);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) => _heartbeat());
    await transport.start('${id.name}·${id.selfId}'); // name·id => symmetry-breaker inequality
    state = state.copyWith(transportUp: true);
    await ref.read(bridgeProvider).init();
    _log(ref.read(bridgeProvider).status);
  }

  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    await transport.stop();
    await stopSiren();
    state = state.copyWith(transportUp: false, peers: 0);
  }

  // ---------- Event router ----------
  void _onEvent(TransportEvent e) {
    switch (e.type) {
      case EventType.log:
        _log(e.message);
      case EventType.peerConnected:
        state = state.copyWith(peers: transport.connectedEndpoints.length);
        _log('CONNECTED: ${e.endpointName ?? e.endpointId}');
        unawaited(_flushPeer(e.endpointId!));
      case EventType.peerDisconnected:
        state = state.copyWith(peers: transport.connectedEndpoints.length);
        _log('DISCONNECTED: ${e.endpointId}');
      case EventType.endpointFound: break; // auto-request already handled in transport
      case EventType.endpointLost: break;
      case EventType.payload:
        _onPayload(e.endpointId!, e.json!);
      case EventType.transferFailure:
        _engine?.downgradeEndpoint(e.endpointId!);
        _log('FAILURE->${e.endpointId}: deliveries re-armed (retry at next connect)');
        _persist();
      case EventType.transportUp:
        _log('MESH ONLINE');
      case EventType.transportDown:
        _log('MESH STOPPED');
    }
  }

  void _onPayload(String fromId, String raw) {
    final r = engine.ingest(fromId, raw, DateTime.now().toUtc());
    _log(r.note);
    if (r.siren && r.packet != null) {
      state = state.copyWith(alertPacket: r.packet);
      if (_sirenArmed) unawaited(_playSiren());
      unawaited(FlutterForegroundTask.updateService(
        notificationTitle: '🆘 SOS: ${r.packet!.senderName}',
        notificationText: 'Distress signal received — TAP to open AidBridge',
      ));
    }
    if (r.action == PacketAction.cancel) {
      _log('RESOLVED ${r.targetId} — ${r.packet?.senderName} is safe');
    }
    if (r.uplink && r.packet != null) {
      final me = ref.read(identityProvider)?.name ?? 'unknown';
      unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
    }
    _refreshCounts(); _persist();
    _relayFrom(fromId); // fan-out to every other peer (never echo back — engine book handles it)
  }

  // ---------- FLUSH LAW (POC _doFlush as glue routine) ----------
  Future<void> _flushPeer(String endpointId) async {
    for (final p in engine.outboundFor(endpointId)) {
      await transport.sendTo(endpointId, p.toWire());
      engine.markDelivered(p.id, endpointId);
      _log('SENT (${p.type.name}${p.hops > 0 ? " hop" : ""}) ttl=${p.ttl} hops=${p.hops} -> $endpointId');
    }
  }

  void _relayFrom(String exceptId) {
    for (final ep in transport.connectedEndpoints) {
      if (ep != exceptId) unawaited(_flushPeer(ep));
    }
  }

  void _flushAll() {
    for (final ep in transport.connectedEndpoints) {
      unawaited(_flushPeer(ep));
    }
  }

  // ---------- OUTBOUND API (debug cockpit now, real UI in Batch-4) ----------
  Future<void> fireSos({required SosCategory category, String text = ''}) async {
    double? lat, lng;
    // GHOST LAW: one active own-SOS per device. If one exists (even restored
    // after a process kill), re-arm the visible state and refuse a second one —
    // a cancel targets ONE id; a stray second SOS would ghost forever.
    final selfId = ref.read(identityProvider)?.selfId;
    for (final p in engine.notebook.reversed) {
      if (p.type == PacketType.sos && p.senderId == selfId && !engine.isResolved(p.id)) {
        _log('OWN SOS already ACTIVE — use I\'M SAFE first');
        state = state.copyWith(ownActiveSosId: p.id);
        return;
      }
    }
    try { // GPS best-effort: null after ~4s, send NEVER blocked (indoor-law)
      final last = await Geolocator.getLastKnownPosition();
      final pos = last ?? await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(accuracy: LocationAccuracy.medium, timeLimit: const Duration(seconds: 4)));
      lat = pos.latitude; lng = pos.longitude;
    } catch (_) {}
    final r = engine.sendSos(category: category, text: text, lat: lat, lng: lng);
    _log(r.note); state = state.copyWith(ownActiveSosId: r.packet?.id);
    _refreshCounts(); _persist(); _flushAll();
    final me = ref.read(identityProvider)?.name ?? 'unknown';
    unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
  }

  Future<void> imSafe() async {
    String? id = state.ownActiveSosId;
    if (id == null || _engine!.isResolved(id)) {
      // process-restart path: ownActiveSosId died in RAM — recover from the persisted notebook
      final selfId = ref.read(identityProvider)?.selfId;
      for (final p in engine.notebook.reversed) {
        if (p.type == PacketType.sos && p.senderId == selfId && !engine.isResolved(p.id)) { id = p.id; break; }
      }
    }
    if (id == null) { _log('Nothing active to resolve'); return; }
    final r = engine.sendCancel(id);
    _log('I AM SAFE -> resolve ${r.targetId}');
    state = MeshState(transportUp: state.transportUp, peers: state.peers,
        seenCount: state.seenCount, notebookCount: state.notebookCount,
        log: state.log, alertPacket: state.alertPacket); // ownActiveSosId purged
    _refreshCounts(); _persist(); _flushAll();
    final me = ref.read(identityProvider)?.name ?? 'unknown';
    unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
  }

  Future<void> _heartbeat() async {
    final r = _engine?.heartbeatTick(DateTime.now().toUtc());
    if (r != null) { _log(r.note); _flushAll(); _persist(); }
  }

  // ---------- Siren (temporary debug rig; alert service arrives Batch-4) ----------
  Future<void> _playSiren() async {
    try {
      await _siren.setReleaseMode(ReleaseMode.loop);
      await _siren.play(AssetSource('audio/siren.mp3'));
    } catch (_) {}
  }
  Future<void> sirenTest() async {
    try {
      await _siren.setReleaseMode(ReleaseMode.stop);
      await _siren.play(AssetSource('audio/siren.mp3'));
      Future.delayed(const Duration(seconds: 2), () => _siren.stop());
    } catch (_) {}
  }
  Future<void> stopSiren() async {
    try { await _siren.stop(); } catch (_) {}
    state = state.copyWith(clearAlert: true);
    unawaited(FlutterForegroundTask.updateService(
      notificationTitle: 'AidBridge mesh active',
      notificationText: 'Relaying SOS packets. Keep this app alive.',
    ));
  }

  void _refreshCounts() {
    if (_engine == null) return;
    state = state.copyWith(seenCount: _engine!.seenCount,
        notebookCount: _engine!.notebook.length,
        peers: transport.connectedEndpoints.length);
  }

  @override
  void dispose() {
    _sub?.cancel(); _heartbeatTimer?.cancel(); _siren.dispose();
    super.dispose();
  }
}