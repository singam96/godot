#!/usr/bin/env python3
"""Verify incremental links see object-content changes inside thin archives."""

import hashlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(
    sys.platform.startswith("linux") and all(shutil.which(tool) for tool in ("scons", "cc", "ar")),
    "Requires Linux SCons, C compiler and GNU/LLVM ar",
)
class IncrementalArchiveLinkTests(unittest.TestCase):
    def exercise_archive(self, thin):
        with tempfile.TemporaryDirectory(prefix="godot-archive-link-") as temporary:
            folder = Path(temporary)
            (folder / "SConstruct").write_text(
                """
import sys
from SCons.Script import ARGUMENTS, Environment
sys.path.insert(0, ARGUMENTS["godot_root"])
import methods
env = Environment()
env.Decider("MD5-timestamp")
if ARGUMENTS["thin"] == "yes":
    env.Append(ARFLAGS=["--thin"])
library = methods.add_library(env, "state", env.SharedObject("value.c"))
env.Prepend(LIBS=[library])
methods.add_program(env, "probe", "main.c")
methods.add_shared_library(env, "probe_shared", "forward.c")
""",
                encoding="utf-8",
            )
            value = folder / "value.c"
            value.write_text("int read_value(void) { return 1; }\n", encoding="utf-8")
            (folder / "main.c").write_text(
                '#include <stdio.h>\nint read_value(void);\nint main(void) { printf("%d\\n", read_value()); }\n',
                encoding="utf-8",
            )
            (folder / "forward.c").write_text(
                "int read_value(void);\nint forwarded_value(void) { return read_value(); }\n", encoding="utf-8"
            )
            command = ["scons", "-Q", "godot_root=" + str(ROOT), "thin=" + ("yes" if thin else "no")]

            def build():
                result = subprocess.run(command, cwd=folder, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            def outputs():
                executable = subprocess.check_output([str(folder / "probe")], text=True).strip()
                shared = subprocess.check_output(
                    [
                        sys.executable,
                        "-c",
                        "import ctypes; print(ctypes.CDLL('./libprobe_shared.so').forwarded_value())",
                    ],
                    cwd=folder,
                    text=True,
                ).strip()
                return executable, shared

            build()
            self.assertEqual(outputs(), ("1", "1"))
            archive = folder / "libstate.a"
            self.assertEqual(archive.read_bytes()[:8], b"!<thin>\n" if thin else b"!<arch>\n")
            original_archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            # Keep source length/symbols constant and cross SCons' timestamp granularity.
            time.sleep(1.1)
            value.write_text("int read_value(void) { return 2; }\n", encoding="utf-8")
            build()
            if thin:
                self.assertEqual(
                    hashlib.sha256(archive.read_bytes()).hexdigest(),
                    original_archive_hash,
                    "The fixture must exercise an unchanged thin-archive content signature",
                )
            self.assertEqual(outputs(), ("2", "2"), "An object-body change must relink both output kinds")
            timestamps = [(folder / name).stat().st_mtime_ns for name in ("probe", "libprobe_shared.so")]
            build()
            self.assertEqual(
                [(folder / name).stat().st_mtime_ns for name in ("probe", "libprobe_shared.so")],
                timestamps,
                "An unchanged build should not relink",
            )

    def test_regular_archive_incremental_link(self):
        self.exercise_archive(False)

    def test_thin_archive_incremental_link(self):
        self.exercise_archive(True)


if __name__ == "__main__":
    unittest.main()
