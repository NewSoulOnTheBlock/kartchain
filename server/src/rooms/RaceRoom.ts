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
// Quick-race matchmaking: if a room hasn't filled within this window after
// the FIRST player joined, auto-start with whoever is present.
const AUTO_START_AFTER_MS = 30_000;
// Minimum wall-clock duration a race must run before any player can finish.
// Acts as a floor: even with the stub lap counter (or a future bug in real
// lap detection) a player cannot trigger settlement before this elapses.
const MIN_RACE_DURATION_MS = 5 * 60 * 1000;

type JoinOpts = {
  raceId: string;
  wallet?: string;
  kartType?: number;
  entryTxSignature?: string; // required for paid lobbies
  maxPlayers?: number;       // 2 / 4 / 8 for quick-race matchmaking
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

  async onCreate(options: { raceId: string; entryFeeLamports?: string | number; trackId?: string; maxPlayers?: number }) {
    try {
      this.raceId = options?.raceId ?? "ad-hoc";
      // Clamp maxPlayers into a sane range. Default 8 (the previous behaviour);
      // quick-race menu passes 2/4/8 explicitly.
      const desired = Number(options?.maxPlayers ?? 8);
      const clamped = Number.isFinite(desired)
        ? Math.max(1, Math.min(8, Math.floor(desired)))
        : 8;
      this.maxClients = clamped;
      const state = new RaceState();
      // Prefer explicit option, else derive from lobby seeding (matching the
      // raceId convention: "free-<trackId>" or "wager-..." with fixed mapping).
      state.trackId = options?.trackId ?? this._deriveTrackId(this.raceId);
      state.maxPlayers = clamped;
      state.entryFeeLamports = Number(options?.entryFeeLamports ?? 0);
      state.racePda = "";
      this.setState(state);

      this.setMetadata({ raceId: this.raceId, phase: "waiting", maxPlayers: clamped }).catch((err) => {
        console.warn(`[race:${this.raceId}] setMetadata failed:`, err);
      });
      console.log(`[race:${this.raceId}] room CREATED trackId=${state.trackId} fee=${state.entryFeeLamports} maxPlayers=${clamped}`);

      this.onMessage("input", (client, payload: { seq: number; throttle: number; brake: number; steer: number; items?: number }) => {
        try {
          // Log first input per client so we can confirm the bridge is alive.
          if (!this._lastSeq.has(client.sessionId)) {
            console.log(`[race:${this.raceId}] FIRST input from ${client.sessionId} throttle=${payload.throttle} steer=${payload.steer}`);
          }
          const last = this._lastSeq.get(client.sessionId) ?? -1;
          if (payload.seq <= last) return; // drop stale
          this._lastSeq.set(client.sessionId, payload.seq);
          this._inputs.set(client.sessionId, {
            throttle: clamp(Number(payload.throttle) || 0, -1, 1),
            brake: clamp(Number(payload.brake) || 0, 0, 1),
            steer: clamp(Number(payload.steer) || 0, -1, 1),
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
      console.log(`[race:${this.raceId}] onJoin OK sessionId=${client.sessionId} wallet=${k.wallet.slice(0,8) || "(none)"} kartType=${k.kartType} kartsAfter=${this.state.karts.size}/${this.maxClients}`);

      // First player to arrive starts the matchmaking wait window.
      // Solo (maxClients=1) skips the wait entirely.
      if (this.state.karts.size === 1 && this.maxClients > 1 && this.state.waitingUntilMs === 0) {
        this.state.waitingUntilMs = Date.now() + AUTO_START_AFTER_MS;
        console.log(`[race:${this.raceId}] wait window started — auto-start in ${AUTO_START_AFTER_MS / 1000}s`);
        // Schedule the auto-start fallback (cancelled below if everyone is
        // ready earlier).
        this.clock.setTimeout(() => this._tryAutoStart(), AUTO_START_AFTER_MS);
      }
      // Full room: try to start immediately (still gated by everyone being ready).
      if (this.state.karts.size >= this.maxClients) {
        this._maybeStartCountdown();
      }
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
    // Quick-race gate: wait for room to be FULL (server set maxClients from
    // client opts: 2 / 4 / 8). Solo rooms (maxClients = 1) skip this.
    if (this.maxClients > 1 && this.state.karts.size < this.maxClients) return;
    let allReady = true;
    this.state.karts.forEach((k) => { if (!k.ready) allReady = false; });
    if (!allReady) return;
    this._startCountdown();
  }

  /**
   * Called by the AUTO_START_AFTER_MS clock when the wait window expires.
   * Starts the race with however many players are present (provided they
   * are all marked ready).
   */
  private _tryAutoStart() {
    if (this.state.phase !== "waiting") return;
    if (this.state.karts.size < 1) return;
    let allReady = true;
    this.state.karts.forEach((k) => { if (!k.ready) allReady = false; });
    if (!allReady) {
      console.log(`[race:${this.raceId}] auto-start fired but ${this._readyCount()}/${this.state.karts.size} ready — waiting`);
      return;
    }
    console.log(`[race:${this.raceId}] auto-start: room not full (${this.state.karts.size}/${this.maxClients}) but window expired`);
    this._startCountdown();
  }

  private _startCountdown() {
    this.state.phase = "countdown";
    this.state.waitingUntilMs = 0;
    this.setMetadata({ raceId: this.raceId, phase: "countdown", maxPlayers: this.maxClients }).catch(() => undefined);
    let s = COUNTDOWN_SECONDS;
    this.broadcast("countdown", { seconds: s });
    const tick = () => {
      s -= 1;
      this.broadcast("countdown", { seconds: s });
      if (s <= 0) {
        this.state.phase = "racing";
        this.state.startTimestamp = Date.now();
        this.setMetadata({ raceId: this.raceId, phase: "racing", maxPlayers: this.maxClients }).catch(() => undefined);
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
      // Lap progress is stubbed: paced so a full N-lap race lands at exactly
      // MIN_RACE_DURATION_MS (5 min for 3 laps). TODO: real track-segment
      // crossing logic — when that lands, this stub can go away but the
      // MIN_RACE_DURATION_MS finish floor below must stay.
      const elapsedMs = Date.now() - this.state.startTimestamp;
      const lapsToRun = Math.max(1, this.state.totalLaps);
      const stubLapIntervalMs = MIN_RACE_DURATION_MS / lapsToRun;
      if (kart.lap < this.state.totalLaps &&
          elapsedMs > (kart.lap + 1) * stubLapIntervalMs) {
        kart.lap += 1;
        this.broadcast("lap", {
          playerId: sessionId,
          lapNumber: kart.lap,
          lapTime: stubLapIntervalMs / 1000,
        });
      }
      // Finish gate: a player only finishes after completing every lap AND
      // after the minimum race duration has elapsed. The stub naturally
      // satisfies both at the same instant; a future real-lap-detection
      // implementation will still be capped at MIN_RACE_DURATION_MS so
      // quick races (or accidental teleports) can't end early.
      if (kart.lap >= this.state.totalLaps && elapsedMs >= MIN_RACE_DURATION_MS) {
        kart.finished = true;
        kart.finishTime = elapsedMs / 1000;
        this._finishKart(sessionId, kart);
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
   *
   * raceId formats:
   *   quick-Np-<trackId>   - new MapSelect format, track is explicit
   *   quick-Np             - legacy quick-race (no map pick) — rotates by day
   *   free-<trackId>       - lobby browser free-practice rooms
   *   wager-0.01-sol       - paid wager, fixed track
   *   wager-0.1-sol        - paid wager, fixed track
   *   anything else        - first race-eligible bundled track
   */
  private _deriveTrackId(raceId: string): string {
    const bundledList = (
      process.env.CLIENT_BUNDLED_TRACKS ??
      "lighthouse,snowmountain,scotland,snowtuxpeak,sandtrack"
    )
      .split(",").map((s) => s.trim()).filter(Boolean);
    const bundled = new Set(bundledList);
    const fallback = bundled.has("lighthouse") ? "lighthouse" : (bundledList[0] ?? "default");

    // quick-Np-<trackId> — MapSelect-driven format.
    const quickMatch = /^quick-\d+p-(.+)$/.exec(raceId);
    if (quickMatch) {
      const t = quickMatch[1];
      return bundled.has(t) ? t : fallback;
    }

    // Legacy quick-Np (no map pick) — rotate by day.
    if (/^quick-\d+p$/.test(raceId) && bundledList.length > 0) {
      const d = new Date();
      const daySeed = (d.getUTCFullYear() * 10000) + ((d.getUTCMonth() + 1) * 100) + d.getUTCDate();
      return bundledList[daySeed % bundledList.length];
    }

    let candidate = "";
    if (raceId.startsWith("free-")) candidate = raceId.slice("free-".length);
    else if (raceId === "wager-0.01-sol") candidate = "lighthouse";
    else if (raceId === "wager-0.1-sol")  candidate = "cocoa_temple";
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
