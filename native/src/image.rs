//! The decoder boundary of artwork.py: static PNG/JPEG/WebP only, decoded
//! by ImageMagick inside bubblewrap behind a seccomp filter, rlimits, a
//! deadline and a fixed-size output; the supervisor writes the only PNG
//! that ever reaches the shell. Artwork and the avatar are 256x256
//! thumbnails under artwork.py's limits; a lock-screen `Background` is the
//! screen's size under limits scaled to it, in the same sandbox.

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

/// The bounds of one decoder run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Limits {
    /// Exactly this many bytes of RGB output (also the file-size rlimit).
    output: usize,
    /// `RLIMIT_AS`, bytes.
    address_space: u64,
    /// `RLIMIT_CPU`, seconds.
    cpu: u64,
    /// Wall clock, from spawning bubblewrap.
    deadline: Duration,
}

/// artwork.py's `decoder_limits` and its 3 s deadline.
const THUMBNAIL_LIMITS: Limits = Limits {
    output: PIXEL_BYTES,
    address_space: 256 * 1024 * 1024,
    cpu: 2,
    deadline: Duration::from_secs(3),
};

const MIB: u64 = 1024 * 1024;
pub const MIN_BACKGROUND_SIDE: u64 = 16;
pub const MAX_BACKGROUND_WIDTH: u64 = 7680;
pub const MAX_BACKGROUND_HEIGHT: u64 = 4320;
/// One 3840x2160 screen: the unit the CPU budget grows by.
const UHD_PIXELS: usize = 3840 * 2160;
/// The fill behind transparent pixels, as for thumbnails.
const MATTE: &str = "#171b26";

/// A lock-screen background request: the screen's logical size and how
/// much to blur it (0 none, 1 the most).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Background {
    pub width: usize,
    pub height: usize,
    pub blur: f64,
}

impl Background {
    /// `width` and `height` integers in 16..=7680 and 16..=4320, else
    /// `invalid-size`; `blur` a number in 0..=1, else `invalid-request`.
    pub fn parse(request: &serde_json::Map<String, serde_json::Value>) -> Result<Background, Fail> {
        let side = |key: &str, max: u64| {
            request
                .get(key)
                .and_then(serde_json::Value::as_u64)
                .filter(|side| (MIN_BACKGROUND_SIDE..=max).contains(side))
                .map(|side| side as usize)
                .ok_or(Fail("invalid-size"))
        };
        let width = side("width", MAX_BACKGROUND_WIDTH)?;
        let height = side("height", MAX_BACKGROUND_HEIGHT)?;
        let blur = request
            .get("blur")
            .filter(|blur| blur.is_number())
            .and_then(serde_json::Value::as_f64)
            .filter(|blur| (0.0..=1.0).contains(blur))
            .ok_or(Fail("invalid-request"))?;
        Ok(Background {
            width,
            height,
            blur,
        })
    }

    fn pixels(&self) -> usize {
        self.width * self.height
    }

    /// The exact RGB output: width x height x 3 bytes.
    pub fn pixel_bytes(&self) -> usize {
        self.pixels() * 3
    }

    /// The Gaussian blur's standard deviation in output pixels:
    /// `blur x min(width, height) / 40` (so 27 px at 1 on a 1080-pixel-high
    /// screen); 0 is no blur.
    pub fn sigma(&self) -> f64 {
        self.blur * self.width.min(self.height) as f64 / 40.0
    }

    /// 2 s of CPU plus 1 s per 3840x2160 screen of output (3 s up to 4K,
    /// 6 s at 7680x4320); the deadline is 1 s more, so the whole job stays
    /// within its 9 s.
    fn limits(&self) -> Limits {
        let cpu = 2 + self.pixels().div_ceil(UHD_PIXELS) as u64;
        Limits {
            output: self.pixel_bytes(),
            address_space: 768 * MIB + 32 * self.pixels() as u64,
            cpu,
            deadline: Duration::from_secs(cpu + 1),
        }
    }

