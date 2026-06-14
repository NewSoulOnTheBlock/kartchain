import { Room, Client } from "@colyseus/core";
import { RaceState, Kart } from "../schemas/RaceState.js";
import { simulateKart, type KartInput } from "../simulation/kartSim.js";
import { verifyEntryTx } from "../solana/verifyEntry.js";
import { settleRace } from "../solana/settle.js";
import { mintP2eRewards, p2eRewardForPosition } from "../solana/p2e.js";
import { loadTrackCatalog } from "../content/catalog.js";

const TICK_RATE_HZ = 30;
const TICK_MS = 1000 / TICK_RATE_HZ;
const COUNTDOWN_SECONDS = 3;

type JoinOpts = {
  raceId: string;
  wallet?: string;
  kartType?: number;
  entryTxSignature?: string; // required for paid lobbies
};

/**
 * Authoritative race room.
 * - Clients send inputs at ~30 Hz
 * - Server runs a deterministic kart sim and broadcasts state via Schema
 * - On finish, server signs settle_race(...) onchain
 */
export class RaceRoom extends Room<RaceState> {
  maxClients = 8;
  autoDispose = true;

  // Per-client latest input
  private _inputs = new Map<string, KartInput>();
  // Per-client accepted input seq (for ignoring stale)
  private _lastSeq = new Map<string, number>();

  // Track which raceId this room belongs to (used by lobby polling)
  raceId = "";

  async onCreate(options: { raceId: string; entryFeeLamports?: string | number; trackId?: string }) {
    try {
      this.raceId = options?.raceId ?? "ad-hoc";
      const state = new RaceState();
      // Prefer explicit option, else derive from lobby seeding (matching the
      // raceId convention: "free-<trackId>" or "wager-..." with fixed mapping).
      state.trackId = options?.trackId ?? this._deriveTrackId(this.raceId);
      state.maxPlayers = this.maxClients;
      state.entryFeeLamports = Number(options?.entryFeeLamports ?? 0);
      state.racePda = "";
      this.setState(state);

      this.setMetadata({ raceId: this.raceId, phase: "waiting" }).catch((err) => {
        console.warn(`[race:${this.raceId}] setMetadata failed:`, err);
      });
      console.log(`[race:${this.raceId}] room CREATED trackId=${state.trackId} fee=${state.entryFeeLamports}`);

      this.onMessage("input", (client, payload: { seq: number; throttle: number; brake: number; steer: number; items?: number }) => {
        try {
          const last = this._lastSeq.get(client.sessionId) ?? -1;
          if (payload.seq <= last) return; // drop stale
          this._lastSeq.set(client.sessionId, payload.seq);
          this._inputs.set(client.sessionId, {
            throttle: clamp(payload.throttle, -1, 1),
            brake: clamp(payload.brake, 0, 1),
            steer: clamp(payload.steer, -1, 1),
            useItem: !!payload.items,
          });
        } catch (err) {
          console.error(`[race:${this.raceId}] input handler error:`, err);
        }
      });

      this.onMessage("ready", (client) => {
        try {
          const kart = this.state.karts.get(client.sessionId);
          if (!kart) return;
          kart.ready = true;
          console.log(`[race:${this.raceId}] ready ${client.sessionId} (${this._readyCount()}/${this.state.karts.size})`);
          this._maybeStartCountdown();
        } catch (err) {
          console.error(`[race:${this.raceId}] ready handler error:`, err);
        }
      });

      this.onMessage("useItem", (client, payload: { slot: number }) => {
        const kart = this.state.karts.get(client.sessionId);
        if (kart && kart.itemSlot === payload.slot) {
          kart.itemSlot = 0;
        }
      });

      // Any player can submit a "spawn override" world position — the server
      // stores it in state so every kart spawns at the same place.
      this.onMessage("setSpawn", (_client, payload: { x: number; y: number; z: number }) => {
        if (typeof payload?.x !== "number") return;
        this.state.spawnOverrideX = payload.x;
        this.state.spawnOverrideY = payload.y;
        this.state.spawnOverrideZ = payload.z;
        this.state.hasSpawnOverride = true;
        console.log(`[race:${this.raceId}] spawn override set: (${payload.x.toFixed(1)}, ${payload.y.toFixed(1)}, ${payload.z.toFixed(1)})`);
      });

      // 30 Hz tick
      this.setSimulationInterval((deltaMs) => {
        try {
          this._tick(deltaMs);
        } catch (err) {
          console.error(`[race:${this.raceId}] tick error:`, err);
        }
      }, TICK_MS);
    } catch (err) {
      console.error(`[race:${this.raceId}] onCreate FAILED:`, err);
      throw err;
    }
  }

