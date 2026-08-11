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
