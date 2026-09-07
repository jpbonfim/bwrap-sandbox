#!/usr/bin/env python3
"""
Lightweight, zero-dependency domain-filtering proxy and Unix socket relay.
Used by bwrap-sandbox.sh for kernel-enforced network isolation.

Modes:
  --proxy <unix_socket> <whitelist_file>  (Runs on Host: Filters HTTP/CONNECT by domain)
  --relay <tcp_port> <unix_socket>        (Runs in Sandbox: Bridges TCP 127.0.0.1 to Unix socket)
"""

import asyncio
import fnmatch
import os
import signal
import sys

BUFFER_SIZE = 65536


def load_whitelist(path):
    patterns = []
    if not os.path.isfile(path):
        print(f"[proxy] Error: Whitelist file not found: {path}", file=sys.stderr)
        sys.exit(1)
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            patterns.append(line.lower())
    return patterns


def is_domain_allowed(host, patterns):
    host = host.lower().split(":")[0]
    for pat in patterns:
        if fnmatch.fnmatch(host, pat):
            return True
        # If pattern is *.domain.com, also match domain.com directly
        if pat.startswith("*.") and host == pat[2:]:
            return True
    return False


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUFFER_SIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.CancelledError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


class FilteringProxyServer:
    def __init__(self, whitelist_path):
        self.patterns = load_whitelist(whitelist_path)

    async def handle_client(self, client_r, client_w):
        try:
            req_line = await client_r.readline()
            if not req_line:
                client_w.close()
                return

            line_str = req_line.decode("utf-8", "replace").strip()
            parts = line_str.split()
            if len(parts) < 2:
                client_w.close()
                return

            method, target = parts[0].upper(), parts[1]

            if method == "CONNECT":
                # CONNECT host:port HTTP/1.1
                hp = target.split(":")
                host = hp[0]
                port = int(hp[1]) if len(hp) > 1 else 443

                # Read remaining request headers
                while True:
                    hdr = await client_r.readline()
                    if not hdr or hdr in (b"\r\n", b"\n"):
                        break

                if not is_domain_allowed(host, self.patterns):
                    resp = (
                        f"HTTP/1.1 403 Forbidden\r\n"
                        f"Content-Type: text/plain\r\n"
                        f"Connection: close\r\n\r\n"
                        f"Blocked by sandbox filter: {host}\n"
                    )
                    client_w.write(resp.encode("utf-8"))
                    await client_w.drain()
                    client_w.close()
                    return

                try:
                    remote_r, remote_w = await asyncio.open_connection(host, port)
                except Exception as e:
                    resp = (
                        f"HTTP/1.1 502 Bad Gateway\r\n"
                        f"Content-Type: text/plain\r\n"
                        f"Connection: close\r\n\r\n"
                        f"Failed to connect to {host}:{port}: {e}\n"
                    )
                    client_w.write(resp.encode("utf-8"))
                    await client_w.drain()
                    client_w.close()
                    return

                client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await client_w.drain()

                t1 = asyncio.create_task(pipe(client_r, remote_w))
                t2 = asyncio.create_task(pipe(remote_r, client_w))
                await asyncio.gather(t1, t2, return_exceptions=True)

            else:
                # Plain HTTP (GET http://host/path HTTP/1.1)
                headers = [req_line]
                host = ""
                while True:
                    hdr = await client_r.readline()
                    if not hdr or hdr in (b"\r\n", b"\n"):
                        headers.append(b"\r\n")
                        break
                    headers.append(hdr)
                    if hdr.lower().startswith(b"host:"):
                        host = hdr.decode("utf-8", "replace").split(":", 1)[1].strip()

                if not host and target.startswith("http://"):
                    host = target[7:].split("/", 1)[0]

                if not host or not is_domain_allowed(host, self.patterns):
                    resp = (
                        f"HTTP/1.1 403 Forbidden\r\n"
                        f"Content-Type: text/plain\r\n"
                        f"Connection: close\r\n\r\n"
                        f"Blocked by sandbox filter: {host or 'unknown'}\n"
                    )
                    client_w.write(resp.encode("utf-8"))
                    await client_w.drain()
                    client_w.close()
                    return

                port = 80
                if ":" in host:
                    h_parts = host.split(":")
                    host = h_parts[0]
                    try:
                        port = int(h_parts[1])
                    except ValueError:
                        port = 80

                try:
                    remote_r, remote_w = await asyncio.open_connection(host, port)
                except Exception as e:
                    resp = (
                        f"HTTP/1.1 502 Bad Gateway\r\n"
                        f"Content-Type: text/plain\r\n"
                        f"Connection: close\r\n\r\n"
                        f"Failed to connect to {host}:{port}: {e}\n"
                    )
                    client_w.write(resp.encode("utf-8"))
                    await client_w.drain()
                    client_w.close()
                    return

                remote_w.writelines(headers)
                await remote_w.drain()

                t1 = asyncio.create_task(pipe(client_r, remote_w))
                t2 = asyncio.create_task(pipe(remote_r, client_w))
                await asyncio.gather(t1, t2, return_exceptions=True)

        except Exception:
            pass
        finally:
            try:
                client_w.close()
            except Exception:
                pass


async def run_proxy(sock_path, whitelist_path):
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    proxy = FilteringProxyServer(whitelist_path)
    server = await asyncio.start_unix_server(proxy.handle_client, sock_path)
    os.chmod(sock_path, 0o600)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    finally:
        server.close()
        await server.wait_closed()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


async def run_relay(tcp_port, sock_path):
    async def handle_tcp(client_r, client_w):
        try:
            unix_r, unix_w = await asyncio.open_unix_connection(sock_path)
        except Exception:
            client_w.close()
            return

        t1 = asyncio.create_task(pipe(client_r, unix_w))
        t2 = asyncio.create_task(pipe(unix_r, client_w))
        await asyncio.gather(t1, t2, return_exceptions=True)

    server = await asyncio.start_server(handle_tcp, "127.0.0.1", tcp_port)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    finally:
        server.close()
        await server.wait_closed()


def main():
    if len(sys.argv) < 2:
        print("Usage: net-proxy.py --proxy <unix_sock> <whitelist_file>", file=sys.stderr)
        print("       net-proxy.py --relay <tcp_port> <unix_sock>", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    if mode == "--proxy" and len(sys.argv) == 4:
        sock_path = sys.argv[2]
        wl_path = sys.argv[3]
        asyncio.run(run_proxy(sock_path, wl_path))
    elif mode == "--relay" and len(sys.argv) == 4:
        tcp_port = int(sys.argv[2])
        sock_path = sys.argv[3]
        asyncio.run(run_relay(tcp_port, sock_path))
    else:
        print(f"Error: Invalid arguments: {sys.argv}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
