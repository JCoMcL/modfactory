#!/usr/bin/env python3
"""Minimal RCON client using only the Python standard library."""

from __future__ import annotations

import socket
import struct
import sys

MAX_PACKET = 10 * 1024 * 1024


def recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("connection closed")
        data.extend(chunk)
    return bytes(data)


def send_packet(sock: socket.socket, request_id: int, packet_type: int, payload: str) -> None:
    body = struct.pack("<ii", request_id, packet_type) + payload.encode("utf-8") + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(body)) + body)


def recv_packet(sock: socket.socket) -> tuple[int, int, str]:
    length = struct.unpack("<i", recv_exact(sock, 4))[0]
    if length < 10 or length > MAX_PACKET:
        raise ValueError(f"invalid packet length: {length}")
    body = recv_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", body[:8])
    payload = body[8:-2].decode("utf-8", errors="replace")
    return request_id, packet_type, payload


def main() -> int:
    if len(sys.argv) < 5:
        print("usage: rcon.py <host> <port> <password> <command...>", file=sys.stderr)
        return 2

    host = sys.argv[1]
    try:
        port = int(sys.argv[2])
    except ValueError:
        print(f"rcon: invalid port: {sys.argv[2]}", file=sys.stderr)
        return 2
    password = sys.argv[3]
    command = " ".join(sys.argv[4:])

    try:
        with socket.create_connection((host, port), timeout=10) as sock:
            sock.settimeout(10)
            send_packet(sock, 1, 3, password)
            request_id, _packet_type, _payload = recv_packet(sock)
            if request_id == -1:
                print("rcon: authentication failed", file=sys.stderr)
                return 1

            send_packet(sock, 2, 2, command)
            sock.settimeout(1.0)
            chunks: list[str] = []
            while True:
                try:
                    request_id, _packet_type, payload = recv_packet(sock)
                except socket.timeout:
                    break
                except ConnectionError:
                    break
                if request_id == -1:
                    print("rcon: authentication failed", file=sys.stderr)
                    return 1
                if payload:
                    chunks.append(payload)

            output = "".join(chunks)
            if output:
                sys.stdout.write(output)
                if not output.endswith("\n"):
                    sys.stdout.write("\n")
            return 0
    except (OSError, ValueError) as exc:
        print(f"rcon: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
