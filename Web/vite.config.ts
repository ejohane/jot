import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => ({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: { input: mode === "motion-lab" ? ["index.html", "lab.html"] : ["index.html"] },
  },
  test: {
    environment: "jsdom",
  },
}));
