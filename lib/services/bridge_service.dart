import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../protocol/packet.dart';

/// THE BRIDGE: any AidBridge phone with internet auto-uplinks SOS packets.
/// LAW: sos+cancel only (chat never crosses — privacy partition).
/// GENIUS OF SIMPLICITY: id == Firestore doc id => duplicates are impossible
/// (idempotent set+merge), and Firestore's native offline queue IS our outbox:
/// writes made without internet sit locally and flush when the satellite reappears.
class BridgeService {
  FirebaseFirestore? _db;
  bool ready = false;
  String status = 'bridge: idle';

  Future<void> init() async {
    try {
      await Firebase.initializeApp(); // configured natively from google-services.json
      _db = FirebaseFirestore.instance;
      ready = true;
      status = 'BRIDGE READY — uplinks on sight';
    } catch (e) {
      ready = false; status = 'BRIDGE DISABLED: $e';
    }
  }

  Future<String> onPacket(AidPacket p, String uploaderName) async {
    if (!ready) return 'bridge offline — skipped';
    try {
      if (p.type == PacketType.sos) {
        await _db!.collection('sos').doc(p.id).set({
          'id': p.id, 'senderId': p.senderId, 'senderName': p.senderName,
          if (p.phone != null) 'phone': p.phone,
          'category': p.category?.name, 'text': p.text,
          if (p.lat != null) 'lat': p.lat, if (p.lng != null) 'lng': p.lng,
          'createdAt': p.createdAt, 'hops': p.hops, 'ttl': p.ttl,
          'status': 'active', 'uploader': uploaderName,
          'uploadedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return 'UPLINK ☁️ SOS ${p.id} -> cloud';
      }
      if (p.type == PacketType.cancel && p.targetId != null) {
        await _db!.collection('sos').doc(p.targetId).set({
          'status': 'resolved', 'resolvedBy': p.senderName,
          'resolvedAt': p.createdAt, 'uploader': uploaderName,
        }, SetOptions(merge: true));
        return 'UPLINK ☁️ RESOLVE ${p.targetId} -> cloud';
      }
      return 'bridge: packet not uplinkable (chat ignored by law)';
    } catch (e) {
      return 'uplink error: $e';
    }
  }
}