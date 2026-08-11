# Norypt Ghost Hardening Implementation Plan

> Implementation plan: each task lists the exact files, test code, and bite-sized steps (TDD, one commit per task). Complete them in order.

**Goal:** Turn Norypt Ghost's per-field randomization into coherent full-device-identity rotation — one real-looking device profile per rotation, every identifier changing together across a reboot, with no connected-device history left on flash and the factory identity sealed.

**Architecture:** A device-profile catalog (`profiles.json`) is the single source of truth: each rotation picks one profile and derives IMEI, MACs, SSID, PSK, and hostname from it, so all layers name the same vendor. A new `new-identity` command stages the whole identity to UCI + a pending file, regenerates SSH/TLS keys, renders a Wi-Fi QR to the framebuffer, and reboots; the existing S25 pre-attach hook writes the staged IMEIs before the modem attaches. Supporting services strip persistent telemetry (`norypt-ghost-clean`), seal factory state (`seal.sh`), normalize TTL, and lock the modem to 5G/LTE. New shell logic is split into focused libraries (`profile.sh`, `identity.sh`, `clean.sh`, `seal.sh`) sourced by `functions.sh`.

**Tech Stack:** POSIX `ash` shell (OpenWrt), Lua 5.1 + luabitop (on-device IMEI generator), `jsonfilter` (on-device JSON parsing), `uci`, `gl_modem` AT interface, framebuffer RGB565. Host test harness in Python 3 + `shellcheck`. CI adds `lua5.1`/`lua-bitop` and the OpenWrt SDK.

## Global Constraints

- **License:** GPL-2.0-only. Every new file carries a one-line GPL-2.0 header. Derived-code attribution in `NOTICE` is never removed.
- **Norypt-authored only** — no external-tool or vendor attribution in any commit message, code comment, doc, or file. Verify before every commit.
- **No sensitive data committed:** no real IMEIs, IMSIs, MACs, or device screenshots. Example identifiers in code/docs are `<placeholder>` or documented-fake.
- **Naming:** package/CLI/UCI namespace is `norypt-ghost`; LuCI view `norypt_ghost`; ACL `luci-app-norypt-ghost`. New identifiers follow the existing `_lower_snake` (private) / `UPPER_SNAKE` (exported helper) convention in `functions.sh`.
- **Target device:** GL-iNet GL-E5800 (Mudi 7), firmware 4.8.3 / 4.8.5, `aarch64_cortex-a53`. Dependencies limited to what stock firmware ships (`luci-base`, `lua`, `luabitop`, `jsonfilter`) plus `openssl-util` *only* as an optional, detected-at-runtime enhancement — never a hard dependency.
- **Fail-closed on privacy:** any modem write failure leaves RF off (`AT+CFUN=4`); any missing telemetry path is skipped, never fatal; any absent crypto primitive falls back to plain mode with a loud warning.
- **Every generated identifier** is drawn with rejection sampling against `/dev/urandom` (no modulo bias).
- **On-device facts** (modem bands + exact `AT+QNWPREFCFG` syntax, crypto-tool presence, real GL telemetry paths, QR-encoder availability, firewall backend) are confirmed on the unit before the depending step is relied on. Each has a fallback defined in its task.

---

## File Structure

**New files:**
- `files/usr/share/norypt-ghost/profiles.json` — device-profile catalog (replaces `tac_pool.json` + `oui_pool.json`, whose data folds in).
- `files/lib/norypt-ghost/profile.sh` — catalog load, selection, coherent identifier derivation.
- `files/lib/norypt-ghost/identity.sh` — the stage/apply `new-identity` engine.
- `files/lib/norypt-ghost/clean.sh` — ephemeral-state helpers (no-history).
- `files/lib/norypt-ghost/seal.sh` — factory-state seal/unseal + crypto discovery.
- `files/etc/init.d/norypt-ghost-clean` — boot/shutdown telemetry-strip service.
- `files/lib/norypt-ghost/qr.lua` — QR matrix → RGB565 framebuffer renderer (dev/runtime).
- `tests/validate_profiles.py` — host profile-catalog + coherence validator.
- `tests/test_generator_logic.py` — host Luhn / format-token / MCC-select logic tests.
- `tests/lua/test_imei_generate.lua` — CI-only Lua unit tests (gated on lua presence).
- `tests/run.sh` — host test entrypoint (shellcheck + python + optional lua).

**Modified files:**
- `files/lib/norypt-ghost/functions.sh` — source new libs; replace `awk` JSON scanners; add MCC read, RAT lock, wired/BT MAC, TTL helpers; move timestamps to `/tmp`.
- `files/lib/norypt-ghost/imei_generate.lua` — generate from a passed profile TAC list; rejection sampling.
- `files/usr/bin/norypt-ghost` — add `new-identity`; wire MCC select; document partial-rotation caveat.
- `files/etc/init.d/norypt-ghost-sim-swap` — apply staged full identity (SSH/TLS regen, RAT lock) alongside IMEI write.
- `files/usr/libexec/norypt-ghost` — expose `new-identity`, `factory_mode`, `rat_lock`; profile in status.
- `files/www/luci-static/resources/view/norypt_ghost.js` — lead with New Identity; RAT-lock + factory-mode controls.
- `build-ipk.sh`, `Makefile` — stage new files; `postinst` passphrase prompt; `preinst` crypto probe.
- `.github/workflows/build.yml` — add `tests/run.sh` gate (shellcheck + python + lua).
- `docs/ROADMAP.md` — tick delivered items.

---

## Phase A — Profile catalog + generators

### Task A1: Host test harness + profile schema validator

**Files:**
- Create: `tests/validate_profiles.py`
- Create: `tests/run.sh`
- Create: `files/usr/share/norypt-ghost/profiles.schema.json`

**Interfaces:**
- Produces: `tests/validate_profiles.py <profiles.json> [--release]` — exit 0 on pass; hard-fails always on structural/coherence/LA-bit errors; `verified:false` TACs are a warning without `--release`, a hard error with it. `tests/run.sh` runs shellcheck + all python tests + optional lua.

