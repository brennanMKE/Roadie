#!/usr/bin/env python3 -I
"""flac-tag.py — write a VORBIS_COMMENT block into a FLAC file in place (#0195). Stdlib only.

Usage: python3 -I scripts/flac-tag.py <file.flac> KEY=value [KEY=value ...]
Any existing VORBIS_COMMENT block is replaced; the new one goes right after STREAMINFO.
"""
import struct
import sys

VORBIS_COMMENT = 4


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: flac-tag.py <file.flac> KEY=value ...")
    path, tags = argv[1], argv[2:]
    data = open(path, "rb").read()
    if data[:4] != b"fLaC":
        sys.exit(f"{path}: not a FLAC file")
    pos, blocks, last = 4, [], False
    while not last:
        header = data[pos]
        last = bool(header & 0x80)
        kind = header & 0x7F
        length = int.from_bytes(data[pos + 1:pos + 4], "big")
        blocks.append((kind, data[pos + 4:pos + 4 + length]))
        pos += 4 + length
    frames = data[pos:]

    vendor = b"roadie flac-tag.py"
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(tags))
    for tag in tags:
        raw = tag.encode("utf-8")
        body += struct.pack("<I", len(raw)) + raw
    blocks = [b for b in blocks if b[0] != VORBIS_COMMENT]
    blocks.insert(1, (VORBIS_COMMENT, body))

    out = bytearray(b"fLaC")
    for i, (kind, payload) in enumerate(blocks):
        flag = 0x80 if i == len(blocks) - 1 else 0
        out.append(flag | kind)
        out += len(payload).to_bytes(3, "big")
        out += payload
    out += frames
    with open(path, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main(sys.argv)
