"""Black-box tests of the artwork helper: it runs as a process, with the
environment Quickshell gives it, one JSON request line on standard input and
one JSON reply line on standard output.

FOAMY_HELPER is the helper's argv prefix as a JSON list (default: this
machine's bin/<arch>/foamy-lock-helper); the tests append "artwork" (or
"wallpaper <link>" for the background probe).
For the aarch64 build through qemu binfmt:
  FOAMY_HELPER='["bin/aarch64/foamy-lock-helper"]' python3 -I -B -m unittest discover -s tests -p artwork_test.py

Three kinds of tests:
- Requests: refused before any decoder runs (every architecture).
- Fake decoder: the helper runs in an outer bubblewrap mount namespace where
  /usr/bin/bwrap and /usr/bin/magick are test scripts. The fake bwrap
  records exactly how the helper launches the decoder (argv, environment,
  rlimits, inherited fds, the seccomp program, the private policy.xml) and
  answers with fixed pixels, too much output, a hang or a failure. Needs
  unprivileged user namespaces; runs for every architecture.
- Real decoder: real bwrap, ImageMagick and seccomp. Only for a helper of
  this machine's architecture (qemu-user has no seccomp, and the host's bwrap
  would install a foreign-architecture filter).

HTTPS goes to a local TLS server with a test CA (SSL_CERT_FILE) through the
helper's documented test-only overrides FOAMY_LOCK_TEST_RESOLVE (DNS answers)
and FOAMY_LOCK_TEST_CONNECT (the checked address -> a loopback endpoint).
"""
import fcntl
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import textwrap
import threading
import time
import unittest
import zlib

PLUGIN = Path(__file__).resolve().parents[1]
MAX_INPUT = 5 * 1024 * 1024
MAX_AVATAR_INPUT = 16 * 1024 * 1024
PIXEL_BYTES = 256 * 256 * 3
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
POLICY = '''<policymap>
  <policy domain="resource" name="width" value="4096"/>
  <policy domain="resource" name="height" value="4096"/>
  <policy domain="resource" name="memory" value="128MiB"/>
  <policy domain="resource" name="map" value="0"/>
  <policy domain="resource" name="disk" value="0"/>
  <policy domain="resource" name="thread" value="1"/>
  <policy domain="resource" name="time" value="2"/>
  <!-- ImageMagick counts internal working images, not only source frames. -->
  <policy domain="resource" name="list-length" value="8"/>
  <policy domain="delegate" rights="none" pattern="*"/>
  <policy domain="filter" rights="none" pattern="*"/>
  <policy domain="coder" rights="none" pattern="*"/>
  <policy domain="coder" rights="read" pattern="{PNG,JPEG,WEBP}"/>
  <policy domain="coder" rights="write" pattern="RGB"/>
  <policy domain="path" rights="none" pattern="@*"/>
</policymap>'''
# The decoder's seccomp policy: syscalls answered with EPERM, per architecture.
SECCOMP = {
    # clone, fork, vfork, ptrace, mount, unshare, setns, bpf, clone3
    'x86_64': (0xc000003e, {56, 57, 58, 101, 165, 272, 308, 321, 435}),
    # mount, unshare, ptrace, clone, setns, bpf, clone3
    'aarch64': (0xc00000b7, {40, 97, 117, 220, 268, 280, 435}),
}
RET_KILL_PROCESS, RET_EPERM, RET_ALLOW = 0x80000000, 0x00050001, 0x7fff0000


def helper_prefix():
    if os.environ.get('FOAMY_HELPER'):
        prefix = json.loads(os.environ['FOAMY_HELPER'])
    else:
        prefix = [str(PLUGIN / 'bin' / platform.machine() / 'foamy-lock-helper')]
    program = prefix[0] if '/' in prefix[0] else shutil.which(prefix[0])
    if not program:
        raise RuntimeError(f'helper program not found: {prefix[0]}')
    return [str(Path(program).resolve()), *prefix[1:]]


HELPER = helper_prefix()


def helper_machine():
    """The architecture the helper runs as: an ELF's e_machine, else this host's."""
    with open(HELPER[0], 'rb') as stream:
        header = stream.read(20)
    if header[:4] == b'\x7fELF':
        return {0x3e: 'x86_64', 0xb7: 'aarch64'}.get(struct.unpack_from('<H', header, 18)[0], 'unknown')
    return platform.machine()


MACHINE = helper_machine()
NATIVE = MACHINE == platform.machine()


def works(command):
    try:
        return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


NAMESPACES = works(['/usr/bin/bwrap', '--dev-bind', '/', '/', '--', '/usr/bin/true'])
REAL_DECODER = (NATIVE and NAMESPACES and Path('/usr/bin/magick').is_file()
                and works(['/usr/bin/bwrap', '--unshare-all', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/lib',
                           '/lib64', '--', '/usr/bin/true']))
needs_namespaces = unittest.skipUnless(NAMESPACES, 'unprivileged user namespaces are unavailable')
needs_real_decoder = unittest.skipUnless(
    REAL_DECODER, 'needs a native helper, bubblewrap with namespaces and ImageMagick')