- [ ] **Step 1: Write the failing test (the validator's own self-test)**

Create `tests/validate_profiles.py` with an embedded self-test block and the validation logic:

```python
#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost profile-catalog validator. Host-runnable; no third-party deps.
import json, re, sys

_TOKEN = re.compile(r'\{(\d+)(hex|lower|digits)\}')
_OUI   = re.compile(r'^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$')
_TAC   = re.compile(r'^\d{8}$')

def _oui_is_universal(oui):
    first = int(oui.split(':')[0], 16)
    return (first & 0x02) == 0            # locally-administered bit must be clear

def validate(catalog, release=False):
    errors, warnings = [], []
    profiles = catalog.get('profiles')
    if not isinstance(profiles, list) or not profiles:
        return ['"profiles" must be a non-empty array'], []
    seen_ids = set()
    for p in profiles:
        pid = p.get('id', '<no id>')
        if pid in seen_ids: errors.append(f'{pid}: duplicate id')
        seen_ids.add(pid)
        if p.get('class') not in ('hotspot', 'phone'):
            errors.append(f'{pid}: class must be hotspot|phone')
        if p.get('region') not in ('EU', 'NA'):
            errors.append(f'{pid}: region must be EU|NA')
        if not p.get('vendor'):
            errors.append(f'{pid}: missing vendor')
        tacs = p.get('imei_tacs') or []
        if not tacs: errors.append(f'{pid}: needs >=1 TAC')
        for t in tacs:
            if not _TAC.match(t.get('tac', '')):
                errors.append(f'{pid}: TAC {t.get("tac")!r} not 8 digits')
            if not t.get('verified'):
                (errors if release else warnings).append(
                    f'{pid}: TAC {t.get("tac")} verified=false')
        ouis = p.get('wifi_oui') or []
        if not ouis: errors.append(f'{pid}: needs >=1 OUI')
        for o in ouis:
            if not _OUI.match(o): errors.append(f'{pid}: OUI {o!r} malformed')
            elif not _oui_is_universal(o):
                errors.append(f'{pid}: OUI {o} is locally-administered')
        for key in ('ssid_format', 'psk_format', 'hostname_format',
                    'dhcp_hostname_format'):
            fmt = p.get(key)
            if not isinstance(fmt, str) or not fmt:
                errors.append(f'{pid}: missing {key}')
            else:
                for _n, kind in _TOKEN.findall(fmt):
                    if kind not in ('hex', 'lower', 'digits'):
                        errors.append(f'{pid}: {key} bad token kind {kind}')
    return errors, warnings

def main(argv):
    release = '--release' in argv
    paths = [a for a in argv[1:] if not a.startswith('--')]
    catalog = json.load(open(paths[0]))
    errors, warnings = validate(catalog, release)
    for w in warnings: print(f'WARN  {w}')
    for e in errors:   print(f'FAIL  {e}')
    if errors:
        print(f'\n{len(errors)} error(s).'); return 1
    print(f'OK — {len(catalog["profiles"])} profiles, {len(warnings)} warning(s).')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
```

- [ ] **Step 2: Run it against a deliberately-broken fixture to verify it fails**

Run:
```bash
printf '{"profiles":[{"id":"x","class":"bad","region":"XX","vendor":"","imei_tacs":[],"wifi_oui":["DA:A1:19"]}]}' > /tmp/bad.json
python3 tests/validate_profiles.py /tmp/bad.json; echo "exit=$?"
```
Expected: prints `FAIL` lines including `class must be hotspot|phone`, `region must be EU|NA`, `needs >=1 TAC`, `OUI DA:A1:19 is locally-administered`, and `exit=1`.

- [ ] **Step 3: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host test entrypoint for Norypt Ghost. Runs shellcheck, python logic tests,
# the profile validator, and (if lua is present) the Lua unit tests.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

echo "== shellcheck =="
shellcheck -s sh files/usr/bin/norypt-ghost files/usr/libexec/norypt-ghost \
    files/lib/norypt-ghost/*.sh files/etc/init.d/norypt-ghost-*

echo "== profile validator =="
python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json "$@"

echo "== python logic tests =="
python3 -m unittest discover -s tests -p 'test_*.py' -v

if command -v lua5.1 >/dev/null 2>&1 || command -v lua >/dev/null 2>&1; then
    echo "== lua unit tests =="
    LUA="$(command -v lua5.1 || command -v lua)"
    "$LUA" tests/lua/test_imei_generate.lua
else
    echo "== lua unit tests SKIPPED (no interpreter; runs in CI) =="
fi
echo "All host tests passed."
```

- [ ] **Step 4: Make executable and confirm shellcheck stage runs**

Run: `chmod +x tests/run.sh tests/validate_profiles.py && shellcheck -s sh files/lib/norypt-ghost/functions.sh && echo OK`
Expected: `OK` (functions.sh is clean today; this proves shellcheck works before we add files).

- [ ] **Step 5: Commit**

```bash
git add tests/validate_profiles.py tests/run.sh files/usr/share/norypt-ghost/profiles.schema.json
git commit -m "test: profile-catalog validator and host test entrypoint"
```

---

### Task A2: Author the profile catalog

**Files:**
- Create: `files/usr/share/norypt-ghost/profiles.json`

**Interfaces:**
- Produces: `profiles.json` with top-level `{"_comment":..., "profiles":[...]}`. Each profile: `id, class, region, vendor, imei_tacs:[{tac,device,verified,source}], wifi_oui:[..], client_oui:[..], ssid_format, psk_format, hostname_format, dhcp_hostname_format, bands:[..], weight`. Consumed by `profile.sh` and `validate_profiles.py`.

- [ ] **Step 1: Write the catalog**

Seed with ≥3 NA + ≥3 EU profiles across both classes. TACs carry `verified:false` and a `source` TODO — the validator warns (dev) / fails (release) until curated on-device against a TAC database. OUIs are real universally-administered vendor WLAN OUIs (the folded-in `oui_pool.json` router entries, minus the invalid `DA:A1:19`). Example structure (one entry shown; author the full set following it):

```json
{
  "_comment": "Norypt Ghost device-profile catalog. One coherent real-device archetype per entry: the IMEI TAC vendor, the wifi_oui vendor, and the SSID brand are the same vendor by construction. TACs must be verified against a TAC database and sourced before a release build (validator --release enforces this). OUIs must be universally-administered (LA bit clear).",
  "profiles": [
    {
      "id": "netgear-nighthawk-m6-na",
      "class": "hotspot", "region": "NA", "vendor": "NETGEAR",
      "imei_tacs": [
        { "tac": "86437503", "device": "Netgear Nighthawk M6 Pro (MR6450)",
          "verified": false, "source": "TODO: verify against TAC DB" }
      ],
      "wifi_oui": ["A0:63:91", "C0:3F:0E", "20:E5:2A"],
      "client_oui": ["3C:22:FB", "88:66:5A"],
      "ssid_format": "NETGEAR-{4hex}",
      "psk_format": "{10lower}",
      "hostname_format": "Nighthawk-M6",
      "dhcp_hostname_format": "android-{16hex}",
      "bands": ["n2","n5","n25","n41","n66","n71","n77","n78"],
      "weight": 3
    }
  ]
}
```

Author additionally (real vendor OUIs from the inherited `oui_pool.json`): a TP-Link NA hotspot, an Inseego/MiFi NA hotspot, a Samsung EU phone, an Apple EU phone, and an AVM/FRITZ or generic EU hotspot. `client_oui` for STA uses the inherited client OUIs. Keep `HOME-{4hex}` SSID format for generic-vendor entries (Google Nest / Meraki).

- [ ] **Step 2: Run the validator (dev mode)**

Run: `python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json`
Expected: `OK — N profiles, M warning(s).` with warnings only for `verified=false` TACs, zero `FAIL` lines.

- [ ] **Step 3: Run the validator (release mode) to confirm the gate bites**

Run: `python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json --release; echo "exit=$?"`
Expected: `FAIL` lines for each unverified TAC and `exit=1` — proving release builds cannot ship unverified TACs.

- [ ] **Step 4: Commit**

```bash
git add files/usr/share/norypt-ghost/profiles.json
git commit -m "feat: device-profile catalog (EU/NA, hotspot/phone) with coherence invariants"
```

---

### Task A3: Format-token expansion + MCC-region logic (host-tested)

**Files:**
- Create: `tests/test_generator_logic.py`
- Create: `files/lib/norypt-ghost/profile.sh` (the `_expand_format` + `_mcc_region` functions only in this task)

**Interfaces:**
- Produces (shell, sourced): `_expand_format "<fmt>"` → prints the format with `{Nhex}`/`{Nlower}`/`{Ndigits}` tokens replaced by N random chars from `/dev/urandom` (rejection-sampled). `_mcc_region "<imsi>" "<default>"` → prints `EU` or `NA` from the IMSI's first 3 digits, else the default.
- The Python test re-implements the same token grammar and MCC table to lock the contract; the shell implementation must match it.

- [ ] **Step 1: Write the failing Python contract test**

```python
# tests/test_generator_logic.py
# SPDX-License-Identifier: GPL-2.0-only
import re, subprocess, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parent.parent
LIB  = REPO / "files/lib/norypt-ghost/profile.sh"

def sh(fn, *args):
    script = f'. "{LIB}"; {fn} ' + ' '.join(f'"{a}"' for a in args)
    return subprocess.check_output(["sh", "-c", script], text=True).strip()

class TestFormatExpansion(unittest.TestCase):
    def test_hex_token_length_and_charset(self):
        out = sh("_expand_format", "NETGEAR-{4hex}")
        self.assertRegex(out, r'^NETGEAR-[0-9a-f]{4}$')
    def test_multiple_tokens(self):
        out = sh("_expand_format", "{2lower}-{3digits}")
        self.assertRegex(out, r'^[a-z0-9]{2}-[0-9]{3}$')
    def test_literal_preserved(self):
        self.assertEqual(sh("_expand_format", "Nighthawk-M6"), "Nighthawk-M6")

class TestMccRegion(unittest.TestCase):
    def test_na_mcc(self):     # 310 = USA
        self.assertEqual(sh("_mcc_region", "310260123456789", "EU"), "NA")
    def test_eu_mcc(self):     # 262 = Germany
        self.assertEqual(sh("_mcc_region", "262019876543210", "NA"), "EU")
    def test_unknown_falls_back(self):
        self.assertEqual(sh("_mcc_region", "", "NA"), "NA")

if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails (no profile.sh yet)**

Run: `python3 -m unittest tests.test_generator_logic -v`
Expected: FAIL — `profile.sh` does not exist / functions undefined.

- [ ] **Step 3: Implement `_expand_format` and `_mcc_region` in `profile.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — device-profile catalog: load, select, derive.
# Sourced by functions.sh and the init.d services.

_PROFILES_PATH=/usr/share/norypt-ghost/profiles.json

# Unbiased random integer in [0, $1) from /dev/urandom (rejection sampling).
_rand_below() {
    local n="$1" limit max v
    [ "$n" -gt 0 ] || { echo 0; return; }
    max=65536
    limit=$(( max - (max % n) ))
    while :; do
        v=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        [ "$v" -lt "$limit" ] && { echo $(( v % n )); return; }
    done
}

# Emit $1 random chars from charset $2 ("hex"|"lower"|"digits").
_rand_chars() {
    local count="$1" kind="$2" set i out=""
    case "$kind" in
        hex)    set="0123456789abcdef" ;;
        lower)  set="0123456789abcdefghijklmnopqrstuvwxyz" ;;
        digits) set="0123456789" ;;
    esac
    i=0
    while [ "$i" -lt "$count" ]; do
        out="${out}$(printf '%s' "$set" | cut -c "$(( $(_rand_below ${#set}) + 1 ))")"
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# Replace {Nhex}/{Nlower}/{Ndigits} tokens in $1 with random chars.
_expand_format() {
    local fmt="$1" out="" rest="$fmt" tok n kind
    while printf '%s' "$rest" | grep -q '{[0-9]\+\(hex\|lower\|digits\)}'; do
        out="${out}${rest%%\{*}"                 # literal before first {
        tok="${rest#*\{}"; tok="${tok%%\}*}"     # e.g. 4hex
        rest="${rest#*\}}"                        # remainder after }
        n="$(printf '%s' "$tok" | tr -dc '0-9')"
        kind="$(printf '%s' "$tok" | tr -dc 'a-z')"
        out="${out}$(_rand_chars "$n" "$kind")"
    done
    printf '%s' "${out}${rest}"
}

# Map an IMSI's MCC (first 3 digits) to a region; $2 = default if unknown.
# NA = North America MCCs (310-316, 302, 330-...); everything in the EU table
# returns EU; else the default.
_mcc_region() {
    local imsi="$1" default="$2" mcc
    mcc="$(printf '%s' "$imsi" | cut -c1-3)"
    case "$mcc" in
        310|311|312|313|314|315|316|302|330|334) echo NA ;;
        2[0-9][0-9]) echo EU ;;     # ITU zone 2 = Europe
        *) echo "$default" ;;
    esac
}
```

- [ ] **Step 4: Run the test, verify pass**

Run: `python3 -m unittest tests.test_generator_logic -v`
Expected: all 6 tests PASS.

- [ ] **Step 5: shellcheck the new lib**

Run: `shellcheck -s sh files/lib/norypt-ghost/profile.sh && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add tests/test_generator_logic.py files/lib/norypt-ghost/profile.sh
git commit -m "feat: format-token expansion and MCC->region mapping (rejection-sampled)"
```

---

### Task A4: Profile selection + coherent derivation (jsonfilter, CI/on-device)

**Files:**
- Modify: `files/lib/norypt-ghost/profile.sh` (add selection + derivation)
- Modify: `tests/validate_profiles.py` (add a `--coherence` sampled check invoked from run.sh)

**Interfaces:**
- Produces (shell): `_profile_pick "<region>"` → prints a profile `id`, weighted by `weight`, restricted to `region`. `_profile_field "<id>" "<jsonpath>"` → prints a scalar via `jsonfilter`. `_profile_derive "<id>"` → sets shell vars `NG_VENDOR NG_TAC NG_WIFI_OUI NG_CLIENT_OUI NG_SSID NG_GUEST_SSID NG_PSK NG_GUEST_PSK NG_HOSTNAME NG_DHCP_HOSTNAME` (SSID/PSK/hostname already format-expanded; one TAC and one OUI chosen from their lists). Consumed by `identity.sh` and `imei_generate.lua` (TAC passed in).

- [ ] **Step 1: Write the failing coherence test in the validator**

Add to `tests/validate_profiles.py` a `coherence(catalog)` function and a `--coherence` flag: for every profile assert `vendor` appears in `ssid_format` OR the format is a documented generic (`HOME-`), and that each `wifi_oui` differs from each `client_oui` (a device never uses its own AP OUI as its upstream-client OUI). Test:

```python
def coherence(catalog):
    errs = []
    for p in catalog['profiles']:
        v = p['vendor'].upper()
        fmt = p['ssid_format'].upper()
        if v not in fmt and not fmt.startswith('HOME-'):
            errs.append(f'{p["id"]}: SSID format {p["ssid_format"]!r} does not name vendor {v}')
        if set(p.get('wifi_oui', [])) & set(p.get('client_oui', [])):
            errs.append(f'{p["id"]}: wifi_oui and client_oui overlap')
    return errs
```
Wire it into `main` so `--coherence` runs it and fails on any error.

- [ ] **Step 2: Run it against the catalog, expect PASS (data already coherent)**

Run: `python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json --coherence`
Expected: `OK` — the authored catalog is coherent. (If it fails, fix `profiles.json`, not the test.)

- [ ] **Step 3: Implement selection + derivation in `profile.sh`**

```sh
# List "id weight" for profiles in region $1.
_profile_list_region() {
    local region="$1" n i id reg wt
    n="$(jsonfilter -i "$_PROFILES_PATH" -e '@.profiles[*].id' | wc -l)"
    i=0
    while [ "$i" -lt "$n" ]; do
        reg="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].region")"
        if [ "$reg" = "$region" ]; then
            id="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].id")"
            wt="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].weight")"
            echo "$id ${wt:-1}"
        fi
        i=$(( i + 1 ))
    done
}

# Pick one profile id in region $1, weighted. Falls back to any region if empty.
_profile_pick() {
    local region="$1" pool total pick acc id wt
    pool="$(_profile_list_region "$region")"
    [ -n "$pool" ] || pool="$(_profile_list_region NA)$(printf '\n')$(_profile_list_region EU)"
    total=0
    while read -r id wt; do [ -n "$id" ] && total=$(( total + wt )); done <<EOF
$pool
EOF
    [ "$total" -gt 0 ] || return 1
    pick=$(_rand_below "$total"); acc=0
    while read -r id wt; do
        [ -n "$id" ] || continue
        acc=$(( acc + wt ))
        [ "$pick" -lt "$acc" ] && { echo "$id"; return 0; }
    done <<EOF
$pool
EOF
}

# Index of the profile with id $1.
_profile_index() {
    local want="$1" n i id
    n="$(jsonfilter -i "$_PROFILES_PATH" -e '@.profiles[*].id' | wc -l)"
    i=0
    while [ "$i" -lt "$n" ]; do
        id="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].id")"
        [ "$id" = "$want" ] && { echo "$i"; return 0; }
        i=$(( i + 1 ))
    done
    return 1
}

# Pick a random element from the jsonfilter array at path $2 of profile index $1.
_profile_pick_array() {
    local idx="$1" path="$2" vals cnt
    vals="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].$path")"
    cnt="$(printf '%s\n' "$vals" | grep -c '.')"
    [ "$cnt" -gt 0 ] || return 1
    printf '%s\n' "$vals" | sed -n "$(( $(_rand_below "$cnt") + 1 ))p"
}

# Derive every identifier for profile id $1 into NG_* shell vars.
_profile_derive() {
    local id="$1" idx
    idx="$(_profile_index "$id")" || return 1
    NG_VENDOR="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].vendor")"
    NG_TAC="$(_profile_pick_array "$idx" 'imei_tacs[*].tac')"
    NG_WIFI_OUI="$(_profile_pick_array "$idx" 'wifi_oui[*]')"
    NG_CLIENT_OUI="$(_profile_pick_array "$idx" 'client_oui[*]')"
    NG_SSID="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].ssid_format")")"
    NG_GUEST_SSID="${NG_SSID}-Guest"
    NG_PSK="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].psk_format")")"
    NG_GUEST_PSK="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].psk_format")")"
    NG_HOSTNAME="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].hostname_format")")"
    NG_DHCP_HOSTNAME="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].dhcp_hostname_format")")"
    [ -n "$NG_TAC" ] && [ -n "$NG_WIFI_OUI" ]
}
```

- [ ] **Step 4: shellcheck**

Run: `shellcheck -s sh files/lib/norypt-ghost/profile.sh && echo OK`
Expected: `OK`.

- [ ] **Step 5: Add coherence to run.sh and commit**

Append `--coherence` to the validator call in `tests/run.sh`, then:
```bash
git add files/lib/norypt-ghost/profile.sh tests/validate_profiles.py tests/run.sh
git commit -m "feat: weighted profile selection and coherent identifier derivation via jsonfilter"
```

> **On-device note:** `jsonfilter`, `od`, and `sed` are on stock firmware; the selection/derivation functions are exercised end-to-end by the on-device checklist (Task F4) and in CI where `jsonfilter` is installed. Host CI without jsonfilter skips these shell functions but still runs the Python coherence gate.

---

### Task A5: IMEI generator — generate from a profile TAC + Lua unit tests

**Files:**
- Modify: `files/lib/norypt-ghost/imei_generate.lua`
- Modify: `files/lib/norypt-ghost/functions.sh:186-236` (`GENERATE_IMEI`, `_gen_imei`)
- Create: `tests/lua/test_imei_generate.lua`

**Interfaces:**
- Consumes: `NG_TAC` from `_profile_derive`.
- Produces (lua CLI): `lua imei_generate.lua fromtac <8-digit-tac>` → prints one 15-digit Luhn-valid IMEI with that TAC + 6 rejection-sampled serial digits. Existing `random`/`deterministic` modes retained. `_gen_imei <slot> <mode> [tac]` in shell passes the profile TAC through in profile mode.

- [ ] **Step 1: Write the failing Lua unit test**

```lua
-- tests/lua/test_imei_generate.lua
-- SPDX-License-Identifier: GPL-2.0-only
package.path = "files/lib/norypt-ghost/?.lua;" .. package.path
local luhn = require("luhn")
local fails = 0
local function ok(cond, msg) if not cond then fails = fails + 1; print("FAIL "..msg) end end

-- fromtac output is 15 digits, Luhn-valid, and starts with the given TAC.
local h = io.popen("lua files/lib/norypt-ghost/imei_generate.lua fromtac 86437503")
local imei = h:read("*l"); h:close()
ok(imei and #imei == 15, "length 15 (got "..tostring(imei)..")")
ok(imei:sub(1,8) == "86437503", "TAC preserved")
ok(luhn.is_valid(imei), "Luhn valid")

-- distribution: 200 serials over TAC should not collide trivially (sanity).
local seen, dup = {}, 0
for _=1,200 do
    local g = io.popen("lua files/lib/norypt-ghost/imei_generate.lua fromtac 86437503")
    local v = g:read("*l"); g:close()
    if seen[v] then dup = dup + 1 end; seen[v] = true
end
ok(dup < 20, "serials reasonably distributed (dups="..dup..")")

if fails == 0 then print("lua imei tests OK") else os.exit(1) end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `command -v lua >/dev/null && lua tests/lua/test_imei_generate.lua || echo "install lua5.1+lua-bitop to run"`
Expected: FAIL on the `fromtac` mode (unknown arg today) — or the install hint if no lua. In CI (lua present) it must fail before Step 3.

- [ ] **Step 3: Add `fromtac` mode + rejection sampling to `imei_generate.lua`**

Replace the fully-random serial loop with a rejection-sampled digit helper and add the mode. Add near the top:

```lua
-- Unbiased digit [0,9] from /dev/urandom, falling back to math.random.
local function rand_digit()
    local f = io.open("/dev/urandom", "rb")
    if f then
        while true do
            local b = f:read(1)
            if not b then break end
            local v = b:byte()
            if v < 250 then f:close(); return v % 10 end  -- 250 = 25*10, unbiased
        end
        f:close()
    end
    return math.random(0, 9)
end

local function gen_serial(n)
    local s = ""; for _ = 1, n do s = s .. tostring(rand_digit()) end; return s
end

local function gen_imei_from_tac(tac)
    if not (tac and tac:match("^%d%d%d%d%d%d%d%d$")) then
        io.stderr:write("imei_generate: fromtac needs an 8-digit TAC\n"); os.exit(1)
    end
    return luhn.make_imei(tac .. gen_serial(6))
end
```

Extend the mode dispatch:

```lua
elseif mode == "fromtac" then
    imei = gen_imei_from_tac(arg[2])
```

- [ ] **Step 4: Wire the shell to pass the profile TAC through**

In `functions.sh`, extend `_gen_imei` to accept an optional 3rd arg (the profile TAC) and a new `profile` mode:

```sh
# $1=slot  $2=mode(random|deterministic|static|profile)  $3=profile TAC (profile mode)
_gen_imei() {
    local slot="$1" mode="$2" tac="$3"
    if [ "$mode" = "profile" ]; then
        if [ -n "$tac" ]; then
            lua /lib/norypt-ghost/imei_generate.lua fromtac "$tac"
        else
            GENERATE_IMEI
        fi
        return
    fi
    # ... existing deterministic/static/random body unchanged ...
```

- [ ] **Step 5: Run the Lua test, verify pass (CI/local-with-lua)**

Run: `lua tests/lua/test_imei_generate.lua`
Expected: `lua imei tests OK`.

- [ ] **Step 6: Commit**

```bash
git add files/lib/norypt-ghost/imei_generate.lua files/lib/norypt-ghost/functions.sh tests/lua/test_imei_generate.lua
git commit -m "feat: generate IMEI from a profile TAC with rejection-sampled serial + lua tests"
```

---

## Phase B — new-identity rotation engine

### Task B1: Wired + Bluetooth MAC helpers; source new libs

**Files:**
- Modify: `files/lib/norypt-ghost/functions.sh` (source `profile.sh`; add `RANDOMIZE_WIRED_MAC`, `_bt_present`, `RANDOMIZE_BT_MAC`; replace `_load_ouis`/`_load_router_identities` awk scanners with a deprecation shim that calls profile.sh)

**Interfaces:**
- Consumes: `NG_WIFI_OUI`, `NG_CLIENT_OUI`, `MAC_GEN`.
- Produces: `RANDOMIZE_WIRED_MAC "<oui>"` sets `network.@device[0].macaddr` (WAN/LAN) to a MAC on the given OUI; `RANDOMIZE_BT_MAC` sets the BT adapter MAC if `_bt_present` is true, else no-op.

- [ ] **Step 1: Add the helpers to functions.sh**

```sh
# Rotate the wired (WAN/LAN) device MAC onto OUI $1 (client-class recommended).
RANDOMIZE_WIRED_MAC() {
    local oui="$1" dev i=0
    while :; do
        dev="$(uci -q get "network.@device[$i]" 2>/dev/null)" || break
        uci -q get "network.@device[$i].macaddr" >/dev/null 2>&1 && \
            uci set "network.@device[$i].macaddr=$(MAC_GEN clients "$oui")"
        i=$(( i + 1 ))
    done
    uci commit network
}

# True if a Bluetooth adapter is present.
_bt_present() { [ -d /sys/class/bluetooth ] && ls /sys/class/bluetooth/hci* >/dev/null 2>&1; }

# Rotate the BT adapter MAC (best-effort; hardware/firmware dependent).
RANDOMIZE_BT_MAC() {
    _bt_present || return 0
    local hci mac
    for hci in /sys/class/bluetooth/hci*; do
        mac="$(MAC_GEN clients)"
        hciconfig "$(basename "$hci")" down 2>/dev/null
        btmgmt --index "$(basename "$hci" | tr -dc 0-9)" public-addr "$mac" 2>/dev/null \
            || logger -t norypt-ghost "BT MAC set unsupported on this unit"
        hciconfig "$(basename "$hci")" up 2>/dev/null
    done
}
```

Add `. /lib/norypt-ghost/profile.sh` near the top of `functions.sh` (after the `BUS`/`SUB` defs).

- [ ] **Step 2: shellcheck**

Run: `shellcheck -s sh files/lib/norypt-ghost/functions.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add files/lib/norypt-ghost/functions.sh
git commit -m "feat: wired and Bluetooth MAC rotation helpers; source profile.sh"
```

> **On-device note:** whether `btmgmt`/`hciconfig` exist and can set a public BT address on the E5800 is confirmed on the unit; if not, `RANDOMIZE_BT_MAC` logs and no-ops (fail-open is acceptable here — BT is off by default on the Mudi 7).

---

### Task B2: MCC read + RAT lock helpers

**Files:**
- Modify: `files/lib/norypt-ghost/functions.sh` (add `READ_MCC`, `RAT_LOCK_APPLY`)

**Interfaces:**
- Produces: `READ_MCC` → prints the active SIM's 3-digit MCC (from IMSI) or empty. `RAT_LOCK_APPLY` → applies the 5G/LTE-only preference when `blue-merle`… (UCI `norypt-ghost.options.rat_lock` != 0), returns non-zero on AT failure.

- [ ] **Step 1: Add helpers**

```sh
# Active SIM MCC (first 3 IMSI digits), empty if unreadable.
READ_MCC() {
    local imsi
    imsi="$(READ_IMSI_SLOT1 2>/dev/null)"
    [ -n "$imsi" ] || imsi="$(READ_IMSI_SLOT2 2>/dev/null)"
    printf '%s' "$imsi" | cut -c1-3
}

# Lock the modem to 5G-NR + LTE (block 2G/3G downgrade). Controlled by
# norypt-ghost.options.rat_lock (default on). Syntax confirmed on-device
# against the RG650V before relied upon; logs and returns non-zero on failure.
RAT_LOCK_APPLY() {
    _opt_enabled rat_lock || { logger -t norypt-ghost "rat_lock disabled by option"; return 0; }
    local out
    out="$(_at 'AT+QNWPREFCFG="mode_pref",NR5G:LTE' 2>&1)"
    if echo "$out" | grep -q "OK"; then
        logger -t norypt-ghost "RAT locked to NR5G:LTE"
        return 0
    fi
    logger -t norypt-ghost "RAT lock FAILED: $out"
    return 1
}
```

- [ ] **Step 2: shellcheck + commit**

Run: `shellcheck -s sh files/lib/norypt-ghost/functions.sh && echo OK`
```bash
git add files/lib/norypt-ghost/functions.sh
git commit -m "feat: MCC read and 2G/3G-downgrade RAT lock helpers"
```

> **On-device note:** the exact `AT+QNWPREFCFG` argument form is verified with `AT+QNWPREFCFG=?` on the unit; if the RG650V uses a different token, update the one string here. Fallback if unsupported: `AT+QCFG="nwscanmode"` equivalent, decided on-device.

---

### Task B3: The `identity.sh` stage engine

**Files:**
- Create: `files/lib/norypt-ghost/identity.sh`

**Interfaces:**
- Consumes: `_profile_pick`, `_profile_derive`, `_mcc_region`, `READ_MCC`, `RANDOMIZE_*` UCI writers, `MAC_GEN`.
- Produces: `IDENTITY_STAGE` → picks a region+profile, writes all wireless/system identifiers to UCI, writes `/etc/norypt-ghost.identity-pending` (staged IMEIs + profile id + regen flag), returns 0 on success. `IDENTITY_APPLY_BOOT` → (called by S25) reads the pending file, writes staged IMEIs, regenerates SSH/TLS if flagged, applies RAT lock, removes the pending file.

- [ ] **Step 1: Write `identity.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — full-identity stage/apply engine.
. /lib/norypt-ghost/functions.sh   # also pulls profile.sh

_PENDING=/etc/norypt-ghost.identity-pending

# Pick a coherent identity and write its wireless/system half to UCI now;
# stage the IMEIs and a regen flag for the post-reboot apply.
IDENTITY_STAGE() {
    local region default_region id imei1 imei2 iface
    default_region="$(uci -q get norypt-ghost.options.default_region 2>/dev/null)"
    case "$default_region" in EU|NA) ;; *) default_region=NA ;; esac
    region="$(_mcc_region "$(READ_MCC)" "$default_region")"

    id="$(_profile_pick "$region")" || { echo "no profile for region $region" >&2; return 1; }
    _profile_derive "$id" || { echo "profile derive failed for $id" >&2; return 1; }

    # Wireless BSSIDs — all AP ifaces share the profile's wifi OUI.
    for iface in wifi2g wifi5g wifi6g guest2g guest5g guest6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && \
            uci set "wireless.${iface}.macaddr=$(MAC_GEN routers "$NG_WIFI_OUI")"
    done
    # STA (upstream) gets the client-class OUI.
    if uci -q get wireless.sta >/dev/null 2>&1; then
        uci set "wireless.sta.macaddr=$(MAC_GEN clients "$NG_CLIENT_OUI")"
    fi
    # SSIDs.
    for iface in wifi2g wifi5g wifi6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.ssid=$NG_SSID"
    done
    for iface in guest2g guest5g guest6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.ssid=$NG_GUEST_SSID"
    done
    # PSKs.
    for iface in wifi2g wifi5g wifi6g;    do uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.key=$NG_PSK"; done
    for iface in guest2g guest5g guest6g; do uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.key=$NG_GUEST_PSK"; done
    uci -q set 'wireless.wifi0.random_bssid=0'; uci -q set 'wireless.wifi1.random_bssid=0'; uci -q set 'wireless.wifi2.random_bssid=0'
    uci commit wireless

    # Wired MAC + hostname + upstream DHCP hostname.
    RANDOMIZE_WIRED_MAC "$NG_CLIENT_OUI"
    uci set "system.@system[0].hostname=$NG_HOSTNAME"; uci commit system
    printf '%s' "$NG_HOSTNAME" > /proc/sys/kernel/hostname
    uci -q set "network.wan.hostname=$NG_DHCP_HOSTNAME" 2>/dev/null; uci -q commit network

    # Stage IMEIs (written pre-attach on next boot, profile mode with this TAC).
    imei1="$(_gen_imei 1 profile "$NG_TAC")"
    imei2="$(_gen_imei 2 profile "$NG_TAC")"
    printf 'PROFILE_ID=%s\nSTAGED_IMEI1=%s\nSTAGED_IMEI2=%s\nREGEN_KEYS=1\n' \
        "$id" "$imei1" "$imei2" > "$_PENDING"

    echo "$id"
}

# Post-reboot completion (invoked by norypt-ghost-sim-swap S25).
IDENTITY_APPLY_BOOT() {
    [ -f "$_PENDING" ] || return 0
    local PROFILE_ID="" STAGED_IMEI1="" STAGED_IMEI2="" REGEN_KEYS=0
    . "$_PENDING"; rm -f "$_PENDING"

    MODEM_RF_DISABLE
    if [ -n "$STAGED_IMEI1" ] && [ -n "$STAGED_IMEI2" ]; then
        SET_IMEIS "$STAGED_IMEI1" "$STAGED_IMEI2" || { logger -t norypt-ghost "identity: IMEI write failed"; _screen_splash error; return 1; }
    fi
    [ "$REGEN_KEYS" = "1" ] && IDENTITY_REGEN_KEYS
    RAT_LOCK_APPLY
    _at AT+CFUN=1 >/dev/null 2>&1
    date '+%Y-%m-%d %H:%M (new-identity)' > /tmp/norypt-ghost.last_imei_rotate
    logger -t norypt-ghost "identity applied: profile=$PROFILE_ID"
    _screen_splash done
}

# Regenerate SSH host keys and the LuCI TLS cert — both are permanent device IDs.
IDENTITY_REGEN_KEYS() {
    rm -f /etc/dropbear/dropbear_*_host_key 2>/dev/null
    /etc/init.d/dropbear restart 2>/dev/null
    if [ -x /etc/init.d/uhttpd ]; then
        rm -f /etc/uhttpd.crt /etc/uhttpd.key 2>/dev/null
        [ -x /usr/sbin/px5g ] && px5g selfsigned -der \
            -keyout /etc/uhttpd.key -out /etc/uhttpd.crt \
            -subj "/C=US/CN=$(cat /proc/sys/kernel/hostname)" 2>/dev/null
        /etc/init.d/uhttpd restart 2>/dev/null
    fi
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck -s sh files/lib/norypt-ghost/identity.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add files/lib/norypt-ghost/identity.sh
git commit -m "feat: identity stage/apply engine — coherent full-fingerprint rotation across reboot"
```

---

### Task B4: `new-identity` CLI command + boot wiring

**Files:**
- Modify: `files/usr/bin/norypt-ghost` (add `new-identity` case; `_usage`; partial-rotation caveat)
- Modify: `files/etc/init.d/norypt-ghost-sim-swap` (call `IDENTITY_APPLY_BOOT` before the legacy sim-swap block)

**Interfaces:**
- Consumes: `IDENTITY_STAGE`, `IDENTITY_APPLY_BOOT`, `_render_join_qr` (Task C1, guarded so this task works before C1 lands).
- Produces: `norypt-ghost new-identity` command; S25 applies staged identity on boot.

- [ ] **Step 1: Add the command**

In `files/usr/bin/norypt-ghost`, source identity.sh at the top (`. /lib/norypt-ghost/identity.sh`) and add a case:

```sh
    new-identity)
        _save_factory_state || exit 1
        echo "norypt-ghost: staging new device identity..."
        _screen_splash rotating
        _id="$(IDENTITY_STAGE)" || { echo "staging failed" >&2; _screen_fail; exit 1; }
        echo "  Profile: $_id"
        echo "  SSID:    $(uci -q get wireless.wifi2g.ssid)"
        # QR on the framebuffer if available (Task C1); text otherwise.
        if command -v _render_join_qr >/dev/null 2>&1; then
            _render_join_qr "$(uci -q get wireless.wifi2g.ssid)" "$(uci -q get wireless.wifi2g.key)"
        fi
        echo "norypt-ghost: rebooting in 5s to apply the new identity cleanly."
        echo "  Scan the QR on the device screen to rejoin Wi-Fi."
        sleep 5
        /sbin/reboot
        ;;
```

- [ ] **Step 2: Add the caveat to `_usage` and the partial commands**

In `_usage`, add under Commands:
```
  new-identity     Full clean rotation: new profile, every identifier, reboot (recommended)
```
And append to the `rotate` / `rotate-wireless` help lines: `(partial, live — NOT a clean break; use new-identity for unlinkability)`.

- [ ] **Step 3: Wire boot apply into S25**

In `files/etc/init.d/norypt-ghost-sim-swap`, at the top of `start()` (before the existing `[ -f /etc/norypt-ghost.sim-swap-pending ]` guard), add:

```sh
    # Full-identity rotation (new-identity) completes here too, before attach.
    if [ -f /etc/norypt-ghost.identity-pending ]; then
        . /lib/norypt-ghost/identity.sh
        _screen_splash rotating
        _wait_for_at || { _screen_splash error; return 1; }
        IDENTITY_APPLY_BOOT
        return 0
    fi
```

- [ ] **Step 4: shellcheck both files**

Run: `shellcheck -s sh files/usr/bin/norypt-ghost files/etc/init.d/norypt-ghost-sim-swap && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add files/usr/bin/norypt-ghost files/etc/init.d/norypt-ghost-sim-swap
git commit -m "feat: new-identity command and boot-time apply hook; mark partial rotations non-clean"
```

---

## Phase C — QR + splash

### Task C1: Wi-Fi-join QR renderer

**Files:**
- Create: `files/lib/norypt-ghost/qr.lua`
- Modify: `files/lib/norypt-ghost/functions.sh` (add `_render_join_qr`)

**Interfaces:**
- Produces: `_render_join_qr "<ssid>" "<psk>"` → renders a `WIFI:T:WPA;S:<ssid>;P:<psk>;;` QR to `/dev/fb0`, centered, with the SSID/PSK as text below. No-op (returns 0) if no QR encoder is available.

- [ ] **Step 1: Implement the renderer with a graceful fallback**

`_render_join_qr` prefers on-device `qrencode` if present (emit PNG→raw is heavy; instead use qrencode's UTF8/ANSI to a text overlay), else falls back to text-only on the framebuffer. Because stock firmware likely lacks `qrencode`, the primary path is a self-contained Lua QR encoder writing RGB565 directly:

```sh
# Render a Wi-Fi join QR (or text fallback) to the framebuffer.
_render_join_qr() {
    local ssid="$1" psk="$2" payload
    payload="WIFI:T:WPA;S:${ssid};P:${psk};;"
    if [ -f /lib/norypt-ghost/qr.lua ] && command -v lua >/dev/null 2>&1; then
        ubus call service delete '{"name":"gl_screen"}' 2>/dev/null
        /etc/init.d/gl_screen stop >/dev/null 2>&1; pkill -9 gl_screen 2>/dev/null
        lua /lib/norypt-ghost/qr.lua "$payload" "$ssid" > /dev/fb0 2>/dev/null && return 0
    fi
    logger -t norypt-ghost "QR renderer unavailable — credentials shown as text only"
    return 0
}
```

`qr.lua` contains a minimal QR (version-auto, byte mode, ECC-L) encoder producing a module matrix, scaled to fit 240×320 with a quiet zone, packed to RGB565 (black modules on white), with the SSID drawn as text rows below using a tiny embedded 5×7 bitmap font. (Full encoder is ~250 lines; implement from the QR spec, byte mode only, versions 1–6 which cover a `WIFI:` payload.)

- [ ] **Step 2: Host smoke — matrix generation is deterministic and square**

Add `tests/lua/test_qr.lua` asserting the encoder returns an NxN boolean matrix for a known payload and that the finder patterns are present at three corners. Run in CI (lua). Locally, skipped.

Run (CI/local-with-lua): `lua tests/lua/test_qr.lua`
Expected: `qr tests OK`.

- [ ] **Step 3: shellcheck functions.sh + commit**

```bash
git add files/lib/norypt-ghost/qr.lua files/lib/norypt-ghost/functions.sh tests/lua/test_qr.lua
git commit -m "feat: Wi-Fi-join QR renderer to framebuffer with text fallback"
```

> **On-device note:** if a self-contained encoder proves too large or the framebuffer format differs, fall back to `qrencode` (add to package Depends only if it is in the GL feed) or to the text-only path, which is already wired. The rotation never depends on the QR.

---

## Phase D — Ephemeral state (no logs)

### Task D1: `clean.sh` telemetry-strip helpers

**Files:**
- Create: `files/lib/norypt-ghost/clean.sh`

**Interfaces:**
- Produces: `CLEAN_APPLY` → unset flash syslog, tmpfs-mount every present client-telemetry dir, disable dnsmasq query logging + persistent cache, force DHCP leases to RAM. `CLEAN_WIPE` → remove RAM-backed copies (shutdown). `CLEAN_STATUS` → prints one line per control with OK/absent for the health check.

- [ ] **Step 1: Write `clean.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — ephemeral state: never persist connected-device history.
. /lib/norypt-ghost/functions.sh

# Directories that hold per-client history; tmpfs-mount any that exist.
_CLEAN_DIRS="/etc/oui-tertf /var/lib/nlbwmon /etc/vnstat /var/lib/vnstat"

_is_tmpfs() { mount | grep -q "tmpfs on $1 "; }

CLEAN_APPLY() {
    # 1. System log to RAM only — unset any flash log_file.
    if [ -n "$(uci -q get system.@system[0].log_file 2>/dev/null)" ]; then
        uci -q delete system.@system[0].log_file; uci -q commit system
    fi
    # 2. tmpfs over each present telemetry dir (before its daemon starts).
    local d
    for d in $_CLEAN_DIRS; do
        [ -d "$d" ] || continue
        _is_tmpfs "$d" && continue
        rm -f "$d"/* 2>/dev/null
        mount -t tmpfs tmpfs "$d"
    done
    # 3. dnsmasq: no query log, no persistent cache.
    uci -q set dhcp.@dnsmasq[0].logqueries=0
    uci -q set dhcp.@dnsmasq[0].cachelocal=0
    uci -q commit dhcp
    # 4. DHCP leases to RAM (OpenWrt default is /tmp; enforce if GL redirected it).
    local lf; lf="$(uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null)"
    case "$lf" in /tmp/*|"") ;; *) uci -q set dhcp.@dnsmasq[0].leasefile=/tmp/dhcp.leases; uci -q commit dhcp ;; esac
    logger -t norypt-ghost "clean: telemetry persistence disabled"
}

CLEAN_WIPE() {
    local d
    for d in $_CLEAN_DIRS; do _is_tmpfs "$d" && rm -f "$d"/* 2>/dev/null; done
    rm -f /tmp/dhcp.leases 2>/dev/null
}

CLEAN_STATUS() {
    [ -z "$(uci -q get system.@system[0].log_file 2>/dev/null)" ] \
        && echo "  PASS  syslog not persisted to flash" \
        || echo "  FAIL  syslog log_file set — logs hitting flash"
    local d
    for d in $_CLEAN_DIRS; do
        [ -d "$d" ] || continue
        _is_tmpfs "$d" && echo "  PASS  $d is RAM-backed" || echo "  FAIL  $d on flash"
    done
}
```

- [ ] **Step 2: shellcheck + commit**

Run: `shellcheck -s sh files/lib/norypt-ghost/clean.sh && echo OK`
```bash
git add files/lib/norypt-ghost/clean.sh
git commit -m "feat: clean.sh — strip persistent connected-device telemetry"
```

> **On-device note:** the real GL.iNet telemetry path set is confirmed on the unit (`gl-tertf`, nlbwmon, vnstat, any `gl_clients` DB location). Absent paths are skipped by `[ -d ]`; extra paths found on-device are appended to `_CLEAN_DIRS`.

---

### Task D2: `norypt-ghost-clean` service + retire volatile-macs

**Files:**
- Create: `files/etc/init.d/norypt-ghost-clean`
- Modify: `files/etc/init.d/norypt-ghost-volatile-macs` → delete (superseded); fold its client.db handling into `clean.sh` (`/etc/oui-tertf` is already in `_CLEAN_DIRS`)
- Modify: `build-ipk.sh`, `Makefile`, `deploy.sh` (swap the service names), `postinst`/`prerm` (enable/disable `-clean` not `-volatile-macs`), `functions.sh` health check (`CLEAN_STATUS`)

**Interfaces:**
- Produces: init service at START=9 calling `CLEAN_APPLY` on boot, `CLEAN_WIPE` on stop.

- [ ] **Step 1: Write the service**

```sh
#!/bin/sh /etc/rc.common
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — ephemeral state service. Runs before gl_clients / dnsmasq /
# gl-tertf so those daemons write to RAM from their first write.
START=9
STOP=99
start() { . /lib/norypt-ghost/clean.sh; CLEAN_APPLY; }
stop()  { . /lib/norypt-ghost/clean.sh; CLEAN_WIPE; }
```

- [ ] **Step 2: Remove volatile-macs and update every reference**

```bash
git rm files/etc/init.d/norypt-ghost-volatile-macs
```
In `build-ipk.sh`, `Makefile`, `deploy.sh`, `postinst`, `prerm`, `postrm`: replace every `norypt-ghost-volatile-macs` with `norypt-ghost-clean`. In `functions.sh` `_run_check`, replace the `tmpfs on /etc/oui-tertf` block with `. /lib/norypt-ghost/clean.sh; CLEAN_STATUS`.

- [ ] **Step 3: shellcheck all touched shell**

Run: `shellcheck -s sh files/etc/init.d/norypt-ghost-clean build-ipk.sh deploy.sh files/lib/norypt-ghost/functions.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Grep to prove no dangling reference**

Run: `! grep -rn 'volatile-macs' files/ build-ipk.sh Makefile deploy.sh`
Expected: exit 0 (no matches).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: norypt-ghost-clean service replaces volatile-macs; wire lifecycle + health check"
```

---

## Phase E — Sealed factory state

### Task E1: `seal.sh` crypto wrapper with discovery + fallback

**Files:**
- Create: `files/lib/norypt-ghost/seal.sh`
- Create: `tests/test_seal_roundtrip.py` (host, requires `openssl` which is present here)

**Interfaces:**
- Produces: `SEAL_AVAILABLE` → 0 if a crypto tool exists. `SEAL_ENCRYPT <plaintext-file> <passphrase>` → prints base64 blob. `SEAL_DECRYPT <blob> <passphrase>` → prints plaintext, non-zero on wrong passphrase. `SEAL_MODE` → prints `sealed` or `plain` per `norypt-ghost.options.factory_mode` and availability.

- [ ] **Step 1: Write the host round-trip test**

```python
# tests/test_seal_roundtrip.py
# SPDX-License-Identifier: GPL-2.0-only
import subprocess, unittest, pathlib, shutil
REPO = pathlib.Path(__file__).resolve().parent.parent
LIB  = REPO / "files/lib/norypt-ghost/seal.sh"

def sh(script):
    return subprocess.run(["sh","-c",f'. "{LIB}"; {script}'],
                          capture_output=True, text=True)

@unittest.skipUnless(shutil.which("openssl"), "openssl required")
class TestSeal(unittest.TestCase):
    def test_roundtrip(self):
        r = sh('printf "IMEI=123\\n" > /tmp/pt; '
               'B=$(SEAL_ENCRYPT /tmp/pt "correct horse"); '
               'SEAL_DECRYPT "$B" "correct horse"')
        self.assertIn("IMEI=123", r.stdout)
    def test_wrong_passphrase_fails(self):
        r = sh('printf "IMEI=123\\n" > /tmp/pt; '
               'B=$(SEAL_ENCRYPT /tmp/pt "right"); '
               'SEAL_DECRYPT "$B" "wrong"; echo "rc=$?"')
        self.assertIn("rc=", r.stdout)
        self.assertNotIn("IMEI=123", r.stdout)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails (no seal.sh)**

Run: `python3 -m unittest tests.test_seal_roundtrip -v`
Expected: FAIL (seal.sh missing).

- [ ] **Step 3: Implement `seal.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — factory-state sealing. openssl if present, else plain fallback.

_seal_tool() { command -v openssl 2>/dev/null; }

SEAL_AVAILABLE() { [ -n "$(_seal_tool)" ]; }

# SEAL_ENCRYPT <plaintext-file> <passphrase> -> base64 blob on stdout.
SEAL_ENCRYPT() {
    local f="$1" pass="$2"
    SEAL_AVAILABLE || { cat "$f" | _b64; return; }        # plain fallback: base64 only
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -a \
        -in "$f" -pass "pass:${pass}" 2>/dev/null
}

# SEAL_DECRYPT <blob> <passphrase> -> plaintext on stdout; non-zero on failure.
SEAL_DECRYPT() {
    local blob="$1" pass="$2"
    SEAL_AVAILABLE || { printf '%s' "$blob" | _unb64; return; }
    printf '%s' "$blob" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -a \
        -pass "pass:${pass}" 2>/dev/null
}

SEAL_MODE() {
    local want; want="$(uci -q get norypt-ghost.options.factory_mode 2>/dev/null)"
    if [ "$want" = "plain" ]; then echo plain; return; fi
    SEAL_AVAILABLE && echo sealed || echo plain
}

_b64()   { openssl base64 2>/dev/null || busybox base64; }
_unb64() { openssl base64 -d 2>/dev/null || busybox base64 -d; }
```

- [ ] **Step 4: Run the test, verify pass**

Run: `python3 -m unittest tests.test_seal_roundtrip -v`
Expected: both tests PASS.

- [ ] **Step 5: shellcheck + commit**

```bash
git add files/lib/norypt-ghost/seal.sh tests/test_seal_roundtrip.py
git commit -m "feat: seal.sh — AES-256 factory-state sealing with plain fallback"
```

---

### Task E2: Seal the factory section; passphrase prompts

**Files:**
- Modify: `files/usr/bin/norypt-ghost` (`_save_factory_state` seals; `restore` unseals; add `factory_mode` handling)
- Modify: `build-ipk.sh` + `Makefile` `postinst` (prompt for passphrase at install when sealing; warn+plain when no crypto), `preinst` (probe crypto, print `opkg install openssl-util` hint if absent)

**Interfaces:**
- Consumes: `SEAL_MODE`, `SEAL_ENCRYPT`, `SEAL_DECRYPT`.
- Produces: factory section stored as `sealed=1` + `blob=` when sealing; `restore` prompts for the passphrase.

- [ ] **Step 1: Seal on capture**

After the existing `uci ... commit blue-merle`… (the `uci -c /etc/config commit norypt-ghost` line) in `_save_factory_state`, add: if `SEAL_MODE` = sealed, serialize the just-written `blue-merle.factory.*`… (`norypt-ghost.factory.*`) keys to a temp file, `SEAL_ENCRYPT` them under a passphrase read from `/tmp/norypt-ghost.seal-pass` (written by postinst prompt, unlinked after), replace the plaintext factory subkeys with a single `blob` + `sealed=1`, and commit. Guard so a second capture on an already-sealed section is a no-op.

```sh
    _seal_factory_if_requested   # defined below, called at end of _save_factory_state
```

Add the helper:

```sh
_seal_factory_if_requested() {
    . /lib/norypt-ghost/seal.sh
    [ "$(SEAL_MODE)" = "sealed" ] || return 0
    [ "$(uci -q get norypt-ghost.factory.sealed 2>/dev/null)" = "1" ] && return 0
    local pass; pass="$(cat /tmp/norypt-ghost.seal-pass 2>/dev/null)"
    [ -n "$pass" ] || { logger -t norypt-ghost "seal: no passphrase provided — leaving plain"; return 0; }
    local tmp=/tmp/ng.factory.$$
    uci -q show norypt-ghost.factory | grep -v '\.sealed=' > "$tmp"
    local blob; blob="$(SEAL_ENCRYPT "$tmp" "$pass")"; rm -f "$tmp" /tmp/norypt-ghost.seal-pass
    # Wipe plaintext subkeys, store the blob.
    local k; for k in $(uci -q show norypt-ghost.factory | sed -n 's/^norypt-ghost\.factory\.\([^=]*\)=.*/\1/p'); do
        [ "$k" = "sealed" ] && continue; uci -q delete "norypt-ghost.factory.$k"; done
    uci set norypt-ghost.factory.sealed=1
    uci set norypt-ghost.factory.blob="$blob"
    uci commit norypt-ghost
    logger -t norypt-ghost "factory state sealed"
}
```

- [ ] **Step 2: Unseal on restore**

At the top of the `restore)` case, before reading factory IMEIs, add: if `norypt-ghost.factory.sealed=1`, prompt for the passphrase (TTY), `SEAL_DECRYPT` the blob into a temp UCI-format file, and load the values into shell vars the restore body reads (adapt `_get_factory` to read from the decrypted temp when sealed). On wrong passphrase, abort with a clear message and leave RF untouched.

- [ ] **Step 3: postinst/preinst prompts**

In `preinst`, after the firmware check, probe: `command -v openssl >/dev/null || echo "note: openssl-util not installed — factory state will be stored UNSEALED. Install with: opkg install openssl-util, then reinstall."`. In `postinst`, before `/usr/bin/norypt-ghost install`, if sealing is available and `factory_mode` != plain and no factory section exists yet, prompt (TTY) for a passphrase twice, confirm match, write to `/tmp/norypt-ghost.seal-pass` (0600).

- [ ] **Step 4: shellcheck + a host dry-run of seal/unseal via the CLI path**

Run: `shellcheck -s sh files/usr/bin/norypt-ghost && echo OK`
Expected: `OK`. (Full seal-in-place is exercised on-device; the crypto primitive itself is covered by E1's host test.)

- [ ] **Step 5: Commit**

```bash
git add files/usr/bin/norypt-ghost build-ipk.sh Makefile
git commit -m "feat: seal factory identity at install; passphrase-gated restore; crypto probe"
```

---

## Phase F — TTL, LuCI, docs, acceptance

### Task F1: TTL/hop-limit normalization

**Files:**
- Create: `files/etc/init.d/norypt-ghost-ttl` (or a firewall include — chosen by backend)
- Modify: `functions.sh` health check to assert the rule is present

**Interfaces:**
- Produces: an egress rule normalizing IPv4 TTL and IPv6 hop-limit to 64, applied at boot and reapplied after `wifi reload`.

- [ ] **Step 1: Implement backend-aware rule application**

```sh
#!/bin/sh /etc/rc.common
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — normalize egress TTL/hop-limit to 64 so NATed client traffic
# looks device-originated (defeats TTL-based tethering detection).
START=45
STOP=10
_apply() {
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        nft add table inet norypt_ghost 2>/dev/null
        nft add chain inet norypt_ghost postrouting \
            '{ type filter hook postrouting priority 300; }' 2>/dev/null
        nft flush chain inet norypt_ghost postrouting 2>/dev/null
        nft add rule inet norypt_ghost postrouting ip ttl set 64 2>/dev/null
        nft add rule inet norypt_ghost postrouting ip6 hoplimit set 64 2>/dev/null
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -C POSTROUTING -j TTL --ttl-set 64 2>/dev/null || \
            iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64 2>/dev/null
        ip6tables -t mangle -C POSTROUTING -j HL --hl-set 64 2>/dev/null || \
            ip6tables -t mangle -A POSTROUTING -j HL --hl-set 64 2>/dev/null
    fi
}
start() { _apply; }
stop()  { nft delete table inet norypt_ghost 2>/dev/null; \
          iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null; \
          ip6tables -t mangle -D POSTROUTING -j HL --hl-set 64 2>/dev/null; true; }
