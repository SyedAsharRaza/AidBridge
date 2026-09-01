/// The single translation layer between pure protocol logic and the
/// nearby_connections plugin. Batch-3 implements NearbyConnectionsTransport.
/// Engine/glue NEVER imports the plugin — only this file. (ARCHITECTURE LAW)
enum EventType {
  endpointFound, endpointLost, peerConnected, peerDisconnected,
  payload, transferFailure, transportUp, transportDown, log,
}

class TransportEvent {
  final EventType type;
  final String? endpointId;
  final String? endpointName;
  final String? json;   // payload events: raw wire string
  final String message; // human log line
  const TransportEvent(this.type,
      {this.endpointId, this.endpointName, this.json, this.message = ''});
}

abstract class NearbyTransport {
  /// Request permissions, clean leftover native state (hot-restart law),
  /// then start advertise+discover (CLUSTER) with auto-accept/auto-connect.
  Future<void> start(String endpointName);

  /// FULL STOP: disconnectAll + stopAdvertising + stopDiscovery, atomically.
  /// MUST be called before ANY role/mode change and at startup. (8009 law)
  Future<void> stop();

  /// Serialized per endpoint in the implementation (anti double-send race).
  Future<void> sendTo(String endpointId, String payloadJson);

  /// Currently connected endpoint ids (glue flushes these).
  Set<String> get connectedEndpoints;

  Stream<TransportEvent> get events;
  bool get isAdvertising;
  bool get isDiscovering;
}