def png(pixels, width=256, height=256):
    """A plain RGB PNG (test input; the helper's own output is checked by read_output)."""
    stride = width * 3
    rows = b''.join(b'\0' + pixels[i:i + stride] for i in range(0, len(pixels), stride))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (PNG_MAGIC + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def solid(rgb):
    return png(bytes(rgb) * 256 * 256)


def read_output(test, path):
    """Checks a generated thumbnail and returns its RGB pixels: exactly IHDR,
    IDAT and IEND, valid CRCs, 256x256 RGB8, filter 0 rows and a zlib stream
    of stored (uncompressed) blocks only."""
    data = Path(path).read_bytes()
    test.assertEqual(data[:8], PNG_MAGIC)
    offset, chunks = 8, []
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        kind, body = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        test.assertEqual(crc, zlib.crc32(kind + body), kind)
        chunks.append((kind, body))
        offset += 12 + length
    test.assertEqual(offset, len(data))
    test.assertEqual([kind for kind, _ in chunks], [b'IHDR', b'IDAT', b'IEND'])
    test.assertEqual(chunks[0][1], struct.pack('>IIBBBBB', 256, 256, 8, 2, 0, 0, 0))
    test.assertEqual(chunks[2][1], b'')
    stream = chunks[1][1]
    test.assertEqual(stream[0] & 0x0f, 8)
    test.assertEqual((stream[0] << 8 | stream[1]) % 31, 0)
    position = 2
    while True:
        header = stream[position]
        test.assertEqual((header >> 1) & 3, 0, 'only stored deflate blocks')
        size, inverse = struct.unpack_from('<HH', stream, position + 1)
        test.assertEqual(size ^ 0xffff, inverse)
        position += 5 + size
        if header & 1:
            break
    test.assertEqual(position + 4, len(stream))
    raw = zlib.decompress(stream)
    test.assertEqual(len(raw), 256 * 769)
    rows = [raw[i:i + 769] for i in range(0, len(raw), 769)]
    test.assertTrue(all(row[0] == 0 for row in rows))
    return b''.join(row[1:] for row in rows)


class Workspace(unittest.TestCase):
    """A private HOME and XDG_CACHE_HOME per test; the helper runs with the
    environment Quickshell gives it."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='foamy-artwork-test-')
        self.base = Path(self.temporary.name)
        self.cache = self.base / 'cache'
        self.artwork = self.cache / 'omarchy/foamy.lock/artwork'
        self.png = solid([34, 120, 156])

    def tearDown(self):
        self.temporary.cleanup()

    def environment(self, extra=None):
        return dict({'HOME': str(self.base), 'XDG_CACHE_HOME': str(self.cache), 'PATH': '/usr/bin',
                     'LANG': 'C.UTF-8'}, **(extra or {}))

    def run_helper(self, request, env=None, wrap=(), timeout=20, pass_fds=()):
        line = request if isinstance(request, bytes) else (json.dumps(request) + '\n').encode()
        started = time.monotonic()
        result = subprocess.run([*wrap, *HELPER, 'artwork'], input=line, capture_output=True,
                                env=self.environment(env), timeout=timeout, pass_fds=pass_fds)
        self.elapsed = time.monotonic() - started
        self.assertEqual(result.stderr, b'')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1, result.stdout)
        reply = json.loads(result.stdout)
        self.assertIsInstance(reply, dict)
        if reply.get('ok') is True:
            self.assertEqual(set(reply), {'ok', 'path'})
        else:
            self.assertEqual(reply.get('ok'), False, reply)
            self.assertEqual(set(reply), {'ok', 'error'})
            self.assertRegex(reply['error'], r'^[a-z-]{1,48}$')
        return reply

    def error(self, request, **kwargs):
        reply = self.run_helper(request, **kwargs)
        self.assertFalse(reply['ok'], reply)
        return reply['error']

    def write(self, name, data):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def local(self, path, roots=None):
        return {'url': Path(path).as_uri(), 'roots': [str(self.base)] if roots is None else roots}

    def leftovers(self):
        return sorted(str(p.relative_to(self.base)) for p in self.base.rglob('*')
                      if p.name.startswith(('.job-', '.avatar-')))


class Requests(Workspace):
    def test_request_framing(self):
        self.assertEqual(self.error(b'[]\n'), 'invalid-request')
        self.assertEqual(self.error(b'"text"\n'), 'invalid-request')
        self.assertEqual(self.error(b'{not json}\n'), 'source-unavailable')
        self.assertEqual(self.error(b''), 'source-unavailable')
        request = json.dumps({'url': 'http://example.com/a'})
        # 32768 bytes is the limit including the newline; later lines are ignored.
        self.assertEqual(self.error((request.ljust(32767) + '\n').encode()), 'unsupported-scheme')
        self.assertEqual(self.error((request.ljust(32768) + '\n').encode()), 'invalid-request')
        self.assertEqual(self.error((request + '\n{"kind": "avatar"}\n').encode()), 'unsupported-scheme')

    def test_url_and_options(self):
        cases = [
            ('http://example.com/a', 'unsupported-scheme'), ('data:image/png,abc', 'unsupported-scheme'),
            ('ftp://example.com/a', 'unsupported-scheme'), ('example.com/a', 'unsupported-scheme'),
            ('https://u:p@example.com/a', 'invalid-url'), ('https://@example.com/a', 'invalid-url'),
            ('https://example.com:8080/a', 'invalid-https-url'), ('https:///a', 'invalid-https-url'),
            ('https://example.com/a#fragment', 'invalid-url'), ('file://host/tmp/a', 'invalid-file-url'),
            ('file:///tmp/a?v=1', 'invalid-file-url'), ('https://example.com/\nheader', 'invalid-url'),
            ('https://example.com/ a', 'invalid-url'), ('https://example.com/\\x', 'invalid-url'),
            ('https://example.com/é', 'invalid-url'), ('x' * 8193, 'invalid-url'), ('', 'invalid-url'),
            ('https://example.com:99999/a', 'invalid-url'), ('https://example.com:4a/a', 'invalid-url'),
            ('https://[::1/a', 'invalid-url'), ('https://example.com]/a', 'invalid-url'),
            ('https://example.com:443/a', 'host-not-allowed'), ('https://example.com:/a', 'host-not-allowed'),
            ('https://example.com/a#', 'host-not-allowed'), ('HTTPS://Example.COM/a', 'host-not-allowed'),
        ]
        for url, code in cases:
            with self.subTest(url=url[:60]):
                self.assertEqual(self.error({'url': url}), code)
        for value in [None, 5, ['https://example.com/a']]:
            self.assertEqual(self.error({'url': value}), 'invalid-url')
        self.assertEqual(self.error({}), 'invalid-url')
        hosts = [['*.example.com'], ['localhost'], ['127.0.0.1'], ['EXAMPLE.COM'], ['a' * 64 + '.com'],
                 ['example.com.'], ['-a.example.com'], ['example.com\n'], [5], 'example.com', None,
                 ['a.example.com'] * 33, ['x.' * 126 + 'com']]
        for value in hosts:
            with self.subTest(hosts=str(value)[:60]):
                self.assertEqual(self.error({'url': 'http://x', 'hosts': value}), 'invalid-hosts')
        roots = [['/'], ['/tmp/../home'], ['relative'], ['/tmp/\0'], ['/' + 'a' * 4096], [5], '/tmp', None,
                 ['/tmp'] * 17, ['/tmp/..']]
        for value in roots:
            with self.subTest(roots=str(value)[:60]):
                self.assertEqual(self.error({'url': 'http://x', 'roots': value}), 'invalid-roots')
        accepted = {'url': 'http://x', 'hosts': ['images.example.com', 'a' * 63 + '.b2.example'] + ['c.example'] * 30,
                    'roots': ['/tmp/artwork', '/' + 'a' * 4095, '//', '/.'] + ['/tmp'] * 12}
        self.assertEqual(self.error(accepted), 'unsupported-scheme')
        # Hosts are checked before the URL.
        self.assertEqual(self.error({'url': 5, 'hosts': ['EXAMPLE.COM']}), 'invalid-hosts')
        self.assertEqual(self.error({'url': 'https://example.com/', 'hosts': ['images.example.com']}),
                         'host-not-allowed')

    def test_local_files_are_confined_snapshots(self):
        allowed = self.base / 'allowed'
        allowed.mkdir()
        source = allowed / 'cover.png'
        source.write_bytes(self.png)
        outside = self.write('secret.png', self.png)
        (allowed / 'link.png').symlink_to(outside)
        (allowed / 'directory').symlink_to(self.base, target_is_directory=True)
        (allowed / 'sub').mkdir()
        os.mkfifo(allowed / 'fifo')
        (self.base / 'linked-root').symlink_to(allowed, target_is_directory=True)
        roots = [str(allowed)]
        cases = [
            (outside.as_uri(), roots, 'file-outside-roots'),
            ((allowed / 'link.png').as_uri(), roots, 'source-unavailable'),
            ((allowed / 'directory' / 'secret.png').as_uri(), roots, 'source-unavailable'),
            ((allowed / 'fifo').as_uri(), roots, 'not-owned-regular-file'),
            ((allowed / 'sub').as_uri(), roots, 'source-unavailable'),
            ((allowed / 'missing.png').as_uri(), roots, 'source-unavailable'),
            ('file://' + str(allowed) + '//cover.png', roots, 'source-unavailable'),
            ('file://' + str(allowed) + '/sub/../cover.png', roots, 'invalid-file-path'),
            ('file://' + str(allowed) + '/%2e%2e/secret.png', roots, 'invalid-file-path'),
            ('file://' + str(allowed) + '/a%00.png', roots, 'invalid-file-path'),
            ('file://' + str(allowed) + '/%ff.png', roots, 'source-unavailable'),
            ('file:relative.png', roots, 'invalid-file-path'),
            (source.as_uri(), [str(self.base / 'linked-root')], 'file-outside-roots'),
            ((self.base / 'linked-root' / 'cover.png').as_uri(), [str(self.base / 'linked-root')],
             'source-unavailable'),
            ('file:///dev/null', ['/dev'], 'not-owned-regular-file'),
        ]
        for url, roots_for_case, code in cases:
            with self.subTest(url=url):
                self.assertEqual(self.error({'url': url, 'roots': roots_for_case}), code)
        with source.open('wb') as stream:
            stream.truncate(MAX_INPUT + 1)
        self.assertEqual(self.error(self.local(source, roots)), 'input-too-large')
        self.assertEqual(self.leftovers(), [])

    def test_static_formats_only(self):
        actl = struct.pack('>I', 8) + b'acTL' + b'\0' * 8 + b'\0' * 4
        cases = [
            (b'<svg xmlns="http://www.w3.org/2000/svg"/>', 'unsupported-format'),
            (b'GIF89a' + b'\0' * 32, 'unsupported-format'), (b'', 'unsupported-format'),
            (self.png[:33] + actl + self.png[33:], 'animated-image'),
            (b'RIFF' + b'\0' * 4 + b'WEBPANIM' + b'\0' * 4, 'animated-image'),
            (b'RIFF' + b'\0' * 4 + b'WEBPVP8 ' + struct.pack('<I', 2) + b'\0\0' + b'ANMF' + b'\0' * 4,
             'animated-image'),
            (b'RIFF' + b'\0' * 4 + b'WEBPVP8X' + struct.pack('<I', 10) + b'\x02' + b'\0' * 9, 'animated-image'),
        ]
        for index, (data, code) in enumerate(cases):
            with self.subTest(index=index):
                self.assertEqual(self.error(self.local(self.write(f'in{index}', data))), code)
        self.assertEqual(self.leftovers(), [])

    def test_cache_must_be_private_and_free(self):
        source = self.write('cover.png', self.png)
        self.artwork.mkdir(parents=True, mode=0o700)
        self.artwork.chmod(0o750)
        self.assertEqual(self.error(self.local(source)), 'unsafe-cache')
        self.artwork.chmod(0o700)
        with open(self.artwork / '.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.error(self.local(source)), 'cache-busy')
        shutil.rmtree(self.artwork)
        elsewhere = self.base / 'elsewhere'
        elsewhere.mkdir(mode=0o700)
        self.artwork.symlink_to(elsewhere, target_is_directory=True)
        self.assertEqual(self.error(self.local(source)), 'unsafe-cache')
        self.artwork.unlink()
        self.artwork.parent.rmdir()
        (self.cache / 'omarchy/foamy.lock').symlink_to(elsewhere, target_is_directory=True)
        face = self.write('face.png', self.png)
        self.assertEqual(self.error({'kind': 'avatar', 'path': str(face)}), 'unsafe-cache')

    def test_avatar_rejects_special_missing_large_and_foreign_formats(self):
        fifo = self.base / 'fifo'
        os.mkfifo(fifo)
        large = self.base / 'large.png'
        with large.open('wb') as stream:
            stream.truncate(MAX_AVATAR_INPUT + 1)
        svg = self.write('face.svg', b'<svg xmlns="http://www.w3.org/2000/svg"/>')
        (self.base / 'dangling').symlink_to(self.base / 'nowhere')
        for path, code in [(str(fifo), 'not-regular-file'), (str(self.base / 'missing'), 'avatar-missing'),
                           (str(self.base / 'dangling'), 'avatar-missing'), (str(large), 'input-too-large'),
                           (str(svg), 'unsupported-format'), ('relative.png', 'invalid-avatar-path'),
                           (str(self.base), 'not-regular-file'), ('/' + 'a' * 4096, 'invalid-avatar-path'),
                           ('/tmp/\0', 'invalid-avatar-path'), (5, 'invalid-avatar-path'),
                           (None, 'invalid-avatar-path')]:
            with self.subTest(code=code, path=str(path)[:40]):
                self.assertEqual(self.error({'kind': 'avatar', 'path': path}), code)
        self.assertEqual(self.error({'kind': 'avatar'}), 'invalid-avatar-path')
        self.assertEqual(self.leftovers(), [])


class Wallpaper(unittest.TestCase):
    """`wallpaper <link>`: the lock's background probe (argv in, one JSON line out)."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='foamy-wallpaper-test-')
        self.base = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def probe(self, *args):
        result = subprocess.run([*HELPER, *args], stdin=subprocess.DEVNULL, capture_output=True,
                                env={'PATH': '/usr/bin', 'LANG': 'C.UTF-8'}, timeout=10)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1, result.stdout)
        reply = json.loads(result.stdout)
        if reply.get('ok') is True:
            self.assertEqual(set(reply), {'ok', 'path', 'signature'})
        else:
            self.assertEqual(set(reply), {'ok', 'error'}, reply)
        return reply

    def test_resolves_like_readlink_and_stat(self):
        current = self.base / 'state/omarchy/current'
        current.mkdir(parents=True)
        theme = self.base / 'themes/one'
        theme.mkdir(parents=True)
        image = theme / 'wall # paper.png'
        image.write_bytes(b'one')
        (current / 'theme').symlink_to('../../../themes/one')
        link = current / 'background'
        link.symlink_to('theme/wall # paper.png')
        reply = self.probe('wallpaper', str(link))
        self.assertEqual(reply['path'], str(image))
        expected = subprocess.check_output(['readlink', '-f', '--', str(link)], text=True).strip()
        self.assertEqual(reply['path'], expected)
        self.assertEqual(self.probe('wallpaper', str(link)), reply, 'stable while unchanged')
        os.utime(image, ns=(10**18, 10**18))
        touched = self.probe('wallpaper', str(link))
        self.assertNotEqual(touched['signature'], reply['signature'])
        image.write_bytes(b'rewritten')
        self.assertNotEqual(self.probe('wallpaper', str(link))['signature'], touched['signature'])

    def test_failures(self):
        (self.base / 'dangling').symlink_to(self.base / 'nowhere')
        (self.base / 'directory').mkdir()
        os.mkfifo(self.base / 'fifo')
        (self.base / 'loop').symlink_to(self.base / 'loop')
        for args, code in [(['wallpaper', str(self.base / 'dangling')], 'wallpaper-missing'),
                           (['wallpaper', str(self.base / 'missing')], 'wallpaper-missing'),
                           (['wallpaper', str(self.base / 'loop')], 'wallpaper-missing'),
                           (['wallpaper', str(self.base / 'directory')], 'not-regular-file'),
                           (['wallpaper', str(self.base / 'fifo')], 'not-regular-file'),
                           (['wallpaper', 'relative'], 'invalid-request'),
                           (['wallpaper'], 'invalid-request'),
                           (['wallpaper', str(self.base), 'extra'], 'invalid-request'),
                           (['wallpapers', str(self.base)], 'invalid-request')]:
            with self.subTest(args=args[:1] + [Path(a).name for a in args[1:]]):
                self.assertEqual(self.probe(*args), {'ok': False, 'error': code})


