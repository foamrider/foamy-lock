"""Boundaries use small fixtures; decoder tests require unprivileged namespaces."""
import importlib.util
import io
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zlib

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artwork', SOURCE / 'artwork.py')
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)


class Boundaries(unittest.TestCase):
    def test_url_and_options(self):
        for url in ['http://example.com/a', 'data:image/png,abc', 'ftp://example.com/a',
                    'https://u:p@example.com/a', 'https://example.com:8080/a',
                    'https://example.com/a#fragment', 'file://host/tmp/a', 'file:///tmp/a?v=1',
                    'https://example.com/\nheader', 'https://example.com/\\x', 'x' * 8193]:
            with self.subTest(url=url[:80]), self.assertRaises(art.ArtworkError):
                art.parse_url(url)
        for hosts, roots in [(['*.example.com'], []), (['localhost'], []), (['127.0.0.1'], []),
                             (['EXAMPLE.COM'], []), ([], ['/']), ([], ['/tmp/../home'])]:
            with self.assertRaises(art.ArtworkError):
                art.validate_options(hosts, roots)
        art.validate_options(['images.example.com'], ['/tmp/artwork'])

    def test_dns_rejects_nonpublic_and_mixed_answers(self):
        for address in ['127.0.0.1', '10.0.0.1', '169.254.169.254', '0.0.0.0', '224.0.0.1',
                        '::1', 'fc00::1', 'fe80::1', '::ffff:8.8.8.8', '2002:0808:0808::1', '64:ff9b::7f00:1']:
            answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443)),
                       (socket.AF_INET, socket.SOCK_STREAM, 6, '', (address, 443))]
            with patch.object(art.socket, 'getaddrinfo', return_value=answers), self.subTest(address=address):
                with self.assertRaisesRegex(art.ArtworkError, 'non-public-address'):
                    art.public_addresses('images.example.com')

    def test_local_snapshot_rejects_escape_symlinks_devices_and_growth(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            allowed = base / 'allowed'
            allowed.mkdir()
            source = allowed / 'cover.png'
            source.write_bytes(b'fixture')
            roots = [str(allowed)]
            self.assertEqual(art.read_local(art.parse_url(source.as_uri()), roots), b'fixture')
            outside = base / 'secret'
            outside.write_bytes(b'private')
            (allowed / 'link').symlink_to(outside)
            (allowed / 'directory').symlink_to(base, target_is_directory=True)
            os.mkfifo(allowed / 'fifo')
            for path in [outside, allowed / 'link', allowed / 'directory' / 'secret', allowed / 'fifo']:
                with self.subTest(path=path), self.assertRaises((art.ArtworkError, OSError)):
                    art.read_local(art.parse_url(path.as_uri()), roots)
            with source.open('wb') as stream:
                stream.truncate(art.MAX_INPUT + 1)
            with self.assertRaisesRegex(art.ArtworkError, 'input-too-large'):
                art.read_local(art.parse_url(source.as_uri()), roots)

    def test_transport_pins_ip_and_tls_name(self):
        raw = unittest.mock.Mock()
        wrapped = unittest.mock.Mock()
        with patch.object(art.socket, 'create_connection', return_value=raw) as connect, \
                patch.object(art.ssl, 'create_default_context') as context:
            context.return_value.wrap_socket.return_value = wrapped
            connection = art.PinnedHTTPS('images.example.com', '8.8.8.8', 3)
            connection.connect()
            connect.assert_called_once_with(('8.8.8.8', 443), 3)
            context.return_value.wrap_socket.assert_called_once_with(raw, server_hostname='images.example.com')

    def test_bounded_http_and_redirect_policy(self):
        class Response:
            def __init__(self, status=200, headers=None, body=b'png'):
                self.status, self.headers, self.body = status, headers or {}, io.BytesIO(body)
            def getheader(self, key, default=None):
                return self.headers.get(key, default)
            def read1(self, size):
                return self.body.read(size)

        connection = unittest.mock.Mock()
        connection.sock = None
        with patch.object(art, 'public_addresses', return_value=['8.8.8.8']) as dns, \
                patch.object(art, 'PinnedHTTPS', return_value=connection):
            cases = [
                (Response(headers={'Content-Length': str(art.MAX_INPUT + 1)}), 'input-too-large'),
                (Response(body=b'x' * (art.MAX_INPUT + 1)), 'input-too-large'),
                (Response(headers={'Content-Encoding': 'gzip'}), 'encoded-response'),
                (Response(404), 'http-error'),
                (Response(302, {'Location': 'https://other.example/a'}), 'host-not-allowed'),
                (Response(302, {'Location': 'http://images.example.com/a'}), 'unsupported-scheme'),
            ]
            for response, code in cases:
                connection.getresponse.return_value = response
                with self.subTest(code=code), self.assertRaisesRegex(art.ArtworkError, code):
                    art.fetch_https('https://images.example.com/a', ['images.example.com'])
            connection.getresponse.side_effect = [Response(302, {'Location': '/b'}), Response(body=b'ok')]
            self.assertEqual(art.fetch_https('https://images.example.com/a', ['images.example.com']), b'ok')
            connection.getresponse.side_effect = [Response(302, {'Location': '/a'}) for _ in range(3)]
            with self.assertRaisesRegex(art.ArtworkError, 'redirect-limit'):
                art.fetch_https('https://images.example.com/a', ['images.example.com'])
            # Every hop resolves and checks the destination again.
            self.assertGreaterEqual(dns.call_count, 10)

    def test_redirect_rechecks_dns_before_connecting(self):
        connection = unittest.mock.Mock()
        connection.getresponse.return_value.status = 302
        connection.getresponse.return_value.getheader.return_value = '/next'
        answers = [[(socket.AF_INET, socket.SOCK_STREAM, 6, '', (address, 443))]
                   for address in ['8.8.8.8', '127.0.0.1']]
        with patch.object(art.socket, 'getaddrinfo', side_effect=answers), \
                patch.object(art, 'PinnedHTTPS', return_value=connection) as connect:
            with self.assertRaisesRegex(art.ArtworkError, 'non-public-address'):
                art.fetch_https('https://images.example.com/a', ['images.example.com'])
            self.assertEqual(connect.call_count, 1)

    def test_static_formats_and_generated_png(self):
        with self.assertRaisesRegex(art.ArtworkError, 'unsupported-format'):
            art.image_format(b'<svg xmlns="http://www.w3.org/2000/svg"/>')
        with self.assertRaisesRegex(art.ArtworkError, 'animated-image'):
            art.image_format(art.PNG_MAGIC + art.png_chunk(b'acTL', b'\x00' * 8))
        with self.assertRaisesRegex(art.ArtworkError, 'animated-image'):
            art.image_format(b'RIFF' + b'\x00' * 4 + b'WEBPANIM' + b'\x00' * 4)
        pixels = bytes([34, 120, 156]) * 256 * 256
        png = art.encode_png(pixels)
        self.assertEqual(struct.unpack('>II', png[16:24]), (256, 256))
        length = struct.unpack('>I', png[33:37])[0]
        raw = zlib.decompress(png[41:41 + length])
        self.assertEqual(raw, (b'\0' + bytes([34, 120, 156]) * 256) * 256)
        with self.assertRaisesRegex(art.ArtworkError, 'invalid-pixels'):
            art.encode_png(pixels + b'\x00')


class RealDecoder(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='foamy-artwork-test-')
        self.base = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, XDG_CACHE_HOME=str(self.base / 'cache'))
        self.environment.start()
        self.png = art.encode_png(bytes([34, 120, 156]) * 256 * 256)

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def test_real_png_jpeg_webp_and_private_atomic_output(self):
        source = self.base / 'source.png'
        source.write_bytes(self.png)
        for extension in ['png', 'jpg', 'webp']:
            target = self.base / ('source.' + extension)
            if extension != 'png':
                subprocess.run(['/usr/bin/magick', str(source), str(target)], check=True, timeout=3)
            result = art.prepare({'url': target.as_uri(), 'roots': [str(self.base)]})
            output = Path(result['path'])
            self.assertTrue(result['ok'])
            self.assertEqual(struct.unpack('>II', output.read_bytes()[16:24]), (256, 256))
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(list(output.parent.glob('.job-*')), [])

    def test_malformed_and_oversized_dimensions_fail_closed(self):
        huge = (art.PNG_MAGIC + art.png_chunk(b'IHDR', struct.pack('>IIBBBBB', 50000, 50000, 8, 2, 0, 0, 0))
                + art.png_chunk(b'IDAT', zlib.compress(b'\0')) + art.png_chunk(b'IEND', b''))
        for data in [b'\xff\xd8\xffbroken', huge]:
            with self.subTest(data=data[:8]), self.assertRaises(art.ArtworkError):
                art.decode(data, self.base)

    def test_no_unsandboxed_fallback(self):
        with patch.object(art.subprocess, 'Popen', side_effect=OSError('unavailable')) as launch:
            with self.assertRaises(OSError):
                art.decode(self.png, self.base)
            self.assertEqual(launch.call_count, 1)
            command = launch.call_args.args[0]
            self.assertEqual(command[0], '/usr/bin/bwrap')
            self.assertIn('--unshare-all', command)

    def test_output_pipe_and_wall_clock_are_bounded(self):
        real_popen = subprocess.Popen
        for script, error in [('import os; os.write(1, b"x" * 250000)', 'invalid-pixels'),
                              ('import time; time.sleep(10)', 'decode-timeout')]:
            def fixture(*args, **kwargs):
                return real_popen(['/usr/bin/python3', '-I', '-c', script], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
            with patch.object(art.subprocess, 'Popen', fixture), self.subTest(error=error):
                start = time.monotonic()
                with self.assertRaisesRegex(art.ArtworkError, error):
                    art.decode(self.png, self.base)
                self.assertLess(time.monotonic() - start, 4)

    def test_cache_is_bounded_and_recovers_orphaned_work(self):
        cache = self.base / 'cache/omarchy/foamy.lock/artwork'
        cache.mkdir(parents=True, mode=0o700)
        orphan = cache / '.job-abcdefgh'
        orphan.mkdir()
        (orphan / 'input').write_bytes(b'incomplete')
        source = self.base / 'source.png'
        source.write_bytes(self.png)
        with patch.object(art, 'decode') as decode:
            for index in range(20):
                decode.return_value = bytes([index, 0, 0]) * 256 * 256
                art.prepare({'url': source.as_uri(), 'roots': [str(self.base)]})
        self.assertEqual(len(list(cache.glob('*.png'))), art.MAX_CACHE)
        self.assertFalse(orphan.exists())

    def test_real_https_redirect_to_thumbnail(self):
        cert, key = self.base / 'cert.pem', self.base / 'key.pem'
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=images.example.com', '-addext', 'subjectAltName=DNS:images.example.com'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        png, requests = self.png, []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/cover.png')
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(png)))
                    self.end_headers()
                    self.wfile.write(png)
            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client_context = ssl.create_default_context(cafile=str(cert))
        connect = socket.create_connection
        # Only this fixture redirects the checked public IP to the local TLS
        # server. Production DNS and address policy are tested separately above.
        def local_connection(address, timeout):
            self.assertEqual(address, ('8.8.8.8', 443))
            return connect(server.server_address, timeout)
        try:
            with patch.object(art, 'public_addresses', return_value=['8.8.8.8']), \
                    patch.object(art.socket, 'create_connection', local_connection), \
                    patch.object(art.ssl, 'create_default_context', return_value=client_context):
                result = art.prepare({'url': 'https://images.example.com/redirect',
                                      'hosts': ['images.example.com']})
                self.assertTrue(result['ok'])
                self.assertTrue(Path(result['path']).is_file())
                self.assertEqual(requests, ['/redirect', '/cover.png'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_cli_and_cancel_leave_no_job(self):
        source = self.base / 'source.png'
        source.write_bytes(self.png)
        request = json.dumps({'url': source.as_uri(), 'roots': [str(self.base)]}) + '\n'
        result = subprocess.run(['/usr/bin/python3', '-I', str(SOURCE / 'artwork.py')],
                                input=request, text=True, capture_output=True, timeout=10, check=True)
        self.assertTrue(json.loads(result.stdout)['ok'], result.stdout)
        self.assertEqual(result.stderr, '')
        process = subprocess.Popen(['/usr/bin/python3', '-I', str(SOURCE / 'artwork.py')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.1)
        process.send_signal(signal.SIGTERM)
        output, errors = process.communicate(timeout=2)
        self.assertEqual(json.loads(output)['error'], 'cancelled')
        self.assertEqual(errors, b'')
        self.assertEqual(list((self.base / 'cache').rglob('.job-*')), [])


if __name__ == '__main__':
    unittest.main()
