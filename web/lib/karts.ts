"use client";

import { useEffect, useState } from "react";
import { fetchOwnedKarts, type OwnedKart } from "./karts-fetch";

export function useOwnedKarts(wallet?: string) {
  const [karts, setKarts] = useState<OwnedKart[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!wallet) { setKarts([]); return; }
    let cancelled = false;
    setLoading(true);
    fetchOwnedKarts(wallet)
      .then((k) => { if (!cancelled) setKarts(k); })
      .catch((err) => { console.error(err); if (!cancelled) setKarts([]); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [wallet]);

  return { karts, loading };
}