class Server:
    """A local HTTPS server for images.example.com and cdn.example.com,
    signed by a test CA, with programmable routes."""

    def __init__(self, directory):
        self.ca = directory / 'ca.pem'
        self.other_ca = directory / 'other-ca.pem'
        openssl = ['/usr/bin/openssl']
        quiet = {'check': True, 'stdout': subprocess.DEVNULL, 'stderr': subprocess.DEVNULL, 'timeout': 20}
        for name in ['ca', 'other-ca']:
            subprocess.run([*openssl, 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                            '-nodes', '-keyout', str(directory / f'{name}.key'), '-out', str(directory / f'{name}.pem'),
                            '-days', '2', '-subj', f'/CN=Foamy {name} test',
                            '-addext', 'basicConstraints=critical,CA:TRUE',
                            '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
                            '-addext', 'subjectKeyIdentifier=hash'], **quiet)
        (directory / 'leaf.ext').write_text(
            'subjectAltName=DNS:images.example.com,DNS:cdn.example.com\nbasicConstraints=CA:FALSE\n'
            'keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
            'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n')
        subprocess.run([*openssl, 'req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
                        '-keyout', str(directory / 'leaf.key'), '-out', str(directory / 'leaf.csr'),
                        '-subj', '/CN=images.example.com'], **quiet)
        subprocess.run([*openssl, 'x509', '-req', '-in', str(directory / 'leaf.csr'), '-CA', str(self.ca),
                        '-CAkey', str(directory / 'ca.key'), '-set_serial', '7', '-days', '1',
                        '-extfile', str(directory / 'leaf.ext'), '-out', str(directory / 'leaf.pem')], **quiet)
        self.routes = {}
        self.requests = []
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                server.requests.append({'path': self.path, 'line': self.requestline,
                                        'headers': list(self.headers.items())})
                route = server.routes.get(self.path)
                if route is None:
                    self.send_response(404)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                route(self)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.httpd.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(directory / 'leaf.pem', directory / 'leaf.key')
        self.httpd.socket = context.wrap_socket(self.httpd.socket, server_side=True)
        self.endpoint = '127.0.0.1:%d' % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def environment(self, resolve=None, connect=None, ca=None):
        return {'SSL_CERT_FILE': str(ca or self.ca),
                'FOAMY_LOCK_TEST_RESOLVE': json.dumps(resolve or {'images.example.com': ['8.8.8.8'],
                                                                  'cdn.example.com': ['8.8.8.8']}),
                'FOAMY_LOCK_TEST_CONNECT': json.dumps(connect or {'8.8.8.8': self.endpoint})}