```

- [ ] **Step 2: shellcheck + commit**

Run: `shellcheck -s sh files/etc/init.d/norypt-ghost-ttl && echo OK`
```bash
git add files/etc/init.d/norypt-ghost-ttl
git commit -m "feat: normalize egress TTL/hop-limit to 64 (anti tethering-detection)"
```

> **On-device note:** confirm the firewall backend (`nft` on 23.05 GL builds vs iptables-legacy) and that the `TTL`/`HL` targets or nft `ttl set` are compiled in; keep whichever branch works, drop the other.

---

### Task F2: LuCI + rpcd — lead with New Identity; new controls

**Files:**
- Modify: `files/usr/libexec/norypt-ghost` (add `new_identity`, `factory_mode`/`rat_lock`/`default_region` to `set:` validation and `status`)
- Modify: `files/www/luci-static/resources/view/norypt_ghost.js` (New Identity primary button; RAT-lock, factory-mode, default-region controls; profile in status)

**Interfaces:**
- Consumes: CLI `new-identity`; new UCI options.
- Produces: LuCI "New Identity (full rotation)" primary action; toggles that persist via the validated `set:` backend.

- [ ] **Step 1: rpcd — add command + option validation**

In `files/usr/libexec/norypt-ghost`, add a `new_identity)` case mirroring `rotate)` (background the CLI, return `{"started":true}`), and extend the `set:` validator: `rat_lock` ∈ {0,1}; `factory_mode` ∈ {sealed,plain}; `default_region` ∈ {EU,NA}. Add these keys to the `status` JSON.

- [ ] **Step 2: JS — primary button + controls**

In `norypt_ghost.js`, add a prominent "New Identity (full rotation — reboots)" button calling `exec('new_identity')` with a double-confirm, above the existing partial-rotation buttons (which get a muted "advanced" caption). Add a RAT-lock checkbox, a factory-mode display (read-only if already sealed), and an EU/NA/auto default-region select, each saving via the existing instant-save `set:` path.

- [ ] **Step 3: shellcheck rpcd + JS lint sanity**

Run: `shellcheck -s sh files/usr/libexec/norypt-ghost && node --check files/www/luci-static/resources/view/norypt_ghost.js 2>/dev/null || echo "node not present — JS checked on-device"`
Expected: shellcheck `OK`.

- [ ] **Step 4: Commit**

```bash
git add files/usr/libexec/norypt-ghost files/www/luci-static/resources/view/norypt_ghost.js
git commit -m "feat: LuCI leads with New Identity; RAT-lock, factory-mode, region controls"
```

---

### Task F3: CI gate + packaging + docs

**Files:**
- Modify: `.github/workflows/build.yml` (add a test job)
- Modify: `build-ipk.sh`, `Makefile` (stage new files: profile.sh, identity.sh, clean.sh, seal.sh, qr.lua, profiles.json, new init.d services; drop tac_pool/oui_pool if fully folded)
- Modify: `docs/ROADMAP.md` (tick delivered items), `README.md` (new-identity, no-logs, sealed state, RAT lock)

**Interfaces:**
- Produces: green CI running `tests/run.sh` (with lua installed) before the build job; IPK containing all new files.

- [ ] **Step 1: Add the CI test job**

In `build.yml`, add a `test` job before `build`, and make `build` depend on it:

```yaml
  test:
    name: Host tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: sudo apt-get update && sudo apt-get install -y shellcheck lua5.1 lua-bitop jsonfilter
      - run: ./tests/run.sh
