import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // The example graphs live next to the compiler, not under editor/, so the
  // dev server has to be allowed to read one level up.
  server: { port: 5173, fs: { allow: [".."] } },
});
