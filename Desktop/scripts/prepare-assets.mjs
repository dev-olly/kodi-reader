import { cpSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = resolve(desktop, 'node_modules/pdfjs-dist');
const target = resolve(desktop, 'public/vendor/pdfjs');
mkdirSync(target, { recursive: true });
for (const file of ['legacy/build/pdf.mjs', 'legacy/build/pdf.worker.mjs', 'web/pdf_viewer.css', 'web/images', 'cmaps', 'standard_fonts', 'wasm', 'LICENSE']) {
  const destination=file.startsWith('legacy/build/')?file.slice('legacy/build/'.length):file.startsWith('web/')?file.slice(4):file;
  cpSync(resolve(source, file), resolve(target, destination), { recursive: true });
}
