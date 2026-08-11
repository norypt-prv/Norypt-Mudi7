# Norypt Ghost — Security & Anonymity Hardening

**Design spec · 2026-08-11**

Status: approved for planning. Author: Norypt.

## Goal

Three user requirements drive this work:

1. **Better security and anonymity** overall.
2. **IMEI randomization that looks like a legitimate real phone** — not merely
   Luhn-valid, but a TAC belonging to a real device model whose radio bands
   match the cell it attaches to.
3. **Full-fingerprint rotation** — every identifier changes together, so
   nothing in a new identity links back to the previous one, at any layer an
   observer or a later device inspector can see.
4. **Never persist connected-device history** — on every boot the device is
   clean; someone who later connects to the router must find no record of what
   phones or clients were connected to it.

This is a hardening pass over the inherited codebase, not a rewrite. The
two-stage SIM-swap flow is correct and is left untouched.

## Threat model

Two distinct adversaries, addressed separately:

- **Network observer** — the carrier, or anyone scanning nearby Wi-Fi.
  Defeated by rotating every identifier together and by making each identity
  internally coherent (a device that claims to be a Netgear over the radio
  broadcasts a Netgear BSSID and SSID). Pure upside; no trade-off.
- **Device inspector** — someone who later obtains the device and reads its
  flash. Defeated by (a) storing no connected-device history on flash and
  (b) sealing the factory-identity state behind a passphrase.

Out of scope, and documented as such: upstream traffic content (use a VPN/Tor
on top), what the carrier logs on its side, and live capture while a client is
actively connected.

## Design decisions (locked)

| Decision | Choice |
|---|---|
| Fingerprint model | **Option A — device-profile catalog.** One coherent archetype per rotation. |
| Rotation application | **Reboot-based**, with new Wi-Fi credentials rendered as a QR on the touchscreen. |
| IMEI pool | **Dual EU/NA pools**, auto-selected from the SIM's IMSI MCC. |
| Factory state | **Sealed by default** (passphrase), `plain` opt-in for lab units, graceful fallback if no on-device crypto. |
| Extra hardening | **TTL normalization** + **SSH host key / LuCI TLS cert regeneration** + **2G/3G downgrade block (RAT lock)**. |
| Not doing | IPv6 privacy addressing, DoH/DoT pinning, LAN subnet randomization, scheduled rotation, IMSI-catcher *detection*. |

---

## Section 1 — Identity Profile Catalog (Option A)

A new data file `files/usr/share/norypt-ghost/profiles.json` supersedes the
disconnected `tac_pool.json` + `oui_pool.json` stitching (those files' data is
folded into it). Each entry is one coherent real-device archetype:

```json
{
  "id": "netgear-nighthawk-m6",
  "class": "hotspot",
  "region": "NA",
  "vendor": "NETGEAR",
  "imei_tacs": ["<verified Netgear M6 TAC>", "..."],
  "wifi_oui":  ["<real Netgear WLAN OUI>", "..."],
  "ssid_format":         "NETGEAR-{4hex}",
  "psk_format":          "{10lower}",
  "hostname_format":     "Nighthawk-M6",
  "dhcp_hostname_format": "android-{16hex}",
  "bands": ["n2","n5","n25","n41","n66","n71","n77","n78"]
}
```

Rules:

- One rotation picks **one profile** and derives *every* identifier from it.
  The IMEI TAC vendor, the Wi-Fi BSSID OUI vendor, and the SSID brand are the
  same vendor by construction. Vendor-mismatched fingerprints are impossible,
  not merely discouraged.
- `class` ∈ {`hotspot`, `phone`}. A `hotspot` profile presents a MiFi/Nighthawk
  identity; a `phone` profile presents a handset TAC and a client-style DHCP
  hostname. Default selection weights favour `hotspot` (closest match to what
  the Mudi 7 physically is).
- `region` ∈ {`EU`, `NA`}. Selection is constrained to the region chosen by
  MCC auto-select (Section 3).
- Format tokens: `{Nhex}` = N random hex chars, `{Nlower}` = N random
  lowercase alphanumerics, `{Ndigits}` = N random digits. Literal text is kept
  verbatim. A profile whose factory SSID is not brand-prefixed (e.g. Google
  Nest) may use a `HOME-{4hex}` style format — still coherent because the OUI
  and SSID are both "generic home router".

Selection uses rejection sampling against `/dev/urandom` to avoid the modulo
bias present in the inherited code.

Parsing uses `jsonfilter` (present in OpenWrt base), not the inherited
hand-rolled `awk` scanners, which break on nested arrays.

## Section 2 — Full-fingerprint rotation engine (`new-identity`)

New primary command `norypt-ghost new-identity`. Reboot-based, three phases.

