import 'dart:convert';

/// AidBridge packet — the letter that travels the mesh.
/// ORIGIN FIELDS ARE IMMUTABLE. A relay may ONLY produce a copy with
/// ttl-1 / hops+1 via [forRelay]. Nothing else. Ever. (LAW)
const int kProtocolVersion = 1;

/// Hard cap on any free-text field. Enforced on BOTH ends: outbound so we never emit
/// an oversized letter, inbound so a hostile peer cannot use us as an amplifier by
/// pushing a megabyte of text through a 4-hop flood.
const int kMaxTextLen = 500;

/// Truncate without ever splitting a surrogate pair — half an emoji is a lone
/// surrogate, which breaks JSON round-trips on some decoders.
String clampText(String t) {
  if (t.length <= kMaxTextLen) return t;
  var end = kMaxTextLen;
  final c = t.codeUnitAt(end - 1);
  if (c >= 0xD800 && c <= 0xDBFF) end -= 1; // high surrogate would be orphaned
  return t.substring(0, end);
}

enum PacketType { sos, cancel, chat }
enum SosCategory { medical, waterFood, rescue, custom }

const Map<PacketType, String> _typeWire = {
  PacketType.sos: 'sos', PacketType.cancel: 'cancel', PacketType.chat: 'chat',
};
const Map<SosCategory, String> _catWire = {
  SosCategory.medical: 'MEDICAL', SosCategory.waterFood: 'WATER_FOOD',
  SosCategory.rescue: 'RESCUE', SosCategory.custom: 'CUSTOM',
};

class AidPacket {
  final String id;          // unique fingerprint == Firestore doc id
  final int version;        // kProtocolVersion
  final PacketType type;
  final String senderId;    // persistent random device id
  final String senderName;
  final String? phone;      // origin's contact — optional, immutable
  final SosCategory? category; // sos only
  final String text;        // sos note / chat body (cancel: empty)
  final double? lat;
  final double? lng;
  final int createdAt;      // epoch seconds (UTC)
  final String? targetId;   // cancel only — id of the SOS being resolved
  final int ttl;
  final int hops;

  const AidPacket({
    required this.id, required this.type, required this.senderId,
    required this.senderName, required this.createdAt,
    required this.ttl, required this.hops,
    this.version = kProtocolVersion,
    this.phone, this.category, this.text = '', this.lat, this.lng, this.targetId,
  });

  /// The ONLY legal mutation. (TTL wall law, test T11)
  AidPacket forRelay() => AidPacket(
    id: id, version: version, type: type, senderId: senderId,
    senderName: senderName, phone: phone, category: category, text: text,
    lat: lat, lng: lng, createdAt: createdAt, targetId: targetId,
    ttl: ttl - 1, hops: hops + 1,
  );

  Map<String, Object?> toJson() => {
    'v': version, 'id': id, 'type': _typeWire[type],
    'senderId': senderId, 'senderName': senderName,
    if (phone != null) 'phone': phone,
    if (category != null) 'category': _catWire[category],
    'text': text,
    if (lat != null) 'lat': lat, if (lng != null) 'lng': lng,
    'createdAt': createdAt,
    if (targetId != null) 'targetId': targetId,
    'ttl': ttl, 'hops': hops,
  };

  String toWire() => jsonEncode(toJson());


  /// Tolerant decode: garbage in → null out. Never throws on wire data.
  static AidPacket? fromWire(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      PacketType? t = PacketType.values.firstWhere(
              (e) => _typeWire[e] == m['type'], orElse: () => PacketType.chat);
      final id = m['id'], senderId = m['senderId'], createdAt = num.tryParse('${m['createdAt']}');
      final ttl = num.tryParse('${m['ttl']}'), hops = num.tryParse('${m['hops']}');
      if (id is! String || id.isEmpty || senderId is! String || senderId.isEmpty ||
          createdAt == null || ttl == null || hops == null || (m['type'] != 'sos' && m['type'] != 'cancel' && m['type'] != 'chat')) {
        return null;
      }
      SosCategory? cat;
      for (final e in SosCategory.values) { if (_catWire[e] == m['category']) cat = e; }
      return AidPacket(
        id: id, version: num.tryParse('${m['v']}')?.toInt() ?? kProtocolVersion,
        type: t, senderId: senderId,
        senderName: '${m['senderName'] ?? 'Unknown'}',
        phone: m['phone'] as String?, text: clampText('${m['text'] ?? ''}'),
        lat: m['lat'] == null ? null : num.tryParse('${m['lat']}')?.toDouble(),
        lng: m['lng'] == null ? null : num.tryParse('${m['lng']}')?.toDouble(),
        createdAt: createdAt.toInt(),
        targetId: m['targetId'] as String?,
        ttl: ttl.toInt(), hops: hops.toInt(), category: cat,
      );
    } catch (_) { return null; }
  }
}