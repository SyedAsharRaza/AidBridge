# AidBridge

**When the towers fall, the phones become the network.**

AidBridge is an offline-first disaster SOS mesh. It turns a crowd of ordinary Android
phones into a store-and-forward relay network that carries distress calls out of a
blackout zone — no cell tower, no Wi-Fi, no internet, no infrastructure of any kind.

The moment *any* phone in the chain touches the internet, every SOS it is carrying
teleports to a live command dashboard.

---

## 1. The problem

In the first 72 hours of a flood, quake or landslide, the cell towers are the first
thing to die — and they are exactly what every existing emergency app depends on.

- **112 / 1122 / 911** need a tower.
- **WhatsApp location sharing** needs the internet.
- **Google's emergency SOS** needs a network.
- Satellite messengers exist, but nobody in a Pakistani flood village owns one.

So the people who need help most are precisely the people who cannot ask for it.
Meanwhile they are standing in a crowd of phones — each with Bluetooth and Wi-Fi
Direct radios that work perfectly at 100 metres and are doing *nothing*.

**AidBridge uses that wasted radio.**

---

## 2. How it works

An SOS is modelled as a **letter carried by a crowd**, not a message sent to a server.

```
   ┌────────────┐        BLE / Wi-Fi Direct        ┌────────────┐
   │  PHONE A   │  ─────────  no towers  ───────▶  │  PHONE B   │
   │  victim    │                                  │  stranger  │
   │  offline   │      "carry this for me"          │  offline   │
   └────────────┘                                  └─────┬──────┘
                                                         │  walks 200m
                                                         │  still offline
                                                         ▼
                                                   ┌────────────┐
                                                   │  PHONE C   │
                                                   │  NGO/relief│
                                                   │  HAS 4G    │
                                                   └─────┬──────┘
                                                         │  auto-uplink
                                                         ▼
                                                 ┌───────────────┐
                                                 │   Firestore   │
                                                 │  live command │
                                                 │   dashboard   │
                                                 └───────────────┘
```

Phone B never opened the app for phone A. It never agreed to help a specific person.
It simply **carries every letter it has ever heard** and hands them to everyone new it
meets. Phone C did not even have to be present when the SOS was fired — the notebook
on phone B remembers, and delivers minutes or hours later.

This is *epidemic routing*: the SOS spreads like a rumour, and the network is made of
strangers.

### The four laws that make it work

| Law | What it does |
|---|---|
| **Store-and-forward notebook** | Every phone keeps the last 200 letters on disk. A letter survives the app closing, the phone rebooting, and the sender walking away. |
| **Dedup set** | Each letter has a globally unique id. A phone that has seen an id ignores it forever — so a rumour in a dense crowd cannot echo into a storm. |
| **TTL hop wall** | A letter may only be relayed 4 times. Bounded blast radius, no infinite loops. Origin fields are immutable; a relay may *only* produce a copy with `ttl-1 / hops+1`. |
| **Idempotent uplink** | The packet id *is* the Firestore document id. Ten phones uploading the same SOS produce **one** row, not ten. Duplicate delivery is free. |

---

## 3. Architecture

The codebase is deliberately layered so that the part that matters can be proven
without hardware.

```
┌──────────────────────────────────────────────────────────────┐
│  UI          civilian shell (SOS · alerts · settings)        │
│              NGO command shell (incidents · map · bridge)    │
├──────────────────────────────────────────────────────────────┤
│  GLUE        MeshController  (Riverpod StateNotifier)        │
│              engine decides → glue executes → transport moves│
├──────────────────────────────────────────────────────────────┤
│  ENGINE      ProtocolEngine   ★ PURE DART, ZERO PLUGINS ★    │
│              dedup · notebook · TTL · cancel · heartbeat     │
├──────────────────────────────────────────────────────────────┤
│  TRANSPORT   NearbyTransport (interface)                     │
│              └─ NearbyConnectionsTransport (the only plugin  │
│                 -aware file: BLE / Wi-Fi Direct, self-heal)  │
├──────────────────────────────────────────────────────────────┤
│  BRIDGE      BridgeService → Cloud Firestore (opportunistic) │
└──────────────────────────────────────────────────────────────┘
```

**The architectural rule:** `ProtocolEngine` never imports a plugin. Not one. That is
why every routing decision — dedup, the TTL wall, cancel resolution, heartbeat fuel,
crash recovery — is covered by unit tests that run on a laptop with no phones, no
radios and no internet.

