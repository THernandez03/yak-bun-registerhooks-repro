console.log("runtime:", process.versions.bun ? "bun " + process.versions.bun : "node " + process.version);
import { viteYak } from "@yak/react/vite";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [viteYak()],
});
