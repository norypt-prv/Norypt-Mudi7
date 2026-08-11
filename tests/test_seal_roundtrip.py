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
