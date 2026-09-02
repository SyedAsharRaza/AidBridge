import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as ph; // ServiceStatus clashes with geolocator
import 'package:shared_preferences/shared_preferences.dart';
import '../protocol/packet.dart';
import '../protocol/protocol_engine.dart';
import '../transport/nearby_connections_transport.dart';
import '../transport/nearby_transport.dart';
import '../services/bridge_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Shipped asset (16-bit PCM WAV — decodes on every Android without a codec gamble).
const String kSirenAsset = 'audio/siren.wav';

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

/// BridgeService is a mutable singleton, so watching it can never rebuild anything.
/// This flag is the reactive shadow of `BridgeService.ready` — cloud streams and the
/// NGO bridge tab watch THIS, otherwise they latch "offline" forever. (REACTIVITY LAW)
final bridgeReadyProvider = StateProvider<bool>((ref) => false);



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
  final String? radioWarning;   // Bluetooth/Location OFF => mesh is deaf and blind
  const MeshState({
    this.transportUp = false, this.peers = 0, this.seenCount = 0,
    this.notebookCount = 0, this.log = const [], this.alertPacket, this.ownActiveSosId,
    this.radioWarning,
  });
  MeshState copyWith({bool? transportUp, int? peers, int? seenCount, int? notebookCount,
    List<String>? log, AidPacket? alertPacket, String? ownActiveSosId, String? radioWarning,
    bool clearAlert = false, bool clearOwnSos = false, bool clearRadioWarning = false}) =>
      MeshState(
        transportUp: transportUp ?? this.transportUp, peers: peers ?? this.peers,
        seenCount: seenCount ?? this.seenCount, notebookCount: notebookCount ?? this.notebookCount,
        log: log ?? this.log, alertPacket: clearAlert ? null : (alertPacket ?? this.alertPacket),
        ownActiveSosId: clearOwnSos ? null : (ownActiveSosId ?? this.ownActiveSosId),
        radioWarning: clearRadioWarning ? null : (radioWarning ?? this.radioWarning),
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
  /// UI builds can run BEFORE start()'s microtask creates the engine — every screen
  /// must check this before touching [engine]. (FIRST-FRAME LAW)
  bool get engineReady => _engine != null;
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
    final restored = _engine!.ownActiveSos();
    if (restored != null) state = state.copyWith(ownActiveSosId: restored.id);

    _sub?.cancel();
    _sub = transport.events.listen(_onEvent);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) => _heartbeat());
    await transport.start('${id.name}·${id.selfId}'); // name·id => symmetry-breaker inequality
    state = state.copyWith(transportUp: true);
    await refreshRadioWarning();   // radios OFF is the #1 silent "nothing connects" cause
    await ref.read(bridgeProvider).init();
    ref.read(bridgeReadyProvider.notifier).state = ref.read(bridgeProvider).ready;
    _log(ref.read(bridgeProvider).status);
  }

  /// Manual recovery hatch (Settings button): full stop, then a clean start.
  /// The notebook survives — only radios and native state are recycled.
  Future<void> restart() async {
    _log('MANUAL MESH RESTART requested');
    await stop();
    await start();
  }

  /// Nearby Connections needs BOTH Bluetooth and Location switched ON. When either is
  /// off, discovery silently finds nobody — so we say it out loud instead of failing mute.
  Future<void> refreshRadioWarning() async {
    String? w;
    try {
      final btOff = (await ph.Permission.bluetooth.serviceStatus) == ph.ServiceStatus.disabled;
      final locOff = (await ph.Permission.location.serviceStatus) == ph.ServiceStatus.disabled;
      if (btOff && locOff) {
        w = 'Bluetooth AND Location are OFF — no phone can be found.';
      } else if (btOff) {
        w = 'Bluetooth is OFF — turn it on to reach nearby phones.';
      } else if (locOff) {
        w = 'Location is OFF — Android needs it to scan for phones.';
      }
    } catch (_) {/* status unknown => never block the SOS path */}
    state = w == null ? state.copyWith(clearRadioWarning: true) : state.copyWith(radioWarning: w);
    if (w != null) _log('RADIO WARNING: $w');
  }

  Future<void> openRadioSettings() async {
    try { await Geolocator.openLocationSettings(); } catch (_) {}
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
    // DUPLICATE-ALERT GUARD: engine dedup already blocks re-ingest of the same id; this
    // stops a stacked takeover/siren for a packet we are ALREADY screaming about.
    if (r.siren && r.packet != null && state.alertPacket?.id != r.packet!.id) {
      state = state.copyWith(alertPacket: r.packet);
      if (_sirenArmed) unawaited(_playSiren());
      unawaited(_notify('🆘 SOS: ${r.packet!.senderName}',
          'Distress signal received — TAP to open AidBridge'));
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
    final existing = engine.ownActiveSos();
    if (existing != null) {
      _log('OWN SOS already ACTIVE — use I\'M SAFE first');
      state = state.copyWith(ownActiveSosId: existing.id);
      return;
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
      id = engine.ownActiveSos()?.id; // RAM lost it after a process kill — the notebook did not
    }
    if (id == null) { _log('Nothing active to resolve'); return; }
    final r = engine.sendCancel(id);
    _log('I AM SAFE -> resolve ${r.targetId}');
    state = state.copyWith(clearOwnSos: true); // only ownActiveSosId is purged
    _refreshCounts(); _persist(); _flushAll();
    final me = ref.read(identityProvider)?.name ?? 'unknown';
    unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
  }

  Future<void> _heartbeat() async {
    final r = _engine?.heartbeatTick(DateTime.now().toUtc());
    if (r != null) { _log(r.note); _flushAll(); _persist(); }
  }

  // ---------- Siren + haptics (a muted or pocketed phone must STILL wake its owner) ----------
  Future<void> _playSiren() async {
    _buzzAlarm();
    try {
      await _siren.setReleaseMode(ReleaseMode.loop);
      await _siren.setVolume(1.0);
      await _siren.play(AssetSource(kSirenAsset));
    } catch (e) {
      _log('SIREN failed ($e) — vibration only');
    }
  }

  /// Spaced heavy impacts ≈ alarm pattern, no extra dependency, works on silent mode.
  void _buzzAlarm() {
    for (var i = 0; i < 6; i++) {
      Future.delayed(Duration(milliseconds: 400 * i), () => HapticFeedback.heavyImpact());
    }
  }

  Future<void> sirenTest() async {
    _buzzAlarm();
    try {
      await _siren.setReleaseMode(ReleaseMode.stop);
      await _siren.setVolume(1.0);
      await _siren.play(AssetSource(kSirenAsset));
      Future.delayed(const Duration(seconds: 2), () => _siren.stop());
    } catch (e) {
      _log('SIREN TEST failed ($e) — vibration only');
    }
  }

  Future<void> stopSiren() async {
    try { await _siren.stop(); } catch (_) {}
    state = state.copyWith(clearAlert: true);
    unawaited(_notify('AidBridge mesh active', 'Relaying SOS packets. Keep this app alive.'));
  }

  /// The service can be dead (OEM killer, swipe) — an unguarded updateService would
  /// throw into the void and take the isolate's error handler with it.
  Future<void> _notify(String title, String text) async {
    try {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    } catch (_) {}
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