```
Add `needs: test` to the `build` job. (Release builds additionally pass `--release` to the validator; add `./tests/run.sh --release` guarded by `if: startsWith(github.ref,'refs/tags/')`.)

- [ ] **Step 2: Stage new files in both builders**

Add `install`/`$(INSTALL_*)` lines for `profile.sh`, `identity.sh`, `clean.sh`, `seal.sh`, `qr.lua`, `profiles.json`, and the `-clean`/`-ttl` init services in both `build-ipk.sh` and `Makefile`. Remove `tac_pool.json`/`oui_pool.json` staging if their data fully moved into `profiles.json` (keep them only if still referenced).

- [ ] **Step 3: Build the IPK locally to prove staging is complete**

Run: `sudo apt-get install -y gcc-aarch64-linux-gnu >/dev/null 2>&1; ./build-ipk.sh 2>&1 | tail -5`
Expected: `==> norypt-ghost_1.0.0-Script-Local.ipk (...)`. If a file is missing, `install` errors — fix the staging line.

- [ ] **Step 4: Verify the IPK contains the new files**

Run: `tar tzf norypt-ghost_1.0.0-Script-Local.ipk | grep -c control` and inspect data:
```bash
mkdir -p /tmp/ipk && tar xzf norypt-ghost_1.0.0-Script-Local.ipk -C /tmp/ipk && tar tzf /tmp/ipk/data.tar.gz | grep -E 'profile.sh|identity.sh|clean.sh|seal.sh|profiles.json|norypt-ghost-clean|norypt-ghost-ttl'
```
Expected: all listed paths present.

- [ ] **Step 5: Update docs and commit**

Tick items 1–7 in `docs/ROADMAP.md` where now delivered; add README sections for `new-identity`, no-logs guarantee, sealed factory state, and the RAT lock. Then:
```bash
git add .github/workflows/build.yml build-ipk.sh Makefile docs/ROADMAP.md README.md
git commit -m "ci: host-test gate; package new libs/services; document hardening features"
```

---

### Task F4: On-device acceptance checklist

**Files:**
- Create: `docs/ACCEPTANCE.md`

**Interfaces:** none (manual gate).

- [ ] **Step 1: Write the checklist**

A step-by-step on-device procedure and the on-device facts to confirm, each with its fallback:

```markdown
# Norypt Ghost — On-Device Acceptance

