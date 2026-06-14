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
    const room = await colyseus.createRoom("race", {
      raceId: "free-rookie",
      entryFeeLamports: "0",
    });
    const client = await colyseus.connectTo(room, { raceId: "free-rookie", wallet: "" });
    expect(room.state.karts.size).toBe(1);

    await client.send("ready", {});
    await new Promise((r) => setTimeout(r, 100));
    expect(["countdown", "racing"]).toContain(room.state.phase);

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });
});
