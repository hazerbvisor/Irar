#!/usr/bin/env python3
"""Behavioral tests of Irar's C extraction backend; no Wine or JIT.
Usage: python3 tests/host/check-archives.py /path/to/libirar-archive.so /path/to/libarchive-source
The optional source supplies licensed upstream uuencoded RAR/RAR5/7z fixtures.
"""
import binascii
import ctypes as C
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

LIBRARY = Path(sys.argv[1]).resolve()
SOURCE = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
sys.argv = sys.argv[:1]
CALLBACK = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_char_p, C.c_char_p, C.c_int64,
                     C.c_int, C.c_int, C.c_int64, C.c_int64)
lib = C.CDLL(str(LIBRARY))
lib.irar_archive_run.argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, CALLBACK,
                                    C.c_void_p, C.c_char_p, C.c_size_t]
lib.irar_archive_run.restype = C.c_int


def run(volumes, root=None, destination=None, cancel=None):
    entries, updates = [], []
    @CALLBACK
    def callback(_, name, fmt, size, directory, entry, written, consumed):
        if entry:
            entries.append((name.decode(), fmt.decode(), size, bool(directory)))
        updates.append((written, consumed))
        return int(cancel(written) if cancel else False)
    error = C.create_string_buffer(2048)
    code = lib.irar_archive_run("\n".join(map(str, volumes)).encode(),
                                   str(root).encode() if root else None,
                                   str(destination).encode() if destination else None,
                                   callback, None, error, len(error))
    return code, error.value.decode(), entries, updates


def decode(name, output):
    raw = (SOURCE / "libarchive/test" / (name + ".uu")).read_bytes().splitlines()
    started, data = False, bytearray()
    for line in raw:
        if line.startswith(b"begin "):
            started = True
        elif started and line == b"end":
            break
        elif started:
            data.extend(binascii.a2b_uu(line))
    output.write_bytes(data)
    return output


