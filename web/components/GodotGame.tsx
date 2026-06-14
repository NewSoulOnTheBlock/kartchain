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
 */
import { useEffect, useRef } from "react";

export function GodotGame() {
  const iframeRef = useRef<HTMLIFrameElement>(null);
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
    return () => f.removeEventListener("load", install);
  }, []);

  return (
    <iframe
      ref={iframeRef}
      title="Kartchain game"
      src={`/game/index.html${cacheBust.current}`}
      allow="autoplay; gamepad; fullscreen"
      allowFullScreen
    />
  );
}
