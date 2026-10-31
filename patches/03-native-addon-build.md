# Patch 03 — Rebuilding the missing native `flock` addon

This is the subtlest of the three runtime defects, because the failure is a
**missing optional dependency** rather than a broken line of code. Nothing in
the JavaScript sources is wrong. The package that the JavaScript expects was
simply never shipped.

---

## 1. Symptom

Opening a workspace, or starting a session that needs an exclusive file lock,
killed the renderer. The UI went blank or froze, and the console carried:

```
Error: Cannot find module '@deepseek-ai/node-addon-system-linux-arm64/package.json'
Require stack:
- .../node_modules/@deepseek-ai/node-addon-system/lib/flock.js
```

The message is misleading in one respect: it talks about a missing *JSON
manifest*, but the actual import chain wants a native shared object. Resolving
the manifest is only the first hop. Once the manifest resolves, the code builds
a path from it and `require()`s a `.node` binary.

This did not happen on the upstream Windows build because the Windows platform
package (`@deepseek-ai/node-addon-system-win32-x64`) *was* present in that
distribution. The Linux arm64 platform package is an optional dependency, and
the release that was mirrored did not include it.

---

## 2. Why a stub is not enough

`lib/flock.js` resolves its binding through `loadBinding()`. The logic is worth
reading in full, because it dictates exactly what a valid replacement must look
like:

```js
function loadBinding() {
  const platform = process.platform;            // must be "linux" or "darwin"
  const arch = process.arch;                    // must be "arm64" here

  if (platform !== 'linux' && platform !== 'darwin') {
    throw new Error(`unsupported platform: ${platform}`);
  }

  // glibc vs musl, decided at runtime from the process report
  const isMusl = !process.report.getReport().header.glibcVersionRuntime;
  const libc = isMusl ? 'musl' : 'glibc';

  const filename = 'system.node';

  // Step 1: resolve the per-platform package manifest
  const manifest = require.resolve(
    `@deepseek-ai/node-addon-system-${platform}-${arch}/package.json`
  );

  // Step 2: require the binary that lives next to that manifest
  const dir = join(dirname(manifest), 'bin', libc);

  return require(join(dir, filename));
}
```

Three consequences follow, and each one rules out a shortcut:

1. **The manifest must exist and be resolvable.**
   `require.resolve('.../package.json')` throws if the package directory is
   absent or if the `exports` field hides `package.json`. So the platform
   package needs a real `package.json` that permits that subpath.

2. **The binary must be a real ELF shared object.**
   Step 2 is a plain `require()` of a `.node` file. Node loads it through
   `process.dlopen`. A JavaScript file renamed to `.node`, or an empty file,
   fails at `dlopen` with `invalid ELF header` — *after* the manifest check has
   already passed, so the error message changes and gets harder to diagnose.

3. **Both libc variants must be present, or at least the one in use.**
   The `libc` segment of the path is chosen at runtime. On Debian/Ubuntu under
   PRoot, `glibcVersionRuntime` is present, so `bin/glibc/system.node` is the
   one loaded. But because the same tree may be inspected or copied elsewhere,
   both paths are populated with the identical object.

A pure-JS shim that exports the same function names would also "work" at the
API level — but it would silently change locking semantics (for example, by
falling back to `mkdir`-based locks), and it would diverge from upstream
behaviour in a way that is hard to test. Rebuilding the C source is both
smaller and more honest.

---

## 3. The source is shipped; only the build is missing

`node-addon-system` ships its C sources:

```
node_modules/@deepseek-ai/node-addon-system/
├── LICENSE
├── README.md
├── README.zh.md
├── package.json
├── lib/
│   └── flock.js
└── src/
    ├── flock.c        (5744 bytes)
    └── main.c         (11757 bytes)
```

`flock.c` is the implementation of interest: it wraps the POSIX `flock(2)`
syscall in an N-API module. No third-party build system is required — a single
`gcc -shared` invocation produces the object.

### N-API headers

The build needs `node_api.h` and friends. They do not have to be downloaded:
the runtime tree already contains a vendored copy, pulled in by `koffi`:

```
node_modules/@deepseek-ai/dsh-desktop-host/node_modules/koffi/vendor/node-api-headers/include/node_api.h
node_modules/koffi/vendor/node-api-headers/include/node_api.h
```

Because the addon targets **N-API** (ABI-stable across Node versions) rather
than the raw V8 API, the header version does not need to match the runtime
version. That is what makes compiling against a vendored header set safe here.

---

## 4. Building it

Environment used for the shipped build:

| Component | Version |
|---|---|
| Compiler | `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` |
| Runtime | Node `v24.21.0` (under `ELECTRON_RUN_AS_NODE`) |
| Target arch | `aarch64` / `arm64` |
| Target libc | glibc (Debian arm64 under PRoot) |

