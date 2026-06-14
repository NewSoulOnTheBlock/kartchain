import { Schema, MapSchema, type } from "@colyseus/schema";

export class Kart extends Schema {
  @type("string") playerId = "";
  @type("string") wallet = "";
  @type("uint8")  kartType = 0;
  @type("uint8")  position = 0;
  @type("uint8")  lap = 0;
  @type("number") x = 0;
  @type("number") y = 0;
  @type("number") z = 0;
  @type("number") yaw = 0;
  @type("number") vx = 0;
  @type("number") vy = 0;
  @type("number") vz = 0;
  @type("number") speed = 0;
  @type("uint8")  itemSlot = 0;
  @type("boolean") ready = false;
  @type("boolean") finished = false;
  @type("number") finishTime = 0;
}

export class RaceState extends Schema {
  /** waiting | countdown | racing | finished | settling */
  @type("string") phase = "waiting";
  @type("string") trackId = "default";
  @type("uint8")  totalLaps = 3;
  @type("uint8")  maxPlayers = 8;
  @type({ map: Kart }) karts = new MapSchema<Kart>();
  /**
   * Entry fee in lamports (0 = free race). Stored as plain `number` because
   * Colyseus matchmaker JSON-serializes metadata and `bigint` round-trips
   * blow up there. Max safe int (2^53) = 9_007_199_254_740_992 lamports
   * = ~9 million SOL, far above any practical race fee.
   */
  @type("number") entryFeeLamports = 0;
  /** PDA address (base58) for the on-chain escrow vault */
  @type("string") racePda = "";
  /** Server tick counter */
  @type("uint32") tick = 0;
  /** Server time when race started (ms since epoch) */
  @type("number") startTimestamp = 0;
  /** Per-room spawn override (player can broadcast via setSpawn) */
  @type("boolean") hasSpawnOverride = false;
  @type("number")  spawnOverrideX = 0;
  @type("number")  spawnOverrideY = 0;
  @type("number")  spawnOverrideZ = 0;
  /**
   * Auto-start timer for quick-race matchmaking. Server sets this when the
   * first player joins; if the room hasn't filled by then we start anyway
   * with whoever's present. 0 = no auto-start scheduled (single-player or
   * an already-running race). Stored as ms-since-epoch.
   */
  @type("number") waitingUntilMs = 0;
}