def respond(status, headers=(), body=b'', chunked=False, delay=0):
    def route(handler):
        if delay:
            time.sleep(delay)
        if chunked:
            handler.protocol_version = 'HTTP/1.1'
        try:
            handler.send_response(status)
            for name, value in headers:
                handler.send_header(name, value)
            if chunked:
                handler.send_header('Transfer-Encoding', 'chunked')
            handler.end_headers()
            if chunked:
                for offset in range(0, len(body), 40000):
                    piece = body[offset:offset + 40000]
                    handler.wfile.write(b'%x;ext=1\r\n' % len(piece) + piece + b'\r\n')
                handler.wfile.write(b'0\r\nTrailer: x\r\n\r\n')
                handler.close_connection = True
            else:
                handler.wfile.write(body)
        except OSError:
            handler.close_connection = True
    return route


def public(address):
    """The helper's address rule, as artwork.py had it (Python 3.14 ipaddress)."""
    ip = ipaddress.ip_address(address)
    return not (not ip.is_global or ip.is_multicast or ip.is_unspecified
                or getattr(ip, 'ipv4_mapped', None) is not None
                or getattr(ip, 'sixtofour', None) is not None
                or getattr(ip, 'teredo', None) is not None
                or (ip.version == 6 and ip in ipaddress.ip_network('64:ff9b::/96')))


class HttpsBase(Workspace):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='foamy-artwork-tls-')
        cls.server = Server(Path(cls.directory.name))

    @classmethod
    def tearDownClass(cls):
        cls.server.close()
        cls.directory.cleanup()

    def setUp(self):
        super().setUp()
        self.server.routes.clear()
        self.server.requests.clear()

    def fetch(self, url, hosts=('images.example.com', 'cdn.example.com'), **environment):
        return self.run_helper({'url': url, 'hosts': list(hosts)}, env=self.server.environment(**environment))

    def paths(self):
        return [request['path'] for request in self.server.requests]


class Https(HttpsBase):
    def test_request_is_minimal_and_pinned(self):
        self.assertEqual(self.fetch('https://IMAGES.example.com/cover.png?size=600&v=2#')['error'], 'http-error')
        self.assertEqual(self.fetch('https://images.example.com')['error'], 'http-error')
        self.assertEqual(self.fetch('https://images.example.com/a?')['error'], 'http-error')
        self.assertEqual(self.paths(), ['/cover.png?size=600&v=2', '/', '/a'])
        request = self.server.requests[0]
        self.assertEqual(request['line'], 'GET /cover.png?size=600&v=2 HTTP/1.1')
        self.assertEqual(request['headers'], [
            ('Host', 'images.example.com'), ('Accept', 'image/png,image/jpeg,image/webp'),
            ('Accept-Encoding', 'identity'), ('User-Agent', 'FoamyLock/1.0'), ('Connection', 'close')])
        # Only the first checked address is used: no fallback to another.
        self.server.requests.clear()
        first = {'images.example.com': ['8.8.4.4', '8.8.8.8']}
        self.assertEqual(self.fetch('https://images.example.com/x', resolve=first,
                                    connect={'8.8.4.4': self.server.endpoint})['error'], 'http-error')
        second = {'images.example.com': ['8.8.8.8', '8.8.4.4']}
        self.assertEqual(self.fetch('https://images.example.com/y', resolve=second,
                                    connect={'8.8.4.4': self.server.endpoint})['error'], 'source-unavailable')
        self.assertEqual(self.paths(), ['/x'])

    def test_tls_is_verified_against_the_hostname(self):
        self.assertEqual(self.fetch('https://wrong.example.com/a', hosts=['wrong.example.com'],
                                    resolve={'wrong.example.com': ['8.8.8.8']})['error'], 'source-unavailable')
        self.assertEqual(self.fetch('https://images.example.com/a', ca=self.server.other_ca)['error'],
                         'source-unavailable')
        self.assertEqual(self.server.requests, [])

    def test_dns_rejects_nonpublic_and_mixed_answers(self):
        refused = ['127.0.0.1', '10.0.0.1', '169.254.169.254', '0.0.0.0', '224.0.0.1', '::1', 'fc00::1',
                   'fe80::1', '::ffff:8.8.8.8', '2002:0808:0808::1', '64:ff9b::7f00:1']
        more = ['100.64.0.1', '100.127.255.255', '172.16.0.1', '172.31.255.255', '172.32.0.1', '192.0.0.8',
                '192.0.0.9', '192.0.0.10', '192.0.0.170', '192.0.2.1', '192.88.99.1', '192.168.1.1',
                '198.18.0.1', '198.51.100.1', '203.0.113.1', '240.0.0.1', '255.255.255.255', '239.255.255.255',
                '1.1.1.1', '9.9.9.9', '11.0.0.1', '2606:4700::1111', '2001:db8::1', '2001::1', '2001:1::1',
                '2001:1::3', '2001:3::1', '2001:4:112::1', '2001:20::1', '2001:30::1', '2001:200::1',
                '3fff::1', '4000::1', 'fec0::1', 'ff02::1', '::', '::2', '100::1', '64:ff9b:1::1',
                '64:ff9b::1:0:0', '::8.8.8.8', '2a00:1450:4001::200e']
        for address in refused + more:
            with self.subTest(address=address):
                error = self.fetch('https://images.example.com/a',
                                   resolve={'images.example.com': ['8.8.8.8', address]})['error']
                if address in refused or not public(address):
                    self.assertEqual(error, 'non-public-address')
                else:
                    self.assertEqual(error, 'http-error')
        self.assertEqual(self.fetch('https://images.example.com/a', resolve={'images.example.com': []})['error'],
                         'dns-failed')
        self.assertEqual(self.fetch('https://images.example.com/a', resolve={'other.example': ['8.8.8.8']})['error'],
                         'source-unavailable')

    def test_bounded_http_and_redirect_policy(self):
        self.server.routes.update({
            '/big-length': respond(200, [('Content-Length', str(MAX_INPUT + 1))], b'x'),
            '/bad-length': respond(200, [('Content-Length', 'abc')], b'x'),
            '/two-lengths': respond(200, [('Content-Length', '1'), ('Content-Length', '1')], b'x'),
            '/big-body': respond(200, [], b'x' * (MAX_INPUT + 1)),
            '/big-chunked': respond(200, [], b'x' * (MAX_INPUT + 1), chunked=True),
            '/gzip': respond(200, [('Content-Encoding', 'gzip')], b'x'),
            '/identity-space': respond(200, [('Content-Encoding', 'identity ')], b'x'),
            '/teapot': respond(418),
            '/early-hints': respond(103),
            '/other-host': respond(302, [('Location', 'https://other.example/a')]),
            '/plain-http': respond(302, [('Location', 'http://images.example.com/a')]),
            '/file': respond(301, [('Location', 'file:///etc/passwd')]),
            '/fragment': respond(307, [('Location', '/a#x')]),
            '/space': respond(308, [('Location', '/a b')]),
            '/no-location': respond(302),
            '/loop': respond(303, [('Location', '/loop')]),
            '/text': respond(200, [('Content-Length', '5')], b'hello'),
        })
        expected = {
            '/big-length': 'input-too-large', '/bad-length': 'input-too-large', '/two-lengths': 'input-too-large',
            '/big-body': 'input-too-large', '/big-chunked': 'input-too-large', '/gzip': 'encoded-response',
            '/identity-space': 'encoded-response', '/teapot': 'http-error', '/early-hints': 'http-error',
            '/other-host': 'host-not-allowed', '/plain-http': 'unsupported-scheme', '/file': 'host-not-allowed',
            '/fragment': 'invalid-url', '/space': 'invalid-url', '/no-location': 'redirect-limit',
            '/loop': 'redirect-limit', '/text': 'unsupported-format',
        }
        for path, code in expected.items():
            with self.subTest(path=path):
                self.server.requests.clear()
                self.assertEqual(self.fetch('https://images.example.com' + path)['error'], code)
                if path == '/loop':
                    self.assertEqual(self.paths(), ['/loop'] * 3)
        self.assertEqual(self.leftovers(), [])

    def test_redirect_rechecks_dns_before_connecting(self):
        self.server.routes['/hop'] = respond(302, [('Location', 'https://cdn.example.com/b')])
        resolve = {'images.example.com': ['8.8.8.8'], 'cdn.example.com': ['127.0.0.1']}
        self.assertEqual(self.fetch('https://images.example.com/hop', resolve=resolve)['error'], 'non-public-address')
        self.assertEqual(self.paths(), ['/hop'])

    def test_fetch_has_a_deadline(self):
        self.server.routes['/slow'] = respond(200, [('Content-Length', '1')], b'x', delay=7)
        self.assertEqual(self.fetch('https://images.example.com/slow')['error'], 'fetch-timeout')
        self.assertGreater(self.elapsed, 4.5)
        self.assertLess(self.elapsed, 6.5)


