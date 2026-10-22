"""Independent interoperability check of the archive written by native XCTest."""
import argparse
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, "Native ZIP failed CRC validation"
        assert set(archive.namelist()) == {"payload.txt", "fïle.txt"}
        assert archive.read("payload.txt") == b"123456789"
        assert archive.read("fïle.txt") == b"unicode"
        assert archive.getinfo("payload.txt").CRC == 0xCBF43926
        assert all(i.compress_type == zipfile.ZIP_STORED for i in archive.infolist())
    print("Native ZIP passes independent Python CRC/content/UTF-8 checks.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    verify(parser.parse_args().archive)
