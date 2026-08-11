# Norypt Ghost — Improvement Roadmap

Findings from a full read of the inherited codebase, ranked by privacy impact
per unit of effort. Each item states the problem, why it matters, and what the
fix looks like.

Effort key: **S** ≈ hours · **M** ≈ 1–2 days · **L** ≈ a week or more.

---

## Delivered

Implemented and host-tested (shellcheck + profile validator + Lua/Python unit
tests, all green in CI). **Not yet on-device verified** — see
[Project Status](../README.md#project-status) for the acceptance pass still
required before these are called shipped.

- **Profile-coherent IMEI realism with verified TACs** (closes Item 1). A new
  `usr/share/norypt-ghost/profiles.json` catalog binds vendor, wifi/client
  OUI, SSID/hostname/password format, region, and TAC into one coherent
  real-device archetype per entry — `norypt-ghost new-identity` and the
  sim-swap Stage 2 path pick a whole profile, not independent random fields,
  so the presented identity can no longer show a mismatched SSID over a
  different vendor's OUI. The catalog is **phone-only** (six popular Apple /
  Samsung archetypes, EU + US): a phone tethering its SIM is a far larger
  anonymity set than any single hotspot model, and reads as a phone on the
  carrier network. **Every TAC is `verified: true`** — each is the first 8
  digits of a real device IMEI recorded in Swappa's IMEI database for that
  exact model, with the source URL stored per entry — and the CI host-test
  job now runs the validator with `--release`, which fails the build if any
  TAC is ever left unverified.
- **Full-fingerprint `new-identity`** (closes Item 11). One command rotates
  IMEIs, all MACs (including wired — see below), SSID/hostname/passwords,
  SSH host keys, and the LuCI TLS cert together, across a reboot, and
  displays a Wi-Fi-join QR/credentials on the device screen to rejoin.
  `rotate` / `rotate-wireless` remain as documented partial, live operations.
- **RAT lock / 2G-3G downgrade block** (closes Item 2). `AT+QNWPREFCFG="mode_pref",NR5G:LTE`
  is applied on every identity apply, gated by `norypt-ghost.options.rat_lock`
  (default on).
- **Wired MAC rotation** (closes Item 3). `RANDOMIZE_WIRED_MAC` covers
  `network.@device[0].macaddr` with a client-class OUI, wired into the
  `new-identity` stage/apply flow.
- **No persistent connected-device logs.** `norypt-ghost-clean` (formerly
  `norypt-ghost-volatile-macs`, broadened) mounts `tmpfs` over every
  telemetry directory that exists (`oui-tertf`, `nlbwmon`, `vnstat`), unsets
  the flash syslog file, disables dnsmasq query logging/cache, and forces
  DHCP leases to `/tmp`. `norypt-ghost check` reports pass/fail per
  directory.
- **Sealed factory state** (partially closes Item 4). `factory_mode=sealed`
  (default when `openssl` is present) AES-256-CBC/PBKDF2-encrypts the
  `factory` UCI section behind an install-time passphrase; restore requires
  an interactive SSH session and the passphrase — non-interactive callers
  (prerm, backgrounded LuCI restore) refuse rather than fail silently or
  leave state in a half-restored condition. **Trade-off, stated plainly: a
  forgotten passphrase means the factory identity cannot be recovered.**
  **Not closed:** the `last_*_rotate` timestamp-to-flash and
  export/import-factory sub-items are still open.
- **TTL/hop-limit normalization** (new capability, not in the original
  numbered list). `norypt-ghost-ttl` sets egress TTL/hop-limit to 64 via
  `nft` (or `iptables`/`ip6tables` fallback) so NATed client traffic no
  longer reveals itself by TTL decrement — defeats the common
  carrier tethering-detection heuristic.
- **SSH/TLS regen.** `IDENTITY_REGEN_KEYS` (part of `new-identity`)
  regenerates the dropbear host keys and the LuCI self-signed TLS cert —
  both are permanent device identifiers that survived every prior rotation.

---

## Tier 1 — Holes in the tool's own threat model

These are cases where the package does not deliver what its design promises.

