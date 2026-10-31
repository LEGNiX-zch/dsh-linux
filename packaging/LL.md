# Installation

This document describes how to install the prebuilt `.deb` on an **arm64
Debian** system, and how to build it yourself from an upstream DeepSeek
Windows desktop client.

Nothing here involves Wine, Hangover, Box64, QEMU or any other emulation
layer. The result is a native arm64 Linux executable running on the system's
own `node` runtime.

---

## 1. Target environment

| Item | Value |
| --- | --- |
| CPU architecture | `arm64` (`aarch64`) |
| OS | Debian 12/13, Ubuntu 24.04+, or a PRoot Debian arm64 container |
| Verified on | PRoot Debian arm64 inside the *XiaoXiaoDianNao* Android app |
| Runtime | bundled by the package (no system-wide Node.js required) |
| Display | X11 or XWayland (electron needs a working X server) |

Check your architecture before downloading anything:

```sh
uname -m
# must print: aarch64
```

If it prints `x86_64`, `armv7l` or anything else, **do not install this
package** — it will refuse to run.

---

## 2. Download

Grab the latest release asset from:

```
https://github.com/LEGNiX-zch/dsh-linux/releases
```

The file name follows
`deepseek-harness_<version>_arm64.deb`.

### Verify the download

The release notes list a SHA256 for every asset. Compare it:

```sh
sha256sum deepseek-harness_0.2.1_arm64.deb
```

For version `0.2.1` the expected values are:

| Hash | Value |
| --- | --- |
| size | `126234980` bytes |
| MD5 | `6f33bbacaf3c019c46865b192069b3f4` |
| SHA256 | `5919135e28958d73855db6e1443cc1afab4385ddbf6ae64f10f312fa3a267a37` |

If the SHA256 does not match, the download is corrupted or tampered with.
Delete it and download again.

---

## 3. Install

```sh
sudo apt install ./deepseek-harness_0.2.1_arm64.deb
```

The `./` prefix matters: it tells `apt` to treat the argument as a local
file path rather than a package name from the repositories.

If you have no `sudo` (common inside PRoot containers), install directly as
root:

```sh
dpkg -i deepseek-harness_0.2.1_arm64.deb
```

### Dependencies

The package declares 21 runtime dependencies. `apt` resolves them
automatically. With plain `dpkg -i` a missing dependency leaves the package
in a half-configured state; repair it with:

```sh
apt --fix-broken install
```

The essentials, if you want to check them by hand first:

```sh
dpkg -l libgtk-3-0 libnss3 libasound2t64 libgbm1 libxss1 \
        libatk-bridge2.0-0 libdrm2 xdg-utils
```

Exact library names differ slightly between Debian bookworm, trixie and
Ubuntu noble (for example `libasound2` vs `libasound2t64`). Let `apt`
choose; do not force-install a name from a different release.

---

## 4. First run

```sh
deepseek-harness
```

or, to pick a port explicitly:

```sh
DSH_PORT=19387 deepseek-harness
```

### What happens on startup

1. The bundled Node.js runtime boots the desktop host process.
2. The host binds its HTTP listener on `127.0.0.1:$DSH_PORT`.
   The default is `19387`; if that port is already taken the host falls
   back to the next free port and prints the effective one in its log.
3. An Electron window opens and loads the local UI.

### Running as root / inside PRoot

Electron refuses to start as root unless the sandbox is disabled. The
launcher installed by this package already passes the required flags. If
you invoke the binary by hand as root, add:

```sh
--no-sandbox --disable-gpu-sandbox
```

Without a GPU, add `--disable-gpu` as well; the UI falls back to software
rendering and remains fully functional.

### If nothing appears

Check that an X server is reachable:

```sh
echo "$DISPLAY"
xdpyinfo | head -n 3
```

An empty `DISPLAY` is the most common cause of an immediate exit with no
window. Start your desktop session or export `DISPLAY` before launching.

---

## 5. Configure the API key

The application is a *client*. It needs a DeepSeek API key to talk to the
model backend. Without one the UI still starts and you can browse
workspaces, but every send attempt fails with `MISSING_CREDENTIAL`.

Set the key in the environment:

```sh
export DEEPSEEK_API_KEY='sk-...'
deepseek-harness
```

To make it permanent for your shell:

```sh
echo "export DEEPSEEK_API_KEY='sk-...'" >> ~/.bashrc
```

Or enter it in the application's settings panel, which stores it in the
user config directory:

```
~/.config/deepseek-harness/
```

`MISSING_CREDENTIAL` is a *configuration* state, not a porting defect. The
transplant is complete and working; it simply has no credentials yet.

---

## 6. Upgrading

```sh
sudo apt install ./deepseek-harness_<newer>_arm64.deb
```

`dpkg` replaces the previous version in place. User configuration under
`~/.config/deepseek-harness/` and workspaces under your home directory are
untouched.

Verify you got the new version:

```sh
dpkg -s deepseek-harness | grep -E '^(Version|Installed-Size)'
```

---

## 7. Uninstalling

Remove the files but keep configuration:

```sh
sudo apt remove deepseek-harness
```

Remove everything including configuration:

```sh
sudo apt purge deepseek-harness
```

Your own workspaces and projects are never deleted — they live outside the
package tree.

---

## 8. Files installed

| Path | Contents |
| --- | --- |
| `/opt/deepseek-harness/` | application tree, including the bundled runtime |
| `/opt/deepseek-harness/runtime/dsh/` | Node.js runtime and `node_modules` |
| `/usr/bin/deepseek-harness` | launcher wrapper |
| `/usr/share/applications/deepseek-harness.desktop` | menu entry |
| `/usr/share/icons/hicolor/...` | application icons |
| `/var/lib/dpkg/info/deepseek-harness.*` | package metadata (md5sums, control) |

Total installed size is roughly **479944 KiB**. Budget about 470 MiB of
free disk space.

---

## 9. Building from source

If you want to reproduce the package instead of downloading it, see:

- [`patches/`](../patches) — the source modifications, with rationale
- [`build/assemble.sh`](../build/assemble.sh) — apply patches to an upstream tree
- [`build/build-addon.sh`](../build/build-addon.sh) — compile the native addon
- [`build/package.sh`](../build/package.sh) — produce the final `.deb`
- [`docs/VERIFY.md`](VERIFY.md) — how the result was validated

You must supply your own copy of the upstream Windows client. It is not
distributed here, and must not be redistributed.