The commands, relative to the packaged runtime root
`opt/deepseek-harness/runtime/dsh/`:

```sh
NODE_MODULES=node_modules
ADDON="$NODE_MODULES/@deepseek-ai/node-addon-system"
OUT="$NODE_MODULES/@deepseek-ai/node-addon-system-linux-arm64"
INCLUDE="$NODE_MODULES/koffi/vendor/node-api-headers/include"

mkdir -p "$OUT/bin/glibc" "$OUT/bin/musl"

gcc -O2 -fPIC -shared \
    -DNAPI_VERSION=8 \
    -I"$INCLUDE" \
    -o "$OUT/bin/glibc/system.node" \
    "$ADDON/src/flock.c"

cp -f "$OUT/bin/glibc/system.node" "$OUT/bin/musl/system.node"
chmod 0755 "$OUT/bin/glibc/system.node"
```

Notes on the flags:

- `-shared -fPIC` — required for a loadable module.
- `-DNAPI_VERSION=8` — pins the N-API level so the header set does not need to
  agree with the runtime's default.
- No `-l` flags are needed; `flock` lives in libc, which is linked by default.

The `musl` copy is byte-identical to the `glibc` copy on purpose. Under PRoot
on Debian, only the `glibc` path is ever selected, but keeping both in sync
means the tree stays valid if it is ever relocated onto an Alpine-style userland
where `glibcVersionRuntime` is absent.

### The manifest

`@deepseek-ai/node-addon-system-linux-arm64/package.json` (295 bytes) must
permit resolution of the `package.json` subpath and must not block the `bin`
directory:

```json
{
  "name": "@deepseek-ai/node-addon-system-linux-arm64",
  "version": "0.1.2",
  "license": "BSD-3-Clause",
  "os": ["linux"],
  "cpu": ["arm64"],
  "files": ["bin"]
}
```

If an `exports` map is added to this file later, it must keep
`"./package.json": "./package.json"` — otherwise `loadBinding()` breaks again
with the same confusing message.

---

## 5. Package metadata impact

Two generated metadata files inside the `.deb` describe the addon, and both
were regenerated after the object was rebuilt:

- `DEBIAN/control` — `Installed-Size` went from `479840` to `479944` KB.
- `DEBIAN/md5sums` — one new entry was appended per libc variant, so the file
  grew by two lines.

Expected checksums:

| File | Size (bytes) | MD5 |
|---|---|---|
| `bin/glibc/system.node` | 71488 | `e3ed9c271bb6b5c3fc415a648e12f6b2` |
| `bin/musl/system.node` | 71488 | `e3ed9c271bb6b5c3fc415a648e12f6b2` |

The two files are identical, so a single MD5 covers both. Anyone verifying a
build should see these exact values; a different hash means a different
compiler or different source, not necessarily a broken build — but it should be
explained, not ignored.

---

## 6. Verification performed

The addon was exercised in three ways before the package was sealed:

1. **Load test** — `require()` from the packaged path succeeded, and the
   exported `flock` function was a callable.
2. **Exclusive-lock test** — a second handle attempting an exclusive lock on
   the same file received the expected `EAGAIN`-style contention error instead
   of succeeding.
3. **Release-then-relock test** — releasing the first handle allowed the second
   handle to acquire the lock immediately.

Beyond the addon itself, the decisive check was end-to-end: with the rebuilt
addon in place, opening the `work` workspace succeeded and a message was sent
and rendered in a real session. Prior to the rebuild, that same action failed
with the missing-manifest error.

---

## 7. Reproducing from a clean upstream tree

If you are starting from an untouched upstream payload rather than from the
released `.deb`:

1. Extract the upstream installer and locate
   `opt/deepseek-harness/runtime/dsh/`.
2. Confirm `node_modules/@deepseek-ai/node-addon-system/src/flock.c` exists. If
   it does not, the payload differs from the one this document was written
   against, and the rebuild path does not apply.
3. Create `node-addon-system-linux-arm64/` with the manifest shown above.
4. Run the `gcc -O2 -fPIC -shared` command from section 4.
5. Copy the result to both `bin/glibc/` and `bin/musl/`.
6. Verify: `node -e "require('@deepseek-ai/node-addon-system').flock"` from the
   runtime root should not throw.

`build/build-addon.sh` in this repository automates steps 2–5 and refuses to
run if the source file is absent.

---

## 8. Why this is not distributed as a patch

Patches 01 and 02 are genuine source diffs and are shipped as `.patch` files.
This defect is not a source diff — it is a missing binary artifact. A `.patch`
file for a 71 KB compiled object would be base64 noise, and it would only be
valid for one exact compiler invocation. The reproducible artifact here is the
**build script plus the recorded checksums**, which is what this document and
`build/build-addon.sh` provide.