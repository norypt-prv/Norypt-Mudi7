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
