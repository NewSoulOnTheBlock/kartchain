"use client";

/**
 * GodotGame
 *
 * Hosts the exported Godot 4 HTML5 build via an <iframe>.
 *
 * The Godot WASM autoloads run before our React `useEffect` can synchronously
 * inject anything, so we use a getter on `iframe.contentWindow.kartchain` that
 * always reads the parent's current value. The Godot side polls until the
 * bridge appears (see NetworkClient.gd._try_init_bridge).
 *
 * While the WASM is downloading + initializing we overlay a TrenchKart boot
 * splash so the user never sees Godot's default loading screen.
 */
import { useEffect, useRef, useState } from "react";

export function GodotGame() {
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [loading, setLoading] = useState(true);
  // Mounted-once cache-buster. Changes every time the React tree mounts,
  // so a manual reload forces a fresh fetch of /game/index.* assets.
  const cacheBust = useRef(`?v=${Date.now()}`);

  useEffect(() => {
    const f = iframeRef.current;
    if (!f) return;

    const install = () => {
      try {
        const w = f.contentWindow as any;
        if (!w) return;
        Object.defineProperty(w, "kartchain", {
          configurable: true,
          get() { return (window as any).kartchain; },
        });

        // ── Aggressive focus: the Godot WASM canvas is the actual key event
        // target. The iframe element itself is not focusable by default, and
        // even with tabIndex set, only the canvas inside the iframe receives
        // keystrokes. We re-grab focus on every click/pointerdown.
        const focusCanvas = () => {
          try {
            const d = w.document;
            const canvas = d?.getElementById?.("canvas") ?? d?.querySelector?.("canvas");
            canvas?.focus?.();
            if (canvas && typeof canvas.click === "function") {
              // Some browsers need a real focus event — clicking puts the
              // canvas in active focus state for key events.
              canvas.setAttribute?.("tabindex", "0");
            }
          } catch (e) {}
        };
        try {
          w.addEventListener("click", focusCanvas, true);
          w.addEventListener("pointerdown", focusCanvas, true);
          w.document?.addEventListener?.("click", focusCanvas, true);
          focusCanvas();
          // Periodically re-attempt focus until canvas exists (Godot loads async)
          let tries = 0;
          const id = w.setInterval(() => {
            focusCanvas();
            if (++tries > 20) w.clearInterval(id);
          }, 500);
        } catch (err) {
          console.warn("[GodotGame] focus install failed", err);
        }
        console.log("[GodotGame] kartchain bridge proxied into iframe");
      } catch (err) {
        console.warn("[GodotGame] cross-origin iframe — bridge not injected", err);
      }
    };

    // Install immediately (in case iframe is already loaded) AND on every load
    // (covers reloads, navigations inside iframe).
    install();
    f.addEventListener("load", install);

    // Poll for the Godot canvas to actually exist + be sized. Once the WASM
    // has booted and the first scene has rendered, the <canvas> picks up a
    // non-zero width — that's our cue to fade the boot splash out.
    let readyTries = 0;
    const readyPoll = window.setInterval(() => {
      readyTries++;
      try {
        const w = f.contentWindow as any;
        const canvas = w?.document?.getElementById?.("canvas")
          ?? w?.document?.querySelector?.("canvas");
        if (canvas && canvas.width > 0 && canvas.height > 0) {
          // Give the first scene one extra render frame before swapping out,
          // so the user doesn't see the canvas clear-color flash.
          window.setTimeout(() => setLoading(false), 500);
          window.clearInterval(readyPoll);
        }
      } catch {}
      // Safety: never block the user behind the splash for more than ~25s.
      if (readyTries > 250) {
        setLoading(false);
        window.clearInterval(readyPoll);
      }
    }, 100);

    return () => {
      f.removeEventListener("load", install);
      window.clearInterval(readyPoll);
    };
  }, []);

  return (
    <div className="godot-host">
      <iframe
        ref={iframeRef}
        title="Kartchain game"
        src={`/game/index.html${cacheBust.current}`}
        allow="autoplay; gamepad; fullscreen"
        allowFullScreen
      />
      {loading && (
        <div className="tk-boot" aria-label="Loading TrenchKart">
          <div className="tk-boot-logo">
            <span className="tk-trench">TRENCH</span>
            <span className="tk-kart">KART</span>
          </div>
          <div className="tk-boot-bar"><div className="tk-boot-bar-fill" /></div>
          <div className="tk-boot-text">LOADING…</div>
        </div>
      )}
    </div>
  );
}

