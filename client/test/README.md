# Godot client tests

GdUnit4-based unit tests for the Kartchain Godot client (autoloads,
Kart controller, TrackLoader).

## One-time setup

GdUnit4 is gitignored under `addons/` because committing the full addon
(~100 files, ~5 MB) would bloat the repo. Install it locally with:

```bash
# from kartchain/client/
git clone --depth 1 https://github.com/MikeSchulze/gdUnit4.git addons/gdUnit4
```

Then open the project in Godot once so it imports the plugin, and enable
**Project → Project Settings → Plugins → gdUnit4**.

## Running the suite

From the repo root:

```bash
# Headless — produces JUnit-format reports for CI
godot --headless --path client \
  -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --run-tests --report-directory ./reports
```

Or per-file:

```bash
godot --headless --path client \
  -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --run-tests --add res://test/kart_test.gd
```

Or via pnpm from repo root:

```bash
pnpm test:client
```

## What's covered

| File | Covers |
|---|---|
| `track_loader_test.gd` | `grid_slot` math, `spawn_offset` default, `GROUND_LIFT` |
| `kart_catalog_test.gd` | `kart_model_path` index wrap, `has_bundled_track` filter |
| `kart_test.gd` | `apply_stats` tuning, `recover()` transform + cooldown |

Tests are written for the **golden behavior** — what the code *should*
do per the design contract — not calibrated to the current
implementation. If a test fails, fix the code; don't relax the test.
