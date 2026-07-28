import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // The example graphs live next to the compiler, not under editor/, so the
  // dev server has to be allowed to read one level up.
  server: {
    port: 5173,
    fs: { allow: [".."] },
    // SharedArrayBuffer, which is how a breakpoint holds the worker still,
    // is only handed out to a cross-origin isolated page.
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
  preview: {
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
});
