"""Independent interoperability check of the archive written by native XCTest."""
import argparse
import unicodedata
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        bad_file = archive.testzip()
        if bad_file is not None:
            raise ValueError(f"Native ZIP failed CRC validation: {bad_file!r}")
        # Equivalent NFC/NFD spellings are valid UTF-8 ZIP names. Preserve the
        # actual ZipInfo for reads; normalizing a lookup string cannot rename an entry.
        entries = archive.infolist()
        by_name = {}
        for entry in entries:
            name = unicodedata.normalize("NFC", entry.filename)
            if name in by_name:
                raise ValueError(f"Native ZIP has duplicate/equivalent names: {ascii(archive.namelist())}")
            by_name[name] = entry
        expected = {"payload.txt": b"123456789", "f\u00efle.txt": b"unicode"}
        if set(by_name) != set(expected):
            raise ValueError(f"Native ZIP filenames differ. Expected {ascii(sorted(expected))}; found {ascii(archive.namelist())}")
        for name, data in expected.items():
            entry = by_name[name]
            if not entry.filename.isascii() and not entry.flag_bits & 0x0800:
                raise ValueError(f"Native ZIP Unicode filename lacks the UTF-8 flag: {ascii(entry.filename)}")
            if archive.read(entry) != data:
                raise ValueError(f"Native ZIP contents differ: {ascii(entry.filename)}")
            if entry.compress_type != zipfile.ZIP_STORED:
                raise ValueError(f"Native ZIP must use stored entries: {ascii(entry.filename)}")
        if by_name["payload.txt"].CRC != 0xCBF43926:
            raise ValueError("Native ZIP known CRC32 vector differs.")
    print("Native ZIP passes independent Python CRC/content/UTF-8 checks.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    try:
        verify(parser.parse_args().archive)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Native ZIP verification failed: {error}\n")
