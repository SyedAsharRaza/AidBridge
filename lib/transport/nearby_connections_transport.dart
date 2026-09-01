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
    try { await Nearby().stopAdvertising(); } catch (_) {}
    try { await Nearby().stopDiscovery(); } catch (_) {}
    try { await Nearby().stopAllEndpoints(); } catch (_) {}
    _found.clear(); _connected.clear(); _pending.clear(); _sendChains.clear();

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
    try {
      _adv = await Nearby().startAdvertising(
        _myName, kStrategy, serviceId: kServiceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      _log('Advertising ${_adv ? "ON" : "FAILED"}');
    } catch (e) { _log('ADVERTISE ERROR: $e'); }
    try {
      _disc = await Nearby().startDiscovery(
        _myName, kStrategy, serviceId: kServiceId,
        onEndpointFound: (id, name, serviceId) => _onEndpointFound(id, name),
        onEndpointLost: (id) {
          _found.remove(id); // no ghosts (only fires while discovering — known platform quirk)
          _events.add(TransportEvent(EventType.endpointLost, endpointId: id));
        },
      );
      _log('Discovery ${_disc ? "ON" : "FAILED"}');
    } catch (e) { _log('DISCOVERY ERROR: $e'); }
    _events.add(const TransportEvent(EventType.transportUp));
  }

  // ---------- Connection lifecycle (auto-everything, 8009-proof) ----------
  void _onEndpointFound(String id, String name) {
    _found[id] = name;
    _events.add(TransportEvent(EventType.endpointFound, endpointId: id, endpointName: name));
    // SYMMETRY-BREAKER: exactly ONE side initiates (lexicographic on "name·id"),
    // so two phones never collision-request each other. selfId-suffixed names guarantee inequality.
    if (_connected.contains(id) || _pending.contains(id)) return; // never touch live/pending — 8009 law
    if (_myName.compareTo(name) >= 0) return; // the smaller name requests; the other auto-accepts
    _pending.add(id);
    Nearby().requestConnection(
      _myName, id,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    ).then((_) => _log('Requesting -> $name')).catchError((e) {
      _pending.remove(id);
      _log('REQUEST ERROR to $name: $e'); // e.g. peer vanished; its loss, notebook outlives it
    });
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) { // (plugin's own typo — keep exact)
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          _events.add(TransportEvent(EventType.payload,
              endpointId: endpointId, json: utf8.decode(payload.bytes!)));
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
    );
  }

  void _onConnectionResult(String id, Status status) {
    _pending.remove(id);
    if (status == Status.CONNECTED) {
      final name = _found[id] ?? id;
      _found.remove(id);        // connected peers leave the found list for good (GHOST FIX)
      _connected.add(id);
      _events.add(TransportEvent(EventType.peerConnected, endpointId: id, endpointName: name));
    } else {
      _log('Connection to $id: $status (will retry if it reappears)');
    }
  }

  void _onDisconnected(String id) {
    _connected.remove(id);
    _sendChains.remove(id);
    _events.add(TransportEvent(EventType.peerDisconnected, endpointId: id, endpointName: _connected.contains(id) ? null : id));
  }

  // ---------- Serial-send law ----------
  @override
  Future<void> sendTo(String endpointId, String payloadJson) {
    Future<void> job() => Nearby()
        .sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(payloadJson)))
        .then((_) {})
        .catchError((Object e) { _log('SEND ERROR -> $endpointId: $e'); });
    final prev = _sendChains[endpointId] ?? Future.value();
    final next = prev.then((_) => job());
    _sendChains[endpointId] = next;
    return next;
  }

  // ---------- FULL STOP (before ANY role/strategy change; 8009 law) ----------
  @override
  Future<void> stop() async {
    try { await Nearby().stopAllEndpoints(); } catch (_) {}
    try { await Nearby().stopAdvertising(); } catch (_) {}
    try { await Nearby().stopDiscovery(); } catch (_) {}
    _connected.clear(); _pending.clear(); _sendChains.clear(); _found.clear();
    _adv = false; _disc = false;
    if (_serviceOn) await _stopService();
    _events.add(const TransportEvent(EventType.transportDown));
    _log('FULL STOP complete');
  }

  // ---------- Foreground service (v10 pattern, POC-verified) ----------
  Future<void> _startService() async {
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
  }

  Future<void> _stopService() async {
    _serviceOn = false;
    await FlutterForegroundTask.stopService();
  }
}