Run on a GL-E5800 (Mudi 7) on firmware 4.8.5. Deploy with `./deploy.sh` then
`norypt-ghost install`.

## Facts to confirm first
- [ ] `ATI` + `AT+QNWPREFCFG=?` → record modem model, supported bands, exact RAT-lock token.
- [ ] `command -v openssl` → sealed vs plain fallback.
- [ ] Which of /etc/oui-tertf, /var/lib/nlbwmon, /etc/vnstat, gl-tertf exist → clean.sh path set.
- [ ] `command -v qrencode` / does qr.lua render on /dev/fb0 → QR vs text fallback.
- [ ] `nft list ruleset` vs `iptables -V` → TTL backend.

## Full-identity rotation
- [ ] `norypt-ghost status` → record every current identifier.
- [ ] `norypt-ghost new-identity` → QR appears; device reboots.
- [ ] After boot: IMEI (both slots), all BSSIDs, STA MAC, wired MAC, SSID, hostname, PSK ALL changed.
- [ ] IMEI TAC vendor == BSSID OUI vendor == SSID brand (coherence).
- [ ] Scanning the QR joins Wi-Fi.
- [ ] `AT+QNWPREFCFG="mode_pref"` reads back NR5G:LTE (2G/3G blocked).
- [ ] Egress capture from a client shows TTL 64.