| File | Responsibility |
|---|---|
| `lib/protocol/packet.dart` | The wire format. Tolerant decode: garbage in → `null` out, never a throw. |
| `lib/protocol/protocol_engine.dart` | Every routing law. Pure Dart. Fully unit-tested. |
| `lib/transport/nearby_transport.dart` | Transport interface — lets the engine be tested and the radio be swapped. |
| `lib/transport/nearby_connections_transport.dart` | Google Nearby Connections + all the self-healing. |
| `lib/app/mesh.dart` | The glue: identity, state, siren, GPS, persistence, uplink. |
| `lib/services/bridge_service.dart` | Opportunistic Firestore uplink. `sos` + `cancel` only. |
| `lib/ui/…` | Civilian shell and NGO command shell, EN/UR bilingual with RTL. |

### Tuned constants (hardware-verified — do not change silently)

| Constant | Value | Why |
|---|---|---|
| `kMaxTtl` | 4 hops | Bounded flood; verified reachable depth. |
| `kMaxNotebook` | 200 letters | Bounded memory on a cheap phone. |
| `kMaxSeen` | 500 ids | Dedup memory, FIFO-capped. |
| `kPacketLifetime` | 48 h | After that an SOS reads EXPIRED, not ACTIVE. |
| `kHeartbeat` | 5 min | Own unresolved SOS re-broadcasts, so a phone that arrives late still hears it. |
| `kPingEvery` | 20 s | Liveness probe to every peer. |
| `kPeerSilence` | 70 s | >3 missed pings ⇒ ghost peer, force-disconnected. |
| `kNoPeerRefresh` | 45 s | Dead air ⇒ full radio restart (cures silently-wedged Android radios). |
| `Strategy` | `P2P_CLUSTER` | Many-to-many; the only strategy that gives a real mesh. |

### Two design decisions worth defending

**The privacy partition.** The protocol supports a `chat` packet type that is *never*
stored, *never* relayed and *never* uplinked to the cloud — it is display-only, local,
and dies with the connection. Distress data leaves the mesh; conversation never does.
(The packet type and its guarantees are implemented and tested; there is no chat UI in
this build.)

**The symmetry-breaker.** When two phones discover each other simultaneously, both
requesting a connection makes Nearby Connections fail with status 8009. AidBridge
resolves it with a lexicographic comparison on `name·deviceId`: the smaller name
requests, the other auto-accepts. Device-id suffixes guarantee the two strings can
never be equal, so exactly one side always initiates.

---

## 4. Running it

```bash
flutter pub get
flutter run            # a real Android device — an emulator has no BLE peer
```

Requirements:

- **2+ physical Android phones.** A single phone or an emulator cannot demonstrate a mesh.
- **Bluetooth AND Location switched ON.** Android requires Location for BLE scanning.
  If either is off the app now says so out loud with a **FIX** button, instead of
  silently finding nobody.
- Firebase is configured natively via `android/app/google-services.json`. With no
  internet the bridge simply stays idle and the mesh is unaffected.

### Tests

```bash
flutter analyze     # clean
flutter test        # 31 tests on the pure-Dart protocol engine
```

The engine tests cover: wire round-trip, garbage rejection, relay-only mutation,
dedup, own-echo rejection, the chat privacy partition, the TTL wall, full-TTL origin
send, delivery-book retry-on-failure, cancel resolution, 48 h expiry, heartbeat
re-arming, spent-heartbeat-fuel burn-off, the 500-char anti-amplification cap
(including surrogate-safe truncation), the cancel→siren matching contract, the
rehearsal reset, and crash recovery via snapshot/restore.

**False-alarm laws** (a phone must only scream for a live emergency) are tested too:
a resolve that arrives *before* its SOS silences it, resolves are handed to a joining
phone *ahead* of the SOSes they close, letters past 48 h are no longer relayed, an SOS
delivered out of someone's storage is filed rather than screamed — and, in the other
direction, a live SOS still takes over the screen even when the sender's clock is wrong.

---

## 5. The 3-phone demo script

The topology is controlled by **when** each phone joins — the notebook does the rest.
This is the whole point: phone C receives an SOS that was fired before it even arrived.

**Setup**

| Phone | Role | Internet | Bluetooth + Location |
|---|---|---|---|
| **A** — victim | civilian | **OFF** (airplane mode, then BT back on) | ON |
| **B** — stranger | civilian | **OFF** | ON |
| **C** — relief | **NGO** | **ON** (mobile data) | ON |

Keep **C's app fully closed** until step 4.

