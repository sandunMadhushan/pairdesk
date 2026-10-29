// SPDX-License-Identifier: GPL-3.0-or-later
//! Screen view as H.264 video (OpenH264, built from source), for phones
//! that can decode it. Much smoother and lighter than JPEG rectangles when
//! a lot changes (scrolling, video, dragging windows).
//!
//! Binary frame (little-endian), one WebSocket binary message:
//!
//! ```text
//! "PDV1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | flags u8 | len u32 | H.264
//! ```
//!
//! `flags` bit 0: the H.264 data starts with a key frame (IDR, with SPS and
//! PPS). The data is one access unit in Annex B form (start codes). `len` 0
//! means only the cursor moved. The first frame, and the first after
//! `screen_refresh`, is a key frame.

use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, Complexity, Encoder, EncoderConfig, FrameRate, FrameType, RateControlMode, UsageType,
};
use openh264::formats::{BgraSliceU8, YUVBuffer};

use super::encode::Quality;

pub const MAGIC: &[u8; 4] = b"PDV1";
pub const FLAG_KEYFRAME: u8 = 1;

pub struct VideoEncoder {
    encoder: Encoder,
    yuv: YUVBuffer,
    width: u32,
    height: u32,
}

impl VideoEncoder {
    /// `width` and `height` must be even.
    pub fn new(width: u32, height: u32, quality: &Quality) -> Result<Self, String> {
        let config = EncoderConfig::new()
            .usage_type(UsageType::ScreenContentRealTime)
            .rate_control_mode(RateControlMode::Bitrate)
            .bitrate(BitRate::from_bps(quality.bitrate))
            .max_frame_rate(FrameRate::from_hz(quality.video_fps as f32))
            .complexity(Complexity::Low)
            // Under heavy change (a playing video) drop frames rather than
            // fall behind; the phone acknowledges what it shows anyway.
            .skip_frames(true)
            .adaptive_quantization(false)
            .background_detection(false);
        let encoder = Encoder::with_api_config(OpenH264API::from_source(), config)
            .map_err(|e| format!("H.264 encoder: {e}"))?;
        Ok(Self {
            encoder,
            yuv: YUVBuffer::new(width as usize, height as usize),
            width,
            height,
        })
    }

    /// Encodes one BGRA frame of the encoder's size. Returns the access unit
    /// (empty if the encoder skipped the frame) and whether it's a key frame.
    pub fn encode(&mut self, bgra: &[u8], key: bool) -> Result<(Vec<u8>, bool), String> {
        let (w, h) = (self.width as usize, self.height as usize);
        if bgra.len() != w * h * 4 {
            return Err("frame size doesn't match the encoder".into());
        }
        self.yuv.read_rgb(BgraSliceU8::new(bgra, (w, h)));
        if key {
            self.encoder.force_intra_frame();
        }
        let bits = self
            .encoder
            .encode(&self.yuv)
            .map_err(|e| format!("H.264 encoding failed: {e}"))?;
        let keyframe = bits.frame_type() == FrameType::IDR;
        if matches!(bits.frame_type(), FrameType::Skip | FrameType::Invalid) {
            return Ok((Vec::new(), false));
        }
        Ok((bits.to_vec(), keyframe))
    }
}

