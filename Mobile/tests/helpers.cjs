const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require('typescript');

const mobileRoot = path.resolve(__dirname, '..');

/** Execute application modules with native services replaced by test adapters. */
function moduleLoader(mocks = {}, globals = {}) {
  const cache = new Map();
  function load(file) {
    if (!path.isAbsolute(file)) file = path.resolve(mobileRoot, file);
    if (cache.has(file)) return cache.get(file).exports;
    const mod = { exports: {} };
    cache.set(file, mod);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const requireModule = (name) => {
      if (Object.hasOwn(mocks, name)) return mocks[name];
      if (name.endsWith('.txt') || name.endsWith('.epub')) return path.resolve(path.dirname(file), name);
      if (name.startsWith('.') || name.startsWith('@/')) {
        const resolved = name.startsWith('@/') ? path.resolve(mobileRoot, 'src', name.slice(2)) : path.resolve(path.dirname(file), name);
        return load(['.ts', '.tsx'].map((extension) => resolved + extension).find(fs.existsSync));
      }
      return require(require.resolve(name, { paths: [mobileRoot] }));
    };
    vm.runInNewContext(source, { module: mod, exports: mod.exports, require: requireModule, console, TextDecoder, Uint8Array, URL, setTimeout, clearTimeout, ...globals }, { filename: file });
    return mod.exports;
  }
  return load;
}

function filesystemAdapter(root, options = {}) {
  const normalize = (value) => value.path || (value.startsWith('file:') ? new URL(value).pathname : value);
  class Directory {
    constructor(...parts) { this.path = path.join(...parts.map(normalize)); }
    get uri() { return 'file://' + this.path; }
    get exists() { return fs.existsSync(this.path); }
    create() { fs.mkdirSync(this.path, { recursive: true }); }
    delete() { fs.rmSync(this.path, { recursive: true }); }
    async move(destination) {
      await options.beforeMove?.(this, destination);
      await fs.promises.rename(this.path, destination.path);
      this.path = destination.path;
    }
  }
  class File extends Directory {
    get size() { return fs.statSync(this.path).size; }
    write(value) { fs.writeFileSync(this.path, value); }
    textSync() { return fs.readFileSync(this.path, 'utf8'); }
    async text() { return fs.promises.readFile(this.path, 'utf8'); }
    async bytes() { return fs.promises.readFile(this.path); }
    async copy(destination, copyOptions = {}) {
      await options.beforeCopy?.(this, destination);
      await fs.promises.copyFile(this.path, destination.path, copyOptions.overwrite ? 0 : fs.constants.COPYFILE_EXCL);
    }
  }
  return { Directory, File, Paths: { document: root, cache: root } };
}

const cryptoAdapter = {
  randomUUID: crypto.randomUUID,
  CryptoDigestAlgorithm: { SHA256: 'SHA-256' },
  digestStringAsync: async (_algorithm, value) => crypto.createHash('sha256').update(value).digest('hex'),
  digest: async (_algorithm, bytes) => new Uint8Array(crypto.createHash('sha256').update(bytes).digest()).buffer,
};

module.exports = { moduleLoader, filesystemAdapter, cryptoAdapter, mobileRoot };
