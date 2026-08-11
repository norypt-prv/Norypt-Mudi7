# SPDX-License-Identifier: GPL-2.0-only
"""Pins the quote-stripping/unescaping parse logic used by the sealed-restore
preamble in files/usr/bin/norypt-ghost (the `restore)` case, Part 2:
unseal-on-restore).

`uci show norypt-ghost.factory` emits lines like:
    norypt-ghost.factory.wifi2g_ssid='My Home WiFi'
and, when a value contains an embedded single quote, escapes it as the
4-character sequence '\'' (apostrophe backslash apostrophe apostrophe), e.g.
a value "Joe's WiFi" is emitted as:
    norypt-ghost.factory.wifi2g_key='Joe'\''s WiFi'
The preamble splits each line on the first '=', strips one leading and one
trailing single-quote from the value, then unescapes any '\'' sequences back
to a literal ' before loading the value into the uncommitted uci delta with
`uci set KEY=VALUE`.

This test exercises that exact shell fragment in isolation (no uci, no
sourcing norypt-ghost) so a regression in the split/strip/unescape logic —
e.g. one that mangles a value containing a space or an apostrophe — is caught
on the host without needing a device.
"""
import subprocess
import unittest

# Mirrors, statement for statement, the parse loop inside the `restore)` case
# of files/usr/bin/norypt-ghost (the block preceded by the comment "uci show
# wraps values in single quotes ..."). Kept in sync by hand — if that loop
# changes, update this snippet to match.
PARSE_SNIPPET = r'''
while IFS= read -r _ng_line; do
    case "$_ng_line" in norypt-ghost.factory.*=*) ;; *) continue ;; esac
    _ng_k="${_ng_line%%=*}"
    _ng_v="${_ng_line#*=}"
    # uci show wraps values in single quotes and escapes an embedded ' as
    # '\''; strip the outer quotes, then unescape that sequence back to a
    # literal ' (e.g. an SSID like "Joe's WiFi").
    _ng_v="${_ng_v#\'}"; _ng_v="${_ng_v%\'}"
    _ng_out=""
    while :; do
        case "$_ng_v" in
            *"'\''"*)
                _ng_out="${_ng_out}${_ng_v%%"'\''"*}'"
                _ng_v="${_ng_v#*"'\''"}"
                ;;
            *)
                _ng_out="${_ng_out}${_ng_v}"
                break
                ;;
        esac
    done
    _ng_v="$_ng_out"
    printf '%s\t%s\n' "$_ng_k" "$_ng_v"
done
'''


def run_parse(input_text):
    """Feed `input_text` (uci-show-style lines) through PARSE_SNIPPET and
    return a dict of {key: value} for every recovered norypt-ghost.factory.*
    line. Non-matching lines are silently dropped, same as the real preamble.
    """
    r = subprocess.run(
        ["sh", "-c", PARSE_SNIPPET],
        input=input_text,
        capture_output=True,
        text=True,
        check=True,
    )
    out = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("\t")
        out[k] = v
    return out


class TestSealFactoryParse(unittest.TestCase):
    def test_normal_imei(self):
        out = run_parse("norypt-ghost.factory.slot1_imei='011714004900929'\n")
        self.assertEqual(out["norypt-ghost.factory.slot1_imei"], "011714004900929")

    def test_value_with_space(self):
        # SSIDs commonly contain spaces; this is the case the strip logic
        # must not break (naive quote-aware splitting would truncate it).
        out = run_parse("norypt-ghost.factory.wifi2g_ssid='My Home WiFi'\n")
        self.assertEqual(out["norypt-ghost.factory.wifi2g_ssid"], "My Home WiFi")

    def test_multiple_lines_with_section_and_junk_line_skipped(self):
        blob = (
            "norypt-ghost.factory=norypt-ghost\n"  # section line, no dot before '=' -> skipped
            "norypt-ghost.factory.slot1_imei='011714004900929'\n"
            "norypt-ghost.factory.slot2_imei='356938035643809'\n"
            "norypt-ghost.factory.wifi2g_ssid='My Home WiFi'\n"
            "norypt-ghost.factory.guest2g_key='correct horse battery'\n"
            "not a factory line at all\n"  # junk -> skipped
        )
        out = run_parse(blob)
        self.assertEqual(len(out), 4)
        self.assertEqual(out["norypt-ghost.factory.slot1_imei"], "011714004900929")
        self.assertEqual(out["norypt-ghost.factory.slot2_imei"], "356938035643809")
        self.assertEqual(out["norypt-ghost.factory.wifi2g_ssid"], "My Home WiFi")
        self.assertEqual(
            out["norypt-ghost.factory.guest2g_key"], "correct horse battery"
        )

    def test_value_with_embedded_apostrophe(self):
        # uci show escapes an internal ' as the 4-char sequence '\'' — a
        # naive "strip one leading/trailing quote" parser recovers the
        # mangled "Joe'\''s WiFi" instead of "Joe's WiFi". Pin the unescape.
        raw = "norypt-ghost.factory.wifi2g_key='Joe'\\''s WiFi'\n"
        out = run_parse(raw)
        self.assertEqual(out["norypt-ghost.factory.wifi2g_key"], "Joe's WiFi")

    def test_sealed_key_itself_round_trips_if_present(self):
        # Not expected in real blobs (Part 1 strips .sealed before encrypting),
        # but the parse loop has no special-case for it — pin that it still
        # round-trips cleanly rather than silently corrupting.
        out = run_parse("norypt-ghost.factory.sealed='1'\n")
        self.assertEqual(out["norypt-ghost.factory.sealed"], "1")


if __name__ == "__main__":
    unittest.main()
