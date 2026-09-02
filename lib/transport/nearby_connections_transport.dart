import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'nearby_transport.dart';

const String kServiceId = "com.aidbridge.app";
const Strategy kStrategy = Strategy.P2P_CLUSTER; // T14-verified. Do not change silently.

/// TRANSPORT CONTROL FRAMES — swallowed here, NEVER handed to the protocol engine
/// (otherwise every ping would log as 'GARBAGE packet dropped'). Exact literals:
/// we generate them, so string equality is the cheapest correct test.
const String kPingFrame = '{"__ab":"ping"}';
const String kPongFrame = '{"__ab":"pong"}';

/// Self-healing knobs. Android kills radios silently and the plugin's disconnect
/// callback is unreliable — so we verify instead of trusting. (GHOST LAW)
const Duration kWatchdogEvery = Duration(seconds: 10);
const Duration kPingEvery = Duration(seconds: 20);
const Duration kPeerSilence = Duration(seconds: 70);   // >3 missed pings => ghost
const Duration kPendingTimeout = Duration(seconds: 15);
const Duration kNoPeerRefresh = Duration(seconds: 45); // dead-air => full radio refresh
const int kMaxConnectTries = 3;

/// NO PLUGIN CALL MAY HANG FOREVER. Every Nearby() future below is bounded, because a
/// wedged native stack that never completes would freeze the very self-healing loops that
/// exist to un-wedge it — and freeze stop(), which is what RESTART MESH waits on.
const Duration kRadioOp = Duration(seconds: 10);
const Duration kPingTimeout = Duration(seconds: 8);

/// Minimal task handler — its only job is to EXIST so Android treats us as an
/// active foreground task (anti OEM-killer). Does NOT survive swipe-from-recents:
/// that is a confirmed platform limitation, not a bug.
@pragma('vm:entry-point')
void aidbridgeServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_MeshTaskHandler());
}

class _MeshTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class NearbyConnectionsTransport implements NearbyTransport {
  final _events = StreamController<TransportEvent>.broadcast();
  final Map<String, String> _found = {};          // endpointId -> display name
  final Set<String> _connected = {};
  final Set<String> _pending = {};                 // request in flight (gate vs 8009)
  final Map<String, Future<void>> _sendChains = {};// serialized sends per endpoint (POC race fix)
  final Map<String, DateTime> _pendingSince = {};  // when the request went out (timeout gate)
  final Map<String, int> _tries = {};              // connect attempts per endpoint
  final Map<String, DateTime> _lastHeard = {};     // last byte received (liveness truth)
  Timer? _watchdog;
  Timer? _liveness;
  bool _running = false;                           // guards timers after stop()
  bool _ticking = false;                           // one watchdog pass at a time (see _watchdogTick)
  DateTime _lastRadioProgress = DateTime.now();    // last time a peer was seen/connected
  String _myName = '';
  bool _adv = false;
  bool _disc = false;
  bool _serviceOn = false;

  void _log(String m) => _events.add(TransportEvent(EventType.log, message: m));
  @override Stream<TransportEvent> get events => _events.stream;
  @override Set<String> get connectedEndpoints => Set.unmodifiable(_connected);
  @override bool get isAdvertising => _adv;
  @override bool get isDiscovering => _disc;

  // ---------- START — order is LAW ----------
  @override
  Future<void> start(String endpointName) async {
    _myName = endpointName;
    // 1) HOT-RESTART KILLER: kill leftover native state before anything ("hot restart -> ALREADY_ADVERTISING" scar)
    try { await Nearby().stopAdvertising().timeout(kRadioOp); } catch (_) {}
    try { await Nearby().stopDiscovery().timeout(kRadioOp); } catch (_) {}
    try { await Nearby().stopAllEndpoints().timeout(kRadioOp); } catch (_) {}
    _found.clear(); _connected.clear(); _pending.clear(); _sendChains.clear();
    _pendingSince.clear(); _tries.clear(); _lastHeard.clear();
    _running = true;

    // 2) Permissions with RESULT CHECKS (we never hope; OEM phones need manual grant sometimes)
    final statuses = await [
      Permission.location, Permission.bluetooth, Permission.bluetoothAdvertise,
      Permission.bluetoothConnect, Permission.bluetoothScan, Permission.nearbyWifiDevices,
    ].request();
    for (final e in statuses.entries) {
      if (!e.value.isGranted) {
        _log('PERMISSION not granted: ${e.key} — grant it manually in Settings on this phone.');
      }
    }

    // 3) Anti-killer service + battery exemption (mandatory every session)
    await _startService();

    // 4) Advertise + Discover simultaneously (CLUSTER config passed T14 hardware test)
    await _beginAdvertising();
    await _beginDiscovery();

    // 5) SELF-HEALING TIMERS: watchdog revives dead radios, liveness buries ghosts.
    _lastRadioProgress = DateTime.now();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(kWatchdogEvery, (_) => unawaited(_watchdogTick()));
    _liveness?.cancel();
    _liveness = Timer.periodic(kPingEvery, (_) => unawaited(_pingAll()));
    _events.add(const TransportEvent(EventType.transportUp));
  }

