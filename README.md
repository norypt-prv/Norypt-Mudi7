# Norypt Ghost

[![Build (script)](https://github.com/norypt-prv/Norypt-Mudi7/actions/workflows/build.yml/badge.svg)](https://github.com/norypt-prv/Norypt-Mudi7/actions/workflows/build.yml)
[![Build (SDK)](https://github.com/norypt-prv/Norypt-Mudi7/actions/workflows/sdk-build.yml/badge.svg)](https://github.com/norypt-prv/Norypt-Mudi7/actions/workflows/sdk-build.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0-blue.svg)](#license)
[![Platform](https://img.shields.io/badge/platform-GL--E5800%20(Mudi%207)-8900ff.svg)](#compatibility)

**Radio-identity rotation for the GL-iNet GL-E5800 (Mudi 7) 5G mobile hotspot** — dual-slot IMEI rotation, MAC/BSSID/SSID/hostname/password randomization, a full-fingerprint `new-identity` rotation, an RAT lock against 2G/3G downgrade, a two-stage SIM-swap flow, sealed factory state, and a no-persistent-connected-device-logs guarantee, controlled from the command line, a LuCI admin page, or the device's touchscreen.

Norypt Ghost is derived from [blue-merle-v2](https://github.com/WSchlesner/blue-merle-v2) (GPL-2.0), itself a ground-up rewrite of [SRLabs' blue-merle](https://github.com/srlabs/blue-merle) for the Mudi 7 — a device with a completely different modem (Quectel RG650V-NA, integrated MHI instead of USB), a rewritten `gl_modem` wrapper, dual SIM + eSIM support, a touchscreen instead of a hardware switch, and a new UCI layout. See [Attribution](#attribution).

> **Legal note:** changing a device's IMEI is restricted or unlawful in some jurisdictions. This software is provided for lawful privacy work and personal use where permitted. You are responsible for compliance with your local laws.

---

## Table of Contents

- [Features](#features)
- [Compatibility](#compatibility)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [LuCI admin page](#luci-admin-page)
  - [Command line](#command-line)
  - [Touchscreen trigger](#touchscreen-trigger)
  - [Health check](#health-check)
- [How It Works](#how-it-works)
  - [What it protects (and what it can't)](#what-it-protects-and-what-it-cant)
  - [Boot sequence](#boot-sequence)
  - [IMEI rotation](#imei-rotation)
  - [IMEI modes](#imei-modes)
  - [SIM-swap flow](#sim-swap-flow)
  - [MAC, BSSID, and SSID randomization](#mac-bssid-and-ssid-randomization)
  - [`new-identity`: full clean rotation](#new-identity-full-clean-rotation)
  - [RAT lock (2G/3G downgrade block)](#rat-lock-2g3g-downgrade-block)
  - [Volatile client MACs](#volatile-client-macs)
  - [No persistent connected-device logs](#no-persistent-connected-device-logs)
  - [Sealed factory state](#sealed-factory-state)
  - [Splash screens](#splash-screens)
- [Configuration Reference](#configuration-reference)
- [Building from Source](#building-from-source)
- [Uninstalling](#uninstalling)
- [AT Commands We Deliberately Avoid](#at-commands-we-deliberately-avoid)
- [Project Status](#project-status)
- [Roadmap](#roadmap)
- [Repository Layout](#repository-layout)
- [Attribution](#attribution)
- [License](#license)

---

## Features

| Feature | Description |
|---|---|
| **Dual IMEI rotation** | Both modem IMEI slots (SIM 1 + SIM 2/eSIM) rotated independently via `AT+EGMR`, persisted to modem NV |
| **Three IMEI modes** | Per-slot: **Random** (Luhn-valid, band-matched TAC), **Deterministic** (stable hash of the SIM's IMSI), or **Static** (user-supplied) |
| **Consistent wireless identity** | One router vendor per rotation: all BSSIDs share a single OUI and the SSID broadcasts a matching brand name — no impossible vendor mixes |
| **Wireless rotation** | BSSIDs/MACs, SSID, hostname, and Wi-Fi passwords randomized on demand or on every boot |
| **Two-stage SIM swap** | Throwaway IMEIs written before poweroff; final IMEIs written on next boot *before* the modem first attaches — neither real identity bridges the swap |
| **`new-identity`** | One command, one reboot: coherent profile, every IMEI/MAC/SSID/password, SSH host keys, and the LuCI TLS cert rotated together, with a join QR to reconnect |
| **RAT lock** | Modem locked to 5G NR/LTE (`AT+QNWPREFCFG`), blocking the 2G/3G downgrade IMSI-catchers rely on |
| **No persistent connected-device logs** | Syslog, dnsmasq query log/cache, DHCP leases, and every telemetry directory RAM-backed — nothing about a connected client reaches flash |
| **Sealed factory state** | Factory IMEIs/MACs/SSIDs/keys AES-256-CBC-encrypted behind an install-time passphrase; restore is SSH-only and needs it |
| **TTL normalization** | Egress TTL/hop-limit set to 64 so NATed client traffic doesn't reveal tethering by TTL decrement |
| **Volatile client MACs** | `tmpfs` mounted over GL-iNet's client-MAC database — connected-device history never reaches flash |
| **Network visibility** | Per-slot registration state, operator, and signal in both the CLI and LuCI |
| **Health check** | `norypt-ghost check` — 16-point read-only self-test of the modem, generator, frames, and services |
| **Three control surfaces** | CLI over SSH, LuCI admin page, and a 2-second touchscreen long-press for SIM swap |
| **GL-iNet UI sync** | Settings → About Device shows the new IMEI automatically after every rotation |
| **Splash screens** | Six full-screen status frames written straight to the framebuffer during operations |

---

## Compatibility

| | |
|---|---|
| **Device** | GL-iNet GL-E5800 (Mudi 7) |
| **Firmware** | GL.iNet 4.8.3 (OpenWrt 23.05.4) and 4.8.5 |
| **Modem firmware** | `RG650VNA01ACR02A04G8G` (unchanged between 4.8.3 and 4.8.5) |
| **Architecture** | `aarch64_cortex-a53` |
| **Dependencies** | `luci-base`, `lua`, `luabitop` — all present in stock firmware |

The installer verifies the device model and firmware version before touching anything. Unknown firmware versions prompt for confirmation (interactive SSH installs only; non-interactive installs on unknown firmware abort safely).

> **Firmware upgrades remove the package without running its uninstall hooks.** Factory state survives in `/etc/config/norypt-ghost`, but the modem keeps its rotated IMEIs and GL-iNet's own BSSID randomization stays disabled until you reinstall Norypt Ghost (or restore manually). Reinstall after every firmware upgrade.

---

## Quick Start

**1. Enable LuCI** (bundled with the firmware, off by default — no internet required):

1. Open the GL-iNet web UI at `http://192.168.8.1`
2. Go to **System → Advanced Settings**
3. Click **Install Now** — this just starts the `uhttpd` web server
4. LuCI is now at `http://192.168.8.1:8080`

**2. Install the package:**

```sh
scp -O norypt-ghost_1.0.0-Script-Local.ipk root@192.168.8.1:/tmp/
ssh root@192.168.8.1 opkg install /tmp/norypt-ghost_1.0.0-Script-Local.ipk
```

Expected output (identifiers below are illustrative placeholders):

```
Installing norypt-ghost (1.0.0) to root...
Firmware 4.8.5 confirmed supported.
Configuring norypt-ghost.
norypt-ghost: capturing factory state...
  IMEI (slot 1):   <factory IMEI slot 1>
  IMEI (slot 2):   <factory IMEI slot 2>
  WiFi MAC (2.4g): <factory BSSID>
  SSID:            GL-E5800-xxxx
  Hostname:        GL-E5800
  WiFi keys saved: main + guest
norypt-ghost: factory state saved to /etc/config/norypt-ghost
norypt-ghost: installation complete. Rotate identity via: norypt-ghost rotate
```

The original device identity is captured **once** at install time and is never overwritten — reinstalls and upgrades (`opkg install --force-reinstall`) preserve it.

**3. Verify and rotate:**

```sh
ssh root@192.168.8.1
norypt-ghost check     # everything should PASS
norypt-ghost rotate    # first identity rotation
```

The admin page is under **Services → Norypt Ghost** in LuCI.

---

## Usage

### LuCI admin page

**Services → Norypt Ghost** (`http://192.168.8.1:8080`):

| Section | Contents |
|---|---|
| **IMEI** | Current vs. factory IMEI per slot, IMSI, and live network state (registration / operator / signal — loaded asynchronously). Rotated values are highlighted green. |
| **Wireless/System Identity** | Current vs. factory SSID, all nine MACs/BSSIDs, hostname, and the main/guest Wi-Fi passwords (masked, with Show/Hide). |
| **Rotation Options** | Boot-rotation master toggle + per-feature checkboxes; per-slot IMEI mode radios (Random / Deterministic / Static) with inline-validated static IMEI fields; re-attach timeout; touchscreen trigger toggle. Every control saves instantly with a ✓ flash. |
| **Actions** | Rotate IMEIs, Rotate Wireless/System, SIM Swap (double-confirmed — powers the device off), Restore Factory. Last-rotation timestamps below. |
| **Last Command Log** | Output of the most recent operation (`/tmp/norypt-ghost.log`). |

> Screenshots are intentionally not committed: the admin page displays live IMEIs, IMSIs, and BSSIDs, and a screenshot of a real unit publishes them permanently.

### Command line

```sh
norypt-ghost status            # identity + network registration overview
norypt-ghost check             # health check (see below)
norypt-ghost rotate            # rotate both IMEIs, cycle RF, wait for re-attach
norypt-ghost rotate-wireless   # rotate MACs/SSID/hostname/password immediately
norypt-ghost new-identity      # full clean rotation: new profile, every identifier, reboot
norypt-ghost sim-swap          # stage 1 of the SIM-swap flow (powers off!)
norypt-ghost restore           # restore every factory value
norypt-ghost install           # (re-)capture factory state — idempotent
norypt-ghost help              # full usage, including per-slot mode flags
```

Per-slot IMEI modes can be set for a single run (`--slot1=deterministic --slot2=random`, or `--random`/`--deterministic`/`--static` for both) — invalid modes and unknown options fail loudly rather than silently falling back. Persistent mode defaults live in UCI (see [Configuration Reference](#configuration-reference)).

Example `rotate`:

```
norypt-ghost: disabling RF before IMEI write...
norypt-ghost: generating IMEIs (slot1=random, slot2=random)...
  Slot 1 IMEI: <generated>
  Slot 2 IMEI: <generated>
  Slot 1 IMEI confirmed: <generated>
  Slot 2 IMEI confirmed: <generated>
norypt-ghost: cycling modem RF for network re-attach...
norypt-ghost: done.
```

`status` includes a Network section — the first place to look when a SIM won't connect:

```
=== Network ===
  Slot 1 registration: registered (home)
  Slot 2 registration: not registered (idle)
  Operator: <carrier>
  Signal:   -77 dBm
```

### Touchscreen trigger

Hold the **clock in the top-left corner** of the home screen for **2 seconds** to start a SIM swap — identical to running `norypt-ghost sim-swap` over SSH, no laptop needed.

The `norypt-ghost-touch` daemon (a small statically linked C binary, source in `src/`) reads `/dev/input/event0` without grabbing it, so the stock `gl_screen` UI keeps working normally. Guards against accidental triggers:

- 2-second hold required — quick taps are logged and ignored
- 10-second cooldown between triggers
- Blocked while a sim-swap is already in progress (stage file present)

Toggle it (persists across reboots and reinstalls) from LuCI → Rotation Options → **Touchscreen Trigger**, or over SSH: `/etc/init.d/norypt-ghost-touch disable && /etc/init.d/norypt-ghost-touch stop`.

### Health check

`norypt-ghost check` is a read-only self-test — run it any time something seems off, or after a firmware update:

```
=== norypt-ghost health check ===

Modem:
  PASS  gl_modem present
  PASS  AT socket present (/tmp/modem.CPU.AT.sock)
  PASS  modem answers AT commands
  PASS  IMEI readable (slot 1: <current IMEI>)

IMEI generator:
  PASS  lua generator produces valid IMEIs (sample: <generated>)
  PASS  TAC pool present (7 TACs)
  PASS  OUI pool present (20 router identities)

Splash frames:
  PASS  all 6 frames present
  PASS  framebuffer present (/dev/fb0)

Services:
  PASS  norypt-ghost-clean enabled
  PASS  norypt-ghost-wireless enabled
  PASS  norypt-ghost-sim-swap enabled
  PASS  norypt-ghost-ttl enabled
  PASS  norypt-ghost-touch enabled and running
  PASS  syslog not persisted to flash
  PASS  /etc/oui-tertf is RAM-backed

State:
  PASS  factory state saved

Result: all checks passed.
```

Exit code is non-zero if anything FAILs, so it can be scripted.

---

## How It Works

### What it protects (and what it can't)

Norypt Ghost reduces the **device-identity** trail a mobile hotspot leaves behind: the IMEI broadcast to cell towers, the Wi-Fi MACs/BSSIDs/SSID visible to anyone scanning nearby, the hostname, and the on-flash history of clients that connected. It cannot anonymize what it doesn't control:

- **The SIM is an identity.** The IMSI/ICCID identify the subscriber regardless of IMEI. Rotating the IMEI without swapping the SIM only unlinks the *hardware*; use the SIM-swap flow (new SIM + new IMEI + new location, together) for a clean break.
- **The eSIM EID is permanent.** The eUICC's EID is a fixed hardware identifier presented during remote SIM provisioning and cannot be rotated.
- **Location and usage patterns correlate.** Re-appearing in the same place, at the same times, with the same traffic patterns can re-link identities no rotation can hide.
- **Upstream traffic is out of scope.** Use a VPN/Tor on top; Norypt Ghost handles the radio identity layer only.

The deterministic IMEI mode trades unlinkability for consistency — see [IMEI modes](#imei-modes).

### Boot sequence

| Priority | Service | What it does |
|---|---|---|
| S9 | `norypt-ghost-clean` | Before GL-iNet's client tracker and telemetry daemons start: RAM-backs the syslog, `tmpfs`-mounts every present telemetry directory, and disables dnsmasq query logging/caching — see [No persistent connected-device logs](#no-persistent-connected-device-logs). |
| S10 | `norypt-ghost-wireless` | If boot rotation is enabled: rotates MACs, SSID, hostname, and Wi-Fi passwords *before* the APs come up. |
| S23 | `gl_cellular_manager` | GL-iNet's modem init daemon — the first point in boot where the AT socket accepts commands. |
| S25 | `norypt-ghost-sim-swap` | Only when a sim-swap or a staged `new-identity` is pending: waits for the AT socket, disables RF, writes the final IMEIs, applies the RAT lock, re-enables RF. The throwaway IMEI from Stage 1 is replaced before the modem ever attaches. Exits instantly on normal boots. |
| S45 | `norypt-ghost-ttl` | Normalizes egress TTL/hop-limit to 64 (`nft`, falling back to `iptables`/`ip6tables`) so NATed client traffic looks device-originated — defeats TTL-based tethering detection. |
| S80 | `gl_screen` | GL-iNet's touchscreen UI daemon. |
| S81 | `norypt-ghost-touch` | The long-press trigger daemon (procd-managed, auto-respawns). |

### IMEI rotation

1. RF off (`AT+CFUN=4`) — the old IMEI stops transmitting before anything is written
2. Both slots written via `AT+EGMR` (field 7 = Slot 1, field 11 = Slot 2/eSIM), NV-persisted with `AT+QPRTPARA=1`
3. RF on (`AT+CFUN=1`) + automatic operator re-attach (`AT+COPS=0`)
4. Registration polled via `AT+CEREG?` until attached or the configured timeout (default 120 s)
5. `gl_cellular_manager` restarted so GL-iNet's cached IMEI (Settings → About Device) matches the modem

A re-attach timeout is **non-fatal**: the warning screen is shown, RF stays on, and the modem keeps retrying in the background — relevant for factory-fresh SIMs whose first activation can take the carrier several minutes.

If a *write* fails, Norypt Ghost deliberately leaves RF **off** rather than transmitting a half-rotated identity, shows the error screen, and prints recovery steps (re-run, `norypt-ghost restore`, or `gl_modem -B CPU -U 1 AT 'AT+CFUN=1'` to force RF back on).

### IMEI modes

**Random** (default) — a TAC from `tac_pool.json` + 6 random serial digits + Luhn check digit. The pool is curated to 5G sub-6 hotspots/handsets whose band sets overlap the RG650V-NA's (n2/n5/n12/n25/n41/n66/n70/n71/n77/n78). This matters: carriers can compare a reported IMEI's expected capabilities against the cell it connects on, and a 4G-only TAC on a 5G NR cell is a contradiction — confirmed on real hardware to trigger ~10 Mbps throttling on at least one US carrier. Don't add LTE-only TACs to the pool.

**Deterministic** — `IMEI = luhn(tac_pool[djb2(IMSI) % n] + serial(djb2(IMSI)))`. The same SIM always maps to the same IMEI, useful when a carrier flags frequent IMEI changes on one subscription. **Privacy trade-off:** djb2 is a public, unkeyed hash — anyone who once observes the IMEI+IMSI pairing can re-derive the link forever. Random is strictly better for unlinkability. (Keying this hash with a per-install secret is on the [Roadmap](#roadmap).)

**Static** — a user-supplied 15-digit IMEI, Luhn-validated in the LuCI form *and* server-side. Written verbatim on every rotation.

All three fall back to Random (with a warning) if their inputs are unavailable, so a rotation never fails because of a missing IMSI or an unset static value.

### SIM-swap flow

The problem with a naive swap: if the modem ever holds *old SIM + new IMEI* (or vice versa), the two identities become linkable. Norypt Ghost splits the swap across a power cycle so they never coexist on air:

1. **Stage 1** (`norypt-ghost sim-swap`, touchscreen, or LuCI): RF off → random **throwaway** IMEIs written to both slots → state saved → device powers off
2. You swap SIM(s) — and ideally location — while it's off
3. **Stage 2** (S25, automatic on next boot): final IMEIs (per your configured modes) are written *before* the modem's first attach; the throwaway IMEIs never register

If Stage 2 can't reach the modem it leaves the pending state in place and retries next boot — the modem keeps the harmless throwaway identity in the meantime.

### MAC, BSSID, and SSID randomization

Every rotation picks **one router identity** — a single vendor OUI plus its SSID brand — from the curated pool in `oui_pool.json`:

- All six AP interfaces (`wifi2g/5g/6g` + guests) get that one OUI with random NIC bytes, like a real consumer router. Mixing vendors across bands is a fingerprinting flag no real device exhibits.
- The SSID becomes `<brand>-XXXX` to match (e.g., a Netgear OUI broadcasts `NETGEAR-A3F1`). Vendors whose factory SSIDs aren't brand-prefixed (Google Nest, Meraki) use a generic `HOME-XXXX`, plausible with any OUI.
- The **STA (repeater) interface** gets a *client*-class OUI (Apple/Intel/Samsung laptops and phones) — upstream networks see a client device, not a router.
- The **locally-administered bit** is forced on every generated MAC: the Qualcomm `ath11k` driver requires LA MACs for runtime channel changes on AP interfaces (GL-iNet's channel co-location in repeater mode breaks with UA MACs). **This has a cost** — an LA bit is itself a randomization signal to anyone scanning. See [Roadmap](#roadmap).

GL-iNet's own `random_bssid` feature is disabled at install (it generates UA MACs on its own schedule) and re-enabled at uninstall. Hostname becomes `router-XXXX`; main and guest networks get independent random 12-hex-character passwords.

### `new-identity`: full clean rotation

`rotate` and `rotate-wireless` are documented as *partial, live* operations — each changes one layer while the device keeps running, which is useful for quick refreshes but leaves the other layer as a linking handle across the boundary. `norypt-ghost new-identity` closes that gap: it is the single command that changes **everything at once**, across a clean reboot, and it's the recommended action whenever you want a real break between sessions.

One run does all of the following:

1. Picks a whole coherent device profile from `usr/share/norypt-ghost/profiles.json` (vendor, wifi/client OUI, SSID/hostname/password format, region, and a matching TAC) — not independent random fields, so the result can't show a NETGEAR SSID over an Apple OUI.
2. Stages new BSSIDs/MACs (including the wired MAC), SSID, hostname, and Wi-Fi passwords into UCI immediately.
3. Regenerates the SSH host keys and the LuCI TLS cert — both are permanent device identifiers that survive `rotate`/`rotate-wireless` untouched.
4. Stages the new IMEIs for both slots.
5. Prints (and, if `qrencode` plus a framebuffer viewer are installed, renders on the device screen) a `WIFI:` join QR and the plain SSID/password, so you can rejoin the new network immediately after reboot.
6. Reboots with RF disabled. The new IMEIs are written *before* RF (and the modem's first attach) is re-enabled on the next boot (the same S25 ordering the SIM-swap flow relies on), so the modem never attaches on the old identity. Note: unlike the two-stage SIM-swap flow, `new-identity` does not write a pre-reboot throwaway IMEI — the modem's own NV storage briefly still holds the old IMEI between shutdown and the S25 rewrite, it just never attaches with it, because RF stays off until after the rewrite.

```
norypt-ghost: staging new device identity...
  Profile: netgear-nighthawk-m6-na
  SSID:    NETGEAR-A3F1
norypt-ghost: rebooting in 5s to apply the new identity cleanly.
  Scan the QR on the device screen to rejoin Wi-Fi.
```

### RAT lock (2G/3G downgrade block)

The classic IMSI-catcher technique is a **downgrade**: force the handset onto 2G, where mutual authentication is absent and encryption is weak or off. Every identity apply (boot, `new-identity`, sim-swap Stage 2) now issues `AT+QNWPREFCFG="mode_pref",NR5G:LTE` — locking the modem to 5G NR / LTE only, so it can no longer silently fall back to GSM.

Controlled by `norypt-ghost.options.rat_lock` (default **on**). Turn it off from LuCI or `uci set norypt-ghost.options.rat_lock=0 && uci commit norypt-ghost` for regions with no LTE coverage.

### Volatile client MACs

GL-iNet's `gl_clients` daemon keeps a persistent database of every client MAC that ever connected, at `/etc/oui-tertf/client.db` on flash. At S9 Norypt Ghost deletes the on-flash copy and mounts a `tmpfs` over the directory — the daemon keeps writing without knowing it's writing to RAM, and the history starts empty every boot.

(The old file is unlinked, not overwritten: the Mudi 7's overlay is ext4 on eMMC, whose flash translation layer remaps writes — overwrite-in-place tools like `shred` are ineffective there. The tmpfs mount is the real protection.)

### No persistent connected-device logs

The volatile-MAC protection above was broadened into a general **no-connected-device-logs guarantee**, applied by the `norypt-ghost-clean` service before any of GL-iNet's tracking daemons start:

- **System log stays in RAM.** Any flash `log_file` configured under `system.@system[0]` is unset — `logread` still works, but nothing is written to flash.
- **`tmpfs` mounted over every telemetry directory present**, not just the client-MAC database: `/etc/oui-tertf` (client tracker), `/var/lib/nlbwmon` (bandwidth monitor), `/etc/vnstat` and `/var/lib/vnstat` (traffic stats). Each daemon keeps writing, believing it's on flash; the data evaporates at every reboot.
- **dnsmasq** runs with `logqueries=0` and `cachelocal=0` — no per-client DNS query log, no persisted local cache.
- **DHCP leases forced to `/tmp`** if GL-iNet's build ever points `leasefile` at flash.

`norypt-ghost check` reports pass/fail for each of these independently, and `norypt-ghost-clean stop` (run automatically on package removal) clears the RAM copies before the service exits — nothing about a connected device's history is ever written to durable storage on a Norypt Ghost install.

### Sealed factory state

The `factory` UCI section is what makes `restore` and clean uninstalls possible — but it's also a complete recovery key for the real identity the tool exists to hide, and by default it lived in cleartext, forever. **Sealed factory state** closes that: when `openssl` is available (the default, `factory_mode=sealed`), the entire `factory` section is AES-256-CBC-encrypted (PBKDF2, 200k iterations) behind a passphrase you set at install time, and the plaintext is discarded immediately after sealing.

What that means in practice:

- **Restore is SSH-only.** A sealed restore needs a human to type the passphrase at a terminal. Non-interactive callers — `opkg remove`'s `prerm`, a backgrounded LuCI restore click — refuse outright with a clear message instead of silently leaving the device half-restored or prompting into nowhere. Run `norypt-ghost restore` from an interactive SSH session when you need the factory identity back.
- **Forgetting the passphrase means no restore, period.** There is no recovery mechanism and no backdoor — that's the point. Wrong passphrase or a corrupted blob aborts the restore with RF left untouched, rather than writing garbage IMEIs.
- **Falls back to plain automatically** when `openssl` isn't installed, or when `factory_mode=plain` is explicitly set — behavior (and risk) then match the original cleartext design exactly, with no silent capability loss.

### Splash screens

During operations, Norypt Ghost stops `gl_screen` and writes pre-rendered frames (240×320 RGB565) directly to `/dev/fb0`:

| | | |
|:---:|:---:|:---:|
| ![Rotating](screens/previews/rotating.png) | ![Done](screens/previews/done.png) | ![SIM Swap](screens/previews/simswap.png) |
| ![Restoring](screens/previews/restoring.png) | ![Warning](screens/previews/warning.png) | ![Error](screens/previews/error.png) |

| Frame | Shown when |
|---|---|
| `rotating` | IMEI rotation or sim-swap Stage 2 in progress |
| `done` | Operation complete and modem re-registered |
| `simswap` | Stage 1: powering off for the SIM swap |
| `restoring` | Factory restore in progress |
| `warning` | Soft failure: IMEIs written but no re-registration within the timeout (modem keeps retrying) |
| `error` | Hard failure: a write failed; **RF is left off** until recovered |

Frames are generated by `screens/generate.py` (Python 3 + Pillow, dev-side only — the device never needs Python) and committed as binaries. To modify: edit the `FRAMES` list, run `python3 generate.py`, commit the regenerated `.rgb565` files and PNG previews.

Implementation note: `gl_screen` respawns via procd, so a plain `stop` would repaint over our frame within seconds — `_screen_splash` first removes it from procd's watch list (`ubus call service delete`), then stops it, then writes the frame. A separate GL-iNet boot process draws a progress bar at a fixed screen position during early boot; the `rotating`/`done` layouts leave that row empty so Stage 2 splashes aren't overdrawn.

---

## Configuration Reference

Everything lives in `/etc/config/norypt-ghost` (standard UCI). The `factory` section is written once at install; the `options` section is yours:

```
config norypt-ghost 'options'
    option randomize_on_boot    '1'        # rotate wireless identity at every boot
    option randomize_mac        '1'        # per-feature toggles for boot + rotate-wireless
    option randomize_ssid       '1'
    option randomize_hostname   '1'
    option randomize_password   '1'
    option imei_mode_slot1      'random'   # random | deterministic | static
    option imei_mode_slot2      'random'
    option static_imei_slot1    ''         # used when the slot's mode is 'static'
    option static_imei_slot2    ''
    option register_timeout     '120'      # seconds to wait for re-attach (10-600)
    option touch_enabled        '1'        # touchscreen trigger preference
    option rat_lock             '1'        # lock modem to 5G NR/LTE; blocks 2G/3G downgrade
    option factory_mode         'sealed'   # sealed | plain — see Sealed factory state
    option default_region       'NA'       # NA | EU — profile region when no SIM/MCC is readable
```

All values are editable from the LuCI page (changes apply instantly) or via `uci set norypt-ghost.options.<name>=<value> && uci commit norypt-ghost`. Every value is validated server-side — malformed input is rejected, never written to the modem.

> **The `factory` section stores your device's real IMEIs, MACs, SSIDs and Wi-Fi keys.** By default (`factory_mode=sealed`, requires `openssl`) it is encrypted behind a passphrase you set at install — see [Sealed factory state](#sealed-factory-state). With `factory_mode=plain`, or when `openssl` isn't installed, it falls back to the original cleartext-on-flash behavior: that's what makes `restore` and clean uninstalls possible, but it also means anyone with the device recovers its true identity.

---

## Building from Source

The touchscreen daemon is compiled from `src/` — no binaries are committed to this repository.

### 1. `build-ipk.sh` — no OpenWrt SDK required

```sh
git clone https://github.com/norypt-prv/Norypt-Mudi7.git
cd Norypt-Mudi7
sudo apt install -y gcc-aarch64-linux-gnu   # or have Docker available
./build-ipk.sh
```

Needs `bash`, `tar`, `gzip`, and an aarch64 cross-compiler (or Docker, used automatically as a fallback). Produces `norypt-ghost_1.0.0-Script-Local.ipk` from the `files/` tree, building `norypt-ghost-touch` first if it is missing or older than its source. **Use for:** day-to-day development and offline builds.

### 2. OpenWrt SDK — `Makefile`

A standard OpenWrt package recipe that compiles the daemon against the exact target toolchain:

```sh
# Use the 23.05.4 ipq807x/generic SDK — the same OpenWrt release the GL-E5800
# firmware is based on, and the same aarch64_cortex-a53 musl ABI. (The
# GL-E5800's IPQ9574 SoC has no upstream stable SDK of its own; any 23.05.4
# aarch64_cortex-a53 target produces an identical package.)
curl -fLO https://downloads.openwrt.org/releases/23.05.4/targets/ipq807x/generic/openwrt-sdk-23.05.4-ipq807x-generic_gcc-12.3.0_musl.Linux-x86_64.tar.xz
tar -xJf openwrt-sdk-23.05.4-*.tar.xz && cd openwrt-sdk-23.05.4-*/

ln -s /path/to/Norypt-Mudi7 package/norypt-ghost
make defconfig
make package/norypt-ghost/compile V=s
```

Output: `bin/packages/aarch64_cortex-a53/base/norypt-ghost_1.0.0-1_aarch64_cortex-a53.ipk`. **Use for:** reproducible/auditable builds or opkg feed submission.

### 3. GitHub Actions — both build paths, automatically

Two workflows run on every push, PR, and release tag:

| Workflow | What it does | Output |
|---|---|---|
| [`build.yml`](.github/workflows/build.yml) | Fast path — installs `gcc-aarch64-linux-gnu` and runs `build-ipk.sh` | `norypt-ghost_<version>-Script-{CI\|Release}.ipk` |
| [`sdk-build.yml`](.github/workflows/sdk-build.yml) | Downloads the pinned 23.05.4 SDK (checksum-verified) and builds via the `Makefile` | `norypt-ghost_<version>-SDK-{CI\|Release}.ipk` |

Both upload their IPK as a workflow artifact (retained 30 days). On a `v*.*.*` tag, a GitHub Release is created with **both** IPKs attached:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

The full release procedure — version bumping, tagging rules, and a command reference — is documented in [docs/RELEASING.md](docs/RELEASING.md).

### Building the touch daemon on its own

```sh
./tools/build-touch.sh
```

Uses `aarch64-linux-gnu-gcc` if present, otherwise Docker + QEMU with Alpine/musl. Output is stripped; `build-ipk.sh` refuses to package an unstripped binary.

### Development deploy

`./deploy.sh [host]` (default `root@192.168.8.1`) copies the working tree straight onto a device over SCP and re-registers the services — fast iteration without rebuilding the IPK. It does **not** run factory capture; run `norypt-ghost install` manually if needed.

---

## Uninstalling

```sh
opkg remove norypt-ghost
```

`prerm` stops and disables all services and **restores the full factory identity** (IMEIs, MACs, SSIDs, passwords, hostname); `postrm` re-enables GL-iNet's BSSID randomization and removes runtime state. Factory state in `/etc/config/norypt-ghost` is intentionally left behind so a future reinstall keeps the original values — delete it for a clean slate:

```sh
uci delete norypt-ghost.factory && uci delete norypt-ghost.options && uci commit norypt-ghost
```

---

## AT Commands We Deliberately Avoid

Hard-won knowledge from bricking-adjacent experiments on the RG650V-NA — none of these are used, and none should be added:

| Command | Why not |
|---|---|
| `AT+QPOWD` | Leaves the modem unresponsive until a full device reboot |
| `AT+CFUN=1,1` | Reboots the entire device, not just the modem RF |
| `AT+QPRTPARA=3` | Quectel factory reset — undefined behavior on carrier units |
| `AT+QUIMSUB` | Breaks the AT socket until reboot |
| `ubus call cellular.cm cm_stop_dial` | Persists `allow_dial=0` to flash; cellular manager then skips SIM detection on every subsequent boot |
| Writes to the RAWDATA MMC partition | Where the factory MAC lives; corruption is unrecoverable |
| Default eSIM profile deletion | Cannot be restored without a factory reset |

---

## Project Status

Inherited as device-verified on firmware 4.8.5 by the upstream project: install/uninstall lifecycle, dual-IMEI rotate and restore (live `AT+EGMR` writes confirmed), wireless rotation, volatile MACs, all six splash frames, the LuCI page, the touchscreen daemon, and the health check.

**Not yet re-verified on Norypt hardware.** The rebrand changed every installed path, service name, and UCI namespace; a full install → check → rotate → restore → uninstall pass on a Norypt unit is required before this is called shipped.

**Pending live-SIM validation** (requires an activated SIM):

- [ ] Re-registration after rotate (`+CEREG` 1/5, end-to-end)
- [ ] Deterministic mode end-to-end (IMSI → IMEI → carrier attach)
- [ ] Full two-stage sim-swap with a physical SIM change
- [ ] Throwaway IMEI exposure window check (`logread | grep "sim-swap throwaway"`)

---

## Roadmap

Ranked improvements, with rationale and effort estimates, are tracked in **[docs/ROADMAP.md](docs/ROADMAP.md)**, including a **[Delivered](docs/ROADMAP.md#delivered)** section for what's since shipped (host-tested, not yet on-device verified). The headline items:

1. Verify and expand the TAC pool (7 unverified entries today — profile-vendor coherence shipped; verification against a TAC database has not)
2. ~~Block 2G/3G downgrade~~ — **delivered**, see [RAT lock](#rat-lock-2g3g-downgrade-block)
3. ~~Rotate the wired WAN/LAN MAC, not just Wi-Fi~~ — **delivered**
4. Encrypt or discard the cleartext factory-identity state on flash — **sealed mode delivered**, see [Sealed factory state](#sealed-factory-state); rotation-timestamp/export-import sub-items remain
5. Reconsider the forced locally-administered MAC bit
6. Key the deterministic IMEI hash with a per-install secret
7. ~~Single-command "new identity" that rotates every layer at once~~ — **delivered**, see [`new-identity`](#new-identity-full-clean-rotation)
8. Serving-cell monitoring / IMSI-catcher detection

---

## Repository Layout

```
Norypt-Mudi7/
├── build-ipk.sh                  IPK builder (no SDK; control scripts inlined)
├── Makefile                      OpenWrt SDK package recipe
├── deploy.sh                     dev deploy over SCP
├── tools/build-touch.sh          cross-compiles the touch daemon from src/
├── src/norypt-ghost-touch.c      touchscreen daemon (C, statically linked)
├── screens/
│   ├── generate.py               RGB565 frame generator (dev-side, Python+Pillow)
│   └── previews/                 PNG previews of all frames (embedded above)
├── docs/
│   ├── RELEASING.md              release process
│   └── ROADMAP.md                ranked improvement backlog
└── files/                        package payload (mirrors the device filesystem)
    ├── usr/bin/norypt-ghost      CLI entry point (ash)
    ├── usr/libexec/norypt-ghost  rpcd exec backend for LuCI (JSON over fs.exec)
    ├── lib/norypt-ghost/
    │   ├── functions.sh          AT helpers, IMEI/MAC/SSID generation, RF control,
    │   │                         RAT lock, splash control — single shared library
    │   ├── profile.sh            profiles.json loader + region/format-token derivation
    │   ├── identity.sh           new-identity stage/apply engine, SSH/TLS key regen
    │   ├── clean.sh               telemetry/log tmpfs + no-persistent-logs guarantee
    │   ├── seal.sh                factory-state AES-256-CBC seal/unseal wrapper
    │   ├── imei_generate.lua     TAC-pool IMEI generator (random + deterministic)
    │   └── luhn.lua              Luhn checksum module
    ├── etc/init.d/               five services: clean (S9), wireless (S10),
    │                             sim-swap stage 2 (S25), ttl (S45), touch (S81)
    ├── usr/share/norypt-ghost/
    │   ├── tac_pool.json         curated 5G TACs (band-matched to the RG650V-NA)
    │   ├── oui_pool.json         router + client OUIs with SSID brand mapping
    │   ├── profiles.json         coherent device-profile catalog (vendor/OUI/TAC/format)
    │   └── screens/*.rgb565      six pre-rendered splash frames
    └── www/…/norypt_ghost.js     LuCI2 admin page (vanilla JS view)
```

---

## Attribution

- **[blue-merle-v2](https://github.com/WSchlesner/blue-merle-v2)** — the direct upstream of this package: the Mudi 7 port, the dual-IMEI `AT+EGMR` mapping, the two-stage SIM-swap design, and the LuCI/touchscreen/splash implementation. GPL-2.0-only.
- **[SRLabs](https://www.srlabs.de) / [srlabs/blue-merle](https://github.com/srlabs/blue-merle)** — the original design, threat model, and first implementation, for the GL-E750 Mudi. BSD 3-Clause.
- **[gl-inet/glinet-tac-fix](https://github.com/gl-inet/glinet-tac-fix)** — the only public GL.iNet code calling `AT+EGMR`, which confirmed the quoting format and the `AT+QPRTPARA=1` NV-persistence pattern for the RG650V-NA.

Norypt Ghost is a rebranded and modified derivative, not an official continuation of either project. Neither SRLabs nor the blue-merle-v2 authors endorse it.

## License

**GPL-2.0-only** — see [LICENSE](LICENSE).

Norypt Ghost inherits GPL-2.0-only from blue-merle-v2. Code derived from SRLabs' BSD-3-Clause blue-merle (`files/lib/norypt-ghost/luhn.lua`) retains SRLabs' copyright, and their full BSD notice is reproduced in [NOTICE](NOTICE) as its terms require. BSD 3-Clause code may be incorporated into a GPL-2.0 work; the combined project is distributed under GPL-2.0-only.