class Archives(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.drive = self.base / "drive_c"
        self.drive.mkdir()
        self.zip = self.base / "game.zip"
    def tearDown(self):
        self.tmp.cleanup()
    def make_zip(self, files):
        with zipfile.ZipFile(self.zip, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, data in files:
                archive.writestr(name, data)
        return self.zip
    def test_zip_listing_and_extraction(self):
        self.make_zip([("Game/", b""), ("Game/setup.exe", b"MZ"), ("Game/data", b"hello" * 1000)])
        code, error, entries, _ = run([self.zip])
        self.assertEqual(code, 0, error)
        self.assertEqual(sum(e[2] for e in entries), 5002)
        self.assertIn("ZIP", entries[0][1])
        code, error, _, progress = run([self.zip], self.drive, self.drive)
        self.assertEqual(code, 0, error)
        self.assertEqual((self.drive / "Game/data").read_bytes(), b"hello" * 1000)
        self.assertTrue(all(a[0] <= b[0] for a, b in zip(progress, progress[1:])))
    def test_traversal(self):
        for name in ["../evil", "dir/../../evil", "/tmp/evil", "C:/evil", "..\\evil", "./evil", "dir//evil", "a" * 4097]:
            with self.subTest(name=name[:80]):
                self.make_zip([(name, b"evil")])
                code, error, _, _ = run([self.zip], self.drive, self.drive)
                self.assertEqual(code, -1)
                self.assertIn("Unsafe", error)
                self.assertFalse((self.base / "evil").exists())
    def test_existing_destination_and_duplicates(self):
        self.make_zip([("keep", b"changed")])
        (self.drive / "keep").write_bytes(b"original")
        code, error, _, _ = run([self.zip], self.drive, self.drive)
        self.assertEqual(code, -1)
        self.assertIn("never overwritten", error)
        self.assertEqual((self.drive / "keep").read_bytes(), b"original")
        self.make_zip([("duplicate", b"first"), ("duplicate", b"second")])
        self.assertEqual(run([self.zip], self.drive, self.drive)[0], -1)
        self.assertEqual((self.drive / "duplicate").read_bytes(), b"first")
    def test_symlink_archive_and_destination(self):
        with zipfile.ZipFile(self.zip, "w") as archive:
            entry = zipfile.ZipInfo("link")
            entry.create_system = 3
            entry.external_attr = 0o120777 << 16
            archive.writestr(entry, "../outside")
        self.assertEqual(run([self.zip], self.drive, self.drive)[0], -1)
        outside = self.base / "outside"
        outside.mkdir()
        (self.drive / "link").symlink_to(outside, target_is_directory=True)
        self.make_zip([("link/evil", b"evil")])
        self.assertEqual(run([self.zip], self.drive, self.drive)[0], -1)
        self.make_zip([("evil", b"evil")])
        self.assertEqual(run([self.zip], self.drive, self.drive / "link")[0], -1)
        self.assertFalse((outside / "evil").exists())
    def test_outside_root(self):
        self.make_zip([("evil", b"evil")])
        self.assertEqual(run([self.zip], self.drive, self.base)[0], -1)
        self.assertEqual(run([self.zip], self.drive, self.drive / ".." / "outside")[0], -1)
    def test_cancellation_removes_partial_file(self):
        self.make_zip([("complete", b"done"), ("partial", b"x" * (8 * 1024 * 1024))])
        code, error, _, _ = run([self.zip], self.drive, self.drive, lambda n: n > 65536)
        self.assertEqual(code, 1, error)
        self.assertEqual((self.drive / "complete").read_bytes(), b"done")
        self.assertFalse((self.drive / "partial").exists())
        self.assertEqual(run([self.zip], cancel=lambda _: True)[0], 1)
    @unittest.skipUnless(sys.platform.startswith("linux"), "address-space limit assertion is Linux-specific")
    def test_streaming_under_memory_limit(self):
        # 256 MiB output in a process with a 160 MiB address-space limit.
        # The fixture is also generated in chunks rather than allocated at once.
        with zipfile.ZipFile(self.zip, "w", zipfile.ZIP_DEFLATED) as archive:
            with archive.open("large", "w", force_zip64=True) as output:
                block = b"a" * 65536
                for _ in range(4096):
                    output.write(block)
        script = """import importlib.util, pathlib, resource, sys
sys.dont_write_bytecode = True
sys.argv = [sys.argv[1], sys.argv[2]]
spec = importlib.util.spec_from_file_location('archive_tests', sys.argv[0])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
resource.setrlimit(resource.RLIMIT_AS, (160 * 1024**2, 160 * 1024**2))
code, error, _, _ = m.run([pathlib.Path(sys.argv[3])], pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[4]))
assert code == 0, error
"""
        # Module resets argv, so pass fixture paths as literal Python data.
        script = script.replace('pathlib.Path(sys.argv[3])', repr(str(self.zip))).replace('pathlib.Path(sys.argv[4])', repr(str(self.drive)))
        result = subprocess.run([sys.executable, "-c", script, str(Path(__file__).resolve()), str(LIBRARY)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.drive / "large").stat().st_size, 256 * 1024**2)
    @unittest.skipUnless(SOURCE, "pass vendored libarchive source for RAR fixtures")
    def test_rar_rar5(self):
        names = ["test_read_format_rar_multi_lzss_blocks.rar", "test_read_format_rar5_compressed.rar"]
        for index, name in enumerate(names):
            with self.subTest(format=name):
                archive = decode(name, self.base / name)
                destination = self.drive / str(index)
                destination.mkdir()
                code, error, entries, _ = run([archive])
                self.assertEqual(code, 0, error)
                self.assertGreater(len(entries), 0)
                expected = "RAR5" if "rar5" in name else "RAR"
                self.assertIn(expected, entries[0][1])
                code, error, _, _ = run([archive], self.drive, destination)
                self.assertEqual(code, 0, error)
                self.assertTrue(any(x.is_file() for x in destination.rglob("*")))
    @unittest.skipUnless(SOURCE, "pass vendored source for multipart RAR fixtures")
    def test_multipart_rar(self):
        parts = [decode(f"test_rar_multivolume_single_file.part{i}.rar", self.base / f"part{i}.rar") for i in range(1, 4)]
        code, error, _, _ = run(parts, self.drive, self.drive)
        self.assertEqual(code, 0, error)
        self.assertTrue(any(x.is_file() for x in self.drive.rglob("*")))
    @unittest.skipUnless(SOURCE, "pass vendored source for multipart RAR fixtures")
    def test_legacy_volume_names(self):
        names = ["game.rar", "game.r00", "game.r01"]
        parts = [decode(f"test_rar_multivolume_single_file.part{i}.rar", self.base / name) for i, name in enumerate(names, 1)]
        code, error, _, _ = run(parts, self.drive, self.drive)
        self.assertEqual(code, 0, error)


if __name__ == "__main__":
    unittest.main(verbosity=2)
