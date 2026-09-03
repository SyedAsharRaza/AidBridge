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
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Shipped asset (16-bit PCM WAV — decodes on every Android without a codec gamble).
const String kSirenAsset = 'audio/siren.wav';

/// Rate limit on originating SOS letters. A demo audience WILL mash the button, and
/// every press that got through would burn a notebook slot and a cloud write.
const Duration kSosCooldown = Duration(seconds: 10);

/// Why a press did NOT originate an SOS. Returned to the caller instead of only being
/// logged: the log lives on another screen, and a disaster button that silently does
/// nothing is worse than one that refuses out loud. The UI localises these.
enum SosRefusal { notReady, busy, cooldown, alreadyActive }

/// How many unacknowledged takeovers we hold at once. The takeover renders ONE victim at a
/// time with a `1 / N` counter, so this is a memory bound, not a screen bound. When it is
/// full we drop the OLDEST — we never let a siren play with nothing queued behind it,
/// because the queue is what the STOP button and an inbound resolve both reach for.
const int kMaxAlertQueue = 20;

class MeshIdentity {
  final String selfId;
  final String name;
  final String? phone;
  final String role;      // 'civilian' | 'ngo'
  final bool onboarded;
  final String? ngoUid;   // Firebase Auth uid — only set once role == 'ngo' and signed in
  const MeshIdentity(this.selfId, this.name, this.phone,
      {this.role = 'civilian', this.onboarded = false, this.ngoUid});
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
        role: p.getString('role') ?? 'civilian', onboarded: p.getBool('onboarded') ?? false,
        ngoUid: p.getString('ngoUid'));
  }
  Future<void> setName(String v) async => _save(name: v);
  Future<void> setPhone(String v) async => _save(phone: v.trim().isEmpty ? null : v.trim());
  Future<void> setRole(String v) async => _save(role: v);
  Future<void> completeOnboarding() async => _save(onboarded: true);

  /// NGO SIGN-IN LAW: accounts are pre-provisioned in Firebase (no signup flow). This only
  /// authenticates and pulls the org name from Firestore — it never creates an account.
  Future<String> signInNgo(String email, String password) async {
    final cred = await fb.FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(), password: password);
    final uid = cred.user!.uid;
    final doc = await FirebaseFirestore.instance.collection('ngos').doc(uid).get();
    final orgName = (doc.data()?['name'] as String?) ?? cred.user!.email ?? 'NGO';
    final p = await SharedPreferences.getInstance();
    await p.setString('name', orgName);
    await p.setString('role', 'ngo');
    await p.setBool('onboarded', true);
    await p.setString('ngoUid', uid);
    state = MeshIdentity(state?.selfId ?? uid, orgName, state?.phone,
        role: 'ngo', onboarded: true, ngoUid: uid);
    return orgName;
  }

  Future<void> signOutNgo() async {
    await fb.FirebaseAuth.instance.signOut();
    final p = await SharedPreferences.getInstance();
    await p.setString('role', 'civilian');
    await p.remove('ngoUid');
    state = MeshIdentity(state?.selfId ?? '', state?.name ?? '', state?.phone,
      role: 'civilian', onboarded: true, ngoUid: null);
  }

  Future<void> _save({String? name, String? phone, String? role, bool? onboarded}) async {
    if (state == null) return;
    final p = await SharedPreferences.getInstance();
    final n = (name?.trim().isEmpty ?? true) ? state!.name : name!.trim();
    final ph = phone ?? state!.phone; final r = role ?? state!.role; final ob = onboarded ?? state!.onboarded;
    await p.setString('name', n);
    if (ph == null) { await p.remove('phone'); } else { await p.setString('phone', ph); }
    await p.setString('role', r); await p.setBool('onboarded', ob);
    state = MeshIdentity(state!.selfId, n, ph, role: r, onboarded: ob, ngoUid: state!.ngoUid);
  }
}
// ---------- MESH STATE ----------
class MeshState {
  final bool transportUp;
  final int peers, seenCount, notebookCount;
  final List<String> log;
  /// Unacknowledged inbound SOS takeovers, oldest first. A QUEUE, not a slot: during a
  /// burst the second victim's alarm used to be swallowed by the first one's open dialog.
  final List<AidPacket> alertQueue;
  final String? ownActiveSosId;
  final String? radioWarning;   // Bluetooth/Location OFF => mesh is deaf and blind
  const MeshState({
    this.transportUp = false, this.peers = 0, this.seenCount = 0,
    this.notebookCount = 0, this.log = const [], this.alertQueue = const [], this.ownActiveSosId,
    this.radioWarning,
  });

