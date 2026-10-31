# dsh-linux

A native **linux-arm64** port of the DeepSeek Harness desktop client.

No Wine. No Box64. No QEMU. No Hangover. Nothing is emulated, and no Windows
executable is ever loaded. The resulting `.deb` contains genuine arm64 ELF
binaries and runs inside plain PRoot containers (e.g. `proot-distro` on Android)
with no user namespaces and no GPU nodes.

> **Status:** arm64 works and has been verified end to end.
> amd64 and other architectures are planned.

---

## Table of contents

- [What this is](#what-this-is)
- [What this repository contains](#what-this-repository-contains)
- [Download](#download)
- [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [Building from source](#building-from-source)
- [What was actually changed](#what-was-actually-changed)
- [Verification](#verification)
- [Known limitations](#known-limitations)
- [Legal notice](#legal-notice)
- [License](#license)

---

## What this is

The upstream DeepSeek Harness desktop client ships as a **Windows Electron**
application. Its payload has two parts:

1. an **Electron shell** (main process, preload, renderer bundle), and
2. a **bundled Node service** (the "host") that owns the actual product logic and
   serves the UI over a loopback HTTP origin.

This project keeps part 2 as-is and replaces part 1:

- The Electron main process is rewritten to run on the official **linux-arm64**
  Electron runtime.
- The bundled Node service is executed through that same Electron binary in
  `ELECTRON_RUN_AS_NODE` mode, so there is exactly one runtime to ship.
- The renderer is served by the bundled service on `http://127.0.0.1:<port>`, and
  the launch cookie is seeded into the Electron session **before** the first
  navigation, so the desktop UI authenticates against its own backend without a
  manual login step.

The result is a single `.deb` that installs a `deepseek-harness` launcher onto
`PATH` and starts like any other Linux desktop app.

---

## What this repository contains

**Only original work.** Specifically:

| Path | Contents |
|---|---|
| `patches/` | Every source change, as readable diffs plus a build recipe |
| `build/` | Shell scripts that assemble the package root and produce the `.deb` |
| `packaging/DEBIAN/` | Debian control metadata and maintainer scripts |
| `docs/` | Install notes and a reproducible verification checklist |
| `README.md` | This document |

**Not** in this repository — by design:

- `electron-app/` — the upstream application payload. It is **not** redistributed
  here. See [Building from source](#building-from-source): you supply it yourself
  from an official installer.
- `stage/`, `pkgroot/`, `out/` — build intermediates, all regenerable.
- `*.deb` — release artifacts are attached to
  [GitHub Releases](../../releases), not committed.

This split keeps the repository small, keeps it buildable, and keeps it
license-clean.

---

## Download

Grab the latest `.deb` from the [Releases](../../releases) page:

```
deepseek-harness_0.2.1_arm64.deb
```

**Always verify the checksum before installing:**

```bash
sha256sum deepseek-harness_0.2.1_arm64.deb
# 5919135e28958d73855db6e1443cc1afab4385ddbf6ae64f10f312fa3a267a37

md5sum deepseek-harness_0.2.1_arm64.deb
# 6f33bbacaf3c019c46865b192069b3f4
```

Size: `126,234,980` bytes.

---

## Install

### Requirements

- Debian / Ubuntu **arm64**, or an arm64 PRoot container
- glibc-based userspace (musl systems are not supported by the Electron runtime)
- The dependencies listed in `packaging/DEBIAN/control` — `dpkg -i` will install
  them from your configured apt sources if they are missing

### Install the package

```bash
sudo dpkg -i deepseek-harness_0.2.1_arm64.deb
sudo apt-get -f install        # only if dpkg reports unmet dependencies
```

Inside a PRoot container you are usually root already, so drop the `sudo`.

Installed layout:

```
/usr/bin/deepseek-harness                      # launcher script
/opt/deepseek-harness/electron-app/            # Electron runtime + app payload
```

### Uninstall

```bash
sudo dpkg -r deepseek-harness
```

---

## Usage

```bash
deepseek-harness
```

The launcher:

1. picks a loopback port (default `19387`, probing forward if it is taken),
2. starts the bundled service under `ELECTRON_RUN_AS_NODE`,
3. waits for it to report ready,
4. seeds the auth cookie into the Electron session, and
5. opens the desktop window against that origin.

Logs are written to `/tmp/dsh.log`; useful when reporting a problem.

To run with a specific port:

```bash
DSH_PORT=19400 deepseek-harness
```

---

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DSH_PORT` | `19387` | Loopback port for the bundled service. If busy, the launcher probes forward and exports the chosen value so the service and the shell agree on one origin. |
| `DEEPSEEK_API_KEY` | *(unset)* | Model credential. Preferred: set it once in the web **Models** page, which stores it in the credentials service. Setting the env var at launch also works. |

### About `DEEPSEEK_API_KEY`

The package does **not** ship a credential and cannot invent one. The first time
you send a message without a key configured, the UI reports:

```
MISSING_CREDENTIAL
llm-deepseek: no API key for provider route "deepseek-official"
```

That is expected behaviour, not a port bug — the request is constructed and sent,
it is the provider that rejects it. Open **Models** in the web UI and store your
key there.

---

## Building from source

### 1. Obtain the upstream payload yourself

This repository does not contain it. Extract `electron-app/` from an official
DeepSeek Harness desktop installer and place it at:

```
<repo>/electron-app/
```

The directory must contain the Electron app root (`package.json`, the app entry
point, the bundled service). Everything downstream expects exactly that layout.

### 2. Run the build

```bash
./build/build-addon.sh     # compile the native flock addon (see below)
./build/assemble.sh        # populate pkgroot/ from electron-app/ + patches
./build/package.sh         # rebuild md5sums, then dpkg-deb --build
```

Output: `out/deepseek-harness_<version>_arm64.deb`.

### 3. Notes on the build scripts

- `assemble.sh` refuses to run if `electron-app/` is missing, so a clean clone
  fails loudly instead of producing a broken package.
- `package.sh` regenerates `DEBIAN/md5sums` from the actual staged files — never
  hand-edit that file.
- **Packaging a ~126 MB `.deb` takes 4–5 minutes.** Run it in the background
  (`nohup ... &`) or with a generous timeout; a killed `dpkg-deb` leaves a
  truncated file that looks like a real package.

---

## What was actually changed

Full diffs live in [`patches/`](patches/). Summary:

### 1. Native Electron main process

The Windows shell is replaced by a linux main process that boots the bundled
service as a child process, waits for its `ready` line, seeds the auth cookie, and
only then navigates the window. This is the structural change; everything else is
a defect found once it ran.

### 2. Loopback port fallback (`patches/01-port-fallback.patch`)

**Symptom:** launching twice left a window stuck on *reconnecting*.

**Cause:** an orphaned backend from a previous PRoot session still held `19387`.
The launcher probed forward to a free port but the host itself was hardcoded to
`19387`, so the two disagreed about the origin.

**Fix:** the host now honours `DSH_PORT`, and the launcher exports the port it
actually selected. If no free port is found nearby, it fails with
`no free port found near $base; set DSH_PORT manually.` rather than hanging.

### 3. WebSocket keepalive disabled (`patches/02-disable-ws-ping.patch`)

**Symptom:** the UI printed *connection lost* and reconnected every two seconds,
forever.

**Cause:** inside PRoot, the Chromium renderer aborts the TCP connection with
close code `1006` as soon as it receives a WebSocket **Ping** control frame
instead of replying with Pong. The multiplexed Remote stream endpoint sends one as
a keepalive probe.

**Fix:** `websocketPingEnabled` now defaults to `false`. This disables **only** the
keepalive probe. Application traffic, stream multiplexing, and peer-scope teardown
are untouched.

### 4. Native `flock` addon (`patches/03-native-addon-build.md`)

**Symptom:**

```
Cannot find module '@deepseek-ai/node-addon-system-linux-arm64/package.json'
```

…raised the moment you opened a workspace or started a session.

**Cause:** the optional addon subpackage `@deepseek-ai/node-addon-system-linux-arm64`
was absent from earlier builds. Any code path that needs an exclusive file lock
died on the failed `require`.

**Resolution path** (worth understanding, since it is the subtle one):

1. `lib/flock.js` calls
   `require.resolve('@deepseek-ai/node-addon-system-linux-arm64/package.json')`
2. it reads `glibcVersionRuntime` from the manifest,
3. it builds the path `bin/<glibc|musl>/system.node`, and
4. it `require()`s that shared object.

So the package needs a real N-API `.so` at that exact path — a stub will not do.

**Fix:** `src/flock.c`, which ships inside `node-addon-system`, is compiled
locally against the bundled N-API headers and installed to **both**
`bin/glibc/system.node` and `bin/musl/system.node`. It is a genuine arm64 N-API
shared object calling `flock(2)` directly.

See [`patches/03-native-addon-build.md`](patches/03-native-addon-build.md) for the
compile command and for how to verify the result.

---

## Verification

[`docs/VERIFY.md`](docs/VERIFY.md) contains the full checklist that was actually
run, including the exact commands and their expected output.

Highlights of the current build:

- 11,965 files in `md5sums`, **0** mismatches on `dpkg-deb -x` + `md5sum -c`
- `flock` addon: ELF magic correct, `require()` succeeds, exports `tryLock`;
  `acquire` → contention returns `EAGAIN` (`errno=11`) → `release` → `acquire`
  succeeds again
- 6 processes stable past 200 s; `Cannot find module`, `connection lost`,
  `Segmentation`, `Uncaught`, `EADDRINUSE` all count **0**
- UI driven over CDP: opened a workspace directory, sent a message, rendered the
  reply bubble — no crash

---

## Known limitations

- **arm64 only.** amd64 needs a separate Electron runtime and a re-run of the
  build; it is planned, not started.
- **glibc only.** The bundled Electron runtime is glibc-linked; Alpine/musl
  containers will not work.
- **No GPU.** Renders with software rasterisation inside PRoot. Fine for the UI,
  slow for anything graphics-heavy.
- **PRoot noise.** `dbus` and `udev` warnings appear in the log. They are
  environment artifacts of a rootless container and can be ignored.
- **You must supply your own API key.** See
  [Configuration](#configuration).
- **Not tested on a physical GPU desktop.** Behaviour there is expected to be the
  same or better, but it has not been observed.

---

## Legal notice

This repository contains **only** original build scripts, patches, and
documentation. It does **not** redistribute any DeepSeek proprietary resources.

The `electron-app/` directory is expected to be produced locally by the user from
an official DeepSeek desktop installer. Nothing in this repository grants you any
right to that software beyond whatever its own license allows.

DeepSeek®, DeepSeek Harness, and related marks are trademarks of their respective
owners. **This is an unofficial community port. It is not affiliated with,
endorsed by, or supported by DeepSeek.**

If the upstream vendor asks for this project to be taken down, it will be.

---

## License

The patches, build scripts, and documentation in this repository are released
under the **MIT License** — see [LICENSE](LICENSE).

This license covers **only** the contents of this repository. It does **not**
extend to any third-party software the build process may consume, including the
upstream Electron payload.
