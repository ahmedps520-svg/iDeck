#!/usr/bin/env python3
"""Extracts a raw arm64 `Image` from a Debian vmlinuz.

Debian's arm64 vmlinuz may be a raw Image, a gzip-compressed Image, or an
EFI zboot image (PE/COFF wrapper with a compressed payload). QEMU's
-kernel accepts all three in recent versions, but a raw Image loads
fastest and works with every QEMU, so the runtime ships the raw form.

  extract_kernel.py vmlinuz Image
"""
import gzip
import struct
import subprocess
import sys

ARM64_MAGIC = b"ARM\x64"


def is_raw_image(b: bytes) -> bool:
    return len(b) > 0x40 and b[0x38:0x3C] == ARM64_MAGIC


def extract(data: bytes) -> bytes:
    if is_raw_image(data):
        return data
    if data[:2] == b"\x1f\x8b":
        out = gzip.decompress(data)
        if is_raw_image(out):
            return out
        raise ValueError("gzip payload is not an arm64 Image")
    # EFI zboot: "MZ" header, "zimg" at offset 4, payload offset/size at
    # 0x08/0x0C, compression type string at 0x18 (linux/drivers/firmware/
    # efi/libstub/zboot-header.S).
    if data[:2] == b"MZ" and data[4:8] == b"zimg":
        off, size = struct.unpack_from("<II", data, 0x08)
        comp = data[0x18:0x18 + 32].split(b"\0")[0].decode()
        payload = data[off:off + size]
        if comp == "gzip":
            out = gzip.decompress(payload)
        elif comp in ("zstd", "zstd22"):
            out = subprocess.run(["zstd", "-dc"], input=payload, capture_output=True, check=True).stdout
        elif comp == "xz":
            import lzma
            out = lzma.decompress(payload)
        else:
            raise ValueError(f"unsupported zboot compression '{comp}'")
        if is_raw_image(out):
            return out
        raise ValueError("zboot payload is not an arm64 Image")
    raise ValueError("unrecognised kernel image format")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    out = extract(data)
    with open(sys.argv[2], "wb") as f:
        f.write(out)
    print(f"{sys.argv[2]}: {len(out)} bytes (raw arm64 Image)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
