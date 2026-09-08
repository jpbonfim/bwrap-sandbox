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


DEFAULT_HTTP_PORTS = {80, 443}
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}


class WhitelistRule:
    def __init__(self, pattern_str):
        self.raw = pattern_str.strip().lower()
        self.host_pattern, self.allowed_ports = self._parse(self.raw)

    def _parse(self, s):
        # Handle IPv6 brackets like [::1]:port or [::1]
        if s.startswith("["):
            parts = s.rsplit(":", 1)
            host_part = parts[0].strip("[]")
            port_part = parts[1] if len(parts) > 1 and not parts[1].endswith("]") else None
        elif ":" in s:
            parts = s.split(":", 1)
            host_part = parts[0]
            port_part = parts[1]
        else:
            host_part = s
            port_part = None

        ports = self._parse_ports(port_part)
        return host_part, ports

    def _parse_ports(self, port_str):
        if port_str is None or not port_str.strip():
            # Default when port is not specified: ONLY standard HTTP/HTTPS ports (80, 443)
            return set(DEFAULT_HTTP_PORTS)
        port_str = port_str.strip()
        if port_str == "*":
            # Explicit wildcard: all ports allowed
            return None
        result = set()
        for chunk in port_str.split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            if chunk == "*":
                return None
            if "-" in chunk:
                try:
                    start_s, end_s = chunk.split("-", 1)
                    start, end = int(start_s.strip()), int(end_s.strip())
                    if 0 <= start <= 65535 and 0 <= end <= 65535 and start <= end:
                        result.update(range(start, end + 1))
                except ValueError:
                    pass
            else:
                try:
                    p = int(chunk)
                    if 0 <= p <= 65535:
                        result.add(p)
                except ValueError:
                    pass
        return result

    def matches(self, target_host, target_port):
        t_host = target_host.strip("[]").lower()
        r_host = self.host_pattern.strip("[]").lower()

        matched_host = False
        if r_host in LOCAL_HOSTS and t_host in LOCAL_HOSTS:
            matched_host = True
        elif fnmatch.fnmatch(t_host, r_host):
            matched_host = True
        elif r_host.startswith("*.") and t_host == r_host[2:]:
            matched_host = True

        if not matched_host:
            return False

        if self.allowed_ports is None:
            return True
        return target_port in self.allowed_ports


def parse_host_port(target, default_port=80):
    target = target.strip()
    if target.startswith("["):
        parts = target.rsplit(":", 1)
        host = parts[0].strip("[]")
        if len(parts) > 1 and not parts[1].endswith("]"):
            try:
                port = int(parts[1])
            except ValueError:
                port = default_port
        else:
            port = default_port
    elif ":" in target:
        parts = target.split(":", 1)
        host = parts[0]
        try:
            port = int(parts[1])
        except ValueError:
            port = default_port
    else:
        host = target
        port = default_port
    return host, port


def load_whitelist(path):
    rules = []
    if not os.path.isfile(path):
        print(f"[proxy] Error: Whitelist file not found: {path}", file=sys.stderr)
        sys.exit(1)
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            rules.append(WhitelistRule(line))
    return rules


def is_allowed(target_host, target_port, rules):
    for rule in rules:
        if rule.matches(target_host, target_port):
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
        self.rules = load_whitelist(whitelist_path)

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
                host, port = parse_host_port(target, default_port=443)

                # Read remaining request headers
                while True:
                    hdr = await client_r.readline()
                    if not hdr or hdr in (b"\r\n", b"\n"):
                        break

                if not is_allowed(host, port, self.rules):
                    body = f"Blocked by sandbox filter: {host}:{port}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 403 Blocked by sandbox filter: {host}:{port}\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"X-Blocked-By: sandbox-filter\r\n"
                        f"X-Blocked-Target: {host}:{port}\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
                    await client_w.drain()
                    client_w.close()
                    return

                connect_host = "127.0.0.1" if host.lower() in LOCAL_HOSTS else host
                try:
                    remote_r, remote_w = await asyncio.open_connection(connect_host, port)
                except Exception as e:
                    body = f"Failed to connect to {host}:{port}: {e}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 502 Bad Gateway\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
                    await client_w.drain()
                    client_w.close()
                    return

                client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await client_w.drain()

                t1 = asyncio.create_task(pipe(client_r, remote_w))
                t2 = asyncio.create_task(pipe(remote_r, client_w))
                await asyncio.gather(t1, t2, return_exceptions=True)

            else:
                # Plain HTTP (GET http://host:port/path HTTP/1.1)
                headers = [req_line]
                host_hdr = ""
                while True:
                    hdr = await client_r.readline()
                    if not hdr or hdr in (b"\r\n", b"\n"):
                        headers.append(b"\r\n")
                        break
                    headers.append(hdr)
                    if hdr.lower().startswith(b"host:"):
                        host_hdr = hdr.decode("utf-8", "replace").split(":", 1)[1].strip()

                target_spec = ""
                if target.startswith("http://"):
                    target_spec = target[7:].split("/", 1)[0]
                elif host_hdr:
                    target_spec = host_hdr

                if not target_spec:
                    client_w.close()
                    return

                host, port = parse_host_port(target_spec, default_port=80)

                if not is_allowed(host, port, self.rules):
                    body = f"Blocked by sandbox filter: {host}:{port}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 403 Blocked by sandbox filter: {host}:{port}\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"X-Blocked-By: sandbox-filter\r\n"
                        f"X-Blocked-Target: {host}:{port}\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
                    await client_w.drain()
                    client_w.close()
                    return

                # Convert absolute URI in request line to origin-form path for compatibility with all HTTP servers
                if target.startswith("http://"):
                    url_after_proto = target[7:]
                    path = "/" + url_after_proto.split("/", 1)[1] if "/" in url_after_proto else "/"
                    proto = parts[2] if len(parts) > 2 else "HTTP/1.1"
                    headers[0] = f"{method} {path} {proto}\r\n".encode("utf-8")

                connect_host = "127.0.0.1" if host.lower() in LOCAL_HOSTS else host
                try:
                    remote_r, remote_w = await asyncio.open_connection(connect_host, port)
                except Exception as e:
                    body = f"Failed to connect to {host}:{port}: {e}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 502 Bad Gateway\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
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