    /// The thumbnail policy with room for the screen: sources up to
    /// 16384 pixels a side and 64 megapixels, the pixel cache in memory
    /// only (128 MiB under the address-space limit), the CPU budget as
    /// ImageMagick's own time limit.
    fn policy(&self) -> String {
        let limits = self.limits();
        let memory = limits.address_space / MIB - 128;
        format!(
            r#"<policymap>
  <policy domain="resource" name="width" value="16384"/>
  <policy domain="resource" name="height" value="16384"/>
  <policy domain="resource" name="area" value="64MP"/>
  <policy domain="resource" name="memory" value="{memory}MiB"/>
  <policy domain="resource" name="map" value="0"/>
  <policy domain="resource" name="disk" value="0"/>
  <policy domain="resource" name="thread" value="1"/>
  <policy domain="resource" name="time" value="{cpu}"/>
  <!-- ImageMagick counts internal working images, not only source frames. -->
  <policy domain="resource" name="list-length" value="8"/>
  <policy domain="delegate" rights="none" pattern="*"/>
  <policy domain="filter" rights="none" pattern="*"/>
  <policy domain="coder" rights="none" pattern="*"/>
  <policy domain="coder" rights="read" pattern="{{PNG,JPEG,WEBP}}"/>
  <policy domain="coder" rights="write" pattern="RGB"/>
  <policy domain="path" rights="none" pattern="@*"/>
</policymap>"#,
            cpu = limits.cpu
        )
    }

    /// ImageMagick's arguments: cover-scaled and centre-cropped to exactly
    /// width x height (Qt's `PreserveAspectCrop`), transparency over the
    /// matte, then the blur. A JPEG whose frame header (`jpeg_frame`) says
    /// both sides exceed max(width, height) is decoded at a reduced DCT
    /// scale that still covers that on both sides (so whatever its EXIF
    /// orientation); the hint is never given for a smaller JPEG, which
    /// libjpeg would scale up. The blur runs at a reduced scale,
    /// `min(1/2, 2/sigma)`, with sigma scaled alike (so at most 2 px there),
    /// and is scaled back up with a triangle filter: the look of a
    /// full-size Gaussian at a fraction of the cost.
    fn magick(&self, kind: &str, frame: Option<(u32, u32)>) -> Vec<OsString> {
        let (width, height) = (self.width, self.height);
        let size = format!("{width}x{height}");
        let mut args: Vec<String> = vec![MAGICK.into()];
        let side = width.max(height);
        if kind == "JPEG" && frame.is_some_and(|(w, h)| w.min(h) as usize > side) {
            args.extend(["-define".into(), format!("jpeg:size={side}x{side}")]);
        }
        args.extend([
            format!("{kind}:/input"),
            "-auto-orient".into(),
            "-resize".into(),
            format!("{size}^"),
            "-gravity".into(),
            "center".into(),
            "-extent".into(),
            size.clone(),
            "+repage".into(),
            "-background".into(),
            MATTE.into(),
            "-alpha".into(),
            "remove".into(),
            "-alpha".into(),
            "off".into(),
        ]);
        let sigma = self.sigma();
        if sigma > 0.0 {
            let scale = (2.0 / sigma).min(0.5);
            let reduced = |side: usize| ((side as f64 * scale).round() as usize).max(1);
            args.extend([
                "-filter".into(),
                "Triangle".into(),
                "-resize".into(),
                format!("{}x{}!", reduced(width), reduced(height)),
                "-blur".into(),
                format!("0x{:.3}", sigma * scale),
                "-resize".into(),
                format!("{size}!"),
            ]);
        }
        args.extend([
            "-colorspace".into(),
            "sRGB".into(),
            "-depth".into(),
            "8".into(),
            "RGB:-".into(),
        ]);
        args.into_iter().map(OsString::from).collect()
    }
}

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

