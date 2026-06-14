import { Room, Client, matchMaker } from "@colyseus/core";
import { Schema, ArraySchema, type } from "@colyseus/schema";
import { pickRaceTracks, type TrackEntry } from "../content/catalog.js";

class LobbyEntry extends Schema {
  @type("string") id = "";
  @type("string") trackId = "default";
  @type("string") trackName = "";
  @type("uint8")  players = 0;
  @type("uint8")  maxPlayers = 8;
  /** lamports as a plain number; see RaceState comment for why */
  @type("number") entryFeeLamports = 0;
  /** waiting | racing | full */
  @type("string") status = "waiting";
}

class LobbyState extends Schema {
  @type({ array: LobbyEntry }) lobbies = new ArraySchema<LobbyEntry>();
}

/**
 * Always-on room that lists open RaceRooms and matchmakes players into them.
 */
export class LobbyRoom extends Room<LobbyState> {
  maxClients = 200;
  private _refreshHandle?: NodeJS.Timeout;

  onCreate() {
    this.setState(new LobbyState());
    this._seedDefaultLobbies();

    this._refreshHandle = setInterval(() => this._refresh(), 2000);

    this.onMessage("joinRace", async (client, payload: { raceId?: string }) => {
      const id = payload?.raceId;
      if (!id) {
        client.send("error", { code: "BAD_REQUEST", message: "raceId required" });
        return;
      }
      const lobby = this.state.lobbies.find((l) => l.id === id);
      if (!lobby) {
        client.send("error", { code: "NOT_FOUND", message: `No lobby ${id}` });
        return;
      }
      if (lobby.players >= lobby.maxPlayers) {
        client.send("error", { code: "FULL", message: "Lobby full" });
        return;
      }
      // The actual race-room join happens client-side via colyseus.js
      // after this message — the lobby just returns the room name to join.
      client.send("joinAck", { roomName: "race", filter: { raceId: id } });
    });
  }

  onDispose() {
    if (this._refreshHandle) clearInterval(this._refreshHandle);
  }

  /**
   * Seed lobbies from real STK race tracks. We create:
   *   - 1 free practice lobby per featured track (rotates daily)
   *   - 2 wager lobbies (0.01 SOL, 0.1 SOL) on hand-picked classic tracks
   *
   * Fallback: if the catalog is empty (assets not imported yet), seed with
   * placeholder track ids so the lobby still appears.
   */
  private _seedDefaultLobbies() {
    const all = pickRaceTracks();

    // Featured rotation: pick 3 random race tracks based on the date
    const featured = pickDeterministic(all, 3, daySeed());

    // Hand-picked tracks for paid wagers (fallback to first available)
    const lighthouse = all.find((t) => t.id === "lighthouse") ?? all[0];
    const cocoa      = all.find((t) => t.id === "cocoa_temple") ?? all[1] ?? lighthouse;
    const volcano    = all.find((t) => t.id === "volcano_island") ?? all[2] ?? lighthouse;

    // Free practice — multiple lobbies, one per featured track
    if (featured.length > 0) {
      for (const t of featured) {
        this._addLobby({
          id: `free-${t.id}`,
          track: t,
          maxPlayers: 8,
          entryFeeLamports: 0,
        });
      }
    } else {
      // Catalog missing — still show *something*
      this._addLobby({
        id: "free-rookie",
        track: { id: "default", name: "Placeholder Loop" } as TrackEntry,
        maxPlayers: 8,
        entryFeeLamports: 0,
      });
    }

    if (lighthouse) {
      this._addLobby({
        id: "wager-0.01-sol",
        track: cocoa ?? lighthouse,
        maxPlayers: 8,
        entryFeeLamports: 10_000_000, // 0.01 SOL
      });
      this._addLobby({
        id: "wager-0.1-sol",
        track: volcano ?? lighthouse,
        maxPlayers: 8,
        entryFeeLamports: 100_000_000, // 0.1 SOL
      });
    }
  }

  private _addLobby(opts: {
    id: string;
    track: { id: string; name: string };
    maxPlayers: number;
    entryFeeLamports: number;
  }) {
    const entry = new LobbyEntry();
    entry.id = opts.id;
    entry.trackId = opts.track.id;
    entry.trackName = opts.track.name;
    entry.maxPlayers = opts.maxPlayers;
    entry.entryFeeLamports = opts.entryFeeLamports;
    entry.players = 0;
    entry.status = "waiting";
    this.state.lobbies.push(entry);
  }

  /** Poll matchmaker for current race-room populations. */
  private async _refresh() {
    const rooms = await matchMaker.query({ name: "race" });
    for (const lobby of this.state.lobbies) {
      const live = rooms.find((r) => r.metadata?.raceId === lobby.id);
      if (live) {
        lobby.players = live.clients;
        lobby.status = live.clients >= lobby.maxPlayers ? "full"
                     : (live.metadata?.phase === "racing" ? "racing" : "waiting");
      } else {
        lobby.players = 0;
        lobby.status = "waiting";
      }
    }
  }
}

// ─── helpers ───────────────────────────────────────────────────────────
function daySeed(): number {
  const d = new Date();
  return (d.getUTCFullYear() * 10000) + ((d.getUTCMonth() + 1) * 100) + d.getUTCDate();
}

/** Stable pseudo-random pick of N items seeded by `seed`. */
function pickDeterministic<T>(arr: T[], n: number, seed: number): T[] {
  if (arr.length <= n) return [...arr];
  const out: T[] = [];
  const used = new Set<number>();
  let s = seed;
  while (out.length < n) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    const idx = s % arr.length;
    if (used.has(idx)) continue;
    used.add(idx);
    out.push(arr[idx]);
  }
  return out;
}