  /// ALWAYS STOPS BEFORE IT STARTS. A start() that timed out on our side may still have
  /// succeeded natively, and starting a radio that is already live returns
  /// ALREADY_ADVERTISING — which would latch _adv=false and put the watchdog in a permanent
  /// loop, restarting a radio that was working the whole time.
  Future<void> _beginAdvertising() async {
    try {
      try { await Nearby().stopAdvertising().timeout(kRadioOp); } catch (_) {}
      _adv = await Nearby().startAdvertising(
        _myName, kStrategy, serviceId: kServiceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      ).timeout(kRadioOp, onTimeout: () => false);
      _log('Advertising ${_adv ? "ON" : "FAILED"}');
    } catch (e) { _adv = false; _log('ADVERTISE ERROR: $e'); }
  }

  Future<void> _beginDiscovery() async {
    try {
      try { await Nearby().stopDiscovery().timeout(kRadioOp); } catch (_) {}
      _disc = await Nearby().startDiscovery(
        _myName, kStrategy, serviceId: kServiceId,
        onEndpointFound: (id, name, serviceId) => _onEndpointFound(id, name),
        onEndpointLost: (id) {
          _found.remove(id); // no ghosts (only fires while discovering — known platform quirk)
          // FRESH BUDGET ON RETURN: without this, _request's "will retry if rediscovered"
          // promise was a lie. The try counter outlived the peer, so someone who failed
          // three times was blacklisted for the whole session — even after walking back
          // into range, which is exactly when a survivor needs the link most.
          _tries.remove(id);
          _events.add(TransportEvent(EventType.endpointLost, endpointId: id));
        },
      ).timeout(kRadioOp, onTimeout: () => false);
      _log('Discovery ${_disc ? "ON" : "FAILED"}');
    } catch (e) { _disc = false; _log('DISCOVERY ERROR: $e'); }
  }

  // ---------- Connection lifecycle (auto-everything, 8009-proof) ----------
  void _onEndpointFound(String id, String name) {
    _found[id] = name;
    _lastRadioProgress = DateTime.now(); // radios ARE working — no refresh needed
    _events.add(TransportEvent(EventType.endpointFound, endpointId: id, endpointName: name));
    // SYMMETRY-BREAKER: exactly ONE side initiates (lexicographic on "name·id"),
    // so two phones never collision-request each other. selfId-suffixed names guarantee inequality.
    if (_myName.compareTo(name) >= 0) return; // the smaller name requests; the other auto-accepts
    _request(id, name);
  }

