#!/usr/bin/env python3
"""Generate .7z test fixtures with Python's own LZMA encoder (stdlib only).

Writes KalsmritikoshTests/Fixtures/Archives/:
  sample-lzma2-encoded.7z  LZMA2 file data + LZMA-encoded header (7-Zip's default layout)
  sample-lzma-plain.7z     LZMA1 file data + plain header
  expected.json            names and SHA-256 of every member
Members: directory "docs", "docs/a.txt", "b.txt" (one solid folder), empty file "empty.txt".
"""
import hashlib, json, lzma, os, random, struct, zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "KalsmritikoshTests", "Fixtures", "Archives")

def num(n):
    for i in range(9):
        if n < (1 << (7 * (i + 1))) or i == 8:
            first = ((0xFF << (8 - i)) & 0xFF) | (n >> (8 * i) if i < 8 else 0)
            return bytes([first & 0xFF]) + n.to_bytes(8, "little")[:i]
    raise ValueError(n)

def lzma1_raw(data):
    alone = lzma.compress(data, format=lzma.FORMAT_ALONE, preset=6)
    return alone[:5], alone[13:]               # 5 property bytes, raw stream

def lzma2_raw(data):
    return lzma.compress(data, format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "dict_size": 1 << 20}])

def folder(coder_id, props, unpack_size):
    flag = len(coder_id) | (0x20 if props else 0)
    f = num(1) + bytes([flag]) + coder_id
    if props: f += num(len(props)) + props
    return f, num(unpack_size)

def streams_info(pack_pos, pack_size, coder_id, props, unpack, sub_sizes=None):
    s = b"\x06" + num(pack_pos) + num(1) + b"\x09" + num(pack_size) + b"\x00"
    f, size = folder(coder_id, props, unpack)
    s += b"\x07\x0b" + num(1) + b"\x00" + f + b"\x0c" + size + b"\x00"
    if sub_sizes is not None:
        s += b"\x08\x0d" + num(len(sub_sizes))
        if len(sub_sizes) > 1:
            s += b"\x09" + b"".join(num(x) for x in sub_sizes[:-1])
        s += b"\x00"
    return s + b"\x00"

def files_info(names, empty_stream, empty_file):
    def bits(v):
        out = bytearray((len(v) + 7) // 8)
        for i, b in enumerate(v):
            if b: out[i // 8] |= 0x80 >> (i % 8)
        return bytes(out)
    es, ef = bits(empty_stream), bits(empty_file)
    name_data = b"\x00" + b"".join(n.encode("utf-16-le") + b"\x00\x00" for n in names)
    return (b"\x05" + num(len(names)) + b"\x0e" + num(len(es)) + es + b"\x0f" + num(len(ef)) + ef
            + b"\x11" + num(len(name_data)) + name_data + b"\x00")

def build(path, file_coder, encode_header):
    random.seed(7)
    a = (b"The contract was signed on 4 May 2024 by both parties. " * 60)
    b = bytes(random.choice(b"abcdefghij klmnop\n") for _ in range(5000)) + b" END OF B"
    solid = a + b
    if file_coder == "lzma2":
        coder_id, props, packed = b"\x21", bytes([16]), lzma2_raw(solid)
    else:
        props, packed = lzma1_raw(solid)
        coder_id = b"\x03\x01\x01"
    header = (b"\x01\x04" + streams_info(0, len(packed), coder_id, props, len(solid), [len(a), len(b)])
              + files_info(["docs", "docs/a.txt", "b.txt", "empty.txt"], [1, 0, 0, 1], [0, 1]) + b"\x00")
    body = packed
    if encode_header:
        hprops, hpacked = lzma1_raw(header)
        next_header = b"\x17" + streams_info(len(packed), len(hpacked), b"\x03\x01\x01", hprops, len(header))
        body += hpacked
    else:
        next_header = header
    tail = struct.pack("<QQI", len(body), len(next_header), zlib.crc32(next_header))
    sig = b"7z\xbc\xaf\x27\x1c\x00\x04" + struct.pack("<I", zlib.crc32(tail)) + tail
    with open(path, "wb") as fh:
        fh.write(sig + body + next_header)
    return {"docs/a.txt": hashlib.sha256(a).hexdigest(), "b.txt": hashlib.sha256(b).hexdigest(),
            "empty.txt": hashlib.sha256(b"").hexdigest()}

os.makedirs(OUT, exist_ok=True)
expected = build(os.path.join(OUT, "sample-lzma2-encoded.7z"), "lzma2", True)
build(os.path.join(OUT, "sample-lzma-plain.7z"), "lzma", False)
with open(os.path.join(OUT, "expected.json"), "w") as fh:
    json.dump(expected, fh, indent=2, sort_keys=True)
print("wrote fixtures to", os.path.abspath(OUT))
