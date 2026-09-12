from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Swift tools")
    def test_swift_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory) / "runtime-tests")
            subprocess.run(["swiftc", str(ROOT / "Runtime.swift"),
                            str(ROOT / "tests/RuntimeTests.swift"), "-o", binary],
                           check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([binary], check=True, capture_output=True, text=True, timeout=15)
            self.assertIn("PASS:", result.stdout)