  async onAuth(_client: Client, options: JoinOpts) {
    try {
      // Paid race: require an on-chain entry transfer to escrow
      if (this.state.entryFeeLamports > 0) {
        if (!options?.entryTxSignature || !options.wallet) {
          throw new Error("Paid race requires { wallet, entryTxSignature }");
        }
        const ok = await verifyEntryTx({
          signature: options.entryTxSignature,
          expectedWallet: options.wallet,
          expectedRaceId: this.raceId,
          expectedLamports: BigInt(this.state.entryFeeLamports),
        });
        if (!ok) throw new Error("entry tx did not verify");
      }
      return true;
    } catch (err) {
      console.error(`[race:${this.raceId}] onAuth FAILED for wallet=${options?.wallet?.slice(0,8) ?? "?"}:`, err);
      throw err;
    }
  }

  onJoin(client: Client, options: JoinOpts) {
    try {
      console.log(`[race:${this.raceId}] onJoin ENTER sessionId=${client.sessionId} phase=${this.state.phase} kartsBefore=${this.state.karts.size}`);
      if (this.state.phase !== "waiting" && this.state.phase !== "countdown") {
        throw new Error(`race ${this.raceId} already in progress (phase=${this.state.phase})`);
      }
      const k = new Kart();
      k.playerId = client.sessionId;
      k.wallet = String(options?.wallet ?? "");
      // Clamp kartType into the schema's uint8 range so a bad client int
      // can never crash schema encoding mid-broadcast.
      const rawKart = Number(options?.kartType ?? 0);
      k.kartType = Number.isFinite(rawKart) ? Math.max(0, Math.min(255, Math.floor(rawKart))) : 0;
      k.position = Math.min(255, this.state.karts.size + 1);
      k.x = (this.state.karts.size % 4) * 2.5 - 3.75;
      k.y = 0.5;
      k.z = -Math.floor(this.state.karts.size / 4) * 3.0;
      k.yaw = 0;
      this.state.karts.set(client.sessionId, k);
      this._inputs.set(client.sessionId, { throttle: 0, brake: 0, steer: 0, useItem: false });
      console.log(`[race:${this.raceId}] onJoin OK sessionId=${client.sessionId} wallet=${k.wallet.slice(0,8) || "(none)"} kartType=${k.kartType} kartsAfter=${this.state.karts.size}`);
    } catch (err) {
      console.error(`[race:${this.raceId}] onJoin FAILED sessionId=${client.sessionId}:`, err);
      throw err;
    }
  }

  onLeave(client: Client, _consented: boolean) {
    console.log(`[race:${this.raceId}] onLeave sessionId=${client.sessionId}`);
    this.state.karts.delete(client.sessionId);
    this._inputs.delete(client.sessionId);
    this._lastSeq.delete(client.sessionId);
  }

  private _readyCount(): number {
    let n = 0;
    this.state.karts.forEach((k) => { if (k.ready) n++; });
    return n;
  }

  private _maybeStartCountdown() {
    if (this.state.phase !== "waiting") return;
    if (this.state.karts.size < 1) return; // dev: allow solo
    let allReady = true;
    this.state.karts.forEach((k) => { if (!k.ready) allReady = false; });
    if (!allReady) return;
    this.state.phase = "countdown";
    this.setMetadata({ raceId: this.raceId, phase: "countdown" }).catch(() => undefined);
    let s = COUNTDOWN_SECONDS;
    this.broadcast("countdown", { seconds: s });
    const tick = () => {
      s -= 1;
      this.broadcast("countdown", { seconds: s });
      if (s <= 0) {
        this.state.phase = "racing";
        this.state.startTimestamp = Date.now();
        this.setMetadata({ raceId: this.raceId, phase: "racing" }).catch(() => undefined);
      } else {
        this.clock.setTimeout(tick, 1000);
      }
    };
    this.clock.setTimeout(tick, 1000);
  }

