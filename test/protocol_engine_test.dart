import 'dart:convert';

import 'package:aidbridge/protocol/packet.dart';
import 'package:aidbridge/protocol/protocol_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The routing engine is pure Dart on purpose (no plugin imports) — which is exactly
/// why the laws that decide whether a stranger's SOS reaches a rescuer can be proven
/// on a laptop, with no phones, no radios and no internet.

/// A letter arriving from some other device on the mesh.
String _wireFrom({
  required String id,
  required String senderId,
  PacketType type = PacketType.sos,
  int ttl = kMaxTtl,
  int hops = 0,
  String? targetId,
  int? createdAt,
}) =>
    AidPacket(
      id: id,
      type: type,
      senderId: senderId,
      senderName: 'Stranger',
      category: type == PacketType.sos ? SosCategory.rescue : null,
      text: type == PacketType.chat ? 'hello' : 'trapped',
      targetId: targetId,
      createdAt: createdAt ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      ttl: ttl,
      hops: hops,
    ).toWire();

ProtocolEngine _engine() => ProtocolEngine(selfId: 'me', selfName: 'Me', selfPhone: '0300');

void main() {
  final now = DateTime.now().toUtc();

  group('packet wire format', () {
    test('survives a round trip unchanged', () {
      final p = AidPacket(
        id: 'x1', type: PacketType.sos, senderId: 's1', senderName: 'Ali',
        phone: '0311', category: SosCategory.medical, text: 'leg broken',
        lat: 24.86, lng: 67.0, createdAt: 1700000000, ttl: 4, hops: 1,
      );
      final back = AidPacket.fromWire(p.toWire())!;
      expect(back.id, p.id);
      expect(back.type, PacketType.sos);
      expect(back.category, SosCategory.medical);
      expect(back.phone, '0311');
      expect(back.lat, closeTo(24.86, 1e-9));
      expect(back.ttl, 4);
      expect(back.hops, 1);
    });

    test('garbage in => null out, never a throw', () {
      expect(AidPacket.fromWire('not json at all'), isNull);
      expect(AidPacket.fromWire('[]'), isNull);
      expect(AidPacket.fromWire('{"id":"a"}'), isNull);              // missing required fields
      expect(AidPacket.fromWire('{"id":"a","senderId":"b","createdAt":1,'
          '"ttl":4,"hops":0,"type":"virus"}'), isNull);              // unknown type is NOT chat
    });

    test('forRelay is the ONLY legal mutation: ttl-1 / hops+1', () {
      final p = AidPacket(
        id: 'x1', type: PacketType.sos, senderId: 's1', senderName: 'Ali',
        phone: '0311', category: SosCategory.rescue, text: 'help',
        lat: 1.5, lng: 2.5, createdAt: 1700000000, ttl: 4, hops: 0,
      );
      final r = p.forRelay();
      expect(r.ttl, 3);
      expect(r.hops, 1);
      // every origin field is untouched
      expect(r.id, p.id);
      expect(r.senderId, p.senderId);
      expect(r.senderName, p.senderName);
      expect(r.phone, p.phone);
      expect(r.text, p.text);
      expect(r.lat, p.lat);
      expect(r.createdAt, p.createdAt);
    });
  });

  group('ingress funnel', () {
    test('a stranger SOS raises the siren once, a repeat is a duplicate', () {
      final e = _engine();
      final wire = _wireFrom(id: 'p1', senderId: 'them');

      final first = e.ingest('e1', wire, now);
      expect(first.action, PacketAction.newSos);
      expect(first.siren, isTrue);
      expect(first.uplink, isTrue);

      final second = e.ingest('e2', wire, now); // same letter, different courier
      expect(second.action, PacketAction.duplicate);
      expect(second.siren, isFalse);
      expect(e.notebook.length, 1);
    });

    test('my own packet echoed back to me is ignored', () {
      final e = _engine();
      final r = e.ingest('e1', _wireFrom(id: 'p1', senderId: 'me'), now);
      expect(r.action, PacketAction.duplicate);
      expect(e.notebook, isEmpty);
    });

    test('garbage is dropped without touching the notebook', () {
      final e = _engine();
      expect(e.ingest('e1', '<<broken>>', now).action, PacketAction.garbage);
      expect(e.notebook, isEmpty);
      expect(e.seenCount, 0);
    });

    test('chat is display-only: never stored, never relayed, never uplinked', () {
      final e = _engine();
      final r = e.ingest('e1', _wireFrom(id: 'c1', senderId: 'them', type: PacketType.chat), now);
      expect(r.action, PacketAction.chat);
      expect(r.uplink, isFalse);
      expect(e.notebook, isEmpty);              // privacy partition
      expect(e.outboundFor('e2'), isEmpty);
    });
  });

  group('relay laws', () {
    test('a carried letter leaves at ttl-1 and never returns to its courier', () {
      final e = _engine();
      e.ingest('courier', _wireFrom(id: 'p1', senderId: 'them', ttl: 4, hops: 0), now);

      expect(e.outboundFor('courier'), isEmpty); // never echo back where it came from

      final out = e.outboundFor('fresh');
      expect(out.length, 1);
      expect(out.single.ttl, 3);
      expect(out.single.hops, 1);
    });

    test('TTL wall: the last hop stores the letter but stops forwarding it', () {
      final e = _engine();
      e.ingest('courier', _wireFrom(id: 'p1', senderId: 'them', ttl: 1, hops: 3), now);
      expect(e.notebook.length, 1);              // still carried (offline truth survives)
      expect(e.outboundFor('fresh'), isEmpty);   // hop budget spent
    });

    test('my own SOS rides at FULL ttl — I am mule number one', () {
      final e = _engine();
      final r = e.sendSos(category: SosCategory.medical, text: 'help');
      expect(r.action, PacketAction.ownSos);
      expect(r.uplink, isTrue);
      expect(e.notebook.length, 1);

      final out = e.outboundFor('peer');
      expect(out.single.ttl, kMaxTtl);           // NOT decremented for the origin
      expect(out.single.hops, 0);
    });

    test('delivery book stops re-sends; a failed transfer re-arms the retry', () {
      final e = _engine();
      final p = e.sendSos(category: SosCategory.rescue).packet!;

      expect(e.outboundFor('peer').length, 1);
      e.markDelivered(p.id, 'peer');
      expect(e.outboundFor('peer'), isEmpty);

      e.downgradeEndpoint('peer');               // transfer failed after all
      expect(e.outboundFor('peer').length, 1);
    });
  });

  group('cancel + status laws', () {
    test('"I am safe" resolves the SOS everywhere and empties the banner', () {
      final e = _engine();
      final sos = e.sendSos(category: SosCategory.rescue).packet!;
      expect(e.ownActiveSos()?.id, sos.id);

      final c = e.sendCancel(sos.id);
      expect(c.action, PacketAction.ownCancel);
      expect(c.targetId, sos.id);
      expect(e.isResolved(sos.id), isTrue);
      expect(e.statusOf(sos, now), PacketStatus.resolved);
      expect(e.ownActiveSos(), isNull);
    });

    test('a stranger resolve arrives and is honoured', () {
      final e = _engine();
      e.ingest('e1', _wireFrom(id: 'p1', senderId: 'them'), now);
      final r = e.ingest('e1',
          _wireFrom(id: 'c1', senderId: 'them', type: PacketType.cancel, targetId: 'p1'), now);
      expect(r.action, PacketAction.cancel);
      expect(r.uplink, isTrue);
      expect(e.isResolved('p1'), isTrue);
    });

    test('a cancel names the SOS it resolves, so the siren can be matched and killed', () {
      // THE SCREAMING-PHONE CONTRACT: MeshController silences the alarm only when
      // r.targetId equals the packet it is currently sirening about. If the engine
      // stopped reporting targetId, the siren would outlive the emergency again.
      final e = _engine();
      e.ingest('e1', _wireFrom(id: 'p1', senderId: 'them'), now);
      final r = e.ingest('e1',
          _wireFrom(id: 'c1', senderId: 'them', type: PacketType.cancel, targetId: 'p1'), now);
      expect(r.targetId, 'p1');
      expect(r.siren, isFalse); // a resolve must never itself raise an alarm
    });

    test('48h old letters read EXPIRED', () {
      final e = _engine();
      final old = AidPacket(
        id: 'p1', type: PacketType.sos, senderId: 'them', senderName: 'Old',
        createdAt: now.subtract(const Duration(hours: 49)).millisecondsSinceEpoch ~/ 1000,
        ttl: 4, hops: 0,
      );
      expect(e.statusOf(old, now), PacketStatus.expired);
    });
  });

  group('heartbeat', () {
    test('re-arms delivery so a late-arriving phone still hears my SOS', () {
      final e = _engine();
      final p = e.sendSos(category: SosCategory.rescue).packet!;
      e.markDelivered(p.id, 'peer');
      expect(e.outboundFor('peer'), isEmpty);

      final beat = e.heartbeatTick(now);
      expect(beat?.action, PacketAction.heartbeat);
      expect(e.outboundFor('peer').length, 1);
    });

    test('stays silent when I have nothing outstanding', () {
      final e = _engine();
      expect(e.heartbeatTick(now), isNull);
    });

    test('THE DUPLICATE-ALERT SCAR: spent fuel is burnt off, never re-broadcast', () {
      // A restored notebook whose own SOS is 49h old but still listed as heartbeat fuel.
      final stale = AidPacket(
        id: 'me-1', type: PacketType.sos, senderId: 'me', senderName: 'Me',
        category: SosCategory.rescue,
        createdAt: now.subtract(const Duration(hours: 49)).millisecondsSinceEpoch ~/ 1000,
        ttl: kMaxTtl, hops: 0,
      );
      final e = _engine();
      e.restore(jsonEncode({
        'seen': ['me-1'],
        'notebook': [stale.toJson()],
        'deliveredTo': <String, List<String>>{},
        'myActiveSos': ['me-1'],
      }));
      expect(e.notebook.length, 1); // restore worked

      expect(e.heartbeatTick(now), isNull); // expired => fuel spent => no re-broadcast
      expect(e.heartbeatTick(now.add(const Duration(hours: 1))), isNull);
    });
  });

  group('text cap (anti-amplification)', () {
    test('an oversized inbound note is truncated on decode', () {
      final fat = AidPacket(
        id: 'p1', type: PacketType.sos, senderId: 'them', senderName: 'Loud',
        text: 'A' * 5000, createdAt: 1700000000, ttl: 4, hops: 0,
      );
      // toWire carries whatever it was built with; the DECODER is the gate.
      final back = AidPacket.fromWire(fat.toWire())!;
      expect(back.text.length, kMaxTextLen);
    });

    test('my own note is capped at origin, so we never emit an oversized letter', () {
      final e = _engine();
      final p = e.sendSos(category: SosCategory.custom, text: 'B' * 5000).packet!;
      expect(p.text.length, kMaxTextLen);
      expect(e.sendChat('C' * 5000).packet!.text.length, kMaxTextLen);
    });

    test('truncation never orphans half of an emoji', () {
      // Pad so the cut lands exactly between the two halves of a surrogate pair.
      final text = '${'x' * (kMaxTextLen - 1)}\u{1F691}rest';
      final cut = clampText(text);
      expect(cut.length, kMaxTextLen - 1);      // stepped back rather than splitting
      expect(cut.codeUnits.last, isNot(inInclusiveRange(0xD800, 0xDBFF)));
      expect(() => jsonDecode(jsonEncode({'t': cut})), returnsNormally);
    });

    test('short text is passed through untouched', () {
      expect(clampText('trapped under concrete'), 'trapped under concrete');
    });
  });

  group('rehearsal reset', () {
    test('clearNotebook wipes carried letters, dedup memory and heartbeat fuel', () {
      final e = _engine();
      final mine = e.sendSos(category: SosCategory.rescue).packet!;
      e.ingest('e1', _wireFrom(id: 'p9', senderId: 'them'), now);
      expect(e.notebook.length, 2);

      e.clearNotebook();

      expect(e.notebook, isEmpty);
      expect(e.seenCount, 0);
      expect(e.ownActiveSos(), isNull);
      expect(e.outboundFor('peer'), isEmpty);   // delivery books gone too
      expect(e.heartbeatTick(now), isNull);     // no fuel left to re-broadcast
      expect(e.isResolved(mine.id), isFalse);
    });

    test('after a reset the same letter is accepted again (dedup memory really went)', () {
      final e = _engine();
      final wire = _wireFrom(id: 'p1', senderId: 'them');
      expect(e.ingest('e1', wire, now).action, PacketAction.newSos);
      expect(e.ingest('e1', wire, now).action, PacketAction.duplicate);

      e.clearNotebook();
      expect(e.ingest('e1', wire, now).action, PacketAction.newSos);
    });
  });

  group('false-alarm laws (every one of these was a field-reported siren)', () {
    test('a resolve that arrives BEFORE its SOS kills the alarm the SOS would have raised', () {
      // THE THIRD-PHONE SCAR: two phones settle a case, a third joins later and was handed
      // the shout before the ending, so it screamed about an emergency that was already over.
      final e = _engine();
      final c = e.ingest('e1',
          _wireFrom(id: 'c1', senderId: 'them', type: PacketType.cancel, targetId: 'p1'), now);
      expect(c.action, PacketAction.cancel);

      final s = e.ingest('e1', _wireFrom(id: 'p1', senderId: 'them'), now);
      expect(s.action, PacketAction.newSos); // still stored and still relayed — history matters
      expect(s.siren, isFalse);              // …but nobody's phone screams for a closed case
      expect(s.uplink, isFalse);             // and the cloud case is NOT re-opened as active
      expect(e.notebook.length, 2);
      expect(e.statusOf(s.packet!, now), PacketStatus.resolved);
    });

    test('RESOLVES TRAVEL FIRST: a joining phone is handed cancels before SOSes', () {
      // This ordering is what makes the law above fire instead of merely correcting itself
      // a packet later — the difference between silence and a burst of siren.
      final e = _engine();
      e.ingest('a', _wireFrom(id: 'p1', senderId: 'them'), now);
      e.ingest('a', _wireFrom(id: 'p2', senderId: 'other'), now);
      e.ingest('a',
          _wireFrom(id: 'c1', senderId: 'them', type: PacketType.cancel, targetId: 'p1'), now);

      final out = e.outboundFor('newcomer', now: now);
      expect(out.length, 3);
      expect(out.first.type, PacketType.cancel);   // the ending leads
      expect(out.first.targetId, 'p1');
      expect(out.skip(1).map((p) => p.id), ['p1', 'p2']); // then the shouts, in order
    });

    test('a letter past its 48h life is not offered to anybody', () {
      final e = _engine();
      e.ingest('a', _wireFrom(id: 'old', senderId: 'them',
          createdAt: now.subtract(const Duration(hours: 49)).millisecondsSinceEpoch ~/ 1000), now);
      e.ingest('a', _wireFrom(id: 'new', senderId: 'them'), now);

      expect(e.notebook.length, 2);                       // still remembered locally
      expect(e.outboundFor('peer', now: now).map((p) => p.id), ['new']);
    });

    test('an SOS handed to us out of storage is filed, not screamed', () {
      // A phone joining a mesh receives the WHOLE notebook at once. Without a freshness
      // line, every unresolved letter of the last two days arrives as a fresh emergency —
      // 'I open the app and it rings immediately'.
      final e = _engine();
      final r = e.ingest('a', _wireFrom(id: 'p1', senderId: 'them',
          createdAt: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000), now);
      expect(r.action, PacketAction.newSos);
      expect(r.siren, isFalse);
      expect(e.notebook.length, 1);                       // readable in ALERTS
      expect(e.outboundFor('peer', now: now), hasLength(1)); // and still relayed onward
    });

    test('a live emergency still takes over the screen — including one with a broken clock', () {
      final e = _engine();
      expect(e.ingest('a', _wireFrom(id: 'p1', senderId: 'them'), now).siren, isTrue);
      // A phone whose clock is unset or ahead must never be silenced by the freshness line:
      // in an app whose whole promise is being heard, silence is the unacceptable failure.
      expect(e.ingest('a', _wireFrom(id: 'p2', senderId: 'them', createdAt: 0), now).siren, isTrue);
      expect(e.ingest('a', _wireFrom(id: 'p3', senderId: 'them',
          createdAt: now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000), now).siren,
          isTrue);
    });
  });

  group('persistence', () {
    test('notebook, dedup memory and heartbeat fuel survive a process kill', () {
      final a = _engine();
      final mine = a.sendSos(category: SosCategory.medical, text: 'crush injury').packet!;
      a.ingest('e1', _wireFrom(id: 'p9', senderId: 'them'), now);
      a.markDelivered(mine.id, 'peer');

      final b = _engine();
      b.restore(a.snapshot());

      expect(b.notebook.length, 2);
      expect(b.seenCount, a.seenCount);
      expect(b.ownActiveSos()?.id, mine.id);          // the SOS banner comes back
      expect(b.outboundFor('peer'), hasLength(1));    // p9 still owed, mine already delivered
      expect(b.ingest('e1', _wireFrom(id: 'p9', senderId: 'them'), now).action,
          PacketAction.duplicate);                    // dedup memory survived too
    });

    test('a corrupt snapshot starts empty instead of crashing the mesh', () {
      final e = _engine();
      e.restore('}{ not json');
      expect(e.notebook, isEmpty);
      expect(e.seenCount, 0);
    });
  });
}