  /// Bounded, retrying connect. One failed request used to mean "never connected" —
  /// now it costs a retry, not the peer. (RETRY LAW)
  void _request(String id, String name) {
    if (!_running) return;
    if (_connected.contains(id) || _pending.contains(id)) return; // never touch live/pending — 8009 law
    final tries = (_tries[id] ?? 0) + 1;
    if (tries > kMaxConnectTries) {
      _log('GIVING UP on $name after $kMaxConnectTries tries (will retry if rediscovered)');
      return;
    }
    _tries[id] = tries;
    _pending.add(id);
    _pendingSince[id] = DateTime.now();
    Nearby().requestConnection(
      _myName, id,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    ).then((_) => _log('Requesting -> $name (try $tries)')).catchError((e) {
      _pending.remove(id); _pendingSince.remove(id);
      _log('REQUEST ERROR to $name: $e — retrying in 2s');
      Timer(const Duration(seconds: 2), () {
        if (_running && !_connected.contains(id)) _request(id, name);
      });
    });
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) { // (plugin's own typo — keep exact)
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          final raw = utf8.decode(payload.bytes!);
          _lastHeard[endpointId] = DateTime.now(); // ANY byte proves this peer is alive
          if (raw == kPingFrame) {                 // answer, never forward
            unawaited(_send(endpointId, kPongFrame, swallow: true));
            return;
          }
          if (raw == kPongFrame) return;           // liveness proof already recorded
          _events.add(TransportEvent(EventType.payload, endpointId: endpointId, json: raw));
        }
      },
      onPayloadTransferUpdate: (endpointId, update) {
        // Plugin CANNOT map a failure to a packet id (POC law).
        // Signal glue -> engine.downgradeEndpoint(): global retry next connect; receiver dedup absorbs re-sends.
        if (update.status == PayloadStatus.FAILURE) {
          _events.add(TransportEvent(EventType.transferFailure,
              endpointId: endpointId, message: 'Transfer failure to $endpointId — deliveries re-armed'));
        }
      },
    ).catchError((Object e) {
      // An accept CAN legitimately fail (8009 crossfire, peer vanished mid-handshake). Left
      // unhandled it was an invisible zone error — and "why did nothing connect?" is the one
      // question a silent log can never answer.
      _log('ACCEPT ERROR from $id: $e');
      return false;
    });
  }

  void _onConnectionResult(String id, Status status) {
    _pending.remove(id); _pendingSince.remove(id);
    if (status == Status.CONNECTED) {
      final name = _found[id] ?? id;
      _found.remove(id);        // connected peers leave the found list for good (GHOST FIX)
      _tries.remove(id);        // fresh budget if this peer ever drops and returns
      _connected.add(id);
      _lastHeard[id] = DateTime.now();
      _lastRadioProgress = DateTime.now();
      _events.add(TransportEvent(EventType.peerConnected, endpointId: id, endpointName: name));
    } else {
      final name = _found[id];
      _log('Connection to $id: $status${name == null ? "" : " — retrying in 3s"}');
      if (name != null) {
        Timer(const Duration(seconds: 3), () {
          if (_running && !_connected.contains(id)) _request(id, name);
        });
      }
    }
  }

  void _onDisconnected(String id) {
    final name = _connected.contains(id) ? id : null; // read BEFORE removing (log-accuracy fix)
    _connected.remove(id);
    _sendChains.remove(id);
    _lastHeard.remove(id);
    _events.add(TransportEvent(EventType.peerDisconnected, endpointId: id, endpointName: name));
  }

  /// A peer the OS still calls "connected" but which no longer answers is worse than
  /// a disconnected one: the engine's delivery book believes packets landed. Bury it.
  Future<void> _forceDisconnect(String id) async {
    _connected.remove(id);
    _sendChains.remove(id);
    _lastHeard.remove(id);
    _pending.remove(id); _pendingSince.remove(id);
    _found.remove(id);
    try { await Nearby().disconnectFromEndpoint(id); } catch (_) {}
    _events.add(TransportEvent(EventType.peerDisconnected, endpointId: id, endpointName: id));
  }

  // ---------- LIVENESS: ping every peer, drop the silent ones ----------
  Future<void> _pingAll() async {
    if (!_running) return;
    final now = DateTime.now();
    for (final id in List.of(_connected)) {
      final heard = _lastHeard[id] ?? now;
      if (now.difference(heard) > kPeerSilence) {
        _log('LIVENESS: $id silent ${now.difference(heard).inSeconds}s — dropping ghost');
        await _forceDisconnect(id);
        continue;
      }
      try {
        // BOUNDED: this loop is sequential, so one send that never completes would stall the
        // ping for every other peer and silently retire the whole liveness system. A hang is
        // indistinguishable from a dead link, so we treat it as one.
        await _send(id, kPingFrame, swallow: false).timeout(kPingTimeout);
      } catch (e) {
        _log('PING FAILED -> $id ($e) — dropping ghost');
        await _forceDisconnect(id);
      }
    }
  }

  // ---------- WATCHDOG: revive dead radios, free stuck slots ----------
  Future<void> _watchdogTick() async {
    if (!_running || _ticking) return;
    // ONE PASS AT A TIME. The radio refresh below sets _adv/_disc false and then awaits
    // several plugin calls. A second tick landing inside that window read "advertising is
    // down" and fired a SECOND startAdvertising at the same radio — ALREADY_ADVERTISING,
    // false, and the watchdog latched into endlessly restarting a healthy radio.
    _ticking = true;
    try {
      await _watchdogPass();
    } finally {
      _ticking = false; // a thrown pass must never disable the watchdog for good
    }
  }

  Future<void> _watchdogPass() async {
    final now = DateTime.now();

    // a) stuck pending requests block all future attempts to that peer — free them
    for (final e in Map.of(_pendingSince).entries) {
      if (now.difference(e.value) > kPendingTimeout) {
        _pending.remove(e.key); _pendingSince.remove(e.key);
        _log('PENDING timeout for ${e.key} — slot freed');
        final name = _found[e.key];
        if (name != null) _request(e.key, name);
      }
    }

    // b) a radio that reported FAILED/threw stays dead forever unless we restart it
    if (!_adv) { _log('WATCHDOG: advertising is down — restarting'); await _beginAdvertising(); }
    if (!_disc) { _log('WATCHDOG: discovery is down — restarting'); await _beginDiscovery(); }

    // c) THE "reopen the app to connect" CURE: total dead air means the native stack
    //    is wedged even though it claims to be running. Recycle both radios.
    if (_connected.isEmpty && _found.isEmpty &&
        now.difference(_lastRadioProgress) > kNoPeerRefresh) {
      _log('WATCHDOG: ${kNoPeerRefresh.inSeconds}s of dead air — full radio refresh');
      _adv = false; _disc = false;
      await _beginAdvertising(); // each one stops the native radio before restarting it
      await _beginDiscovery();
      _lastRadioProgress = DateTime.now(); // give the fresh radios a full window
    }
  }

  // ---------- Serial-send law ----------
  /// One chain per endpoint (anti double-send race). The STORED chain never carries
  /// an error, so a single failed send can no longer poison every later send (#36).
  /// Returns whether the radio actually accepted the bytes — a swallowed error used to
  /// look identical to success, which let the mesh mark undelivered letters as delivered.
  Future<bool> _send(String endpointId, String payload, {required bool swallow}) {
    Future<bool> job() {
      final f = Nearby().sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(payload)));
      if (!swallow) return f.then((_) => true);
      return f.then((_) => true).catchError((Object e) {
        _log('SEND ERROR -> $endpointId: $e');
        return false;
      });
    }
    final prev = _sendChains[endpointId] ?? Future.value();
    final next = prev.then((_) => job(), onError: (_) => job());
    _sendChains[endpointId] = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<bool> sendTo(String endpointId, String payloadJson) =>
      _send(endpointId, payloadJson, swallow: true);

  // ---------- FULL STOP (before ANY role/strategy change; 8009 law) ----------
  @override
  Future<void> stop() async {
    _running = false;
    _watchdog?.cancel(); _watchdog = null;
    _liveness?.cancel(); _liveness = null;
    // BOUNDED: restartMesh() awaits stop() before start(). One hung plugin call here would
    // hold the lifecycle lock forever, leaving the recovery button permanently dead.
    try { await Nearby().stopAllEndpoints().timeout(kRadioOp); } catch (_) {}
    try { await Nearby().stopAdvertising().timeout(kRadioOp); } catch (_) {}
    try { await Nearby().stopDiscovery().timeout(kRadioOp); } catch (_) {}
    _connected.clear(); _pending.clear(); _sendChains.clear(); _found.clear();
    _pendingSince.clear(); _tries.clear(); _lastHeard.clear();
    _adv = false; _disc = false;
    if (_serviceOn) await _stopService();
    _events.add(const TransportEvent(EventType.transportDown));
    _log('FULL STOP complete');
  }

  // ---------- Foreground service (v10 pattern, POC-verified) ----------
  /// BEST-EFFORT, NEVER FATAL. This runs BEFORE the radios come up, so an exception in here
  /// used to abort start() outright: a denied notification or a hostile OEM battery dialog
  /// would leave the phone with NO MESH AT ALL — the entire feature traded away for a
  /// notification. The service only helps us survive backgrounding; relaying works without it.
  Future<void> _startService() async {
    try {
      final notif = await FlutterForegroundTask.checkNotificationPermission();
      if (notif != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (Platform.isAndroid && !(await FlutterForegroundTask.isIgnoringBatteryOptimizations)) {
        _log('Requesting battery-optimization exemption — ACCEPT this dialog (anti-killer)');
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'aidbridge_relay_channel',
          channelName: 'AidBridge Relay Service',
          channelDescription: 'Keeps the disaster mesh alive in background',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(30000),
          autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true,
        ),
      );
      final result = await FlutterForegroundTask.startService(
        serviceId: 100,
        notificationTitle: 'AidBridge mesh active',
        notificationText: 'Relaying SOS packets. Keep this app alive.',
        callback: aidbridgeServiceCallback,
      );
      _serviceOn = true;
      _log('Foreground service started: $result');
    } catch (e) {
      _serviceOn = false;
      _log('FOREGROUND SERVICE UNAVAILABLE: $e — mesh still starting (may sleep in background)');
    }
  }

  Future<void> _stopService() async {
    _serviceOn = false;
    try { await FlutterForegroundTask.stopService(); } catch (_) {}
  }
}