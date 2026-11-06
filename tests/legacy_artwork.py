"""Test-only entry point for the Python artwork.py, used as the default helper
by artwork_test.py while artwork.py exists.

It runs artwork.py's main() unchanged. When the documented test-only
overrides are set (artwork_test.py sets them only for its local TLS server),
it applies them the way the Rust helper does:

  FOAMY_LOCK_TEST_RESOLVE  JSON {"host": ["address", ...]}: replaces DNS; a
                           host missing from it does not resolve.
  FOAMY_LOCK_TEST_CONNECT  JSON {"address": "loopback-ip:port"}: a connection
                           to <address>:443, made after the address checks,
                           goes to that loopback endpoint instead; any other
                           connection is refused.

The CA for the fixture comes through the standard SSL_CERT_FILE.
"""
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import socket

spec = importlib.util.spec_from_file_location('artwork', Path(__file__).resolve().parents[1] / 'artwork.py')
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)

if os.environ.get('FOAMY_LOCK_TEST_RESOLVE'):
    table = json.loads(os.environ['FOAMY_LOCK_TEST_RESOLVE'])

    def getaddrinfo(host, port, *args, **kwargs):
        if host not in table:
            raise socket.gaierror(socket.EAI_NONAME, 'test resolver: unknown host')
        return [(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM, 6, '',
                 (address, port)) for address in table[host]]

    art.socket.getaddrinfo = getaddrinfo

if os.environ.get('FOAMY_LOCK_TEST_CONNECT'):
    endpoints = json.loads(os.environ['FOAMY_LOCK_TEST_CONNECT'])

    def create_connection(address, timeout=None, *args, **kwargs):
        host, port = address[0], address[1]
        target = endpoints.get(host) if port == 443 else None
        if target is None:
            raise ConnectionRefusedError('test connector: no endpoint')
        target_host, _, target_port = target.rpartition(':')
        target = ipaddress.ip_address(target_host.strip('[]'))
        if not target.is_loopback:
            raise ConnectionRefusedError('test connector: endpoint is not loopback')
        # A plain socket: socket.create_connection would ask the test resolver.
        sock = socket.socket(socket.AF_INET6 if target.version == 6 else socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(timeout)
            sock.connect((str(target), int(target_port)))
        except BaseException:
            sock.close()
            raise
        return sock

    art.socket.create_connection = create_connection

art.main()