  /// The alert currently owed a takeover: the head of the queue.
  AidPacket? get alertPacket => alertQueue.isEmpty ? null : alertQueue.first;
  int get alertsWaiting => alertQueue.length;

  MeshState copyWith({bool? transportUp, int? peers, int? seenCount, int? notebookCount,
    List<String>? log, List<AidPacket>? alertQueue, String? ownActiveSosId, String? radioWarning,
    bool clearAlert = false, bool clearOwnSos = false, bool clearRadioWarning = false}) =>
      MeshState(
        transportUp: transportUp ?? this.transportUp, peers: peers ?? this.peers,
        seenCount: seenCount ?? this.seenCount, notebookCount: notebookCount ?? this.notebookCount,
        log: log ?? this.log,
        alertQueue: clearAlert ? const [] : (alertQueue ?? this.alertQueue),
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
  bool _firing = false;        // re-entrancy gate: fireSos awaits GPS, so it can overlap itself
  DateTime? _lastSosAt;        // origin timestamp for the cooldown
  bool _persisting = false;    // one snapshot writer at a time (see _persist)
  bool _persistDirty = false;  // state changed while writing => write once more
  Future<void> _lifecycle = Future.value(); // serialises start/stop/restart
  int _sirenGen = 0;           // invalidates delayed siren/haptic work after a silence
  bool _sirenPlaying = false;  // THE SIREN LAW: true only while an alert is queued behind it
  final Set<String> _flushing = {};   // endpoints with a flush in flight (anti double-send)
  final Set<String> _flushAgain = {}; // …and those that gained work while it ran

  MeshController(this.ref) : super(const MeshState());

  ProtocolEngine get engine => _engine!;
  /// UI builds can run BEFORE start()'s microtask creates the engine — every screen
  /// must check this before touching [engine]. (FIRST-FRAME LAW)
  bool get engineReady => _engine != null;
  NearbyTransport get transport => ref.read(transportProvider);

  void _log(String m) => state = state.copyWith(
      log: [m, ...state.log].take(50).toList());

  /// SNAPSHOT WRITER — serialised AND atomic.
  /// Callers fire this unawaited from six places, so a packet burst used to overlap two
  /// writeAsString() calls on one file: both truncate, the writes interleave, and the
  /// result is half-JSON. restore() treats corrupt JSON as "start empty", so a burst
  /// could SILENTLY ERASE the whole notebook (including the user's own live SOS) at the
  /// next launch — in an app whose entire promise is that the letter survives.
  /// Now: one writer at a time, coalescing later requests, and the file is swapped in by
  /// rename() so a kill mid-write leaves the previous good snapshot intact.
  Future<void> _persist() async {
    if (_engine == null) return;
    if (_persisting) { _persistDirty = true; return; }
    _persisting = true;
    try {
      do {
        _persistDirty = false;
        await _writeSnapshot();
      } while (_persistDirty); // absorbed a change mid-write => the last state still lands
    } finally {
      _persisting = false;
    }
  }

  Future<void> _writeSnapshot() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final tmp = File('${dir.path}/aidbridge_notebook.tmp');
      await tmp.writeAsString(_engine!.snapshot(), flush: true);
      await tmp.rename('${dir.path}/aidbridge_notebook.json'); // atomic on the same volume
    } catch (_) {/* persistence is best-effort, never crash the mesh for it */}
  }

  /// Serialises radio lifecycle work: two callers can never drive start/stop at once.
  Future<void> _serial(Future<void> Function() op) {
    final next = _lifecycle.then((_) => op());
    _lifecycle = next.then((_) {}, onError: (_) {}); // a failure must not poison the queue
    return next;
  }

  /// START — FULL transport lifecycle + notebook restore. (Role-change callers MUST stop() first.)
  /// Queued behind any in-flight start/stop: both shells kick this from initState, and a
  /// RESTART MESH tap during boot used to be able to drive transport.start() twice at once.
  Future<void> start() => _serial(_start);

  Future<void> _start() async {
    if (state.transportUp) { _log('mesh already up — start ignored'); return; }
    await ref.read(identityProvider.notifier).load();
    final id = ref.read(identityProvider)!;
    final freshEngine = _engine == null;
    _engine ??= ProtocolEngine(selfId: id.selfId, selfName: id.name, selfPhone: id.phone);
    // FIRST START ONLY. RESTART MESH must never re-read the disk over a live engine: the
    // snapshot is written unawaited, so a letter that landed seconds ago may not be on disk
    // yet — and restore() clears the notebook before refilling it, so the recovery button
    // could quietly delete the newest SOS. It would also wipe the in-session delivery books
    // and re-flood every connected peer with all 200 letters.
    if (freshEngine) {
      try {
        final f = File('${(await getApplicationDocumentsDirectory()).path}/aidbridge_notebook.json');
        if (await f.exists()) _engine!.restore(await f.readAsString());
      } catch (_) {}
    }
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
  /// ONE serialised unit: as two separate queued ops, anything waiting on the lifecycle
  /// lock could slip in between and drive start() while the radios were still going down.
  Future<void> restart() => _serial(() async {
    _log('MANUAL MESH RESTART requested');
    await _stop();
    await _start();
  });

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

  Future<void> stop() => _serial(_stop);

  Future<void> _stop() async {
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
    // ENQUEUE, don't overwrite: two victims 200ms apart both deserve a takeover. Dedup by
    // id so the same letter arriving from a second courier cannot double-book the screen.
    //
    // THE SIREN LAW: the alarm sounds if and only if something is queued behind it. A siren
    // with no queue entry cannot be reached by the STOP button or by the sender's own
    // resolve — RESTART MESH becomes the only off switch, which is exactly how a field test
    // found this. So we ALWAYS make room by dropping the oldest takeover (still in ALERTS)
    // rather than sounding an alarm nothing owns.
    if (r.siren && r.packet != null && !state.alertQueue.any((p) => p.id == r.packet!.id)) {
      var q = [...state.alertQueue, r.packet!];
      if (q.length > kMaxAlertQueue) {
        _log('ALERT QUEUE FULL — oldest takeover dropped (it stays listed in ALERTS)');
        q = q.sublist(q.length - kMaxAlertQueue); // keep the NEWEST: freshest emergency wins
      }
      state = state.copyWith(alertQueue: q);
      if (_sirenArmed) unawaited(_playSiren());
      unawaited(_notify('🆘 SOS: ${r.packet!.senderName}',
          'Distress signal received — TAP to open AidBridge'));
    }
    if (r.action == PacketAction.cancel) {
      _log('RESOLVED ${r.targetId} — ${r.packet?.senderName} is safe');
      // THE ALARM DIES WITH ITS CAUSE. Pull this victim out of the takeover queue wherever
      // they sit in it — nobody should have to tap a dead alarm quiet.
      if (r.targetId != null) unawaited(dismissAlert(r.targetId!));
    }
    if (r.uplink && r.packet != null) {
      final me = ref.read(identityProvider)?.name ?? 'unknown';
      unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
    }
    _refreshCounts(); _persist();
    _relayFrom(fromId); // fan-out to every other peer (never echo back — engine book handles it)
  }

  // ---------- FLUSH LAW (POC _doFlush as glue routine) ----------
  /// DELIVERY IS ONLY RECORDED ON A CONFIRMED SEND. sendTo() used to swallow radio
  /// errors and return normally, so a failed hand-off was still marked delivered — the
  /// letter then sat in the notebook, never re-offered to that peer. A packet that did
  /// not go out stays unmarked, so the next connect or heartbeat tries again.
  ///
  /// Concurrent callers COALESCE rather than overlap (two flushes to one endpoint would
  /// double-send) — but a request that arrives mid-flush is remembered and served by
  /// another lap, never dropped. Dropping it would strand a fresh packet until the next
  /// heartbeat, up to five minutes on a live link.
  Future<void> _flushPeer(String endpointId) async {
    if (!_flushing.add(endpointId)) { _flushAgain.add(endpointId); return; }
    try {
      var again = true;
      while (again) {
        _flushAgain.remove(endpointId);
        var failed = false;
        for (final p in engine.outboundFor(endpointId)) {
          final ok = await transport.sendTo(endpointId, p.toWire());
          if (!ok) {
            _log('SEND FAILED -> $endpointId: ${p.type.name} stays queued for retry');
            failed = true;
            break; // the link is suspect; leave the rest queued rather than burn them
          }
          engine.markDelivered(p.id, endpointId);
          _log('SENT (${p.type.name}${p.hops > 0 ? " hop" : ""}) ttl=${p.ttl} hops=${p.hops} -> $endpointId');
        }
        // Don't spin on a broken link; the transferFailure handler re-arms deliveries.
        again = !failed && _flushAgain.contains(endpointId);
      }
    } finally {
      _flushing.remove(endpointId);
      _flushAgain.remove(endpointId);
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
  /// Returns null when the letter was originated, or the reason it was refused.
  Future<SosRefusal?> fireSos({required SosCategory category, String text = ''}) async {
    // FIRST-FRAME LAW: the hold button is live before start()'s microtask builds the engine.
    if (_engine == null) { _log('Mesh still starting — SOS not sent'); return SosRefusal.notReady; }

    // RE-ENTRANCY GATE: this method awaits GPS for up to 4s, so two
    // fast taps could BOTH pass the ghost-law check below and originate two SOSes.
    // A cancel targets ONE id, so the second would ghost forever. One at a time.
    if (_firing) { _log('SOS already being sent — repeat press ignored'); return SosRefusal.busy; }

    final since = _lastSosAt == null ? null : DateTime.now().difference(_lastSosAt!);
    if (since != null && since < kSosCooldown) {
      _log('SOS COOLDOWN — ${(kSosCooldown - since).inSeconds + 1}s left');
      return SosRefusal.cooldown;
    }

    // GHOST LAW: one active own-SOS per device. If one exists (even restored
    // after a process kill), re-arm the visible state and refuse a second one.
    final existing = engine.ownActiveSos();
    if (existing != null) {
      _log('OWN SOS already ACTIVE — use I\'M SAFE first');
      state = state.copyWith(ownActiveSosId: existing.id);
      return SosRefusal.alreadyActive;
    }

    _firing = true;
    try {
      double? lat, lng;
      try { // GPS best-effort: null after ~4s, send NEVER blocked (indoor-law)
        final last = await Geolocator.getLastKnownPosition();
        final pos = last ?? await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(accuracy: LocationAccuracy.medium, timeLimit: const Duration(seconds: 4)));
        lat = pos.latitude; lng = pos.longitude;
      } catch (_) {}
      // Re-check AFTER the await: an inbound cancel or a restore could have landed.
      final raced = engine.ownActiveSos();
      if (raced != null) {
        _log('OWN SOS appeared while locating — not sending a second one');
        state = state.copyWith(ownActiveSosId: raced.id);
        return SosRefusal.alreadyActive;
      }
      final r = engine.sendSos(category: category, text: text, lat: lat, lng: lng);
      _lastSosAt = DateTime.now();
      _log(r.note); state = state.copyWith(ownActiveSosId: r.packet?.id);
      _refreshCounts(); _persist(); _flushAll();
      final me = ref.read(identityProvider)?.name ?? 'unknown';
      unawaited(ref.read(bridgeProvider).onPacket(r.packet!, me).then(_log));
    } finally {
      _firing = false; // never leave the button dead, even if GPS or the bridge threw
    }
    return null; // sent
  }

  Future<void> imSafe() async {
    if (_engine == null) { _log('Mesh still starting — try again in a moment'); return; }
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

  /// Acknowledge ONE alert — tapped by the user, or resolved remotely by its sender.
  /// The siren keeps running while other victims are still unacknowledged; it only stops
  /// when the queue empties.
  ///
  /// A resolve for something we never queued still enforces the siren law: if nothing is
  /// waiting, nothing may be screaming. That is the safety net under the whole alert path —
  /// a stray alarm can always be ended by the news that its owner is safe.
  Future<void> dismissAlert(String packetId) async {
    final rest = state.alertQueue.where((p) => p.id != packetId).toList();
    if (rest.length == state.alertQueue.length) {   // not ours to acknowledge
      if (rest.isEmpty && _sirenPlaying) await stopSiren();
      return;
    }
    if (rest.isEmpty) { await stopSiren(); return; } // stopSiren empties the queue
    state = state.copyWith(alertQueue: rest);
    _log('ALERT ACKNOWLEDGED — ${rest.length} still waiting');
  }

  /// REHEARSAL RESET (Settings): local amnesia between demo runs. Wipes this phone's
  /// notebook, dedup memory and delivery books, silences any alert, and rewrites the
  /// snapshot on disk so a relaunch does not resurrect it. Peers keep their own copies.
  Future<void> clearNotebook() async {
    if (_engine == null) return;
    _engine!.clearNotebook();
    await stopSiren();                              // kills the siren AND clears alertPacket
    state = state.copyWith(clearOwnSos: true);      // the SOS banner has nothing to point at
    _lastSosAt = null;                              // a fresh run must not inherit the cooldown
    _refreshCounts();
    await _persist();
    _log('NOTEBOOK CLEARED (this phone only — peers still carry their copies)');
  }

  /// NGO DASHBOARD RESET — deletes every incident from Firestore AND wipes this
  /// phone's local copy, so Incidents + Map both go back to zero.
  /// HONEST LIMIT: this is not a mesh-wide erase. Any nearby phone that is still
  /// carrying one of these SOS letters in its own notebook keeps it, and can hand
  /// it back to this phone (or re-uplink it) the next time they connect. Treat
  /// this as "reset the dashboard for the next run," not "this data is gone forever."
  Future<void> clearAllIncidents() async {
    await ref.read(bridgeProvider).clearAllCloudIncidents();
    if (_engine != null) {
      _engine!.clearNotebook();
      await stopSiren();
      state = state.copyWith(clearOwnSos: true);
      _lastSosAt = null;
      _refreshCounts();
      await _persist();
    }
    _log('ALL INCIDENTS CLEARED — cloud wiped + this phone\'s notebook wiped '
        '(peers still carrying old letters can resurface them)');
  }

  Future<void> _heartbeat() async {
    final r = _engine?.heartbeatTick(DateTime.now().toUtc());
    if (r != null) { _log(r.note); _flushAll(); _persist(); }
  }

  // ---------- Siren + haptics (a muted or pocketed phone must STILL wake its owner) ----------
  Future<void> _playSiren() async {
    final gen = _bumpSiren();
    _sirenPlaying = true;
    _buzzAlarm(gen);
    try {
      await _siren.setReleaseMode(ReleaseMode.loop);
      await _siren.setVolume(1.0);
      if (gen != _sirenGen) return; // silenced while the player was warming up
      await _siren.play(AssetSource(kSirenAsset));
    } catch (e) {
      _log('SIREN failed ($e) — vibration only');
    }
  }

  /// Every siren start/stop takes a ticket. Delayed work compares its ticket before
  /// acting, so nothing queued by a previous alarm can touch a newer one.
  int _bumpSiren() => ++_sirenGen;

  /// Spaced heavy impacts ≈ alarm pattern, no extra dependency, works on silent mode.
  void _buzzAlarm(int gen) {
    for (var i = 0; i < 6; i++) {
      Future.delayed(Duration(milliseconds: 400 * i), () {
        if (gen != _sirenGen) return; // silenced — a phone must stop buzzing when told to
        HapticFeedback.heavyImpact();
      });
    }
  }

  Future<void> sirenTest() async {
    final gen = _bumpSiren();
    _buzzAlarm(gen);
    try {
      await _siren.setReleaseMode(ReleaseMode.stop);
      await _siren.setVolume(1.0);
      await _siren.play(AssetSource(kSirenAsset));
      // TICKET CHECK: without it, this delayed stop() could cut off a REAL siren that
      // started in the meantime — leaving a live emergency showing on screen in silence.
      Future.delayed(const Duration(seconds: 2), () {
        if (gen != _sirenGen) return;
        _siren.stop();
      });
    } catch (e) {
      _log('SIREN TEST failed ($e) — vibration only');
    }
  }

  Future<void> stopSiren() async {
    _bumpSiren(); // invalidate pending haptics and any test's delayed stop()
    _sirenPlaying = false;
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