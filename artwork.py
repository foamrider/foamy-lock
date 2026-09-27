"""Prepare bounded lock artwork. Original images never enter the shell process."""
import ctypes
import fcntl
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import selectors
import signal
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urljoin, urlsplit
import zlib

MAX_INPUT = 5 * 1024 * 1024
SIZE = 256
PIXEL_BYTES = SIZE * SIZE * 3
MAX_CACHE = 16
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
HOST = re.compile(r'(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\Z')


class ArtworkError(Exception):
    """A stable failure code, never a source URL or decoder diagnostic."""


def validate_options(hosts, roots):
    if (not isinstance(hosts, list) or len(hosts) > 32
            or any(not isinstance(h, str) or not HOST.fullmatch(h) for h in hosts)):
        raise ArtworkError('invalid-hosts')
    if (not isinstance(roots, list) or len(roots) > 16
            or any(not isinstance(p, str) or not p.startswith('/') or len(p) > 4096
                   or '\x00' in p or p == '/' or '..' in p.split('/') for p in roots)):
        raise ArtworkError('invalid-roots')


def parse_url(url):
    if (not isinstance(url, str) or not url or len(url) > 8192
            or any(ord(c) <= 32 or ord(c) >= 127 for c in url) or '\\' in url):
        raise ArtworkError('invalid-url')
    try:
        parts = urlsplit(url)
        if parts.username is not None or parts.password is not None or parts.fragment:
            raise ArtworkError('invalid-url')
        port = parts.port
    except ValueError:
        raise ArtworkError('invalid-url') from None
    if parts.scheme == 'file':
        if parts.netloc or parts.query or port is not None:
            raise ArtworkError('invalid-file-url')
    elif parts.scheme == 'https':
        if not parts.hostname or port not in (None, 443):
            raise ArtworkError('invalid-https-url')
    else:
        raise ArtworkError('unsupported-scheme')
    return parts