class TricklingTls:
    """A raw TLS endpoint for images.example.com and cdn.example.com that
    sends one TLS-record byte every `gap` seconds: in the handshake (a record
    header, then the record one byte at a time), or, after a normal handshake
    and response head, in the records that carry the body. A TLS library
    reads the socket many times for one such record."""

    def __init__(self, directory, mode, gap=0.5):
        self.mode, self.gap = mode, gap
        self.requests = []
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(directory / 'leaf.pem', directory / 'leaf.key')
        self.listener = socket.create_server(('127.0.0.1', 0))
        self.listener.settimeout(0.2)
        self.endpoint = '127.0.0.1:%d' % self.listener.getsockname()[1]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)
        self.listener.close()

    def serve(self):
        while not self.stop.is_set():
            try:
                peer, _ = self.listener.accept()
            except OSError:
                continue
            threading.Thread(target=self.handle, args=(peer,), daemon=True).start()

    def trickle(self, peer, data):
        for byte in data:
            if self.stop.wait(self.gap):
                return
            peer.sendall(bytes([byte]))

    def handle(self, peer):
        with peer:
            peer.settimeout(10)
            try:
                if self.mode == 'handshake':
                    peer.recv(65536)
                    # A 16 KiB handshake record that would take over two hours.
                    peer.sendall(b'\x16\x03\x03\x40\x00')
                    self.trickle(peer, bytes(16384))
                else:
                    self.respond(peer)
            except (OSError, ssl.SSLError):
                pass

    def respond(self, peer):
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = self.context.wrap_bio(incoming, outgoing, server_side=True)

        def flush():
            data = outgoing.read()
            if data:
                peer.sendall(data)

        def feed():
            data = peer.recv(65536)
            if not data:
                raise ConnectionError('closed')
            incoming.write(data)

        while True:
            try:
                tls.do_handshake()
                break
            except ssl.SSLWantReadError:
                flush()
                feed()
        flush()
        request = b''
        while b'\r\n\r\n' not in request:
            try:
                request += tls.read(65536)
            except ssl.SSLWantReadError:
                flush()
                feed()
        self.requests.append(request.split(b'\r\n', 1)[0].decode('latin-1'))
        flush()
        tls.write(b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n')
        flush()
        tls.write(b'x' * 100)
        self.trickle(peer, outgoing.read())


class HttpsTrickle(HttpsBase):
    """One 5 s budget for the whole fetch, however many socket reads the TLS
    layer makes: a peer trickling TLS-record bytes is `fetch-timeout` at
    5 s, not `job-timeout` at 9 s. (artwork.py had an independent 5 s
    ITIMER_REAL timer for this.)"""

    def trickler(self, mode):
        trickler = TricklingTls(Path(self.directory.name), mode)
        self.addCleanup(trickler.close)
        return trickler

    def assert_fetch_timeout(self, reply):
        self.assertEqual(reply, {'ok': False, 'error': 'fetch-timeout'})
        self.assertGreater(self.elapsed, 4.5)
        self.assertLess(self.elapsed, 6.5)

    def test_a_trickled_handshake_is_a_fetch_timeout(self):
        trickler = self.trickler('handshake')
        self.assert_fetch_timeout(self.fetch('https://images.example.com/a',
                                             connect={'8.8.8.8': trickler.endpoint}))

    def test_a_trickled_body_after_a_redirect_is_a_fetch_timeout(self):
        trickler = self.trickler('body')
        self.server.routes['/hop'] = respond(302, [('Location', 'https://cdn.example.com/body')])
        resolve = {'images.example.com': ['8.8.8.8'], 'cdn.example.com': ['8.8.4.4']}
        connect = {'8.8.8.8': self.server.endpoint, '8.8.4.4': trickler.endpoint}
        self.assert_fetch_timeout(self.fetch('https://images.example.com/hop', resolve=resolve, connect=connect))
        self.assertEqual(self.paths(), ['/hop'])
        self.assertEqual(trickler.requests, ['GET /body HTTP/1.1'])


FAKE_BWRAP ='''#!/usr/bin/python3 -I
import ctypes, hashlib, json, os, resource, subprocess, sys, time
STATE = {state!r}
PROBE = {probe!r}


def open_fds():
    found = []
    for name in os.listdir('/proc/self/fd'):
        try:
            found.append([int(name), os.readlink('/proc/self/fd/' + name)])
        except OSError:
            pass
    return sorted(found)


def exec_environment():
    # The environment as executed (Python itself may add LC_CTYPE later).
    raw = open('/proc/self/environ', 'rb').read().split(b'\\0')
    return dict(item.decode().split('=', 1) for item in raw if item)


record = {{'fds': open_fds(), 'argv': sys.argv, 'pid': os.getpid(), 'ppid': os.getppid(),
          'env': exec_environment(), 'cwd': os.getcwd(),
          'rlimits': {{name: list(resource.getrlimit(getattr(resource, 'RLIMIT_' + name)))
                      for name in ['AS', 'CPU', 'FSIZE', 'CORE', 'NOFILE']}}}}
signal_number = ctypes.c_int(0)
ctypes.CDLL(None).prctl(2, ctypes.byref(signal_number), 0, 0, 0)
record['pdeathsig'] = signal_number.value
record['sigblk'] = [line.split()[1] for line in open('/proc/self/status') if line.startswith('SigBlk')][0]
argv = sys.argv
seccomp = int(argv[argv.index('--seccomp') + 1]) if '--seccomp' in argv else None
if seccomp is not None:
    record['seccomp'] = os.pread(seccomp, 1 << 16, 0).hex()
for index, option in enumerate(argv[:-2]):
    if option == '--ro-bind' and argv[index + 2] == '/etc/ImageMagick-7/policy.xml':
        record['policy'] = open(argv[index + 1]).read()
    if option == '--ro-bind' and argv[index + 2] == '/input':
        record['input_sha256'] = hashlib.sha256(open(argv[index + 1], 'rb').read()).hexdigest()
        record['staging_mode'] = os.stat(os.path.dirname(argv[index + 1])).st_mode & 0o777
with open(STATE + '/records/%d.json' % time.time_ns(), 'w') as stream:
    json.dump(record, stream)
mode = json.load(open(STATE + '/mode.json'))
kind = mode['mode']
if kind == 'pixels':
    os.write(1, bytes(mode['rgb']) * (mode.get('bytes', 196608) // 3))
    sys.exit(mode.get('exit', 0))
if kind == 'flood':
    try:
        os.write(1, b'x' * 250000)
    except OSError:
        pass
    sys.exit(0)
if kind == 'sleep':
    time.sleep(mode['seconds'])
    sys.exit(0)
if kind == 'probe':
    command = [STATE + '/real-bwrap'] + argv[1:argv.index('/usr/bin/magick')]
    result = subprocess.run(command + ['/usr/bin/python3', '-I', '-c', PROBE], capture_output=True,
                            pass_fds=(seccomp,), timeout=2.5)
    with open(STATE + '/probe.json', 'w') as stream:
        json.dump({{'rc': result.returncode, 'stdout': result.stdout.decode(errors='replace'),
                   'stderr': result.stderr.decode(errors='replace')[:2000]}}, stream)
sys.exit(1)
'''

FAKE_MAGICK = '''#!/usr/bin/python3 -I
import json, sys
with open({state!r} + '/magick-ran', 'a') as stream:
    stream.write(json.dumps(sys.argv) + '\\n')
sys.exit(1)
'''

# Runs as the decoder inside the real sandbox (x86_64): each check answers
# EPERM only if the seccomp filter denies it (otherwise EINVAL, EIO, EBADF...).
PROBE = textwrap.dedent('''\
    import ctypes, json, os, socket
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    def raw(number, *args):
        ctypes.set_errno(0)
        result = libc.syscall(ctypes.c_long(number), *[ctypes.c_long(a) for a in args])
        return 0 if result >= 0 else ctypes.get_errno()
    out = {}
    try:
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        os.waitpid(pid, 0)
        out['fork'] = 0
    except OSError as error:
        out['fork'] = error.errno
    try:
        os.unshare(os.CLONE_NEWUSER)
        out['unshare'] = 0
    except OSError as error:
        out['unshare'] = error.errno
    out['clone'] = raw(56, 0x10000, 0, 0, 0, 0)
    out['clone3'] = raw(435, 0, 0)
    out['ptrace'] = raw(101, -1, 0, 0, 0)
    out['setns'] = raw(308, -1, 0)
    out['getpid'] = raw(39)
    try:
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM).connect(('192.0.2.1', 9))
        out['network'] = 0
    except OSError as error:
        out['network'] = error.errno
    try:
        open('/written', 'w')
        out['write'] = 0
    except OSError as error:
        out['write'] = error.errno
    raw_environment = open('/proc/self/environ', 'rb').read().split(b'\\0')
    out['env'] = dict(item.decode().split('=', 1) for item in raw_environment if item)
    out['cwd'] = os.getcwd()
    out['caps'] = sorted({line.split()[1] for line in open('/proc/self/status')
                          if line.startswith(('CapEff', 'CapPrm', 'CapBnd', 'CapAmb'))})
    out['policy'] = open('/etc/ImageMagick-7/policy.xml').read()
    out['input'] = len(open('/input', 'rb').read())
    print(json.dumps(out), flush=True)
    raw(0x40000000 | 39)
    print('survived', flush=True)
''')


def expected_argv(kind, policy, source, fd):
    return ['/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session', '--cap-drop', 'ALL',
            '--ro-bind', '/usr', '/usr', '--symlink', 'usr/lib', '/lib', '--symlink', 'usr/lib', '/lib64',
            '--symlink', 'usr/bin', '/bin', '--proc', '/proc', '--dev', '/dev', '--dir', '/etc',
            '--dir', '/etc/ImageMagick-7', '--ro-bind', policy, '/etc/ImageMagick-7/policy.xml',
            '--ro-bind', source, '/input', '--chdir', '/', '--clearenv', '--setenv', 'PATH', '/usr/bin',
            '--setenv', 'HOME', '/nonexistent', '--setenv', 'MAGICK_CONFIGURE_PATH', '/etc/ImageMagick-7',
            '--setenv', 'OMP_NUM_THREADS', '1', '--remount-ro', '/', '--seccomp', fd,
            '/usr/bin/magick', kind + ':/input', '-auto-orient', '-thumbnail', '256x256^', '-gravity', 'center',
            '-extent', '256x256', '-background', '#171b26', '-alpha', 'remove', '-alpha', 'off',
            '-colorspace', 'sRGB', '-depth', '8', 'RGB:-']


def run_bpf(program, number, arch):
    """A classic BPF interpreter for seccomp programs (struct seccomp_data)."""
    data = struct.pack('=IIQ6Q', number, arch, 0, *([0] * 6))
    instructions = [struct.unpack_from('=HBBI', program, offset) for offset in range(0, len(program), 8)]
    accumulator, pc = 0, 0
    for _ in range(10000):
        code, jt, jf, k = instructions[pc]
        pc += 1
        if code == 0x20:
            accumulator = struct.unpack_from('=I', data, k)[0]
        elif code == 0x15:
            pc += jt if accumulator == k else jf
        elif code == 0x25:
            pc += jt if accumulator > k else jf
        elif code == 0x35:
            pc += jt if accumulator >= k else jf
        elif code == 0x45:
            pc += jt if accumulator & k else jf
        elif code == 0x05:
            pc += k
        elif code == 0x54:
            accumulator &= k
        elif code == 0x06:
            return k
        else:
            raise AssertionError(f'unexpected BPF instruction {code:#x}')
    raise AssertionError('BPF program does not terminate')


class FakeDecoderBase(Workspace):
    def setUp(self):
        super().setUp()
        self.state = self.base / 'fake'
        (self.state / 'records').mkdir(parents=True)
        (self.state / 'real-bwrap').touch()
        for name, text in [('bwrap', FAKE_BWRAP.format(state=str(self.state), probe=PROBE)),
                           ('magick', FAKE_MAGICK.format(state=str(self.state)))]:
            (self.state / name).write_text(text)
            (self.state / name).chmod(0o755)
        self.mode('fail')

    def mode(self, mode, **options):
        (self.state / 'mode.json').write_text(json.dumps(dict(options, mode=mode)))

    def wrap(self):
        return ['/usr/bin/bwrap', '--dev-bind', '/', '/', '--ro-bind', '/usr/bin/bwrap', str(self.state / 'real-bwrap'),
                '--ro-bind', str(self.state / 'bwrap'), '/usr/bin/bwrap',
                '--ro-bind', str(self.state / 'magick'), '/usr/bin/magick', '--die-with-parent', '--']

    def faked(self, request, env=None, pass_fds=()):
        return self.run_helper(request, env=env, wrap=self.wrap(), pass_fds=pass_fds)

    def records(self):
        return [json.loads(path.read_text()) for path in sorted((self.state / 'records').iterdir())]

    def clear_records(self):
        for path in (self.state / 'records').iterdir():
            path.unlink()

    def check_launch(self, record, kind, staging_parent, prefix, data):
        argv = record['argv']
        self.assertIn('--seccomp', argv)
        fd = argv[argv.index('--seccomp') + 1]
        policy = argv[argv.index('/etc/ImageMagick-7/policy.xml') - 1]
        source = argv[argv.index('/input') - 1]
        self.assertEqual(argv, expected_argv(kind, policy, source, fd))
        staging = Path(policy).parent
        self.assertEqual(staging.parent, staging_parent)
        self.assertRegex(staging.name, '^' + re.escape(prefix) + '[a-z0-9_]{8}$')
        self.assertEqual((Path(policy).name, Path(source).parent, Path(source).name),
                         ('policy.xml', staging, 'input'))
        self.assertEqual(record['staging_mode'], 0o700)
        self.assertEqual(record['policy'], POLICY)
        self.assertEqual(record['input_sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(record['env'], {'PATH': '/usr/bin'})
        self.assertEqual(int(record['sigblk'], 16), 0, 'the decoder starts with blocked signals')
        limits = dict(record['rlimits'])
        if not NATIVE:
            limits.pop('AS')  # qemu-user does not pass address-space limits on
        expected = {'AS': [256 << 20] * 2, 'CPU': [2, 2], 'FSIZE': [PIXEL_BYTES] * 2, 'CORE': [0, 0],
                    'NOFILE': [64, 64]}
        self.assertEqual(limits, {name: expected[name] for name in limits})
        fds = dict(record['fds'])
        self.assertEqual(set(fds), {0, 1, 2, int(fd)}, fds)
        self.assertEqual(fds[0], '/dev/null')
        self.assertTrue(fds[1].startswith('pipe:'), fds)
        self.assertTrue(fds[int(fd)].startswith('/memfd:'), fds)
        self.assertFalse((self.state / 'magick-ran').exists())
        self.check_seccomp(bytes.fromhex(record['seccomp']))

    def check_seccomp(self, program):
        audit, denied = SECCOMP[MACHINE]
        foreign = [0, 0x40000003, 0xc00000b7 if MACHINE == 'x86_64' else 0xc000003e]
        for number in list(range(0, 1024)) + [0x7fffffff, 0xffffffff]:
            if MACHINE == 'x86_64' and number & 0x40000000:
                wanted = RET_KILL_PROCESS
            else:
                wanted = RET_EPERM if number in denied else RET_ALLOW
            self.assertEqual(run_bpf(program, number, audit), wanted, number)
            for arch in foreign:
                self.assertEqual(run_bpf(program, number, arch), RET_KILL_PROCESS, (number, arch))
        if MACHINE == 'x86_64':
            for number in range(0x40000000, 0x40000000 + 600):
                self.assertEqual(run_bpf(program, number, audit), RET_KILL_PROCESS, number)


@needs_namespaces
class FakeDecoder(FakeDecoderBase):
    def test_launch_contract_and_generated_png(self):
        pixels = [17, 99, 201]
        self.mode('pixels', rgb=pixels)
        jpeg = b'\xff\xd8\xff\xe0' + b'not really a jpeg'
        webp = b'RIFF' + struct.pack('<I', 12) + b'WEBPVP8 ' + struct.pack('<I', 2) + b'\0\0'
        # A descriptor the shell leaked to the helper must not reach the decoder.
        stray, writer = os.pipe()
        self.addCleanup(os.close, stray)
        self.addCleanup(os.close, writer)
        for name, data, kind in [('cover.png', self.png, 'PNG'), ('cover.jpg', jpeg, 'JPEG'),
                                 ('cover.webp', webp, 'WEBP')]:
            with self.subTest(kind=kind):
                self.clear_records()
                reply = self.faked(self.local(self.write(name, data)), pass_fds=(stray,))
                self.assertTrue(reply['ok'], reply)
                output = Path(reply['path'])
                self.assertEqual(output.parent, self.artwork)
                self.assertEqual(output.name, hashlib.sha256(output.read_bytes()).hexdigest() + '.png')
                self.assertEqual(read_output(self, output), bytes(pixels) * 65536)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertEqual(self.artwork.stat().st_mode & 0o777, 0o700)
                [record] = self.records()
                self.check_launch(record, kind, self.artwork, '.job-', data)
                self.assertEqual(sorted(p.name for p in self.artwork.iterdir()), ['.lock', output.name])
        self.assertEqual(self.leftovers(), [])

    def test_empty_cache_home_falls_back_to_home(self):
        self.mode('pixels', rgb=[1, 2, 3])
        reply = self.faked(self.local(self.write('cover.png', self.png)), env={'XDG_CACHE_HOME': ''})
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(Path(reply['path']).parent, self.base / '.cache/omarchy/foamy.lock/artwork')

    def test_avatar_launch_contract(self):
        self.mode('pixels', rgb=[200, 80, 40])
        face = self.write('face.png', self.png)
        link = self.base / '.face'
        link.symlink_to(face)
        reply = self.faked({'kind': 'avatar', 'path': str(link)})
        output = self.cache / 'omarchy/foamy.lock/avatar.png'
        self.assertEqual(reply, {'ok': True, 'path': str(output)})
        self.assertEqual(read_output(self, output), bytes([200, 80, 40]) * 65536)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        [record] = self.records()
        self.check_launch(record, 'PNG', output.parent, '.avatar-', self.png)
        self.assertEqual(self.leftovers(), [])

    def test_no_unsandboxed_fallback(self):
        self.mode('fail')
        source = self.write('cover.png', self.png)
        self.assertEqual(self.error(self.local(source), wrap=self.wrap()), 'decode-failed')
        self.assertEqual(self.error({'kind': 'avatar', 'path': str(source)}, wrap=self.wrap()), 'decode-failed')
        self.assertEqual([record['argv'][0] for record in self.records()], ['/usr/bin/bwrap'] * 2)
        self.assertFalse((self.state / 'magick-ran').exists())
        self.assertEqual(self.leftovers(), [])

    def test_output_pipe_exit_and_wall_clock_are_bounded(self):
        source = self.write('cover.png', self.png)
        for options, code in [({'mode': 'flood'}, 'invalid-pixels'),
                              ({'mode': 'pixels', 'rgb': [1, 2, 3], 'bytes': 3000}, 'invalid-pixels'),
                              ({'mode': 'pixels', 'rgb': [1, 2, 3], 'exit': 1}, 'decode-failed'),
                              ({'mode': 'sleep', 'seconds': 10}, 'decode-timeout')]:
            with self.subTest(options=options):
                self.mode(**options)
                self.assertEqual(self.error(self.local(source), wrap=self.wrap()), code)
                self.assertLess(self.elapsed, 4.5)
        self.assertEqual(self.leftovers(), [])

    def test_cache_is_bounded_and_recovers_orphaned_work(self):
        self.artwork.mkdir(parents=True, mode=0o700)
        orphan = self.artwork / '.job-abcdefgh'
        orphan.mkdir()
        (orphan / 'input').write_bytes(b'incomplete')
        kept = [self.artwork / '.job-short', self.artwork / '.job-ABCDEFGH', self.artwork / 'notes.txt']
        kept[0].mkdir()
        kept[1].mkdir()
        kept[2].write_text('not ours')
        source = self.write('cover.png', self.png)
        for index in range(20):
            self.mode('pixels', rgb=[index, 0, 0])
            self.assertTrue(self.faked(self.local(source))['ok'])
        remaining = [p for p in self.artwork.iterdir() if p.suffix == '.png']
        self.assertEqual(len(remaining), 16)
        self.assertEqual(sorted(read_output(self, p)[0] for p in remaining), list(range(4, 20)))
        self.assertFalse(orphan.exists())
        self.assertTrue(all(path.exists() for path in kept))

    def test_abandoned_avatar_staging_is_reclaimed(self):
        directory = self.cache / 'omarchy/foamy.lock'
        old, recent = directory / '.avatar-abcdefgh', directory / '.avatar-ijklmnop'
        for path in [old, recent]:
            (path / 'sub').mkdir(parents=True)
        os.utime(old, (time.time() - 120,) * 2)
        self.mode('pixels', rgb=[5, 6, 7])
        self.assertTrue(self.faked({'kind': 'avatar', 'path': str(self.write('face.png', self.png))})['ok'])
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())

    def test_cancel_during_decode_kills_the_sandbox(self):
        self.mode('sleep', seconds=10)
        stdin, writer = os.pipe()
        os.write(writer, (json.dumps(self.local(self.write('cover.png', self.png))) + '\n').encode())
        process = subprocess.Popen([*self.wrap(), *HELPER, 'artwork'], stdin=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.environment())
        os.close(stdin)
        self.addCleanup(os.close, writer)
        deadline = time.monotonic() + 5
        while not self.records() and time.monotonic() < deadline:
            time.sleep(0.02)
        [record] = self.records()
        os.kill(record['ppid'], signal.SIGTERM)
        output, errors = process.communicate(timeout=2)
        self.assertEqual(json.loads(output), {'ok': False, 'error': 'cancelled'})
        self.assertEqual(errors, b'')
        deadline = time.monotonic() + 2
        while Path(f'/proc/{record["pid"]}').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(Path(f'/proc/{record["pid"]}').exists(), 'the decoder outlived a cancelled job')
        self.assertEqual(self.leftovers(), [])

    def test_precheck_matches_the_helper(self):
        """Model.artworkPrecheck (QML) may only refuse what the helper refuses."""
        self.mode('pixels', rgb=[9, 9, 9])
        music = self.base / 'Music'
        music.mkdir()
        (music / 'a.png').write_bytes(self.png)
        (self.base / 'link').symlink_to(music, target_is_directory=True)
        url = (music / 'a.png').as_uri()
        cases = [
            ([str(music) + '/.'], url, True), ([str(self.base) + '//Music'], url, True),
            ([str(music) + '/'], url, True), ([str(self.base) + '/./Music'], url, True),
            ([str(music) + '//'], url, True), ([str(music)], url, True),
            (['/' + str(music)], url, False),          # "//tmp/…" stays distinct, as in POSIX
            ([str(self.base / 'link')], url, False),   # symlinked root: refused by the helper only
            ([str(self.base / 'link')], (self.base / 'link' / 'a.png').as_uri(), False),
            ([str(self.base / 'Other')], url, False), ([str(music) + '/sub/..'], url, False),
            ([str(music)], 'file://' + str(music) + '//a.png', False),
            ([str(music)], 'file://' + str(music) + '/../Music/a.png', False),
            (['/.'], url, True), (['//'], url, True),
        ]
        script = ("const M = require(process.argv[1]); const cases = JSON.parse(process.argv[2]);"
                  "console.log(JSON.stringify(cases.map(c => M.artworkPrecheck(c[1], [], c[0]))))")
        verdicts = json.loads(subprocess.run(
            ['node', '-e', script, str(PLUGIN / 'Model.js'), json.dumps([[c[0], c[1]] for c in cases])],
            capture_output=True, text=True, check=True, timeout=10).stdout)
        for (roots, source, accepted), verdict in zip(cases, verdicts):
            with self.subTest(roots=roots, url=source):
                helper = self.faked({'url': source, 'roots': roots})['ok']
                self.assertEqual(helper, accepted)
                if helper:
                    self.assertEqual(verdict, '', 'the precheck refused what the helper accepts')
        # The string-level refusals are still made without the helper.
        self.assertEqual(verdicts[6], 'file-outside-roots')
        self.assertEqual(verdicts[9], 'file-outside-roots')
        self.assertEqual(verdicts[10], 'invalid-roots')
        self.assertEqual(verdicts[12], 'invalid-file-path')


@needs_namespaces
class HttpsDecoded(HttpsBase, FakeDecoderBase):
    def test_redirect_and_chunked_bodies_reach_the_decoder(self):
        self.mode('pixels', rgb=[3, 4, 5])
        self.server.routes.update({
            '/redirect': respond(302, [('Location', '/cover.png')]),
            '/cover.png': respond(200, [('Content-Length', str(len(self.png)))], self.png),
            '/chunked.png': respond(200, [], self.png, chunked=True),
            '/until-close.png': respond(200, [], self.png),
            '/relative/deep': respond(301, [('Location', '../cover.png?x=1')]),
            '/cover.png?x=1': respond(200, [('Content-Length', str(len(self.png)))], self.png),
        })
        environment = self.server.environment()
        for path in ['/redirect', '/chunked.png', '/until-close.png', '/relative/deep']:
            with self.subTest(path=path):
                reply = self.run_helper({'url': 'https://images.example.com' + path, 'hosts': ['images.example.com']},
                                        env=environment, wrap=self.wrap())
                self.assertTrue(reply['ok'], reply)
                self.assertEqual(read_output(self, reply['path']), bytes([3, 4, 5]) * 65536)
        self.assertEqual(self.paths(), ['/redirect', '/cover.png', '/chunked.png', '/until-close.png',
                                        '/relative/deep', '/cover.png?x=1'])
        self.assertEqual({record['input_sha256'] for record in self.records()},
                         {hashlib.sha256(self.png).hexdigest()})


@needs_real_decoder
class RealDecoder(Workspace):
    def test_real_png_jpeg_webp_and_private_atomic_output(self):
        source = self.write('source.png', self.png)
        for extension in ['png', 'jpg', 'webp']:
            with self.subTest(extension=extension):
                target = self.base / ('source.' + extension)
                if extension != 'png':
                    subprocess.run(['/usr/bin/magick', str(source), '-quality', '95', str(target)], check=True,
                                   timeout=5)
                reply = self.run_helper(self.local(target))
                self.assertTrue(reply['ok'], reply)
                pixels = read_output(self, reply['path'])
                if extension == 'png':
                    self.assertEqual(pixels, bytes([34, 120, 156]) * 65536)
                else:
                    self.assertTrue(all(abs(a - b) <= 8 for a, b in zip(pixels[:3000], [34, 120, 156] * 1000)))
                self.assertEqual(Path(reply['path']).stat().st_mode & 0o777, 0o600)
                self.assertEqual(self.artwork.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.leftovers(), [])

    def test_malformed_and_oversized_dimensions_fail_closed(self):
        header = struct.pack('>IIBBBBB', 50000, 50000, 8, 2, 0, 0, 0)
        huge = (PNG_MAGIC + struct.pack('>I', 13) + b'IHDR' + header
                + struct.pack('>I', zlib.crc32(b'IHDR' + header)) + png(b'\0\0\0', 1, 1)[33:])
        for name, data in [('broken.jpg', b'\xff\xd8\xffbroken'), ('huge.png', huge), ('truncated.png', self.png[:60])]:
            with self.subTest(name=name):
                # A truncated PNG is refused before the decoder (strip_png_text).
                self.assertIn(self.error(self.local(self.write(name, data))),
                              {'decode-failed', 'invalid-pixels', 'decode-timeout', 'invalid-png'})
        self.assertEqual(self.leftovers(), [])

    def test_avatar_is_sandboxed_resized_and_private(self):
        face = self.write('face.png', png(bytes([200, 80, 40]) * 512 * 300, 512, 300))
        link = self.base / '.face'
        link.symlink_to(face)
        reply = self.run_helper({'kind': 'avatar', 'path': str(link)})
        output = self.cache / 'omarchy/foamy.lock/avatar.png'
        self.assertEqual(reply, {'ok': True, 'path': str(output)})
        self.assertEqual(read_output(self, output), bytes([200, 80, 40]) * 65536)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.leftovers(), [])


@needs_real_decoder
@unittest.skipUnless(MACHINE == 'x86_64', 'the probe uses x86_64 syscall numbers')
class Sandbox(FakeDecoderBase):
    def test_decoder_runs_under_the_seccomp_filter_in_an_empty_sandbox(self):
        self.mode('probe')
        source = self.write('cover.png', self.png)
        self.assertEqual(self.error(self.local(source), wrap=self.wrap()), 'decode-failed')
        probe = json.loads((self.state / 'probe.json').read_text())
        lines = probe['stdout'].splitlines()
        self.assertEqual(len(lines), 1, probe)
        out = json.loads(lines[0])
        denied = ['fork', 'unshare', 'clone', 'clone3', 'ptrace', 'setns']
        self.assertEqual({key: out[key] for key in denied}, dict.fromkeys(denied, 1))  # EPERM
        self.assertEqual(out['getpid'], 0)
        self.assertEqual(out['network'], 101)   # ENETUNREACH: an empty network namespace
        self.assertEqual(out['write'], 30)      # EROFS
        self.assertEqual(out['env'], {'PATH': '/usr/bin', 'HOME': '/nonexistent', 'PWD': '/',
                                      'MAGICK_CONFIGURE_PATH': '/etc/ImageMagick-7', 'OMP_NUM_THREADS': '1'})
        self.assertEqual(out['cwd'], '/')
        self.assertEqual(out['caps'], ['0000000000000000'])
        self.assertEqual(out['policy'], POLICY)
        self.assertEqual(out['input'], len(self.png))
        self.assertNotEqual(probe['rc'], 0)     # the x32 syscall killed the decoder


class Lifecycle(Workspace):
    def start(self):
        """The helper with a request pipe that stays open (no end of input)."""
        stdin, writer = os.pipe()
        self.addCleanup(os.close, writer)
        process = subprocess.Popen([*HELPER, 'artwork'], stdin=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.environment())
        os.close(stdin)
        return process

    def test_cancel_and_job_timeout_signals_reply(self):
        for sent, code in [(signal.SIGTERM, 'cancelled'), (signal.SIGALRM, 'job-timeout')]:
            with self.subTest(signal=sent):
                process = self.start()
                time.sleep(0.4)
                process.send_signal(sent)
                output, errors = process.communicate(timeout=2)
                self.assertEqual(json.loads(output), {'ok': False, 'error': code})
                self.assertEqual(errors, b'')
                self.assertEqual(process.returncode, 0)
        self.assertEqual(self.leftovers(), [])

    def test_parent_death_cancels_the_job(self):
        reply = self.base / 'reply.json'
        launcher = ('import subprocess, sys, time\n'
                    'subprocess.Popen(sys.argv[2:], stdout=open(sys.argv[1], "wb"))\n'
                    'time.sleep(0.4)\n')
        stdin, writer = os.pipe()
        self.addCleanup(os.close, writer)
        parent = subprocess.Popen(['/usr/bin/python3', '-I', '-c', launcher, str(reply), *HELPER, 'artwork'],
                                  stdin=stdin, env=self.environment())
        os.close(stdin)
        parent.wait(timeout=5)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not reply.read_bytes():
            time.sleep(0.02)
        self.assertEqual(json.loads(reply.read_bytes()), {'ok': False, 'error': 'cancelled'})

    def test_the_whole_job_has_a_deadline(self):
        process = self.start()
        started = time.monotonic()
        output, errors = process.communicate(timeout=12)
        self.assertEqual(json.loads(output), {'ok': False, 'error': 'job-timeout'})
        self.assertGreater(time.monotonic() - started, 8.5)
        self.assertEqual(errors, b'')


if __name__ == '__main__':
    unittest.main()