## No-logs
- [ ] Connect a phone, browse; reboot; `logread`, `cat /tmp/dhcp.leases`, GL client list → phone absent.
- [ ] `uci get system.@system[0].log_file` → empty.
- [ ] `norypt-ghost check` → "no persistent client logging" PASS.

## Sealed state + restore
- [ ] `uci get norypt-ghost.factory.sealed` → 1 (if openssl present).
- [ ] `norypt-ghost restore` → prompts passphrase; wrong one refuses; correct one restores all factory values.
- [ ] `opkg remove norypt-ghost` → factory identity restored; GL random_bssid re-enabled.
```

- [ ] **Step 2: Commit**

```bash
git add docs/ACCEPTANCE.md
git commit -m "docs: on-device acceptance checklist and fact-confirmation gate"
```

---

## Self-Review

**Spec coverage:**
- §1 Profile catalog → A1–A4 ✓
- §2 new-identity engine → B3, B4 ✓
- §3 IMEI realism + MCC + RAT lock → A5, B2, B3 ✓
- §4 Ephemeral state → D1, D2 ✓
- §5 Sealed factory state → E1, E2 ✓
- §6 TTL + SSH/TLS regen → F1 (TTL), B3 `IDENTITY_REGEN_KEYS` (SSH/TLS) ✓
- §7 Testing → A1 (validator), A3/A5/E1 (unit), F3 (CI), F4 (on-device) ✓
- §8 Structure (profile/identity/clean/seal libs) + non-goals → files created per structure; non-goals not implemented ✓
- On-device facts → surfaced in F4 and per-task on-device notes ✓

**Placeholder scan:** No TBD/TODO in requirements. The `qr.lua` full encoder body (C1) and the profiles.json full author-set (A2) are described with concrete structure + acceptance tests rather than pasted in full — both are bounded, test-gated deliverables, not vague instructions. All test code and shell helpers are concrete.

**Type/name consistency:** `NG_*` derived vars set in `_profile_derive` (A4) and consumed in `IDENTITY_STAGE` (B3) match. `_gen_imei` 3-arg `profile` mode (A5) matches its call in `IDENTITY_STAGE` (B3). `IDENTITY_APPLY_BOOT`/`IDENTITY_REGEN_KEYS` defined in B3, called in B4/S25. `CLEAN_APPLY/WIPE/STATUS` (D1) match the service (D2) and health check. `SEAL_*` (E1) match E2 usage. `_render_join_qr` guarded in B4 before it exists in C1. Consistent.
