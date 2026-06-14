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
    this.raceId = options?.raceId ?? "ad-hoc";
    const state = new RaceState();
    // Prefer explicit option, else derive from lobby seeding (matching the
    // raceId convention: "free-<trackId>" or "wager-..." with fixed mapping).
    state.trackId = options?.trackId ?? this._deriveTrackId(this.raceId);
    state.maxPlayers = this.maxClients;
    state.entryFeeLamports = Number(options?.entryFeeLamports ?? 0);
    state.racePda = "";
    this.setState(state);

    this.setMetadata({ raceId: this.raceId, phase: "waiting" });

    this.onMessage("input", (client, payload: { seq: number; throttle: number; brake: number; steer: number; items?: number }) => {
      const last = this._lastSeq.get(client.sessionId) ?? -1;
      if (payload.seq <= last) return; // drop stale
      this._lastSeq.set(client.sessionId, payload.seq);
      this._inputs.set(client.sessionId, {
        throttle: clamp(payload.throttle, -1, 1),
        brake: clamp(payload.brake, 0, 1),
        steer: clamp(payload.steer, -1, 1),
        useItem: !!payload.items,
      });
    });

    this.onMessage("ready", (client) => {
      const kart = this.state.karts.get(client.sessionId);
      if (!kart) return;
      kart.ready = true;
      this._maybeStartCountdown();
    });

    this.onMessage("useItem", (client, payload: { slot: number }) => {
      // Stub: simply clear the slot. Real impl: spawn projectile/effect.
      const kart = this.state.karts.get(client.sessionId);
      if (kart && kart.itemSlot === payload.slot) {
        kart.itemSlot = 0;
      }
    });

    // 30 Hz tick
    this.setSimulationInterval((deltaMs) => this._tick(deltaMs), TICK_MS);
  }

  async onAuth(_client: Client, options: JoinOpts) {
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
  }

  onJoin(client: Client, options: JoinOpts) {
    if (this.state.phase !== "waiting" && this.state.phase !== "countdown") {
      throw new Error(`race ${this.raceId} already in progress`);
    }
    const k = new Kart();
    k.playerId = client.sessionId;
    k.wallet = options?.wallet ?? "";
    k.kartType = Number(options?.kartType ?? 0);
    k.position = this.state.karts.size + 1;
    k.x = (this.state.karts.size % 4) * 2.5 - 3.75;
    k.y = 0.5;
    k.z = -Math.floor(this.state.karts.size / 4) * 3.0;
    k.yaw = 0;
    this.state.karts.set(client.sessionId, k);
    this._inputs.set(client.sessionId, { throttle: 0, brake: 0, steer: 0, useItem: false });
    console.log(`[race:${this.raceId}] join sessionId=${client.sessionId} wallet=${k.wallet.slice(0,8)} kartType=${k.kartType}`);
  }

  onLeave(client: Client, _consented: boolean) {
    this.state.karts.delete(client.sessionId);
    this._inputs.delete(client.sessionId);
    this._lastSeq.delete(client.sessionId);
  }

  private _maybeStartCountdown() {
    if (this.state.phase !== "waiting") return;
    if (this.state.karts.size < 1) return; // dev: allow solo
    let allReady = true;
    this.state.karts.forEach((k) => { if (!k.ready) allReady = false; });
    if (!allReady) return;
    this.state.phase = "countdown";
    this.setMetadata({ raceId: this.raceId, phase: "countdown" });
    let s = COUNTDOWN_SECONDS;
    this.broadcast("countdown", { seconds: s });
    const tick = () => {
      s -= 1;
      this.broadcast("countdown", { seconds: s });
      if (s <= 0) {
        this.state.phase = "racing";
        this.state.startTimestamp = Date.now();
        this.setMetadata({ raceId: this.raceId, phase: "racing" });
      } else {
        this.clock.setTimeout(tick, 1000);
      }
    };
    this.clock.setTimeout(tick, 1000);
  }

  private _tick(deltaMs: number) {
    this.state.tick++;
    if (this.state.phase !== "racing") return;
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
   * Map a raceId back to an STK track id.
   *   "free-<trackId>"        -> trackId
   *   "wager-0.01-sol"        -> cocoa_temple (per LobbyRoom seed)
   *   "wager-0.1-sol"         -> volcano_island
   *   anything else           -> first race-eligible track in the catalog
   */
  private _deriveTrackId(raceId: string): string {
    if (raceId.startsWith("free-")) return raceId.slice("free-".length);
    if (raceId === "wager-0.01-sol") return "cocoa_temple";
    if (raceId === "wager-0.1-sol")  return "volcano_island";
    const tracks = loadTrackCatalog();
    const first = tracks.find((t) => !t.isArena && !t.isSoccer && !t.isCutscene);
    return first?.id ?? "default";
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}
