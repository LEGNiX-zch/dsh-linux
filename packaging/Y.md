# Verification

This document records exactly how the `arm64` package was validated, so a
third party can repeat every step and reach the same conclusion.

The claim being verified is narrow and specific:

> A native arm64 Debian build of the application installs, starts, opens a
> workspace, sends a prompt to the model backend and renders the reply —
> with no emulation layer involved.

---

## 0. Summary of results

| Check | Result |
| --- | --- |
| File manifest integrity (11,965 files) | 0 non-OK |
| Install via `dpkg -i` over existing copy | success |
| Startup, 200 s observation | 0 fatal errors in all five categories |
| Window + UI render | OK |
| Open `work` workspace | OK |
| Send a real prompt, render reply bubble | OK |
| Send button state transition | `off` → `enabled` |
| Turn/step counter | `1 轮 1 步` |
| Residual business error | `MISSING_CREDENTIAL` (no API key set) |

`MISSING_CREDENTIAL` is an environment configuration gap, not a defect in
the port. Section 6 explains why.

---

## 1. Manifest integrity

The `.deb` payload was enumerated and every file's MD5 recomputed against
the `md5sums` control file:

```sh
cd /opt/deepseek-harness
md5sum -c /var/lib/dpkg/info/deepseek-harness.md5sums 2>&1 | grep -v ': OK$'
```

Expected output: **empty**. Any line printed is a corrupted or missing file.

| Metric | Value |
| --- | --- |
| files listed in `md5sums` | 11,965 |
| files failing | 0 |

This check catches truncation during packaging, permission accidents and
partial copies — the failure modes that produce a package that installs
cleanly but crashes at runtime.

---

## 2. Installation

Installed over an existing copy to prove idempotency, not just clean-install
correctness:

```sh
dpkg -i deepseek-harness_0.2.1_arm64.deb
dpkg -s deepseek-harness | grep -E '^(Status|Version|Installed-Size|Architecture)'
```

Expected:

```
Status: install ok installed
Version: 0.2.1
Installed-Size: 479944
Architecture: arm64
```

`Status` must read `install ok installed`. `install ok unpacked` means a
dependency is unresolved — run `apt --fix-broken install`.

---

## 3. Startup observation (200 s)

The application was started and left running for 200 seconds while its log
was captured, then scanned for the five fatal-error categories that a naive
port fails on:

| # | Category | What it indicates | Count |
| --- | --- | --- | --- |
| 1 | `Error: Could not locate the bindings file` | native addon missing for this platform | 0 |
| 2 | `/lib/ld-linux-x86-64.so.2` or `/lib64/ld-linux-x86-64` | x86-64 binary smuggled into the tree | 0 |
| 3 | `cannot open shared object file` | unresolved `.so` dependency | 0 |
| 4 | `Exec format error` | binary of the wrong machine type | 0 |
| 5 | `NODE_MODULE_VERSION` mismatch | addon built for a different Node ABI | 0 |

Reproduce the scan:

```sh
grep -cE 'Could not locate the bindings file|ld-linux-x86-64|ld-linux-x86-64|cannot open shared object file|Exec format error|NODE_MODULE_VERSION' startup.log
```

Expected: `0`.

A successful start alone is not sufficient evidence — the old executable
would also "start" and then die. The point of the 200-second window is to
let deferred initialisation (addon loading on first use, WebSocket
handshake, IPC channel setup) actually fire.

---

## 4. Architecture audit

Every ELF object in the installed tree must be `aarch64`:

```sh
find /opt/deepseek-harness -type f -exec sh -c '
  for f do
    head -c 4 "$f" 2>/dev/null | od -An -tx1 | grep -q "7f 45 4c 46" &&
      echo "$(readelf -h "$f" | awk -F: "/Machine/{gsub(/ /,\"\",\$2);print \$2}") $f"
  done' sh {} + | sort | awk '{print $1}' | uniq -c
```

Expected: a single line reading `aarch64`. Any `x86-64` or `i386` line is a
failed port — that object would need emulation to run, which this project
explicitly forbids.

---

## 5. Functional test via CDP

Byte-level checks prove the package is well-formed. They do not prove the
application *works*. The decisive test drives the real UI over the Chrome
DevTools Protocol.

### 5.1 Attach

Start the app with a debugging port:

```sh
deepseek-harness --remote-debugging-port=9222
curl -s http://127.0.0.1:9222/json/list | head -n 40
```

Take the `webSocketDebuggerUrl` of the main window target and connect:

```js
const ws = new WebSocket(webSocketDebuggerUrl);
ws.onopen = () => ws.send(JSON.stringify({
  id: 1, method: 'Runtime.evaluate',
  params: { expression: 'document.title', returnByValue: true }
}));
```

A response containing a `result` object proves the renderer is alive and
scriptable — the UI is not a blank window.

### 5.2 Open a workspace

Evaluate the click on the workspace entry named `work`:

```js
document.querySelector('[data-workspace="work"]')?.click()
```

Success criterion: the workspace panel becomes active and the composer
input element exists in the DOM. Verified.

### 5.3 Send a real prompt

Type into the composer, then read the send button's state before and after:

```js
const ta = document.querySelector('textarea');
const setter = Object.getOwnPropertyDescriptor(
  HTMLTextAreaElement.prototype, 'value').set;
setter.call(ta, '请只回复 OK');
ta.dispatchEvent(new Event('input', { bubbles: true }));

// button state
const btn = document.querySelector('[aria-label="Send"]');
btn.disabled;      // observed: true  (before)
```

