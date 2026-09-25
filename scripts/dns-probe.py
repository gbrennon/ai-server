import socket
import struct
import sys


def build_query(hostname: str) -> bytes:
    header = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
    question = b""
    for label in hostname.split("."):
        question += bytes([len(label)]) + label.encode()
    question += b"\x00" + struct.pack(">HH", 1, 1)
    return header + question


def send_query(query: bytes) -> bytes:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    sock.sendto(query, ("127.0.0.1", 53))
    response, _ = sock.recvfrom(512)
    return response


def skip_name(response: bytes, offset: int) -> int:
    if response[offset] & 0xC0 == 0xC0:
        return offset + 2
    while response[offset] != 0:
        offset += response[offset] + 1
    return offset + 1


def extract_addresses(response: bytes) -> list[str]:
    offset = skip_name(response, 12) + 4
    answer_count = struct.unpack(">H", response[6:8])[0]
    addresses: list[str] = []
    for _ in range(answer_count):
        offset = skip_name(response, offset)
        record_type, _, _, rdlength = struct.unpack(">HHIH", response[offset:offset + 10])
        offset += 10
        rdata = response[offset:offset + rdlength]
        offset += rdlength
        if record_type == 1 and rdlength == 4:
            addresses.append(".".join(str(byte) for byte in rdata))
    return addresses


def main() -> int:
    expected, hostname = sys.argv[1], sys.argv[2]
    addresses = extract_addresses(send_query(build_query(hostname)))
    resolved = expected in addresses
    print("OK" if resolved else "FAIL", addresses)
    return 0 if resolved else 1


if __name__ == "__main__":
    sys.exit(main())
