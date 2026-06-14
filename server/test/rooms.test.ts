import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { boot, ColyseusTestServer } from "@colyseus/testing";
import { Server } from "@colyseus/core";
import { LobbyRoom } from "../src/rooms/LobbyRoom.js";
import { RaceRoom } from "../src/rooms/RaceRoom.js";

describe("Kartchain rooms", () => {
  let colyseus: ColyseusTestServer;

  beforeAll(async () => {
    colyseus = await boot({
      initializeGameServer: (server: Server) => {
        server.define("lobby", LobbyRoom);
        server.define("race", RaceRoom);
      },
    });
  });

  afterAll(async () => {
    await colyseus.shutdown();
  });

  it("lobby seeds default lobbies on create", async () => {
    const room = await colyseus.createRoom("lobby", {});
    expect(room.state.lobbies.length).toBeGreaterThanOrEqual(3);
    // We seed at least 3 free-* lobbies + 2 wager-* lobbies from the STK
    // track catalog. The specific track ids rotate daily.
    const freeLobbies = room.state.lobbies.filter((l) => l.id.startsWith("free-"));
    const wagerLobbies = room.state.lobbies.filter((l) => l.id.startsWith("wager-"));
    expect(freeLobbies.length).toBeGreaterThan(0);
    expect(wagerLobbies.length).toBeGreaterThan(0);
    // Free lobbies must have zero entry fee
    for (const l of freeLobbies) expect(Number(l.entryFeeLamports)).toBe(0);
  });

  it("race accepts a free lobby join and starts countdown after ready", async () => {
    // maxPlayers: 1 → solo race, countdown should fire as soon as the only
    // player marks themselves ready.
    const room = await colyseus.createRoom("race", {
      raceId: "free-rookie",
      entryFeeLamports: "0",
      maxPlayers: 1,
    });
    const client = await colyseus.connectTo(room, {
      raceId: "free-rookie", wallet: "", maxPlayers: 1,
    });
    expect(room.state.karts.size).toBe(1);

    await client.send("ready", {});
    await new Promise((r) => setTimeout(r, 100));
    expect(["countdown", "racing"]).toContain(room.state.phase);

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });

  it("race with maxPlayers > 1 stays waiting until room is full", async () => {
    // 2-player room with only 1 ready player must NOT start (until either
    // a second player joins or the auto-start window expires — 30s).
    const room = await colyseus.createRoom("race", {
      raceId: "quick-2p-test",
      entryFeeLamports: "0",
      maxPlayers: 2,
    });
    const client = await colyseus.connectTo(room, {
      raceId: "quick-2p-test", wallet: "", maxPlayers: 2,
    });
    expect(room.state.karts.size).toBe(1);
    expect(room.state.maxPlayers).toBe(2);
    expect(room.state.waitingUntilMs).toBeGreaterThan(Date.now());

    await client.send("ready", {});
    await new Promise((r) => setTimeout(r, 150));
    // Still waiting — only 1/2 players present.
    expect(room.state.phase).toBe("waiting");

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });
});