**Act 1 — the mesh forms without any network (30 s)**
1. Open A and B. Onboard both as *civilian*. Watch the peer counter reach **1 phone**
   on each. Point out: both are in airplane mode. There is no tower in this room.

**Act 2 — the SOS (30 s)**
2. On **A**, press and hold the SOS button (1.2 s — no accidental sirens), pick
   *Medical*, add a note.
3. **B** erupts: full-screen red takeover, siren, vibration, and the line
   *"via 0 phones"*. A stranger's phone just became a first responder.
   → Then **put A in your pocket / lock it.** The letter is already out of A's hands.

**Act 3 — store-and-forward, the part nobody else has (45 s)**
4. Now open **C** for the first time and onboard it as **NGO**.
   C was not present when the SOS was fired. It arrives late, in a different second.
5. B hands the stored letter to C. C's command dashboard shows the incident —
   with **`via 1` hop**. That hop counter is the proof of relay: the SOS travelled
   A → B → C without either A or B ever touching the internet.
6. Open the **BRIDGE** tab on C and read the **LIVE MESH LOG** aloud:
   `SENT (sos) ttl=3 hops=1 -> …`, `UPLINK ☁️ SOS … -> cloud`. The invisible protocol,
   printed on screen.
7. Open the **MAP** tab — the pin is on the map, GPS captured offline at the moment
   the SOS was fired.

**Act 4 — the cloud and the resolution (30 s)**
8. Show the same incident live in the Firebase console (or a second dashboard). C's
   4G carried it out of the blackout zone for everyone.
9. On **A**, tap **I'M SAFE**. Watch it propagate back across the mesh: B and C both
   flip the incident to **SAFE**, and the cloud row updates to `resolved`. Rescue
   crews are not sent to someone who already walked out.

**If pairing stalls on stage:** Settings → **RESTART MESH**. One tap, radios recycled,
notebook preserved. Do not restart the app.

**Between rehearsal runs:** Settings → **CLEAR NOTEBOOK** on each phone. Wipes that
phone's carried letters and dedup memory so the next run starts from silence.

---

## 6. Honest limitations

We would rather tell you these than have you find them.

| Limitation | Status | Why |
|---|---|---|
| **Does not survive swipe-from-recents** | Platform reality | Android grants no app the right to outlive a user's explicit swipe-kill. We run a foreground service with a battery-optimisation exemption, which survives screen-off, Doze and OEM background killers — but not a deliberate swipe. Every "background" app has this limit; most just don't admit it. |
| **Android only** | By design for this build | iOS forbids the background BLE advertising this depends on. An iOS build would be foreground-only and cannot be an equal mesh peer. Honest scope beats a broken cross-platform claim. |
| **Range is ~100 m line-of-sight** | Physics | BLE / Wi-Fi Direct. Density is the answer, not power: a mesh needs a crowd, which is exactly what a disaster zone has. |
| **No packet signing yet** | Roadmap | A malicious actor on the mesh could forge an SOS or a cancel. Fix is Ed25519 origin signatures — designed, not shipped. |
| **Firestore is in open test mode** | Deliberate, pre-demo | Strict rules without Firebase Auth would deny the app's own reads and kill the dashboard mid-pitch. Rules + anonymous auth ship immediately after. |
| **Release APK is debug-signed** | Demo build | Fine for sideloading; a real keystore is a store-submission task, not a protocol one. |
| **No chat UI** | Scope | The chat packet type and its privacy partition are implemented and tested at the protocol level; the screen is not built. |
| **GPS may be null indoors** | Intentional | The SOS is *never* blocked waiting for a fix. It sends with `lat = null` rather than not sending. A late letter is worse than a letter without coordinates. |

### Roadmap

Ed25519 packet signing · replay-window hardening · anonymous auth + tightened
Firestore rules · FCM push to relief crews · Wi-Fi Aware for longer range · an
iOS foreground companion · triage-priority queueing so medical letters overtake
others under congestion.

---

## 7. What is actually novel here

1. **No infrastructure at all.** Not a private LTE cell, not a LoRa dongle, not a
   satellite subscription. Hardware that is already in every pocket in the disaster zone.
2. **Strangers relay for you automatically.** No pairing, no contact list, no consent
   per-message, no accounts. Proximity is the only requirement.
3. **The internet is optional, not required.** One connected phone drains the whole
   region's backlog to the cloud — and because the packet id is the document id, a
   hundred phones uploading the same letter still produce one row.
4. **The routing engine is provable.** Pure Dart, zero plugin imports, 26 unit tests.
   We can demonstrate correctness on a laptop and behaviour on phones.