  private _tick(deltaMs: number) {
    // Skip tick++ in non-racing phases — it just spams schema patches at
    // 30 Hz to every connected client for no game-state value.
    if (this.state.phase !== "racing") return;
    this.state.tick++;
    const dt = deltaMs / 1000;

    // Simulate each kart
    this.state.karts.forEach((kart, sessionId) => {
      if (kart.finished) return;
      const input = this._inputs.get(sessionId) ?? { throttle: 0, brake: 0, steer: 0, useItem: false };
      simulateKart(kart, input, dt);
      // Lap progress is stubbed: every 8 seconds increment lap.
      // TODO: real track-segment crossing logic.
      if (kart.lap < this.state.totalLaps &&
          Date.now() - this.state.startTimestamp > (kart.lap + 1) * 8000) {
        kart.lap += 1;
        this.broadcast("lap", { playerId: sessionId, lapNumber: kart.lap, lapTime: 8.0 });
        if (kart.lap >= this.state.totalLaps) {
          kart.finished = true;
          kart.finishTime = (Date.now() - this.state.startTimestamp) / 1000;
          this._finishKart(sessionId, kart);
        }
      }
    });

    // Update positions
    this._recomputePositions();

    // End race if everyone finished
    let allDone = this.state.karts.size > 0;
    this.state.karts.forEach((k) => { if (!k.finished) allDone = false; });
    if (allDone && this.state.phase === "racing") {
      this._endRace();
    }
  }

  private _recomputePositions() {
    const sorted = Array.from(this.state.karts.values()).sort((a, b) => {
      if (a.finished && !b.finished) return -1;
      if (!a.finished && b.finished) return 1;
      if (a.finished && b.finished) return a.finishTime - b.finishTime;
      // mid-race: more laps = ahead; tie-break by -z progress as a stub
      if (a.lap !== b.lap) return b.lap - a.lap;
      return a.z - b.z;
    });
    sorted.forEach((k, i) => { k.position = i + 1; });
  }

  private _finishKart(sessionId: string, kart: Kart) {
    this.broadcast("finish", {
      playerId: sessionId,
      totalTime: kart.finishTime,
      position: kart.position,
    });
  }

  private async _endRace() {
    this.state.phase = "settling";
    this.setMetadata({ raceId: this.raceId, phase: "settling" });

    const finishers = Array.from(this.state.karts.values())
      .filter((k) => k.finished && k.wallet)
      .sort((a, b) => a.position - b.position);

    // 1) Distribute SOL prize pool from escrow to winners (if paid race)
    if (this.state.entryFeeLamports > 0 && finishers.length > 0) {
      const pool = BigInt(this.state.entryFeeLamports) * BigInt(this.state.karts.size);
      try {
        const txSignature = await settleRace({
          raceId: this.raceId,
          results: finishers.map((k) => k.wallet),
          poolLamports: pool,
          prizeSplitBps: [7000, 2000, 500], // 70/20/5 with 5% protocol fee
          feeBps: 500,
        });
        this.broadcast("settled", { txSignature });
      } catch (err) {
        console.error("[RaceRoom] settle failed:", err);
        this.broadcast("error", { code: "SETTLE_FAILED", message: String(err) });
      }
    }

    // 2) Mint P2E rewards to every finisher (regardless of paid/free)
    if (process.env.P2E_TOKEN_MINT) {
      for (const k of finishers) {
        const amount = p2eRewardForPosition(k.position);
        mintP2eRewards({ raceId: this.raceId, player: k.wallet, amount: amount })
          .then((sig) => this.broadcast("p2e:minted", {
            playerId: k.playerId,
            amount: amount.toString(),
            txSignature: sig,
          }))
          .catch((err) => console.error("[p2e] mint failed:", err));
      }
    }

    this.state.phase = "finished";
    this.setMetadata({ raceId: this.raceId, phase: "finished" });

    // Auto-dispose after 30s grace period for client reads
    this.clock.setTimeout(() => this.disconnect(), 30_000);
  }

  /**
   * Map a raceId back to an STK track id, clamped to tracks that actually
   * ship in the client pck. Any unknown / unbundled id falls back to the
   * primary bundled track (lighthouse) so the race scene always renders.
   */
  private _deriveTrackId(raceId: string): string {
    const bundled = new Set(
      (process.env.CLIENT_BUNDLED_TRACKS ?? "lighthouse")
        .split(",").map((s) => s.trim()).filter(Boolean)
    );
    const fallback = bundled.has("lighthouse") ? "lighthouse" : ([...bundled][0] ?? "default");

    let candidate = "";
    if (raceId.startsWith("free-")) candidate = raceId.slice("free-".length);
    else if (raceId === "wager-0.01-sol") candidate = "lighthouse";
    else if (raceId === "wager-0.1-sol")  candidate = "lighthouse";
    else {
      const tracks = loadTrackCatalog();
      const first = tracks.find((t) => !t.isArena && !t.isSoccer && !t.isCutscene);
      candidate = first?.id ?? fallback;
    }
    return bundled.has(candidate) ? candidate : fallback;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}
