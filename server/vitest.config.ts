import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Use threads pool to avoid process.send() interference from PM2/APM
    // agents that some Windows envs auto-inject via NODE_OPTIONS.
    pool: "threads",
    poolOptions: {
      threads: {
        singleThread: true,
      },
    },
    // Long timeout for Colyseus room boot
    testTimeout: 10_000,
  },
});