/// The width and height in a JPEG's first frame header (SOF0-SOF15 but
/// DHT, JPG and DAC), found by walking the marker segments up to the first
/// scan; `None` when there is none or the walk leaves the data. Only used
/// to decide on a decoder size hint, never trusted for the output.
pub fn jpeg_frame(data: &[u8]) -> Option<(u32, u32)> {
    if !data.starts_with(b"\xff\xd8") {
        return None;
    }
    let mut at = 2;
    loop {
        if *data.get(at)? != 0xff {
            return None;
        }
        // Fill bytes before a marker.
        while *data.get(at + 1)? == 0xff {
            at += 1;
        }
        let marker = *data.get(at + 1)?;
        at += 2;
        match marker {
            0x01 | 0xd0..=0xd7 => continue, // TEM, RSTn: no length
            0xd9 | 0xda => return None,     // EOI, SOS: no frame before the scan
            _ => {}
        }
        let length = u16::from_be_bytes(data.get(at..at + 2)?.try_into().ok()?) as usize;
        if length < 2 {
            return None;
        }
        if matches!(marker, 0xc0..=0xcf) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            let frame = data.get(at + 2..at + 7)?;
            let height = u16::from_be_bytes([frame[1], frame[2]]) as u32;
            let width = u16::from_be_bytes([frame[3], frame[4]]) as u32;
            return (width > 0 && height > 0).then_some((width, height));
        }
        at += length;
    }
}

/// zlib's CRC-32 table (reflected polynomial 0xedb88320).
const CRC_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut n = 0;
    while n < 256 {
        let mut crc = n as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
            bit += 1;
        }
        table[n] = crc;
        n += 1;
    }
    table
};

