import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  base: "./",
  plugins: [
    react(),
    {
      name: "classic-script",
      transformIndexHtml(html) {
        return html
          .replaceAll(' type="module"', "")
          .replaceAll(" crossorigin", "")
          .replaceAll("<script src=", "<script defer src=");
      },
    },
  ],
  worker: { format: "es" },
  build: {
    outDir: path.resolve(root, "../../Sources/ReaderUI/Resources/Excalidraw"),
    emptyOutDir: true,
    assetsInlineLimit: 8 * 1024 * 1024,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        format: "iife",
        name: "ExcalidrawHost",
        inlineDynamicImports: true,
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name][extname]",
      },
    },
  },
});