### 1. The TAC pool is entirely unverified · **S**

**✅ Delivered** — see [Delivered](#delivered). The catalog is now
`profiles.json`, phone-only, with every TAC `verified: true` against a real
Swappa device record (source URL per entry), and the CI `--release` gate
fails the build on any unverified TAC. The legacy `tac_pool.json` remains
only as the fallback pool for the random-IMEI mode of the live partial
`rotate` path.

Historical context (the problem this closed): the original `tac_pool.json`
shipped 7 TACs, every one `"verified": false`. Its own header warned that an
LTE-only TAC on a 5G cell caused confirmed carrier throttling — the single
most security-relevant data file in the package was unvalidated, and a small
pool cycling on one cell is itself a rotation-tool fingerprint.

**Still open (optional):** expand the catalog beyond six archetypes if a
larger anonymity set is wanted, and periodically refresh TACs as new flagship
models ship.

The sibling `oui_pool.json` needs the same treatment. Its header asserts
"All OUIs are universally-administered (bit 0 of first byte = 0, bit 1 = 0)",
but `DA:A1:19` — listed as "Google Nest WiFi" — has the LA bit *already* set
(`0xDA = 1101_1010`), so it is not a vendor allocation at all. One entry in
twenty violates the file's own stated invariant, which is what an unvalidated
data file looks like. The CI check should assert the invariant, not trust the
comment.

### 2. No 2G/3G downgrade block · **S–M**

**✅ Delivered** — see [Delivered](#delivered).

The ancestor of this project (SRLabs' blue-merle) exists because of IMSI
catchers. The classic IMSI-catcher technique is a **downgrade**: force the
handset onto 2G, where mutual authentication is absent and encryption is weak
or off. Norypt Ghost rotates the IMEI but never constrains the radio access
technology, so the modem will still happily fall back to GSM.

**Fix:** add an RAT lock via `AT+QNWPREFCFG="mode_pref",NR5G:LTE` (Quectel
RG-series syntax), exposed as a UCI option and a LuCI toggle, defaulting to
5G/LTE-only. Include a documented escape hatch for regions with no LTE
coverage. This is the single highest-value *new* capability on this list.

### 3. Wired MACs are never rotated · **S**

**✅ Delivered** — see [Delivered](#delivered). (The Bluetooth-adapter check
mentioned in the fix below was not part of this pass — the E5800 was not
confirmed to carry one.)

`RANDOMIZE_MACADDR` covers `wifi2g/5g/6g`, the three guest APs, and the
repeater STA. It does not touch `network.@device[0].macaddr` — the Ethernet
MAC. `norypt-ghost status` even prints that MAC under "MAC addresses",
implying coverage it does not have.

Anyone using the Mudi 7's Ethernet WAN, or tethering over USB, presents a
stable hardware identifier to the upstream network on every rotation.

**Fix:** extend rotation and factory capture to the wired device MAC(s),
using a client-class OUI (the router is a *client* of the upstream network on
its WAN side). Check for a Bluetooth adapter on the E5800 and cover its MAC
too if present.

### 4. Factory identity is stored in cleartext on flash · **M**

**◐ Partially delivered** — see [Delivered](#delivered). The `sealed`
`factory_mode` ships (encrypted, SSH-only, passphrase-gated restore); the
`last_*_rotate` timestamps still land on flash and `export-factory` /
`import-factory` do not exist yet.

`/etc/config/norypt-ghost` holds the real IMEIs for both slots, all seven
factory MACs, factory SSIDs, hostname, **and the factory Wi-Fi keys** — in
plaintext, on the device, forever. It is what makes `restore` and clean
uninstalls work, and it is also a complete recovery key for the identity the
tool exists to hide. Whoever holds the device holds the real identity.

Compounding it: `/etc/norypt-ghost.last_imei_rotate` and
`.last_wireless_rotate` write **rotation timestamps to flash**, leaving a
dated history of when identities changed.

**Fix, layered:**
- Move the `last_*_rotate` timestamps to `/tmp` (they are UI conveniences).
- Add a `factory_state` mode: `plain` (today), `sealed` (encrypted with a
  passphrase entered at restore time), or `none` (one-way rotation — restore
  is impossible, and `opkg remove` says so loudly).
- Add `norypt-ghost export-factory` / `import-factory` so the state can live
  off-device instead.

### 5. The forced locally-administered bit defeats vendor spoofing · **M**

`MAC_GEN` ORs `0x02` into the first octet of every generated MAC, so an OUI
picked as `04:92:26` (ASUS) is broadcast as `06:92:26` — which is not ASUS,
and is not any vendor. It is a locally-administered address, and no allocated
OUI ever has that bit set. An observer doing an OUI lookup on a beacon gets
"locally administered" — i.e. *randomized* — which is precisely the signal
the carefully curated `oui_pool.json` and brand-matched SSIDs exist to avoid.

The code comments justify it: `ath11k` needs LA MACs for runtime channel
changes when GL-iNet co-locates channels in repeater mode.

**Fix:** make the LA bit *conditional*. When the repeater STA is not in use,
use true universally-administered vendor MACs so the OUI resolves correctly;
force LA only when repeater mode is active, and say so in the UI. Requires
device testing to confirm the constraint's real boundary — the comment
describes repeater-mode co-location specifically, not all AP operation.

---

## Tier 2 — Correctness and cryptographic hygiene

### 6. Deterministic IMEI mode uses an unkeyed public hash · **S**

`djb2(IMSI) → seed → TAC + serial`. The README is honest about this: anyone
who observes one IMEI↔IMSI pairing can re-derive every future IMEI for that
SIM, permanently, because the algorithm is public and there is no secret.

**Fix:** generate a random 32-byte secret at install, store it with the
factory state, and derive the IMEI from `HMAC(secret, IMSI)` instead. Same
per-SIM stability, no external derivability. Regenerating the secret rotates
every deterministic IMEI at once — a useful panic action in itself.

### 7. Modulo bias in every random selection · **S**

`$(( $(od -An -N2 -tu2 /dev/urandom) % count + 1 ))` biases toward low indices
whenever `count` does not divide 65536 — which it never does for 7 TACs or 20
OUIs. Small in absolute terms, but this is a privacy tool: the whole point is
that selections are uniform.

**Fix:** rejection sampling (redraw when the value falls in the biased tail).
Ten lines of shell.

### 8. SSID/BSSID vendor consistency silently breaks · **S**

`RANDOMIZE_MACADDR` writes the chosen brand to
`/tmp/norypt-ghost.session_brand`; `RANDOMIZE_SSID` reads it back. But if a
user disables MAC rotation and leaves SSID rotation on — a supported
combination in the UI — `RANDOMIZE_SSID` picks a *fresh* brand that will not
match the BSSIDs already on the air. The exact vendor-mixing fingerprint the
design goes out of its way to avoid.

**Fix:** when MAC rotation is off, derive the brand from the *current* BSSID's
OUI by reverse lookup in `oui_pool.json`.

### 9. Wi-Fi key format is a fingerprint of its own · **S**

`RANDOMIZE_PASSWORD` produces 12 uppercase hex characters. Strong (48 bits)
but no consumer router ships a key that looks like that — real factory keys
are typically 8–10 lowercase alphanumerics. Same for `router-XXXX` as a
hostname, which matches no vendor's convention.

**Fix:** per-brand key and hostname formats in `oui_pool.json`, so the whole
presented identity is internally consistent, not just the OUI and SSID.

### 10. JSON parsed with hand-rolled `awk` · **S**

`_load_ouis` and `_load_router_identities` scan JSON with `awk` regexes that
terminate a section at the first `]`. It works on today's `oui_pool.json` and
would break the moment an entry contains a nested array — which the sibling
`tac_pool.json` already does (`"bands_5g_sub6": [...]`). One file format
change away from silently returning an empty pool and falling back to a
hardcoded TP-Link OUI.

**Fix:** use `jsonfilter`, which is in OpenWrt base and already on the device.

---

## Tier 3 — Product and operational gaps

### 11. No single "new identity" action · **S**

**✅ Delivered** — see [Delivered](#delivered).

`rotate` changes IMEIs. `rotate-wireless` changes Wi-Fi identity. Nothing
changes both. An operator who runs only one leaves the other as a linking
handle across the rotation boundary — and the LuCI page presents them as two
equal buttons with no guidance.

**Fix:** add `norypt-ghost new-identity` (IMEI + wireless + hostname +
passwords, one command, one splash sequence) and make it the primary LuCI
action, demoting the individual rotations to an "advanced" row.

### 12. No scheduled or event-driven rotation · **M**

Every rotation is manual. A device that rotates only when someone remembers
to rotate it produces long, correlatable sessions.

**Fix:** optional interval rotation via cron (with jitter — a rotation
landing exactly on the hour is its own signal), and optionally rotate on
serving-cell change, which approximates "the user has moved".

### 13. Serving-cell monitoring / IMSI-catcher detection · **L**

The device holds a modem that can report its serving cell and neighbours
(`AT+QENG="servingcell"`, `"neighbourcell"`). Nothing reads them. Logging
cell identity over time and alerting on catcher-typical anomalies — sudden
LAC/TAC change with unchanged location, a cell with no neighbours, an
unexplained RAT downgrade, unusually high broadcast power — turns this from
a rotation tool into a detection tool. It is the natural flagship feature and
the clearest differentiator from upstream.

### 14. Zero automated tests · **M**

**◐ Partially delivered.** `tests/run.sh` runs shellcheck, the profile
validator, a Lua unit suite, and Python logic tests, and `.github/workflows/build.yml`
now runs it as a required `test` job that `build` depends on. **Not closed:**
no container-based install/remove smoke test of the built IPK exists yet.

CI builds the package twice and never tests it. The Luhn module, the IMEI
generator, the TAC/OUI parsers, and the UCI option validation in
`usr/libexec/norypt-ghost` are all pure logic that can be tested on a host.

**Fix:** `shellcheck` over every shell file, a Lua test suite for
`luhn.lua`/`imei_generate.lua` (Luhn validity, TAC membership, determinism,
distribution), and a container-based install/remove smoke test of the IPK.
Wire into CI as a required check.

### 15. Firmware compatibility is hardcoded to two versions · **M**

`preinst` matches literal `4.8.3|4.8.5` strings. Any GL.iNet update prompts
the user to override a warning, on a package that writes to modem NV.

**Fix:** replace version matching with capability probing — confirm `AT+EGMR`
fields 7 and 11 read back plausible IMEIs, confirm the expected UCI wireless
sections exist — and treat the version string as advisory. Fail on missing
capability, not on an unrecognised number.

### 16. Package does not survive firmware upgrades · **S**

A GL.iNet firmware upgrade removes the package *without* running `prerm`, so
the modem keeps its rotated IMEIs while the tool that can restore them is
gone, and GL-iNet's own BSSID randomization stays disabled.

**Fix:** register the config in `/lib/upgrade/keep.d/`, and ship a documented
post-upgrade reinstall step (or a small first-boot check that detects the
orphaned state and warns on the LuCI page and the device screen).

### 17. `gl_screen` can be left deregistered from procd · **S**

`_screen_splash` calls `ubus call service delete` then `pkill -9 gl_screen`
so procd will not repaint over the splash. If the operation is interrupted
between that and `_screen_restore_display` — a reboot, a killed SSH session,
a failed rotate that exits early — the touchscreen UI stays dead until the
next boot, with no indication why.

**Fix:** a shell `trap` that restores `gl_screen` on any exit path, plus a
watchdog in the boot sequence that restarts it if it is absent and no
operation is in progress.

---

## Suggested sequencing

**First pass (roughly one day, no device required):** items 1, 6, 7, 8, 10 —
all pure logic and data, all testable on a host, and together they close the
"the randomization is not as random or as consistent as it claims" class of
problem.

**Second pass (device required):** items 2, 3, 5, 11 — RAT locking, wired MAC
coverage, the LA-bit experiment, and the unified rotate. This is where the
tool stops being a port and becomes a Norypt product.

**Third pass:** items 4, 13, 14 — sealed factory state, cell monitoring, and
the test suite. Larger, and each is worth its own design pass.