def read_local(parts, roots):
    path = unquote(parts.path, errors='strict')
    if not path.startswith('/') or '\x00' in path or '..' in path.split('/'):
        raise ArtworkError('invalid-file-path')
    for root in roots:
        root = os.path.abspath(root)
        if not path.startswith(root.rstrip('/') + '/'):
            continue
        # Walk from the permitted directory using descriptors: no symlink or
        # special-file substitution can escape the selected root during open.
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            pieces = path[len(root.rstrip('/')) + 1:].split('/')
            for piece in pieces[:-1]:
                new_fd = os.open(piece, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = new_fd
            source = os.open(pieces[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(source, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    raise ArtworkError('not-owned-regular-file')
                if info.st_size > MAX_INPUT:
                    raise ArtworkError('input-too-large')
                data = stream.read(MAX_INPUT + 1)
                if len(data) > MAX_INPUT:
                    raise ArtworkError('input-too-large')
                return data
        finally:
            os.close(fd)
    raise ArtworkError('file-outside-roots')


def public_addresses(host):
    addresses = list(dict.fromkeys(result[4][0] for result in socket.getaddrinfo(
        host, 443, type=socket.SOCK_STREAM)))
    if not addresses:
        raise ArtworkError('dns-failed')
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if (not ip.is_global or ip.is_multicast or ip.is_unspecified
                or getattr(ip, 'ipv4_mapped', None) is not None
                or getattr(ip, 'sixtofour', None) is not None
                or getattr(ip, 'teredo', None) is not None
                or (ip.version == 6 and ip in ipaddress.ip_network('64:ff9b::/96'))):
            raise ArtworkError('non-public-address')
    return addresses


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, address, timeout):
        super().__init__(host, timeout=timeout, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        # Connect to the already-checked IP but verify TLS against the hostname.
        # No second hostname lookup, proxy environment, cookies, or credentials.
        sock = socket.create_connection((self.address, 443), self.timeout)
        try:
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


def fetch_https(url, hosts):
    # DNS and slow response headers also count toward the five-second budget.
    def timeout(signum, frame):
        raise ArtworkError('fetch-timeout')
    old_handler = signal.signal(signal.SIGALRM, timeout)
    previous, interval = signal.setitimer(signal.ITIMER_REAL, 5)
    started = time.monotonic()
    try:
        return fetch_https_bounded(url, hosts)
    finally:
        signal.signal(signal.SIGALRM, old_handler)
        signal.setitimer(signal.ITIMER_REAL, max(0.001, previous - (time.monotonic() - started))
                         if previous else 0, interval)


def fetch_https_bounded(url, hosts):
    deadline = time.monotonic() + 5
    for hop in range(3):
        parts = parse_url(url)
        if parts.scheme != 'https' or parts.hostname not in hosts:
            raise ArtworkError('host-not-allowed')
        address = public_addresses(parts.hostname)[0]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ArtworkError('fetch-timeout')
        connection = PinnedHTTPS(parts.hostname, address, remaining)
        try:
            target = parts.path or '/'
            if parts.query:
                target += '?' + parts.query
            connection.request('GET', target, headers={
                'Accept': 'image/png,image/jpeg,image/webp', 'Accept-Encoding': 'identity',
                'User-Agent': 'FoamyLock/1.0', 'Connection': 'close'})
            response = connection.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader('Location')
                if not location or hop == 2:
                    raise ArtworkError('redirect-limit')
                url = urljoin(url, location)
                continue
            if response.status != 200:
                raise ArtworkError('http-error')
            if response.getheader('Content-Encoding', 'identity').lower() != 'identity':
                raise ArtworkError('encoded-response')
            length = response.getheader('Content-Length')
            if length is not None and (not length.isdigit() or int(length) > MAX_INPUT):
                raise ArtworkError('input-too-large')
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ArtworkError('fetch-timeout')
                # read1 returns after one transport read, including chunked bodies.
                if connection.sock is not None:
                    connection.sock.settimeout(remaining)
                chunk = response.read1(min(65536, MAX_INPUT + 1 - len(data)))
                if not chunk:
                    return bytes(data)
                data.extend(chunk)
                if len(data) > MAX_INPUT:
                    raise ArtworkError('input-too-large')
        finally:
            connection.close()
    raise ArtworkError('redirect-limit')


def image_format(data):
    if data.startswith(PNG_MAGIC):
        offset = 8
        while offset + 12 <= len(data):
            size = struct.unpack_from('>I', data, offset)[0]
            kind = data[offset + 4:offset + 8]
            if kind == b'acTL':
                raise ArtworkError('animated-image')
            offset += size + 12
        return 'PNG'
    if data.startswith(b'\xff\xd8\xff'):
        return 'JPEG'
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        offset = 12
        while offset + 8 <= len(data):
            kind = data[offset:offset + 4]
            size = struct.unpack_from('<I', data, offset + 4)[0]
            if kind in (b'ANIM', b'ANMF') or (kind == b'VP8X' and size and data[offset + 8:offset + 9] and data[offset + 8] & 2):
                raise ArtworkError('animated-image')
            offset += 8 + size + (size & 1)
        return 'WEBP'
    raise ArtworkError('unsupported-format')


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


def decoder_limits():
    resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (PIXEL_BYTES, PIXEL_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))


def decoder_filter():
    # No child processes or new namespaces, even after a decoder compromise.
    # Bubblewrap installs this filter after creating its own sandbox children.
    architectures = {
        'x86_64': (0xc000003e, [56, 57, 58, 101, 165, 272, 308, 321, 435]),
        'aarch64': (0xc00000b7, [40, 97, 117, 220, 268, 280, 435]),
    }
    if platform.machine() not in architectures:
        raise ArtworkError('sandbox-architecture-unsupported')
    arch, denied = architectures[platform.machine()]
    # Classic BPF: verify ABI, load syscall number, return EPERM for denied calls.
    instructions = [(0x20, 0, 0, 4), (0x15, 1, 0, arch), (0x06, 0, 0, 0x80000000),
                    (0x20, 0, 0, 0)]
    if platform.machine() == 'x86_64':
        instructions += [(0x45, 0, 1, 0x40000000), (0x06, 0, 0, 0x80000000)]
    for number in denied:
        instructions += [(0x15, 0, 1, number), (0x06, 0, 0, 0x00050001)]
    instructions += [(0x06, 0, 0, 0x7fff0000)]
    return b''.join(struct.pack('HBBI', *instruction) for instruction in instructions)


def decode(data, directory):
    kind = image_format(data)
    if not Path('/usr/bin/bwrap').is_file() or not Path('/usr/bin/magick').is_file():
        raise ArtworkError('decoder-unavailable')
    source = directory / 'input'
    source.write_bytes(data)
    policy = directory / 'policy.xml'
    policy.write_text(POLICY)
    filter_bytes = decoder_filter()
    filter_fd = os.memfd_create('foamy-artwork-seccomp', os.MFD_CLOEXEC)
    os.write(filter_fd, filter_bytes)
    os.lseek(filter_fd, 0, os.SEEK_SET)
    command = ['/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session',
               '--cap-drop', 'ALL', '--ro-bind', '/usr', '/usr',
               '--symlink', 'usr/lib', '/lib', '--symlink', 'usr/lib', '/lib64',
               '--symlink', 'usr/bin', '/bin', '--proc', '/proc', '--dev', '/dev',
               '--dir', '/etc', '--dir', '/etc/ImageMagick-7',
               '--ro-bind', str(policy), '/etc/ImageMagick-7/policy.xml',
               '--ro-bind', str(source), '/input', '--chdir', '/', '--clearenv',
               '--setenv', 'PATH', '/usr/bin', '--setenv', 'HOME', '/nonexistent',
               '--setenv', 'MAGICK_CONFIGURE_PATH', '/etc/ImageMagick-7',
               '--setenv', 'OMP_NUM_THREADS', '1', '--remount-ro', '/', '--seccomp', str(filter_fd),
               '/usr/bin/magick', kind + ':/input', '-auto-orient', '-thumbnail', '256x256^',
               '-gravity', 'center', '-extent', '256x256', '-background', '#171b26',
               '-alpha', 'remove', '-alpha', 'off', '-colorspace', 'sRGB', '-depth', '8', 'RGB:-']
    # A fixed-size pipe protects the trusted supervisor even if the decoder is
    # compromised. Bubblewrap kills its sandbox when this supervisor exits.
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, env={'PATH': '/usr/bin'},
                                   pass_fds=(filter_fd,), preexec_fn=decoder_limits)
    finally:
        os.close(filter_fd)
    try:
        output = bytearray()
        deadline = time.monotonic() + 3
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ArtworkError('decode-timeout')
                chunk = os.read(process.stdout.fileno(), min(65536, PIXEL_BYTES + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > PIXEL_BYTES:
                    raise ArtworkError('invalid-pixels')
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise ArtworkError('decode-failed')
        if len(output) != PIXEL_BYTES:
            raise ArtworkError('invalid-pixels')
        return bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def encode_png(pixels):
    if len(pixels) != PIXEL_BYTES:
        raise ArtworkError('invalid-pixels')
    rows = b''.join(b'\x00' + pixels[i:i + SIZE * 3] for i in range(0, PIXEL_BYTES, SIZE * 3))
    # Only these three chunks are generated; no original metadata or compressed
    # stream crosses the boundary back into Qt's image decoder.
    return (PNG_MAGIC + png_chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0))
            + png_chunk(b'IDAT', zlib.compress(rows, level=0)) + png_chunk(b'IEND', b''))


def prepare(request):
    hosts = request.get('hosts', [])
    roots = request.get('roots', [])
    validate_options(hosts, roots)
    parts = parse_url(request.get('url'))
    if parts.scheme == 'https' and parts.hostname not in hosts:
        raise ArtworkError('host-not-allowed')
    data = read_local(parts, roots) if parts.scheme == 'file' else fetch_https(request['url'], hosts)
    cache_home = Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache')
    cache = cache_home / 'omarchy' / 'foamy.lock' / 'artwork'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = cache.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ArtworkError('unsafe-cache')
    lock_fd = os.open(cache / '.lock', os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, 'wb') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ArtworkError('cache-busy') from None
        # A forced shell kill cannot run Python's finally blocks. The lock lets
        # the next job reclaim only our orphaned staging directories safely.
        for stale in cache.glob('.job-*'):
            if re.fullmatch(r'\.job-[a-z0-9_]{8}', stale.name) and not stale.is_symlink():
                shutil.rmtree(stale)
        # Never reuse disk data as trusted output. Only this shell's in-memory
        # LRU reuses completed thumbnails; a new helper validates anew.
        with tempfile.TemporaryDirectory(prefix='.job-', dir=cache) as temporary:
            directory = Path(temporary)
            pixels = decode(data, directory)
            encoded = encode_png(pixels)
            name = hashlib.sha256(encoded).hexdigest() + '.png'
            output = directory / 'thumbnail.png'
            output.write_bytes(encoded)
            output.chmod(0o600)
            os.replace(output, cache / name)
        entries = sorted((p for p in cache.glob('*.png') if re.fullmatch(r'[a-f0-9]{64}\.png', p.name)),
                         key=lambda path: path.lstat().st_mtime, reverse=True)
        for entry in entries[MAX_CACHE:]:
            entry.unlink()
    return {'ok': True, 'path': str(cache / name)}


def interrupted(signum, frame):
    raise ArtworkError('cancelled' if signum == signal.SIGTERM else 'job-timeout')


def main():
    # Quickshell may be killed or reloaded during a job. Also cover abrupt
    # parent death, so the network helper and its sandbox cannot be orphaned.
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        print(json.dumps({'ok': False, 'error': 'parent-watch-failed'}))
        return
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGALRM, interrupted)
    signal.alarm(9)
    try:
        if os.getppid() != parent or parent == 1:
            raise ArtworkError('cancelled')
        line = sys.stdin.buffer.readline(32769)
        if len(line) > 32768:
            raise ArtworkError('invalid-request')
        request = json.loads(line)
        if not isinstance(request, dict):
            raise ArtworkError('invalid-request')
        result = prepare(request)
    except ArtworkError as error:
        result = {'ok': False, 'error': str(error)}
    except (socket.timeout, TimeoutError, subprocess.TimeoutExpired):
        result = {'ok': False, 'error': 'timeout'}
    except (OSError, ValueError, http.client.HTTPException):
        result = {'ok': False, 'error': 'source-unavailable'}
    except Exception:
        result = {'ok': False, 'error': 'helper-failed'}
    finally:
        signal.alarm(0)
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