fn crc32(parts: &[&[u8]]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for part in parts {
        for &byte in *part {
            crc = CRC_TABLE[((crc ^ byte as u32) & 0xff) as usize] ^ (crc >> 8);
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
#[cfg(test)]
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    zlib_stored_into(&mut out, data);
    out
}

fn zlib_stored_into(out: &mut Vec<u8>, data: &[u8]) {
    out.reserve(data.len() + data.len() / 65535 * 5 + 16);
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
}

/// artwork.py's `encode_png`: a 256x256 RGB8 PNG of exactly IHDR, one IDAT
/// (filter 0 rows, stored deflate) and IEND, so no original metadata or
/// compressed stream crosses back into Qt's image decoder.
pub fn encode_png(pixels: &[u8]) -> Result<Vec<u8>, Fail> {
    encode_rgb(SIZE, SIZE, pixels)
}

/// `encode_png` for any size: exactly `width * height * 3` bytes of RGB.
pub fn encode_rgb(width: usize, height: usize, pixels: &[u8]) -> Result<Vec<u8>, Fail> {
    if width == 0 || height == 0 || pixels.len() != width * height * 3 {
        return Err(Fail("invalid-pixels"));
    }
    let mut rows = Vec::with_capacity(height * (width * 3 + 1));
    for row in pixels.chunks(width * 3) {
        rows.push(0);
        rows.extend_from_slice(row);
    }
    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&(width as u32).to_be_bytes());
    header.extend_from_slice(&(height as u32).to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut out = Vec::with_capacity(rows.len() + rows.len() / 65535 * 5 + 64);
    out.extend_from_slice(PNG_MAGIC);
    chunk(&mut out, b"IHDR", &header);
    // IDAT straight into the output (one copy of a screen-sized stream).
    let start = out.len();
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(b"IDAT");
    zlib_stored_into(&mut out, &rows);
    drop(rows);
    let length = out.len() - start - 8;
    out[start..start + 4].copy_from_slice(&(length as u32).to_be_bytes());
    let crc = crc32(&[&out[start + 4..]]);
    out.extend_from_slice(&crc.to_be_bytes());
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
    run(data, staging, POLICY, &THUMBNAIL_LIMITS, |kind| {
        magick(kind)
    })
}

/// `decode` for a lock-screen background: exactly `background.pixel_bytes()`
/// of RGB, under its own policy and limits, in the same sandbox.
pub fn decode_background(
    data: &[u8],
    staging: &Staging,
    background: &Background,
) -> Result<Vec<u8>, Fail> {
    run(
        data,
        staging,
        &background.policy(),
        &background.limits(),
        |kind| background.magick(kind, jpeg_frame(data)),
    )
}

fn run(
    data: &[u8],
    staging: &Staging,
    policy: &str,
    limits: &Limits,
    magick: impl FnOnce(&str) -> Vec<OsString>,
) -> Result<Vec<u8>, Fail> {
    let kind = format(data)?;
    if !is_file(BWRAP) || !is_file(MAGICK) {
        return Err(Fail("decoder-unavailable"));
    }
    let source = staging.write("input", data)?;
    let policy = staging.write("policy.xml", policy.as_bytes())?;
    let filter = BpfFilter::decoder().map_err(|error| match error.kind() {
        ErrorKind::Unsupported => Fail("sandbox-architecture-unsupported"),
        _ => Fail("source-unavailable"),
    })?;
    let filter = filter.memfd()?;
    let output = sandbox(
        sandbox_bwrap(&policy, &source, &filter),
        magick(kind),
        limits,
    )?;
    if output.overflowed {
        return Err(Fail("invalid-pixels"));
    }
    if output.timed_out {
        return Err(Fail("decode-timeout"));
    }
    if !output.status.success() {
        return Err(Fail("decode-failed"));
    }
    if output.stdout.len() != limits.output {
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
#[cfg(test)]
fn command(
    kind: &str,
    policy: &Path,
    source: &Path,
    filter: &std::os::fd::OwnedFd,
) -> (Bwrap, Vec<OsString>) {
    (sandbox_bwrap(policy, source, filter), magick(kind))
}

fn sandbox_bwrap(policy: &Path, source: &Path, filter: &std::os::fd::OwnedFd) -> Bwrap {
    Bwrap::new(BWRAP)
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
        .seccomp(filter)
}

/// artwork.py's ImageMagick arguments for a 256x256 thumbnail.
fn magick(kind: &str) -> Vec<OsString> {
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
        MATTE,
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
    magick.iter().map(OsString::from).collect()
}

/// Runs the sandbox under `limits` (for thumbnails artwork.py's
/// `decoder_limits`: 256 MiB address space, 2 s CPU, files up to the pixel
/// size, and its 3 s deadline), no core dumps and 64 fds, with the
/// environment `PATH=/usr/bin`, stdin from /dev/null and at most
/// `limits.output` bytes of output: a compromised decoder can neither
/// grow the supervisor's memory nor stall it. The kit's `Bounded` also gives
/// bubblewrap its own process group and `PR_SET_PDEATHSIG(SIGKILL)`.
fn sandbox(
    bwrap: Bwrap,
    magick: Vec<OsString>,
    limits: &Limits,
) -> io::Result<foamy_helper::child::Output> {
    let bounded = bwrap
        .bounded(magick)
        .env_clear()
        .env("PATH", "/usr/bin")
        .timeout(limits.deadline)
        .max_output(limits.output)
        .rlimit(Resource::As, limits.address_space)
        .rlimit(Resource::Cpu, limits.cpu)
        .rlimit(Resource::Fsize, limits.output as u64)
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
    fn jpeg_frames_are_found_before_the_scan() {
        let segment = |marker: u8, body: &[u8]| {
            let mut out = vec![0xff, marker];
            out.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
            out.extend_from_slice(body);
            out
        };
        let sof = |marker| segment(marker, &[8, 0x04, 0x38, 0x07, 0x80, 3, 1, 0x22, 0]);
        let mut jpeg = b"\xff\xd8".to_vec();
        jpeg.extend(segment(0xe0, b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0"));
        jpeg.extend(segment(0xc4, &[0; 20])); // DHT is not a frame
        jpeg.extend([0xff, 0xff]); // fill bytes
        jpeg.extend(sof(0xc2));
        jpeg.extend(segment(0xda, &[0; 10]));
        assert_eq!(jpeg_frame(&jpeg), Some((1920, 1080)));
        for marker in [0xc0, 0xc1, 0xc3, 0xc5, 0xcf] {
            let mut data = b"\xff\xd8".to_vec();
            data.extend(sof(marker));
            assert_eq!(jpeg_frame(&data), Some((1920, 1080)), "{marker:x}");
        }
        for marker in [0xc8, 0xcc] {
            let mut data = b"\xff\xd8".to_vec();
            data.extend(sof(marker));
            assert_eq!(jpeg_frame(&data), None, "{marker:x}");
        }
        // A scan or the end before any frame, a truncated walk, a zero
        // size, a bad length or no marker.
        let mut scan_first = b"\xff\xd8".to_vec();
        scan_first.extend(segment(0xda, &[0; 4]));
        scan_first.extend(sof(0xc0));
        assert_eq!(jpeg_frame(&scan_first), None);
        assert_eq!(jpeg_frame(&jpeg[..jpeg.len() - 20]), None);
        let mut zero = b"\xff\xd8".to_vec();
        zero.extend(segment(0xc0, &[8, 0, 0, 0x07, 0x80, 3]));
        assert_eq!(jpeg_frame(&zero), None);
        assert_eq!(jpeg_frame(b"\xff\xd8\xff\xe0\x00\x01"), None);
        assert_eq!(jpeg_frame(b"\xff\xd8\x00"), None);
        assert_eq!(jpeg_frame(b"\xff\xd8"), None);
        assert_eq!(jpeg_frame(PNG_MAGIC), None);
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
    fn crc_table_matches_the_bitwise_crc() {
        let bitwise = |data: &[u8]| {
            let mut crc = 0xffff_ffffu32;
            for &byte in data {
                crc ^= byte as u32;
                for _ in 0..8 {
                    crc = if crc & 1 != 0 {
                        (crc >> 1) ^ 0xedb8_8320
                    } else {
                        crc >> 1
                    };
                }
            }
            !crc
        };
        let data: Vec<u8> = (0..5000u32).map(|i| (i * 31 % 256) as u8).collect();
        assert_eq!(crc32(&[&data]), bitwise(&data));
        assert_eq!(crc32(&[&data[..7], &data[7..]]), bitwise(&data));
    }

    /// The pixel rows of a PNG written by `encode_rgb`.
    fn unpack(png: &[u8]) -> (u32, u32, Vec<u8>) {
        let width = u32::from_be_bytes(png[16..20].try_into().unwrap());
        let height = u32::from_be_bytes(png[20..24].try_into().unwrap());
        let length = u32::from_be_bytes(png[33..37].try_into().unwrap()) as usize;
        assert_eq!(&png[37..41], b"IDAT");
        assert_eq!(
            u32::from_be_bytes(png[41 + length..45 + length].try_into().unwrap()),
            crc32(&[&png[37..41 + length]])
        );
        assert_eq!(
            &png[45 + length..],
            &[0, 0, 0, 0, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82]
        );
        let stream = &png[41..41 + length];
        let (mut at, mut raw) = (2, Vec::new());
        loop {
            let last = stream[at] & 1 == 1;
            let size = u16::from_le_bytes([stream[at + 1], stream[at + 2]]) as usize;
            raw.extend_from_slice(&stream[at + 5..at + 5 + size]);
            at += 5 + size;
            if last {
                break;
            }
        }
        assert_eq!(at + 4, stream.len());
        assert_eq!(
            u32::from_be_bytes(stream[at..].try_into().unwrap()),
            adler32(&raw)
        );
        let mut pixels = Vec::new();
        for line in raw.chunks(width as usize * 3 + 1) {
            assert_eq!(line[0], 0);
            pixels.extend_from_slice(&line[1..]);
        }
        (width, height, pixels)
    }

    #[test]
    fn any_size_encodes_exactly() {
        for (width, height) in [(1, 1), (5, 3), (64, 36), (300, 250)] {
            let pixels: Vec<u8> = (0..width * height * 3)
                .map(|i| (i * 13 % 256) as u8)
                .collect();
            let png = encode_rgb(width, height, &pixels).unwrap();
            assert_eq!(&png[..8], PNG_MAGIC);
            assert_eq!(&png[24..29], &[8, 2, 0, 0, 0]);
            assert_eq!(unpack(&png), (width as u32, height as u32, pixels.clone()));
            let rows = height * (width * 3 + 1);
            let blocks = rows.div_ceil(65535);
            assert_eq!(png.len(), 8 + 25 + 12 + 2 + 5 * blocks + rows + 4 + 12);
            assert_eq!(
                encode_rgb(width, height, &pixels[1..]).unwrap_err().0,
                "invalid-pixels"
            );
        }
        assert_eq!(encode_rgb(0, 3, &[]).unwrap_err().0, "invalid-pixels");
        let pixels = vec![7u8; PIXEL_BYTES];
        assert_eq!(
            encode_png(&pixels).unwrap(),
            encode_rgb(SIZE, SIZE, &pixels).unwrap()
        );
    }

    fn background(request: serde_json::Value) -> Result<Background, Fail> {
        Background::parse(request.as_object().unwrap())
    }

    #[test]
    fn background_sizes_and_blur_are_validated() {
        use serde_json::json;
        let ok = background(json!({"width": 1920, "height": 1080, "blur": 0.25})).unwrap();
        assert_eq!(
            ok,
            Background {
                width: 1920,
                height: 1080,
                blur: 0.25
            }
        );
        for (width, height) in [(16, 16), (7680, 4320), (16, 4320), (7680, 16)] {
            let b = background(json!({"width": width, "height": height, "blur": 0})).unwrap();
            assert_eq!((b.width, b.height, b.blur), (width, height, 0.0));
        }
        assert_eq!(
            background(json!({"width": 64, "height": 36, "blur": 1}))
                .unwrap()
                .blur,
            1.0
        );
        for size in [
            json!({"width": 15, "height": 1080}),
            json!({"width": 7681, "height": 1080}),
            json!({"width": 1920, "height": 15}),
            json!({"width": 1920, "height": 4321}),
            json!({"width": -1920, "height": 1080}),
            json!({"width": 1920.0, "height": 1080}),
            json!({"width": 1920.5, "height": 1080}),
            json!({"width": "1920", "height": 1080}),
            json!({"width": true, "height": 1080}),
            json!({"width": null, "height": 1080}),
            json!({"width": 1920}),
            json!({"height": 1080}),
            json!({"width": 18446744073709551615u64, "height": 1080}),
        ] {
            let mut request = size.as_object().unwrap().clone();
            request.insert("blur".into(), json!(0));
            assert_eq!(
                Background::parse(&request).unwrap_err().0,
                "invalid-size",
                "{size}"
            );
        }
        for blur in [
            json!(-0.01),
            json!(1.01),
            json!("0.5"),
            json!(true),
            json!(null),
            json!([0]),
        ] {
            assert_eq!(
                background(json!({"width": 64, "height": 36, "blur": blur}))
                    .unwrap_err()
                    .0,
                "invalid-request",
                "{blur}"
            );
        }
        assert_eq!(
            background(json!({"width": 64, "height": 36}))
                .unwrap_err()
                .0,
            "invalid-request"
        );
        // The size is checked before the blur.
        assert_eq!(
            background(json!({"width": 1, "height": 36, "blur": 9}))
                .unwrap_err()
                .0,
            "invalid-size"
        );
    }

    #[test]
    fn background_limits_scale_with_the_screen() {
        let at = |width, height| Background {
            width,
            height,
            blur: 0.0,
        };
        let small = at(16, 16).limits();
        assert_eq!(
            small,
            Limits {
                output: 16 * 16 * 3,
                address_space: 768 * MIB + 32 * 256,
                cpu: 3,
                deadline: Duration::from_secs(4),
            }
        );
        assert_eq!(at(1920, 1080).limits().cpu, 3);
        assert_eq!(at(3840, 2160).limits().cpu, 3);
        assert_eq!(at(3841, 2160).limits().cpu, 4);
        let largest = at(7680, 4320).limits();
        assert_eq!(largest.output, 7680 * 4320 * 3);
        assert_eq!(largest.cpu, 6);
        assert_eq!(largest.deadline, Duration::from_secs(7));
        assert_eq!(largest.address_space, 768 * MIB + 32 * 7680 * 4320);
        // Within the whole job's 9 s.
        assert!(largest.deadline < crate::JOB_DEADLINE);
        let policy = at(7680, 4320).policy();
        assert!(
            policy.contains(r#"name="memory" value="1652MiB""#),
            "{policy}"
        );
        assert!(policy.contains(r#"name="time" value="6""#));
        assert!(policy.contains(r#"name="area" value="64MP""#));
        assert!(policy.contains(r#"pattern="{PNG,JPEG,WEBP}""#));
        assert!(
            at(16, 16)
                .policy()
                .contains(r#"name="memory" value="640MiB""#)
        );
        // Everything but the scaled resources is the thumbnail policy.
        let same = |text: &str| -> Vec<String> {
            text.lines()
                .filter(|line| {
                    !["width", "height", "area", "memory", "time"]
                        .iter()
                        .any(|name| line.contains(&format!(r#"name="{name}""#)))
                })
                .map(str::to_string)
                .collect()
        };
        assert_eq!(same(&at(64, 36).policy()), same(POLICY));
    }

    #[test]
    fn background_blur_follows_the_formula() {
        let at = |width, height, blur| Background {
            width,
            height,
            blur,
        };
        assert_eq!(at(1920, 1080, 1.0).sigma(), 27.0);
        assert_eq!(at(1080, 1920, 0.5).sigma(), 13.5);
        assert_eq!(at(64, 36, 0.0).sigma(), 0.0);
        let args = |b: Background, kind, frame| -> Vec<String> {
            b.magick(kind, frame)
                .into_iter()
                .map(|a| a.into_string().unwrap())
                .collect()
        };
        let cover = [
            "-auto-orient",
            "-resize",
            "1920x1080^",
            "-gravity",
            "center",
            "-extent",
            "1920x1080",
            "+repage",
            "-background",
            "#171b26",
            "-alpha",
            "remove",
            "-alpha",
            "off",
        ];
        let tail = ["-colorspace", "sRGB", "-depth", "8", "RGB:-"];
        let mut expected = vec!["/usr/bin/magick", "PNG:/input"];
        expected.extend(cover);
        expected.extend(tail);
        assert_eq!(args(at(1920, 1080, 0.0), "PNG", None), expected);
        // sigma 27: blurred at 2/27 scale with sigma 2.
        let mut expected = vec![
            "/usr/bin/magick",
            "-define",
            "jpeg:size=1920x1920",
            "JPEG:/input",
        ];
        expected.extend(cover);
        expected.extend([
            "-filter",
            "Triangle",
            "-resize",
            "142x80!",
            "-blur",
            "0x2.000",
            "-resize",
            "1920x1080!",
        ]);
        expected.extend(tail);
        assert_eq!(
            args(at(1920, 1080, 1.0), "JPEG", Some((4000, 3000))),
            expected
        );
        // No hint for a JPEG that would have to be scaled up, or unknown.
        expected.drain(1..3);
        for frame in [Some((1920, 1920)), Some((8000, 1900)), None] {
            assert_eq!(args(at(1920, 1080, 1.0), "JPEG", frame), expected);
        }
        // A small sigma is blurred at half scale.
        let small = args(at(64, 36, 0.1), "WEBP", Some((4000, 3000)));
        assert_eq!(small[1], "WEBP:/input");
        let blur = small.iter().position(|a| a == "-blur").unwrap();
        assert_eq!(
            &small[blur - 1..blur + 4],
            ["32x18!", "-blur", "0x0.045", "-resize", "64x36!"]
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
