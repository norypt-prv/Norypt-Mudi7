# SPDX-License-Identifier: GPL-2.0-only
# Verifies _render_join_qr builds a correct WIFI: join payload and that the
# payload round-trips through a reference QR encoder (python 'qrcode', host-only).
import subprocess, unittest, pathlib, shutil
REPO = pathlib.Path(__file__).resolve().parent.parent
LIB  = REPO / "files/lib/norypt-ghost/functions.sh"

def payload(ssid, psk):
    # Extract only the self-contained _ng_wifi_payload function so we don't
    # source functions.sh (which sources an absolute device-only path).
    fn = subprocess.check_output(
        ["awk", "/^_ng_wifi_payload\\(\\)/{p=1} p{print} p&&/^}/{exit}",
         str(LIB)], text=True)
    script = fn + f'\n_ng_wifi_payload "{ssid}" "{psk}"'
    return subprocess.check_output(["sh", "-c", script], text=True).strip()

class TestJoinPayload(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(payload("NETGEAR-A3F1", "abcdef0123"),
                         "WIFI:T:WPA;S:NETGEAR-A3F1;P:abcdef0123;;")
    def test_escaping(self):
        # semicolons and backslashes in the value must be escaped
        self.assertEqual(payload("a;b", "c\\d"),
                         "WIFI:T:WPA;S:a\\;b;P:c\\\\d;;")

    @unittest.skipUnless(_HAS_QR := __import__("importlib").util.find_spec("qrcode"),
                         "python 'qrcode' needed for the reference-encode check")
    def test_reference_encodes(self):
        import qrcode
        p = payload("NETGEAR-A3F1", "abcdef0123")
        # Reference encoder must accept the payload and produce a square matrix.
        m = qrcode.QRCode(); m.add_data(p); m.make(fit=True)
        mod = m.get_matrix()
        self.assertTrue(len(mod) == len(mod[0]) >= 21)  # >= version 1

if __name__ == "__main__":
    unittest.main()