**Phase 1 — Stage (pre-reboot).**
1. Auto-select region (Section 3), pick one profile.
2. Generate every identifier from the profile:
   - both slot IMEIs (from the profile's verified TACs)
   - all six AP BSSIDs + the repeater STA MAC (STA gets a client-class OUI)
   - the wired WAN/LAN device MAC(s), and the Bluetooth MAC if the adapter
     exists
   - SSID + guest SSID, hostname, DHCP client hostname sent upstream
   - main + guest PSK
3. Write the wireless/system half to UCI immediately.
4. Write `/etc/norypt-ghost.identity-pending` holding the staged IMEIs and the
   profile id (this reuses the sim-swap Stage-2 pre-attach mechanism).
5. Set a flag to regenerate SSH host keys + LuCI TLS cert on boot.
6. Render the new SSID + PSK as a Wi-Fi-join QR code to `/dev/fb0`.
7. Reboot.

**Phase 2 — Boot apply.**
- `norypt-ghost-sim-swap` (S25, before the modem's first attach) writes the
  staged IMEIs, exactly as the sim-swap flow already does.
- A boot hook regenerates SSH host keys and the LuCI TLS cert (only when the
  flag is set), and applies the RAT lock (Section 3).
- All wireless/system identifiers are already in UCI, so interfaces come up
  fresh — no interface ever carries a mix of old and new.

**Phase 3 — Clean landing.**
- Because it is a reboot, every RAM-resident correlation artifact (client-MAC
  db, DHCP leases, ARP/conntrack, in-memory log) is gone by construction. The
  device itself no longer holds the old↔new link. Section 4 guarantees none of
  it was on flash to begin with.

**Existing commands.** `rotate` and `rotate-wireless` remain as live,
single-layer partial rotations for quick changes, documented explicitly as
**not a clean break** (they leave RAM correlation state intact). `new-identity`
is the action the LuCI page leads with; the partial rotations move to an
"advanced" row.

QR rendering is generated dev-side into the frame set where practical, or
drawn at runtime if a small enough QR encoder is available on-device; the
runtime-vs-prerendered choice is settled during planning after checking what
the device has. If neither is feasible the credentials are shown as text on the
splash and the QR is dropped — the rotation itself never depends on the QR.

## Section 3 — IMEI realism + downgrade block

- **Realism.** IMEIs are generated only from a profile's verified TAC list, so
  the IMEI always belongs to a real device model whose bands match the serving
  cell. This removes the capability-contradiction that caused confirmed carrier
  throttling with the inherited unverified pool.
- **MCC auto-select.** At rotation, read the active SIM's IMSI MCC (first 3
  digits) and pick the EU or NA profile pool accordingly, so the IMEI is
  plausible for the network the SIM actually belongs to. If the IMSI is
  unreadable, fall back to `default_region` (UCI option).
- **RAT lock (2G/3G downgrade block).** Apply
  `AT+QNWPREFCFG="mode_pref",NR5G:LTE` at boot and after every rotation,
  exposed as UCI option `rat_lock` and a LuCI toggle, default on. This is the
  core IMSI-catcher prevention: those attacks force a 2G downgrade to strip
  authentication and encryption. A documented escape hatch (`rat_lock=0`)
  exists for regions without LTE coverage. The exact Quectel syntax is
  confirmed against the RG650V on-device during implementation before it is
  relied on.

## Section 4 — Ephemeral state: no logs, clean every boot

New service `norypt-ghost-clean`, running early at boot (before the daemons it
covers start) **and** on shutdown. It ensures no connected-device history ever
reaches flash.

| Persisted data | Location | Treatment |
|---|---|---|
| Client-MAC history | `/etc/oui-tertf/client.db` | tmpfs (inherited behaviour, retained) |
| GL per-client traffic accounting | `gl-tertf` / nlbwmon `/var/lib/nlbwmon` | tmpfs over its dir; disable flash commit |
| Per-device bandwidth stats | vnstat `/etc/vnstat` (if present) | disable persistence |
| DHCP leases (client MAC + hostname) | `/tmp/dhcp.leases` + any GL flash copy | force to tmpfs; wipe on stop |
| System log | `system.@system[0].log_file` → flash | force RAM ring buffer; unset any flash log path |
| dnsmasq query history | query log / persistent cache | query logging off; no persistent cache |
| Static DHCP host entries | `/etc/config/dhcp` | left alone — user config, not history |

Details:

- **Boot ordering** places `norypt-ghost-clean` before `gl_clients`,
  `dnsmasq`, and `gl-tertf`, so those daemons write to RAM from their first
  write rather than being cleaned up after the fact.
- **Shutdown** wipes the RAM-backed copies so a pulled-power forensic capture
  of the eMMC finds nothing.
- **Path discovery is defensive.** Each path is checked for existence on the
  actual firmware; anything absent is skipped, never fatal. The real set of
  GL.iNet telemetry paths is confirmed on-device during implementation.
- **Health gate.** `norypt-ghost check` gains a line asserting "no persistent
  client logging" (log_file unset, expected dirs are tmpfs).
- **Documented limits.** This stops *stored* history. It does not stop a live
  capture while a client is actively connected, and it cannot erase what the
  carrier logs upstream.

Also moved off flash as part of this: the rotation timestamps
(`/etc/norypt-ghost.last_*_rotate`) relocate to `/tmp`, so the device stops
keeping a dated history of when its identity changed.

## Section 5 — Sealed factory state

The factory section (real IMEIs, all MACs, SSIDs, hostname, and Wi-Fi keys) is
encrypted with a passphrase set at install.

- **Crypto primitive discovery**, in priority order: `openssl` CLI, then any
  `mbedtls`-based tool present. If none exists, **fall back to `plain` mode
  with a loud warning** and print the one-line `opkg install openssl-util`
  fix. No cipher is hand-rolled.
- **Format**: `sealed=1`, `kdf=pbkdf2-sha256/<iters>`,
  `blob=<base64 AES-256-CBC>`. `restore` and `opkg remove` prompt for the
  passphrase.
- **UCI option `factory_mode`**: `sealed` (default) or `plain` (lab units).
- **Stated plainly at install**: a forgotten passphrase means restore is
  impossible.

## Section 6 — Additional hardening

- **TTL / hop-limit normalization.** An nftables (or iptables, matching the
  firmware's firewall) rule sets egress TTL to 64 so NATed client traffic
  appears to originate on the device itself. Without it, an IMEI claiming to be
  a phone is contradicted by the decremented TTL of visibly-forwarded packets —
  the standard tethering-detection signal. Near-zero cost, direct realism gain.
- **SSH host keys + LuCI TLS cert regeneration.** Both are permanent device
  identifiers that currently survive every MAC and IMEI change; anyone who has
  connected once can re-identify the device across all rotations. Regenerated
  on every `new-identity`. Documented side effect: SSH prints a
  "host key changed" warning after each rotation.

## Section 7 — Testing strategy

The inherited project ships no tests. Much of this work is pure logic and is
testable on a host.

- **`shellcheck`** over every shell file; required CI check.
- **Lua unit tests** for the generators: Luhn validity, TAC-membership (the
  generated IMEI's TAC is always in the chosen profile), determinism where
  applicable, and a distribution check confirming rejection sampling is
  unbiased.
- **Profile-catalog validator** (CI, fails the build on violation): every
  profile has ≥1 verified TAC and ≥1 OUI; every OUI is genuinely
  universally-administered (catches the inherited `DA:A1:19` bug); `region` ∈
  {EU,NA}; all format strings parse. No `verified:false` TAC may ship.
- **Coherence test**: for a sampled profile, IMEI-TAC vendor, Wi-Fi OUI
  vendor, and SSID brand all resolve to the same vendor.
- **IPK install/remove smoke test** in a container where feasible.
- **On-device manual acceptance checklist** (documented, not automated):
  `new-identity` → reboot → verify every layer changed → QR rejoin → restore.
  This is the gate before the work is called shipped, since AT writes and the
  framebuffer cannot be exercised off-hardware.

## Section 8 — Structure & non-goals

**Structure.** `functions.sh` already carries a lot. New logic is split into
focused libraries it sources, each independently readable and testable:

- `profile.sh` — catalog load, selection, coherence derivation
- `identity.sh` — the stage/apply rotation engine
- `clean.sh` — ephemeral-state helpers
- `seal.sh` — crypto wrapper (seal / unseal / discovery / fallback)

**Explicit non-goals** (YAGNI; deferred to the roadmap, not this work):

- IPv6 privacy addressing / DoH-DoT DNS pinning — not selected.
- LAN subnet randomization — not selected; breaks bookmarks.
- Scheduled or automatic rotation — separate future feature.
- Serving-cell IMSI-catcher *detection* — the RAT lock is *prevention*, which
  is in scope; monitoring/detection is a larger separate project.
- Any change to the two-stage SIM-swap flow — it works; untouched.

---

## On-device facts to confirm before/during implementation

These cannot be checked off-hardware and are verified on the unit during
planning/implementation; each has a defined fallback so none blocks the design:

1. Actual modem model and supported bands (`ATI`, `AT+QNWPREFCFG`) — confirms
   EU-band viability and the exact RAT-lock syntax.
2. Presence of an on-device crypto primitive (`openssl` / mbedtls) — decides
   sealed vs plain fallback.
3. The real set of GL.iNet telemetry/log paths — decides the `clean` service's
   path list.
4. Whether a small QR encoder is available on-device, or QR frames must be
   pre-rendered.
5. Firewall backend (nftables vs iptables) — decides the TTL rule syntax.
