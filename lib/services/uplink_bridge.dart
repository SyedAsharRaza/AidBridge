import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../protocol/packet.dart';

class UplinkState {
  final bool ready;
  final int uploaded;   // packets shipped (or queued offline) this session
  final String? lastError;
  const UplinkState({this.ready = false, this.uploaded = 0, this.lastError});
}

final uplinkBridgeProvider =
StateNotifierProvider<UplinkBridge, UplinkState>((ref) => UplinkBridge());

class UplinkBridge extends StateNotifier<UplinkState> {
  UplinkBridge() : super(const UplinkState());
  bool _init = false;

  Future<void> bootstrap() async {
    if (_init) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      _init = true;
      state = UplinkState(ready: true, uploaded: state.uploaded);
    } catch (e) {
      state = UplinkState(ready: false, lastError: '$e'); // e.g. wrong google-services.json — surfaces in UI/log
    }
  }

  /// One-way uplink LAW: sos + cancel only. CHAT NEVER LEAVES THE MESH (privacy partition).
  Future<void> upload(AidPacket p) async {
    if (p.type == PacketType.chat) return;
    await bootstrap();
    if (!_init) return;
    try {
      await FirebaseFirestore.instance.collection('sos').doc(p.id).set({
        ...p.toJson(),
        'uploadedAt': DateTime.now().millisecondsSinceEpoch,
      });
      state = UplinkState(ready: true, uploaded: state.uploaded + 1);
    } catch (e) {
      state = UplinkState(ready: true, uploaded: state.uploaded, lastError: '$e');
    }
  }
}