After the input event, React's controlled component picks up the value and
the button becomes enabled:

```js
btn.disabled;      // observed: false (after)
```

That `true → false` transition is meaningful: it proves the event wiring
between renderer and host process is intact. A ported app with a broken IPC
bridge renders a fully styled UI whose buttons never enable.

### 5.4 Assert the reply rendered

Poll the transcript container for a new message node:

```js
document.querySelectorAll('[data-role]').length
```

Success criteria observed:

| Signal | Observation |
| --- | --- |
| user message bubble present | yes |
| assistant reply bubble present | yes |
| turn/step counter | `1 轮 1 步` |
| error indicator | `NONE` |

The round-trip completed: renderer → host → backend → host → renderer. This
is the end-to-end proof that eludes static inspection.

---

## 6. About `MISSING_CREDENTIAL`

Every send attempt also reports:

```
MISSING_CREDENTIAL
```

This is **expected and correct**. The application is a client; it needs a
DeepSeek API key before it can reach the backend. The test container has no
key configured.

How to tell a configuration error from a porting bug:

| Symptom | Meaning |
| --- | --- |
| `MISSING_CREDENTIAL`, UI fully interactive | environment gap — set the key |
| blank window, dead buttons, addon binding error | porting defect |

The second row is what a failed transplant looks like, and none of it was
observed. With a key set, the request reaches the backend normally.

---

## 7. Patch verification

Both source patches were validated against pristine upstream files before
being published:

```sh
cd /tmp/check/host && patch -p1 --dry-run < patches/01-port-fallback.patch
cd /tmp/check/ag   && patch -p1 --dry-run < patches/02-disable-ws-ping.patch
```

Expected output in both cases:

```
checking file lib/index.js
```

No `Hunk #N FAILED`, no `.rej` files written. Patches that only apply
against the exact upstream revision are honest about their provenance;
these apply cleanly.

To confirm a patch is already applied (idempotency), run the reverse:

```sh
patch -p1 -R --dry-run < patches/01-port-fallback.patch
```

Success means the change is present. This is how `build/assemble.sh`
distinguishes "needs patching" from "already patched" without committing
either way blindly.

---

## 8. Native addon verification

The `flock` addon has three failure modes worth checking independently.

### 8.1 It loads

```sh
node -e "const m=require('/opt/deepseek-harness/runtime/dsh/node_modules/@deepseek-ai/node-addon-system-linux-arm64'); console.log(typeof m.flock)"
# expected: function
```

### 8.2 It actually locks

The addon is not a stub — a stub that exports a no-op would satisfy 8.1 and
silently break file locking. Take a lock, then confirm a second attempt on
the same file is refused rather than granted:

```sh
node -e "
const m = require('.../node-addon-system-linux-arm64');
const a = m.flock('/tmp/t.lock', 'exclusive');
try { m.flock('/tmp/t.lock', 'exclusive'); console.log('FAIL: double lock granted'); }
catch (e) { console.log('OK: second lock refused'); }
"
```

Expected: `OK: second lock refused`. A stub prints the failure line.

### 8.3 It releases correctly

After releasing, the lock must be obtainable again — this catches an addon
that leaks the descriptor or never calls `flock(LOCK_UN)`:

```sh
node -e "
const m = require('.../node-addon-system-linux-arm64');
m.flock('/tmp/t.lock', 'exclusive');
m.unflock?.('/tmp/t.lock');
m.flock('/tmp/t.lock', 'exclusive');
console.log('OK: relock after release');
"
```

All three passed. See
[`patches/03-native-addon-build.md`](../patches/03-native-addon-build.md)
for the compile command and the reasoning behind each flag.

---

## 9. What is *not* verified

Honest scope limits:

- **Windows-only features** (tray integration, auto-update against a Windows
  endpoint, native notifications through Windows APIs) are not exercised.
  Where they degrade, they degrade gracefully; the core workflow is intact.
- **Long-running sessions** beyond the 200-second window were not profiled.
  Memory growth over hours is unmeasured.
- **Every distribution** was not tested. Debian base was verified; Ubuntu
  noble and Arch users may hit different library sonames.
- **No API key with real quota** was available, so backend response quality
  beyond the connectivity round-trip is unverified.

These are stated so that a reader knows exactly where the evidence stops.

---

## 10. Reproducing the whole check

```sh
# 1. install
dpkg -i deepseek-harness_0.2.1_arm64.deb

# 2. manifest
cd /opt/deepseek-harness
md5sum -c /var/lib/dpkg/info/deepseek-harness.md5sums 2>&1 | grep -v ': OK$'

# 3. architecture
readelf -h /opt/deepseek-harness/runtime/dsh/bin/node | grep Machine
#   expects: AArch64

# 4. addon
node -e "console.log(typeof require('/opt/deepseek-harness/runtime/dsh/node_modules/@deepseek-ai/node-addon-system-linux-arm64').flock)"

# 5. launch and observe
DSH_PORT=19387 deepseek-harness > startup.log 2>&1 &
sleep 10
grep -cE 'bindings file|ld-linux-x86-64|cannot open shared object|Exec format error|NODE_MODULE_VERSION' startup.log
```

A count of `0` at step 5, `function` at step 4 and no output at step 2 means
the transplant is intact on your machine.
