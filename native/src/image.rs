//! The decoder boundary of artwork.py: static PNG/JPEG/WebP only, decoded
//! by ImageMagick inside bubblewrap behind a seccomp filter, rlimits, a
//! three-second deadline and a fixed-size output; the supervisor writes
//! the only PNG that ever reaches the shell.

use std::ffi::OsString;
use std::io::{self, ErrorKind};
use std::path::Path;
use std::time::Duration;

use foamy_helper::process::Resource;
use foamy_helper::sandbox::{BpfFilter, Bwrap};

use crate::Fail;
use crate::store::Staging;

pub const SIZE: usize = 256;
pub const PIXEL_BYTES: usize = SIZE * SIZE * 3;
pub const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";

/// artwork.py's private ImageMagick policy, byte for byte.
pub const POLICY: &str = r#"<policymap>
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
</policymap>"#;

const BWRAP: &str = "/usr/bin/bwrap";
const MAGICK: &str = "/usr/bin/magick";
const DEADLINE: Duration = Duration::from_secs(3);

fn be32(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

fn le32(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// artwork.py's `image_format`: the ImageMagick coder for a static PNG,
/// JPEG or WebP; animated PNG (acTL) and WebP (ANIM, ANMF, VP8X animation
/// flag) are refused.
pub fn format(data: &[u8]) -> Result<&'static str, Fail> {
    if data.starts_with(PNG_MAGIC) {
        let mut offset: u64 = 8;
        while offset + 12 <= data.len() as u64 {
            let at = offset as usize;
            let size = be32(data, at).unwrap_or(0) as u64;
            if &data[at + 4..at + 8] == b"acTL" {
                return Err(Fail("animated-image"));
            }
            offset += size + 12;
        }
        return Ok("PNG");
    }
    if data.starts_with(b"\xff\xd8\xff") {
        return Ok("JPEG");
    }
    if data.starts_with(b"RIFF") && data.get(8..12) == Some(b"WEBP") {
        let mut offset: u64 = 12;
        while offset + 8 <= data.len() as u64 {
            let at = offset as usize;
            let kind = &data[at..at + 4];
            let size = le32(data, at + 4).unwrap_or(0) as u64;
            let animated_flag = kind == b"VP8X"
                && size != 0
                && data.get(at + 8).is_some_and(|flags| flags & 2 != 0);
            if kind == b"ANIM" || kind == b"ANMF" || animated_flag {
                return Err(Fail("animated-image"));
            }
            offset += 8 + size + (size & 1);
        }
        return Ok("WEBP");
    }
    Err(Fail("unsupported-format"))
}

fn crc32(parts: &[&[u8]]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for part in parts {
        for &byte in *part {
            crc ^= byte as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
    }
    !crc
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(5552) {
        for &byte in chunk {
            a += byte as u32;
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc32(&[kind, data]).to_be_bytes());
}

/// A zlib stream of stored (uncompressed) deflate blocks: `zlib.compress(
/// data, level=0)` up to the block boundaries.
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + data.len() / 65535 * 5 + 16);
    out.extend_from_slice(&[0x78, 0x01]);
    let blocks: Vec<&[u8]> = if data.is_empty() {
        vec![&[][..]]
    } else {
        data.chunks(65535).collect()
    };
    for (index, block) in blocks.iter().enumerate() {
        out.push(u8::from(index + 1 == blocks.len()));
        let length = block.len() as u16;
        out.extend_from_slice(&length.to_le_bytes());
        out.extend_from_slice(&(!length).to_le_bytes());
        out.extend_from_slice(block);
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

/// artwork.py's `encode_png`: a 256x256 RGB8 PNG of exactly IHDR, one IDAT
/// (filter 0 rows, stored deflate) and IEND, so no original metadata or
/// compressed stream crosses back into Qt's image decoder.
pub fn encode_png(pixels: &[u8]) -> Result<Vec<u8>, Fail> {
    if pixels.len() != PIXEL_BYTES {
        return Err(Fail("invalid-pixels"));
    }
    let mut rows = Vec::with_capacity(SIZE * (SIZE * 3 + 1));
    for row in pixels.chunks(SIZE * 3) {
        rows.push(0);
        rows.extend_from_slice(row);
    }
    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&(SIZE as u32).to_be_bytes());
    header.extend_from_slice(&(SIZE as u32).to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut out = PNG_MAGIC.to_vec();
    chunk(&mut out, b"IHDR", &header);
    chunk(&mut out, b"IDAT", &zlib_stored(&rows));
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}

fn is_file(path: &str) -> bool {
    std::fs::metadata(path).is_ok_and(|meta| meta.is_file())
}

/// artwork.py's `decode(data, directory)`: the RGB pixels of a 256x256
/// thumbnail, from ImageMagick in a fresh bubblewrap sandbox. There is no
/// unsandboxed fallback: without bubblewrap the job fails.
pub fn decode(data: &[u8], staging: &Staging) -> Result<Vec<u8>, Fail> {
    let kind = format(data)?;
    if !is_file(BWRAP) || !is_file(MAGICK) {
        return Err(Fail("decoder-unavailable"));
    }
    let source = staging.write("input", data)?;
    let policy = staging.write("policy.xml", POLICY.as_bytes())?;
    let filter = BpfFilter::decoder().map_err(|error| match error.kind() {
        ErrorKind::Unsupported => Fail("sandbox-architecture-unsupported"),
        _ => Fail("source-unavailable"),
    })?;
    let filter = filter.memfd()?;
    let output = sandbox(kind, &policy, &source, &filter)?;
    if output.overflowed {
        return Err(Fail("invalid-pixels"));
    }
    if output.timed_out {
        return Err(Fail("decode-timeout"));
    }
    if !output.status.success() {
        return Err(Fail("decode-failed"));
    }
    if output.stdout.len() != PIXEL_BYTES {
        return Err(Fail("invalid-pixels"));
    }
    Ok(output.stdout)
}

/// artwork.py's bubblewrap command line, in its order: every namespace
/// unshared (no network), all capabilities dropped, a new session, dying
/// with this helper, read-only /usr with the usual symlinks, fresh /proc
/// and /dev, the private policy as ImageMagick's only configuration, the
/// image as /input, an empty environment but four variables, / remounted
/// read-only, and the seccomp filter installed by bubblewrap just before
/// it executes ImageMagick.
fn command(
    kind: &str,
    policy: &Path,
    source: &Path,
    filter: &std::os::fd::OwnedFd,
) -> (Bwrap, Vec<OsString>) {
    let bwrap = Bwrap::new(BWRAP)
        .unshare_all()
        .die_with_parent()
        .new_session()
        .cap_drop("ALL")
        .ro_bind("/usr", "/usr")
        .symlink("usr/lib", "/lib")
        .symlink("usr/lib", "/lib64")
        .symlink("usr/bin", "/bin")
        .proc("/proc")
        .dev("/dev")
        .dir("/etc")
        .dir("/etc/ImageMagick-7")
        .ro_bind(policy, "/etc/ImageMagick-7/policy.xml")
        .ro_bind(source, "/input")
        .chdir("/")
        .clearenv()
        .setenv("PATH", "/usr/bin")
        .setenv("HOME", "/nonexistent")
        .setenv("MAGICK_CONFIGURE_PATH", "/etc/ImageMagick-7")
        .setenv("OMP_NUM_THREADS", "1")
        .remount_ro("/")
        .seccomp(filter);
    let input = format!("{kind}:/input");
    let magick = [
        MAGICK,
        &input,
        "-auto-orient",
        "-thumbnail",
        "256x256^",
        "-gravity",
        "center",
        "-extent",
        "256x256",
        "-background",
        "#171b26",
        "-alpha",
        "remove",
        "-alpha",
        "off",
        "-colorspace",
        "sRGB",
        "-depth",
        "8",
        "RGB:-",
    ];
    (bwrap, magick.iter().map(OsString::from).collect())
}

/// Runs the sandbox under artwork.py's `decoder_limits` (256 MiB address
/// space, 2 s CPU, files up to the pixel size, no core dumps, 64 fds), with
/// the environment `PATH=/usr/bin`, stdin from /dev/null, the 3 s deadline
/// and at most `PIXEL_BYTES` of output: a compromised decoder can neither
/// grow the supervisor's memory nor stall it. The kit's `Bounded` also gives
/// bubblewrap its own process group and `PR_SET_PDEATHSIG(SIGKILL)`.
fn sandbox(
    kind: &str,
    policy: &Path,
    source: &Path,
    filter: &std::os::fd::OwnedFd,
) -> io::Result<foamy_helper::child::Output> {
    let (bwrap, magick) = command(kind, policy, source, filter);
    let bounded = bwrap
        .bounded(magick)
        .env_clear()
        .env("PATH", "/usr/bin")
        .timeout(DEADLINE)
        .max_output(PIXEL_BYTES)
        .rlimit(Resource::As, 256 * 1024 * 1024)
        .rlimit(Resource::Cpu, 2)
        .rlimit(Resource::Fsize, PIXEL_BYTES as u64)
        .rlimit(Resource::Core, 0)
        .rlimit(Resource::Nofile, 64);
    crate::signals_unblocked(|| bounded.run())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_follow_artwork_py() {
        assert_eq!(format(b"\xff\xd8\xff\xe0").unwrap(), "JPEG");
        assert_eq!(format(PNG_MAGIC).unwrap(), "PNG");
        let mut apng = PNG_MAGIC.to_vec();
        chunk(&mut apng, b"IHDR", &[0; 13]);
        chunk(&mut apng, b"acTL", &[0; 8]);
        assert_eq!(format(&apng).unwrap_err().0, "animated-image");
        // A chunk length pointing past the end ends the scan.
        let mut long = PNG_MAGIC.to_vec();
        long.extend_from_slice(&[0xff, 0xff, 0xff, 0xff, b'I', b'D', b'A', b'T', 0, 0, 0, 0]);
        long.extend_from_slice(b"\0\0\0\0acTL\0\0\0\0");
        assert_eq!(format(&long).unwrap(), "PNG");
        assert_eq!(
            format(b"RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\x02").unwrap_err().0,
            "animated-image"
        );
        assert_eq!(
            format(b"RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\x01").unwrap(),
            "WEBP"
        );
        assert_eq!(format(b"RIFF\0\0\0\0WEBPVP8X\0\0\0\0\x02").unwrap(), "WEBP");
        assert_eq!(
            format(b"RIFF\0\0\0\0WEBPVP8 \x01\0\0\0\0\0ANIM\0\0\0\0")
                .unwrap_err()
                .0,
            "animated-image"
        );
        assert_eq!(format(b"GIF89a").unwrap_err().0, "unsupported-format");
        assert_eq!(format(b"").unwrap_err().0, "unsupported-format");
    }

    #[test]
    fn checksums_match_zlib() {
        assert_eq!(crc32(&[b"IEND"]), 0xae42_6082);
        assert_eq!(crc32(&[b"123456789"]), 0xcbf4_3926);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
        assert_eq!(adler32(&vec![0xff; 100_000]), {
            let (mut a, mut b) = (1u64, 0u64);
            for _ in 0..100_000 {
                a = (a + 255) % 65521;
                b = (b + a) % 65521;
            }
            ((b << 16) | a) as u32
        });
    }

    #[test]
    fn generated_png_is_minimal_and_exact() {
        let pixels: Vec<u8> = (0..PIXEL_BYTES).map(|i| (i * 7 % 251) as u8).collect();
        let png = encode_png(&pixels).unwrap();
        assert_eq!(&png[..8], PNG_MAGIC);
        assert_eq!(&png[12..16], b"IHDR");
        assert_eq!(&png[16..29], &[0, 0, 1, 0, 0, 0, 1, 0, 8, 2, 0, 0, 0]);
        assert_eq!(
            &png[png.len() - 12..],
            &[0, 0, 0, 0, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82]
        );
        let idat_length = u32::from_be_bytes(png[33..37].try_into().unwrap()) as usize;
        assert_eq!(&png[37..41], b"IDAT");
        assert_eq!(41 + idat_length + 4 + 12, png.len());
        let stream = &png[41..41 + idat_length];
        // Undo the stored blocks by hand.
        let (mut at, mut raw) = (2, Vec::new());
        loop {
            let last = stream[at] & 1 == 1;
            assert_eq!(stream[at] >> 1, 0);
            let length = u16::from_le_bytes([stream[at + 1], stream[at + 2]]) as usize;
            assert_eq!(
                !u16::from_le_bytes([stream[at + 3], stream[at + 4]]) as usize,
                length
            );
            raw.extend_from_slice(&stream[at + 5..at + 5 + length]);
            at += 5 + length;
            if last {
                break;
            }
        }
        assert_eq!(
            u32::from_be_bytes(stream[at..at + 4].try_into().unwrap()),
            adler32(&raw)
        );
        assert_eq!(raw.len(), SIZE * (SIZE * 3 + 1));
        for (row, line) in raw.chunks(SIZE * 3 + 1).enumerate() {
            assert_eq!(line[0], 0);
            assert_eq!(&line[1..], &pixels[row * SIZE * 3..(row + 1) * SIZE * 3]);
        }
        assert_eq!(encode_png(&pixels[1..]).unwrap_err().0, "invalid-pixels");
        assert_eq!(
            zlib_stored(b""),
            vec![0x78, 0x01, 1, 0, 0, 0xff, 0xff, 0, 0, 0, 1]
        );
    }

    #[test]
    fn command_line_is_artwork_py() {
        let fd: std::os::fd::OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        let (bwrap, magick) = command(
            "PNG",
            Path::new("/s/policy.xml"),
            Path::new("/s/input"),
            &fd,
        );
        let argv: Vec<String> = bwrap
            .argv(magick)
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        let fd = std::os::fd::AsRawFd::as_raw_fd(&fd).to_string();
        let expected = [
            "/usr/bin/bwrap",
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--cap-drop",
            "ALL",
            "--ro-bind",
            "/usr",
            "/usr",
            "--symlink",
            "usr/lib",
            "/lib",
            "--symlink",
            "usr/lib",
            "/lib64",
            "--symlink",
            "usr/bin",
            "/bin",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--dir",
            "/etc",
            "--dir",
            "/etc/ImageMagick-7",
            "--ro-bind",
            "/s/policy.xml",
            "/etc/ImageMagick-7/policy.xml",
            "--ro-bind",
            "/s/input",
            "/input",
            "--chdir",
            "/",
            "--clearenv",
            "--setenv",
            "PATH",
            "/usr/bin",
            "--setenv",
            "HOME",
            "/nonexistent",
            "--setenv",
            "MAGICK_CONFIGURE_PATH",
            "/etc/ImageMagick-7",
            "--setenv",
            "OMP_NUM_THREADS",
            "1",
            "--remount-ro",
            "/",
            "--seccomp",
            &fd,
            "/usr/bin/magick",
            "PNG:/input",
            "-auto-orient",
            "-thumbnail",
            "256x256^",
            "-gravity",
            "center",
            "-extent",
            "256x256",
            "-background",
            "#171b26",
            "-alpha",
            "remove",
            "-alpha",
            "off",
            "-colorspace",
            "sRGB",
            "-depth",
            "8",
            "RGB:-",
        ];
        assert_eq!(argv, expected);
    }
}
