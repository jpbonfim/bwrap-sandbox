#!/usr/bin/env python3
"""
Lightweight, zero-dependency domain-filtering proxy and Unix socket relay.
Used by bwrap-sandbox.sh for kernel-enforced network isolation.

Modes:
  --proxy <unix_socket> <whitelist_file>  (Runs on Host: Filters HTTP/CONNECT by domain)
  --relay <tcp_port> <unix_socket>        (Runs in Sandbox: Bridges TCP 127.0.0.1 to Unix socket)
"""

import asyncio
import ctypes
import fnmatch
import ipaddress
import os
import signal
import socket
import sys

BUFFER_SIZE = 65536


DEFAULT_HTTP_PORTS = {80, 443}
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}


def setup_parent_death_signal():
    """
    Instructs the Linux kernel to send SIGTERM if the parent process terminates (even on kill -9).
    Prevents background proxy daemons from becoming orphaned zombies.
    """
    try:
        libc = ctypes.CDLL("libc.so.6")
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass


async def open_safe_connection(host, port):
    """
    Resolves the upstream host, validates IPs against SSRF/DNS Rebinding,
    and connects directly to the validated IP to prevent TOCTOU DNS Rebinding attacks.
    """
    if host.lower() in LOCAL_HOSTS:
        return await asyncio.open_connection("127.0.0.1", port)

    loop = asyncio.get_running_loop()
    try:
        addr_info = await loop.getaddrinfo(host, port, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
    except socket.gaierror as e:
        raise ConnectionError(f"DNS resolution failed for {host}: {e}")

    safe_ips = []
    for item in addr_info:
        ip_str = item[4][0]
        try:
            ip = ipaddress.ip_address(ip_str)
        except ValueError:
            continue
        if ip.is_loopback:
            raise PermissionError(f"SSRF/DNS Rebinding blocked: '{host}' resolved to loopback IP ({ip_str})")
        if ip.is_link_local:
            raise PermissionError(f"SSRF/DNS Rebinding blocked: '{host}' resolved to link-local/cloud metadata IP ({ip_str})")
        if ip.is_unspecified:
            raise PermissionError(f"SSRF/DNS Rebinding blocked: '{host}' resolved to unspecified IP ({ip_str})")
        if ip.is_private:
            raise PermissionError(f"SSRF blocked: '{host}' resolved to private network IP ({ip_str})")
        safe_ips.append(ip_str)

    if not safe_ips:
        raise ConnectionError(f"No valid IP addresses resolved for {host}")

    last_exc = None
    for ip_str in safe_ips:
        try:
            return await asyncio.open_connection(ip_str, port)
        except Exception as e:
            last_exc = e

    raise last_exc or ConnectionError(f"Failed to connect to {host}:{port}")


class WhitelistRule:
    def __init__(self, pattern_str):
        self.raw = pattern_str.strip().lower()
        self.host_pattern, self.allowed_ports = self._parse(self.raw)

    def _parse(self, s):
        # Strip scheme if user mistakenly wrote http:// or https://
        if s.startswith("https://"):
            s = s[8:]
        elif s.startswith("http://"):
            s = s[7:]
        # Strip path or trailing slashes
        s = s.split("/", 1)[0].strip()

        # Handle IPv6 brackets like [::1]:port or [::1]
        if s.startswith("["):
            parts = s.rsplit(":", 1)
            host_part = parts[0].strip("[]")
            port_part = parts[1] if len(parts) > 1 and not parts[1].endswith("]") else None
        elif s.count(":") > 1:
            # Naked IPv6 address without brackets (e.g. ::1 or 2001:db8::1)
            host_part = s
            port_part = None
        elif ":" in s:
            parts = s.split(":", 1)
            host_part = parts[0].strip()
            port_part = parts[1].strip()
        else:
            host_part = s.strip()
            port_part = None

        ports = self._parse_ports(port_part)
        return host_part.strip(), ports

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
        t_host = target_host.strip("[]").rstrip(".").lower()
        r_host = self.host_pattern.strip("[]").rstrip(".").lower()

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
    elif target.count(":") > 1:
        # Naked IPv6 without port
        host = target.strip("[]")
        port = default_port
    elif ":" in target:
        parts = target.split(":", 1)
        host = parts[0].strip()
        try:
            port = int(parts[1])
        except ValueError:
            port = default_port
    else:
        host = target.strip()
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

                try:
                    remote_r, remote_w = await open_safe_connection(host, port)
                except PermissionError as pe:
                    body = f"Blocked by sandbox security policy: {pe}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 403 Forbidden\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"X-Blocked-By: sandbox-filter\r\n"
                        f"X-Blocked-Reason: SSRF-DNS-Rebinding\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
                    await client_w.drain()
                    client_w.close()
                    return
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
                done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()

            else:
                # Plain HTTP (GET http://host:port/path HTTP/1.1)
                headers = [req_line]
                host_hdr = ""
                while True:
                    hdr = await client_r.readline()
                    if not hdr or hdr in (b"\r\n", b"\n"):
                        break
                    if hdr.lower().startswith(b"host:"):
                        host_hdr = hdr.decode("utf-8", "replace").split(":", 1)[1].strip()
                    elif not hdr.lower().startswith(b"connection:") and not hdr.lower().startswith(b"proxy-connection:"):
                        headers.append(hdr)

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

                # Force Connection: close to prevent lingering keep-alive sockets in plain HTTP
                headers.append(b"Connection: close\r\n\r\n")

                try:
                    remote_r, remote_w = await open_safe_connection(host, port)
                except PermissionError as pe:
                    body = f"Blocked by sandbox security policy: {pe}\n"
                    body_bytes = body.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 403 Forbidden\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body_bytes)}\r\n"
                        f"X-Blocked-By: sandbox-filter\r\n"
                        f"X-Blocked-Reason: SSRF-DNS-Rebinding\r\n"
                        f"Connection: close\r\n\r\n"
                    )
                    client_w.write(resp.encode("utf-8") + body_bytes)
                    await client_w.drain()
                    client_w.close()
                    return
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
                done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()

        except Exception:
            pass
        finally:
            try:
                client_w.close()
            except Exception:
                pass


async def run_proxy(sock_path, whitelist_path):
    setup_parent_death_signal()
    parent_pid = os.getppid()

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

    async def parent_watchdog():
        while not stop_event.is_set():
            await asyncio.sleep(1.0)
            if os.getppid() != parent_pid:
                stop_event.set()
                break

    watchdog_task = asyncio.create_task(parent_watchdog())

    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    finally:
        watchdog_task.cancel()
        server.close()
        await server.wait_closed()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


async def run_relay(tcp_port, sock_path):
    setup_parent_death_signal()
    parent_pid = os.getppid()

    async def handle_tcp(client_r, client_w):
        try:
            unix_r, unix_w = await asyncio.open_unix_connection(sock_path)
        except Exception:
            client_w.close()
            return

        t1 = asyncio.create_task(pipe(client_r, unix_w))
        t2 = asyncio.create_task(pipe(unix_r, client_w))
        done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()

    server = await asyncio.start_server(handle_tcp, "127.0.0.1", tcp_port)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    async def parent_watchdog():
        while not stop_event.is_set():
            await asyncio.sleep(1.0)
            if os.getppid() != parent_pid:
                stop_event.set()
                break

    watchdog_task = asyncio.create_task(parent_watchdog())

    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    finally:
        watchdog_task.cancel()
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
