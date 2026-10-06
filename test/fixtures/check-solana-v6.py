"""Independent standard-library ABI vector for DEC-188/DEC-192; no network or keys."""

from pathlib import Path


def word(value):
    return value.to_bytes(32, "big", signed=value < 0)


def key(value):
    return bytes.fromhex(value)


def encode_tuple(fields):
    head_size = sum(32 if dynamic else len(data) for dynamic, data in fields)
    head, tail = b"", b""
    for dynamic, data in fields:
        if dynamic:
            head += word(head_size + len(tail))
            tail += data
        else:
            head += data
    return head + tail


def dynamic_array(elements):
    return word(len(elements)) + b"".join(elements)


def vector(populated=False):
    usdc = key("c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61")
    stock = key("07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a")
    empty = word(0)
    fields = [(False, word(value)) for value in [1, 2, 3, 1, 1, 453978307, 1791286864]]
    fields += [(True, dynamic_array([usdc + word(50_000_000)]))]
    if populated:
        position = b"".join(word(value) for value in [300, 400, 0, (1 << 256) - 1, -100, 100, 1000])
        position += stock + usdc + b"".join(word(value) for value in [12, 34, 56, 78])
        fields += [(True, dynamic_array([position]))]
    else:
        fields += [(True, empty)]
    fields += [(True, empty)] * 2
    fields += [(False, word(0))] * 2
    fields += [(True, dynamic_array([word(900) + word(49_990_000)]))]
    home = dynamic_array([word(901) + word(48_000_000) + word(1)]) if populated else empty
    fields += [(True, home)]
    fields += [(True, empty)] * 2
    mint_state = stock + word(0x3FF0000000000000) * 2 + word(0) * 4
    fields += [(True, dynamic_array([mint_state]))]
    return encode_tuple([(False, word(6)), (True, encode_tuple(fields))]).hex()


if __name__ == "__main__":
    expected = Path(__file__).with_name("solana-report-v6.hex").read_text().strip()
    assert vector() == expected.removeprefix("0x")
    print(f"v6 golden vector: {len(bytes.fromhex(vector()))} bytes, independent ABI check PASS")
    populated = Path(__file__).with_name("solana-report-v6-position.hex").read_text().strip()
    assert vector(True) == populated.removeprefix("0x")
    print(f"v6 position vector: {len(bytes.fromhex(vector(True)))} bytes, signed ticks and Income kind PASS")
