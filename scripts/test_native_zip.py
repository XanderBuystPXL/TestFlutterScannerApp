"""Exercise the independent native-fixture reader, including filesystem Unicode forms."""
import contextlib
import io
from pathlib import Path
import tempfile
import unicodedata
import unittest
import zipfile

from verify_native_zip import verify


class NativeZIPVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "fixture.zip"

    def write(self, unicode_name="f\u00efle.txt", unicode_data=b"unicode", extras=(), compression=zipfile.ZIP_STORED):
        with zipfile.ZipFile(self.archive, "w", compression=compression) as archive:
            archive.writestr("payload.txt", b"123456789")
            archive.writestr(unicode_name, unicode_data)
            for name, data in extras:
                archive.writestr(name, data)

    def check(self):
        with contextlib.redirect_stdout(io.StringIO()):
            verify(self.archive)

    def test_composed_utf8_names_pass(self):
        self.write()
        self.check()

    def test_decomposed_utf8_names_pass_and_original_entry_is_read(self):
        self.write(unicode_name=unicodedata.normalize("NFD", "f\u00efle.txt"))
        self.check()

    def test_equivalent_name_collision_is_rejected(self):
        self.write(extras=[(unicodedata.normalize("NFD", "f\u00efle.txt"), b"unicode")])
        with self.assertRaisesRegex(ValueError, "duplicate/equivalent"):
            self.check()

    def test_extra_entry_is_rejected_with_actual_names(self):
        self.write(extras=[("unexpected.txt", b"extra")])
        with self.assertRaisesRegex(ValueError, "unexpected.txt"):
            self.check()

    def test_wrong_unicode_payload_is_rejected(self):
        self.write(unicode_name=unicodedata.normalize("NFD", "f\u00efle.txt"), unicode_data=b"changed")
        with self.assertRaisesRegex(ValueError, "contents differ"):
            self.check()

    def test_crc_corruption_is_rejected(self):
        self.write()
        data = self.archive.read_bytes()
        self.archive.write_bytes(data.replace(b"123456789", b"123456780", 1))
        with self.assertRaisesRegex(ValueError, "CRC validation"):
            self.check()

    def test_compressed_fixture_is_rejected(self):
        self.write(compression=zipfile.ZIP_DEFLATED)
        with self.assertRaisesRegex(ValueError, "stored entries"):
            self.check()

    def test_non_utf8_unicode_name_is_rejected(self):
        class LegacyName(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode("cp437"), self.flag_bits & ~0x0800

        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("payload.txt", b"123456789")
            archive.writestr(LegacyName("f\u00efle.txt"), b"unicode")
        with self.assertRaisesRegex(ValueError, "UTF-8 flag"):
            self.check()


if __name__ == "__main__":
    unittest.main()
