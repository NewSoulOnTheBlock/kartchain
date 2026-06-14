#!/usr/bin/env node
/**
 * import-stk-catalog.mjs
 *
 * Walks ./stk-assets-src/ (sparse-cloned by fetch-stk-assets.ps1), parses
 * each asset's metadata, and produces:
 *
 *   ../client/karts/<name>/        (source assets: .spm/.blend/.b3d + .png + meta.json)
 *   ../client/tracks/<name>/       (same)
 *   ../client/library/             (shared library objects)
 *   ../client/music/               (.ogg files)
 *   ../client/sfx/                 (.ogg files)
 *
 *   ../client/karts/_catalog.json  ({ karts: [{id, name, stats, model, textures}] })
 *   ../client/tracks/_catalog.json
 *
 *   ./ATTRIBUTION.md               (full credits)
 *
 * Note: the .spm and .b3d files are NOT yet converted to .glb. Godot's
 * Web export can't render them directly — see assets-import/convert-models.ps1
 * for the Blender-based conversion step (needs the blender-stk-tools addon).
 *
 * Until conversion is done, the Godot client should fall back to the
 * built-in placeholder BoxMesh kart.
 *
 * Usage:  cd assets-import && node import-stk-catalog.mjs
 */
import { promises as fs } from "node:fs";
import { existsSync, statSync } from "node:fs";
import { join, relative, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE     = dirname(fileURLToPath(import.meta.url));
const SRC      = join(HERE, "stk-assets-src");
const CLIENT   = join(HERE, "..", "client");
const ATTR_OUT = join(HERE, "ATTRIBUTION.md");

if (!existsSync(SRC)) {
  console.error(`stk-assets-src/ missing. Run fetch-stk-assets.ps1 first.`);
  process.exit(1);
}

// ─── minimal XML parser (just attribute extraction; no DTD/namespaces) ───
function parseXml(text) {
  // We only need name=value pairs from <tag attr="val" /> nodes plus the
  // top-level tag name and one level of children. Real XML parsing in pure
  // JS would pull a dep; a regex pass is enough for STK's flat configs.
  const tags = [];
  const reTag = /<([a-zA-Z][\w-]*)((?:\s+[\w:-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*\/?>/g;
  let m;
  while ((m = reTag.exec(text))) {
    const tagName = m[1];
    const attrs = {};
    const reAttr = /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
    let a;
    while ((a = reAttr.exec(m[2]))) attrs[a[1]] = a[2] ?? a[3] ?? "";
    tags.push({ tag: tagName, attrs });
  }
  return tags;
}

function findTag(tags, name) {
  return tags.find((t) => t.tag === name)?.attrs ?? null;
}

async function readIfExists(path) {
  try { return await fs.readFile(path, "utf-8"); }
  catch { return null; }
}

async function ensureDir(p) { await fs.mkdir(p, { recursive: true }); }

async function copyDir(src, dst, opts = {}) {
  const { skipExt = [] } = opts;
  await ensureDir(dst);
  for (const entry of await fs.readdir(src, { withFileTypes: true })) {
    const s = join(src, entry.name);
    const d = join(dst, entry.name);
    if (entry.isDirectory()) {
      await copyDir(s, d, opts);
    } else {
      if (skipExt.some((e) => entry.name.toLowerCase().endsWith(e))) continue;
      await fs.copyFile(s, d);
    }
  }
}

async function listDirs(p) {
  if (!existsSync(p)) return [];
  return (await fs.readdir(p, { withFileTypes: true }))
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
}

// ─── kart processor ──────────────────────────────────────────────────────
async function processKart(name) {
  const srcDir = join(SRC, "karts", name);
  const dstDir = join(CLIENT, "karts", name);

  const kartXml = await readIfExists(join(srcDir, "kart.xml"));
  if (!kartXml) return null;

  const tags = parseXml(kartXml);
  const k    = findTag(tags, "kart") ?? {};

  const model = k["model-file"] ?? `${name}.spm`;
  const icon  = k["icon-file"] ?? `${name}_icon.png`;
  const minimap = k["minimap-icon-file"] ?? icon;
  const shadow  = k["shadow-file"] ?? "";

  // STK kart "type" gives us a rough stat profile (light/medium/heavy)
  // Real per-stat tuning lives in stk-code's data/stk_config.xml; we
  // derive stats from the kart `type` since stk-assets-mobile only ships
  // per-kart XML with type+groups.
  const profileByType = {
    light:  { topSpeed: 0.85, accel: 0.95, handling: 0.95 },
    medium: { topSpeed: 0.90, accel: 0.80, handling: 0.80 },
    heavy:  { topSpeed: 1.00, accel: 0.60, handling: 0.60 },
  };
  const stats = profileByType[k.type ?? "medium"] ?? profileByType.medium;

  // Pull author/license from licenses.txt if present
  const licensesTxt = await readIfExists(join(srcDir, "licenses.txt"));
  const author = extractAuthor(licensesTxt) ?? "STK contributors";

  await copyDir(srcDir, dstDir, { skipExt: [".blend1", ".blend2"] });
  await fs.writeFile(
    join(dstDir, "meta.json"),
    JSON.stringify({ id: name, displayName: k.name ?? name, type: k.type ?? "medium",
                     groups: k.groups ?? "standard", rgb: k.rgb ?? "",
                     author, model, icon, minimap, shadow, stats }, null, 2)
  );

  return {
    id: name,
    name: k.name ?? name,
    type: k.type ?? "medium",
    groups: (k.groups ?? "standard").split(",").map((s) => s.trim()),
    author,
    license: "CC-BY-SA 4.0",
    model: `karts/${name}/${model}`,
    icon:  `karts/${name}/${icon}`,
    minimapIcon: `karts/${name}/${minimap}`,
    shadow: shadow ? `karts/${name}/${shadow}` : null,
    rgb: k.rgb ?? "",
    stats,
  };
}

function extractAuthor(licensesTxt) {
  if (!licensesTxt) return null;
  // Look for "by Author" or "Author: X" or "Copyright X"
  const m = licensesTxt.match(/(?:^|\n)\s*(?:by|author[:\s]|copyright)\s+([^\n,]+)/i);
  return m ? m[1].trim() : null;
}

// ─── track processor ─────────────────────────────────────────────────────
async function processTrack(name) {
  const srcDir = join(SRC, "tracks", name);
  const dstDir = join(CLIENT, "tracks", name);

  const trackXml = await readIfExists(join(srcDir, "track.xml"));
  if (!trackXml) return null;
  const tags = parseXml(trackXml);
  const t = findTag(tags, "track") ?? {};

  const licensesTxt = await readIfExists(join(srcDir, "licenses.txt"));
  const designer = extractAuthor(licensesTxt) ?? t.designer ?? "STK contributors";

  // Track main model — STK names it "<trackname>_track.spm" or similar.
  // Find the first .spm that contains "track" in its name, else any .spm.
  const files = await fs.readdir(srcDir);
  const spmFiles = files.filter((f) => f.endsWith(".spm"));
  const mainSpm = spmFiles.find((f) => /track/i.test(f)) ?? spmFiles[0] ?? null;
  const screenshot = files.find((f) => /^screenshot\./i.test(f)) ?? null;

  await copyDir(srcDir, dstDir, { skipExt: [".blend1", ".blend2"] });
  const yes = (v) => v === "true" || v === "Y" || v === "yes";
  await fs.writeFile(
    join(dstDir, "meta.json"),
    JSON.stringify({
      id: name, displayName: t.name ?? name,
      groups: t.groups ?? "standard",
      arena: yes(t.arena),
      soccer: yes(t.soccer),
      cutscene: yes(t.cutscene),
      designer, license: "CC-BY-SA 4.0",
      mainModel: mainSpm, screenshot,
    }, null, 2)
  );

  return {
    id: name,
    name: t.name ?? name,
    designer,
    license: "CC-BY-SA 4.0",
    groups: (t.groups ?? "standard").split(",").map((s) => s.trim()),
    isArena: yes(t.arena),
    isSoccer: yes(t.soccer),
    isCutscene: yes(t.cutscene),
    mainModel: mainSpm ? `tracks/${name}/${mainSpm}` : null,
    sceneFile: existsSync(join(srcDir, "scene.xml")) ? `tracks/${name}/scene.xml` : null,
    screenshot: screenshot ? `tracks/${name}/${screenshot}` : null,
    metaJson: `tracks/${name}/meta.json`,
  };
}

function clamp01(x) {
  if (!isFinite(x)) return 0.5;
  return Math.max(0, Math.min(1, x));
}

// ─── attribution generator ───────────────────────────────────────────────
async function collectAttribution(kinds) {
  const lines = [];
  lines.push("# Asset attribution");
  lines.push("");
  lines.push("Kartchain reuses art, models, and audio from the");
  lines.push("[SuperTuxKart](https://supertuxkart.net/) project. All listed assets");
  lines.push("are © their original authors and licensed under");
  lines.push("[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)");
  lines.push("unless a per-asset `licenses.txt` says otherwise.");
  lines.push("");
  lines.push(`Generated by \`assets-import/import-stk-catalog.mjs\` on ${new Date().toISOString().slice(0, 10)}.`);
  lines.push("");
  for (const kind of kinds) {
    const dir = join(SRC, kind);
    if (!existsSync(dir)) continue;
    lines.push(`## ${kind}`);
    lines.push("");
    for (const sub of await listDirs(dir)) {
      lines.push(`### ${kind}/${sub}`);
      const lic = await readIfExists(join(dir, sub, "licenses.txt"))
              ?? await readIfExists(join(dir, sub, "license.txt"))
              ?? await readIfExists(join(dir, sub, "LICENSE.txt"))
              ?? await readIfExists(join(dir, sub, "LICENSE"));
      if (lic) {
        lines.push("");
        lines.push("```");
        lines.push(lic.trim());
        lines.push("```");
      } else {
        lines.push("");
        lines.push("_(no per-asset license file; assume CC-BY-SA 4.0 per the STK repo default)_");
      }
      lines.push("");
    }
  }
  // music has its own per-track .music files with licenses
  const musicDir = join(SRC, "music");
  if (existsSync(musicDir)) {
    lines.push("## music");
    lines.push("");
    const files = await fs.readdir(musicDir);
    for (const f of files.filter((n) => n.endsWith(".music"))) {
      const txt = await readIfExists(join(musicDir, f));
      if (!txt) continue;
      lines.push(`### music/${basename(f, ".music")}`);
      lines.push("");
      lines.push("```");
      lines.push(txt.trim());
      lines.push("```");
      lines.push("");
    }
  }
  return lines.join("\n");
}

// ─── main ────────────────────────────────────────────────────────────────
async function main() {
  const t0 = Date.now();
  await ensureDir(join(CLIENT, "karts"));
  await ensureDir(join(CLIENT, "tracks"));
  await ensureDir(join(CLIENT, "library"));
  await ensureDir(join(CLIENT, "music"));
  await ensureDir(join(CLIENT, "sfx"));

  console.log("[catalog] scanning karts...");
  const kartNames = await listDirs(join(SRC, "karts"));
  const karts = [];
  for (const name of kartNames) {
    try {
      const k = await processKart(name);
      if (k) { karts.push(k); console.log(`  ✓ kart  ${name}`); }
    } catch (err) { console.warn(`  ✗ kart  ${name}: ${err.message}`); }
  }
  await fs.writeFile(
    join(CLIENT, "karts", "_catalog.json"),
    JSON.stringify({ generatedAt: new Date().toISOString(), karts }, null, 2)
  );

  console.log("[catalog] scanning tracks...");
  const trackNames = await listDirs(join(SRC, "tracks"));
  const tracks = [];
  for (const name of trackNames) {
    try {
      const t = await processTrack(name);
      if (t) { tracks.push(t); console.log(`  ✓ track ${name}`); }
    } catch (err) { console.warn(`  ✗ track ${name}: ${err.message}`); }
  }
  await fs.writeFile(
    join(CLIENT, "tracks", "_catalog.json"),
    JSON.stringify({ generatedAt: new Date().toISOString(), tracks }, null, 2)
  );

  console.log("[catalog] copying library...");
  if (existsSync(join(SRC, "library"))) {
    await copyDir(join(SRC, "library"), join(CLIENT, "library"), { skipExt: [".blend1", ".blend2"] });
  }
  console.log("[catalog] copying music...");
  if (existsSync(join(SRC, "music"))) {
    await copyDir(join(SRC, "music"), join(CLIENT, "music"));
  }
  console.log("[catalog] copying sfx...");
  if (existsSync(join(SRC, "sfx"))) {
    await copyDir(join(SRC, "sfx"), join(CLIENT, "sfx"));
  }

  console.log("[catalog] generating ATTRIBUTION.md...");
  const attribution = await collectAttribution(["karts", "tracks", "characters", "library"]);
  await fs.writeFile(ATTR_OUT, attribution);

  // Also copy attribution into client/ so it ships inside the WASM bundle
  await fs.copyFile(ATTR_OUT, join(CLIENT, "ATTRIBUTION.md"));

  // Stats line
  const sizeBytes = await dirSize(join(CLIENT, "karts")) + await dirSize(join(CLIENT, "tracks"))
                  + await dirSize(join(CLIENT, "library")) + await dirSize(join(CLIENT, "music"))
                  + await dirSize(join(CLIENT, "sfx"));
  console.log("");
  console.log(`[catalog] DONE — ${karts.length} karts, ${tracks.length} tracks`);
  console.log(`           total imported: ${(sizeBytes / 1024 / 1024).toFixed(1)} MB`);
  console.log(`           elapsed: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  console.log("");
  console.log("Next: install Blender + blender-stk-tools to convert .spm models to .glb");
  console.log("      (see assets-import/STK-FORMAT-NOTES.md)");
}

async function dirSize(p) {
  if (!existsSync(p)) return 0;
  let total = 0;
  for (const entry of await fs.readdir(p, { withFileTypes: true })) {
    const sub = join(p, entry.name);
    if (entry.isDirectory()) total += await dirSize(sub);
    else total += statSync(sub).size;
  }
  return total;
}

main().catch((err) => { console.error(err); process.exit(1); });
