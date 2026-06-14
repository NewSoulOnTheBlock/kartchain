import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Loads and caches the STK asset catalogs produced by
 * assets-import/import-stk-catalog.mjs.
 *
 * Falls back to empty catalogs (allowing the server to start without
 * imported assets) — race rooms will then use the placeholder track id.
 */

export type KartEntry = {
  id: string;
  name: string;
  type: "light" | "medium" | "heavy";
  groups: string[];
  author: string;
  license: string;
  model: string;
  icon: string;
  minimapIcon: string;
  shadow: string | null;
  rgb: string;
  stats: { topSpeed: number; accel: number; handling: number };
};

export type TrackEntry = {
  id: string;
  name: string;
  designer: string;
  license: string;
  groups: string[];
  isArena: boolean;
  isSoccer: boolean;
  isCutscene: boolean;
  mainModel: string | null;
  sceneFile: string | null;
  screenshot: string | null;
  metaJson: string;
};

const HERE = dirname(fileURLToPath(import.meta.url));
// src/content/catalog.ts → ../../../client/karts/_catalog.json
const KARTS_PATH  = resolve(HERE, "..", "..", "..", "client", "karts", "_catalog.json");
const TRACKS_PATH = resolve(HERE, "..", "..", "..", "client", "tracks", "_catalog.json");

let _karts: KartEntry[] | null = null;
let _tracks: TrackEntry[] | null = null;

export function loadKartCatalog(): KartEntry[] {
  if (_karts) return _karts;
  if (!existsSync(KARTS_PATH)) {
    console.warn(`[catalog] no kart catalog at ${KARTS_PATH} — run assets-import/import-stk-catalog.mjs`);
    _karts = [];
    return _karts;
  }
  const raw = JSON.parse(readFileSync(KARTS_PATH, "utf-8"));
  _karts = raw.karts ?? [];
  console.log(`[catalog] loaded ${_karts!.length} karts`);
  return _karts!;
}

export function loadTrackCatalog(): TrackEntry[] {
  if (_tracks) return _tracks;
  if (!existsSync(TRACKS_PATH)) {
    console.warn(`[catalog] no track catalog at ${TRACKS_PATH} — run assets-import/import-stk-catalog.mjs`);
    _tracks = [];
    return _tracks;
  }
  const raw = JSON.parse(readFileSync(TRACKS_PATH, "utf-8"));
  _tracks = raw.tracks ?? [];
  console.log(`[catalog] loaded ${_tracks!.length} tracks`);
  return _tracks!;
}

/** Returns true if a track is a real racing circuit (not arena/soccer/cutscene). */
export function isRaceTrack(t: TrackEntry): boolean {
  if (t.isArena || t.isSoccer || t.isCutscene) return false;
  const skip = new Set([
    "overworld", "tutorial", "endcutscene", "introcutscene", "introcutscene2",
    "featunlocked", "gplose", "gpwin", "stadium", "stk_enterprise",
  ]);
  return !skip.has(t.id);
}

export function pickRaceTracks(): TrackEntry[] {
  return loadTrackCatalog().filter(isRaceTrack);
}
