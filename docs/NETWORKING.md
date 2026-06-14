# Networking

Wire protocol between Godot client and Colyseus server.

## Transport

WebSocket (WSS in production). Colyseus uses a msgpack-encoded binary
protocol; the client either uses the official JS client library (via
JavaScriptBridge from Godot) or speaks the protocol directly from GDScript.

For the MVP we use **JS bridge**: the Next.js host runs the Colyseus JS
client and forwards messages to Godot via `window.kartchain.send/recv`.

## Rooms

### `LobbyRoom`
Single room, players join on connect. Sends current race lobbies + player
counts. Client requests `joinRace(raceId)` to move into a `RaceRoom`.

### `RaceRoom`
Max 8 clients. Lifecycle:
1. `waiting` — players queue in
2. `countdown` — 3..2..1..GO
3. `racing` — simulation running
4. `finished` — results + settlement
5. `disposed`

## Messages

### Client → Server

| Type | Payload | Notes |
|---|---|---|
| `input` | `{seq, throttle, brake, steer, items}` | 30 Hz, throttle/brake/steer ∈ [-1,1] |
| `ready` | `{}` | Player confirmed ready in lobby |
| `useItem` | `{slot}` | Activate held item |

### Server → Client

Colyseus delta-syncs the `RaceState` schema; in addition:

| Type | Payload | Notes |
|---|---|---|
| `countdown` | `{seconds}` | Broadcast during countdown phase |
| `lap` | `{playerId, lapNumber, lapTime}` | Lap completion |
| `finish` | `{playerId, totalTime, position}` | Final results |
| `settleTx` | `{txSignature}` | Server settled race onchain |

## Schema (RaceState)

```ts
class Kart extends Schema {
  @type("string")  playerId: string;
  @type("string")  wallet: string;
  @type("uint8")   kartType: number;
  @type("uint8")   position: number;  // 1..8
  @type("uint8")   lap: number;
  @type("number")  x: number;
  @type("number")  y: number;
  @type("number")  z: number;
  @type("number")  yaw: number;
  @type("number")  speed: number;
  @type("uint8")   itemSlot: number;  // 0 = empty
  @type("boolean") finished: boolean;
}

class RaceState extends Schema {
  @type("string")            phase: string;   // waiting | countdown | racing | finished
  @type("string")            trackId: string;
  @type("uint8")             totalLaps: number = 3;
  @type({ map: Kart })       karts: MapSchema<Kart>;
  @type("uint64")            entryFeeLamports: bigint;
  @type("string")            racePda: string;  // PDA for escrow
}
```

## Cheat prevention

- Client never tells the server "I am at position X" — server simulates from
  inputs only.
- Item drops are server-rolled with a seeded RNG (race id + lap + position).
- Lap completions require crossing the start-line trigger in server space.
- Settlement is signed by the server-signer keypair; clients can't forge it.

## Tick & latency

- 30 Hz authoritative server tick.
- Client-side prediction on local kart only.
- Remote karts interpolated at `now - 100ms` for smoothness.
- Last-known-good rollback on the local kart when server corrects.