pub fn frame_message(
    seq: u32,
    w: u32,
    h: u32,
    cursor: Option<(i32, i32)>,
    keyframe: bool,
    data: &[u8],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(21 + data.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&(w as u16).to_le_bytes());
    out.extend_from_slice(&(h as u16).to_le_bytes());
    let (cx, cy) = cursor.unwrap_or((-1, -1));
    out.extend_from_slice(&(cx as i16).to_le_bytes());
    out.extend_from_slice(&(cy as i16).to_le_bytes());
    out.push(if keyframe { FLAG_KEYFRAME } else { 0 });
    out.extend_from_slice(&(data.len() as u32).to_le_bytes());
    out.extend_from_slice(data);
    out
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use openh264::decoder::Decoder;
    use openh264::formats::YUVSource;

    /// A screen-like BGRA picture: title bar, lines of "text", a box at `x`.
    pub fn screen(w: usize, h: usize, x: usize) -> Vec<u8> {
        let mut px = vec![0u8; w * h * 4];
        for y in 0..h {
            for col in 0..w {
                let mut c = [240u8, 240, 240];
                if y < 30 {
                    c = [60, 60, 70];
                }
                if y > 50 && (y % 14) < 9 && col > 30 && col < w - 60 && (col / 7) % 3 != 0 {
                    c = [30, 30, 30];
                }
                if (x..x + 80).contains(&col) && (120..200).contains(&y) {
                    c = [210, 80, 40];
                }
                let i = (y * w + col) * 4;
                px[i..i + 4].copy_from_slice(&[c[2], c[1], c[0], 0]);
            }
        }
        px
    }

    /// Peak signal-to-noise ratio between a decoded RGB picture and BGRA.
    pub fn psnr(rgb: &[u8], bgra: &[u8]) -> f64 {
        let n = rgb.len() / 3;
        let mut se = 0f64;
        for i in 0..n {
            for c in 0..3 {
                let d = rgb[i * 3 + c] as f64 - bgra[i * 4 + 2 - c] as f64;
                se += d * d;
            }
        }
        10.0 * (255.0f64 * 255.0 / (se / (n * 3) as f64)).log10()
    }

    #[test]
    fn encodes_a_screen_that_decodes_back() {
        let (w, h) = (640usize, 360usize);
        let q = Quality::preset("medium");
        let mut enc = VideoEncoder::new(w as u32, h as u32, &q).unwrap();
        let mut dec = Decoder::new().unwrap();
        let mut sizes = Vec::new();
        for i in 0..6 {
            let src = screen(w, h, 50 + i * 20);
            let (data, key) = enc.encode(&src, i == 0 || i == 4).unwrap();
            assert_eq!(key, i == 0 || i == 4, "frame {i}");
            sizes.push(data.len());
            let pic = dec.decode(&data).unwrap().expect("a picture per frame");
            assert_eq!(pic.dimensions(), (w, h));
            let mut rgb = vec![0u8; w * h * 3];
            pic.write_rgb8(&mut rgb);
            let quality = psnr(&rgb, &src);
            assert!(quality > 30.0, "frame {i}: {quality:.1} dB");
        }
        // Changes cost a fraction of a key frame.
        assert!(sizes[1] * 5 < sizes[0], "{sizes:?}");
    }

    #[test]
    fn an_unchanged_picture_still_makes_a_tiny_frame() {
        // Sent once after a change, so phone decoders that hold back the
        // latest picture until the next input show it.
        let (w, h) = (640usize, 360usize);
        let mut enc = VideoEncoder::new(w as u32, h as u32, &Quality::preset("medium")).unwrap();
        let a = screen(w, h, 50);
        let b = screen(w, h, 90);
        enc.encode(&a, true).unwrap();
        let (changed, _) = enc.encode(&b, false).unwrap();
        let (repeat, key) = enc.encode(&b, false).unwrap();
        assert!(!key);
        assert!(!repeat.is_empty(), "the encoder skipped the repeat");
        assert!(
            repeat.len() < 200 && repeat.len() < changed.len(),
            "{}",
            repeat.len()
        );
    }

    #[test]
    fn odd_sizes_are_refused_by_the_caller_check() {
        let mut enc = VideoEncoder::new(64, 64, &Quality::preset("low")).unwrap();
        assert!(enc.encode(&[0u8; 10], false).is_err());
    }

    #[test]
    fn frame_layout() {
        let m = frame_message(7, 640, 360, Some((10, -1)), true, b"\0\0\0\x01\x67");
        assert_eq!(&m[0..4], b"PDV1");
        assert_eq!(u32::from_le_bytes(m[4..8].try_into().unwrap()), 7);
        assert_eq!(u16::from_le_bytes(m[8..10].try_into().unwrap()), 640);
        assert_eq!(i16::from_le_bytes(m[14..16].try_into().unwrap()), -1);
        assert_eq!(m[16], FLAG_KEYFRAME);
        assert_eq!(u32::from_le_bytes(m[17..21].try_into().unwrap()), 5);
        assert_eq!(&m[21..], b"\0\0\0\x01\x67");
        let y = YUVBuffer::new(4, 4);
        assert_eq!(y.dimensions(), (4, 4));
    }
}
