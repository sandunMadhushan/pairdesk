// SPDX-License-Identifier: GPL-3.0-or-later
//! Turning captured frames into small updates for the phone: scale down,
//! find the 64×64 tiles that changed since the last frame, merge them into
//! rectangles and JPEG-encode just those.
//!
//! Binary frame (little-endian), one WebSocket binary message:
//!
//! ```text
//! "PDS1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | count u16
//! then `count` times: x u16 | y u16 | w u16 | h u16 | len u32 | JPEG bytes
//! ```
//!
//! `width`/`height` are the scaled frame size; cursor is in scaled
//! pixels, or -1 when the pointer is on another monitor. A frame with no
//! rectangles only moves the cursor.

use fast_image_resize as fir;

pub const MAGIC: &[u8; 4] = b"PDS1";
pub const TILE: u32 = 64;
/// Above this share of changed area, one full frame is cheaper.
const FULL_FRAME_SHARE: f32 = 0.5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Quality {
    pub max_width: u32,
    pub jpeg: u8,
    pub fps: u32,
    /// H.264 (video mode): target bits per second and frames per second.
    pub bitrate: u32,
    pub video_fps: u32,
}

impl Quality {
    pub fn preset(name: &str) -> Self {
        match name {
            "low" => Self {
                max_width: 960,
                jpeg: 50,
                fps: 8,
                bitrate: 1_000_000,
                video_fps: 15,
            },
            "high" => Self {
                max_width: 1920,
                jpeg: 80,
                fps: 15,
                bitrate: 5_000_000,
                video_fps: 30,
            },
            _ => Self {
                max_width: 1280,
                jpeg: 65,
                fps: 12,
                bitrate: 2_500_000,
                video_fps: 24,
            },
        }
    }
}

/// Size after scaling to at most `max_width`, keeping the shape. Even
/// numbers keep JPEG colour subsampling tidy.
pub fn scaled_size(w: u32, h: u32, max_width: u32) -> (u32, u32) {
    let (sw, sh) = if w <= max_width {
        (w, h)
    } else {
        (
            max_width,
            ((h as u64 * max_width as u64 + w as u64 / 2) / w as u64) as u32,
        )
    };
    ((sw & !1).max(2), (sh & !1).max(2))
}

pub struct Scaler {
    resizer: fir::Resizer,
}

impl Default for Scaler {
    fn default() -> Self {
        Self {
            resizer: fir::Resizer::new(),
        }
    }
}

impl Scaler {
    /// Scales a BGRA image. The 4th byte is ignored (GDI leaves it at 0).
    pub fn scale(
        &mut self,
        data: &[u8],
        w: u32,
        h: u32,
        dw: u32,
        dh: u32,
    ) -> Result<Vec<u8>, String> {
        if (w, h) == (dw, dh) {
            return Ok(data.to_vec());
        }
        let src = fir::images::ImageRef::new(w, h, data, fir::PixelType::U8x4)
            .map_err(|e| e.to_string())?;
        let mut dst = fir::images::Image::new(dw, dh, fir::PixelType::U8x4);
        let options = fir::ResizeOptions::new()
            .resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Bilinear))
            .use_alpha(false);
        self.resizer
            .resize(&src, &mut dst, &options)
            .map_err(|e| e.to_string())?;
        Ok(dst.into_vec())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// Rectangles covering every tile that differs between `prev` and `cur`
/// (both BGRA, `w`×`h`). With no previous frame, the whole frame.
pub fn changed_rects(prev: Option<&[u8]>, cur: &[u8], w: u32, h: u32) -> Vec<Rect> {
    let full = vec![Rect { x: 0, y: 0, w, h }];
    let Some(prev) = prev else { return full };
    if prev.len() != cur.len() {
        return full;
    }
    let cols = w.div_ceil(TILE);
    let rows = h.div_ceil(TILE);
    let stride = (w * 4) as usize;

    let mut rects: Vec<Rect> = Vec::new();
    let mut changed_area: u64 = 0;
    for row in 0..rows {
        let y0 = row * TILE;
        let th = TILE.min(h - y0);
        let mut run: Option<(u32, u32)> = None; // (first col, last col)
        for col in 0..=cols {
            let differs = col < cols && {
                let x0 = col * TILE;
                let tw = TILE.min(w - x0);
                (y0..y0 + th).any(|y| {
                    let start = y as usize * stride + x0 as usize * 4;
                    let end = start + tw as usize * 4;
                    prev[start..end] != cur[start..end]
                })
            };
            match (differs, run) {
                (true, None) => run = Some((col, col)),
                (true, Some((a, _))) => run = Some((a, col)),
                (false, Some((a, b))) => {
                    let x = a * TILE;
                    let rw = ((b + 1) * TILE).min(w) - x;
                    changed_area += (rw * th) as u64;
                    // Grow a rectangle from the row above with the same span.
                    if let Some(r) = rects
                        .iter_mut()
                        .find(|r| r.x == x && r.w == rw && r.y + r.h == y0)
                    {
                        r.h += th;
                    } else {
                        rects.push(Rect {
                            x,
                            y: y0,
                            w: rw,
                            h: th,
                        });
                    }
                    run = None;
                }
                (false, None) => {}
            }
        }
    }
    if changed_area as f32 > FULL_FRAME_SHARE * (w as u64 * h as u64) as f32 {
        return full;
    }
    rects
}

/// JPEG-encodes one rectangle of a BGRA image `w` pixels wide.
pub fn encode_rect(img: &[u8], w: u32, r: Rect, quality: u8) -> Result<Vec<u8>, String> {
    let stride = (w * 4) as usize;
    let mut part = Vec::with_capacity((r.w * r.h * 4) as usize);
    for y in r.y..r.y + r.h {
        let start = y as usize * stride + r.x as usize * 4;
        part.extend_from_slice(&img[start..start + r.w as usize * 4]);
    }
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, quality)
        .encode(&part, r.w as u16, r.h as u16, jpeg_encoder::ColorType::Bgra)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

pub fn frame_message(
    seq: u32,
    w: u32,
    h: u32,
    cursor: Option<(i32, i32)>,
    parts: &[(Rect, Vec<u8>)],
) -> Vec<u8> {
    let size: usize = 18 + parts.iter().map(|(_, j)| 12 + j.len()).sum::<usize>();
    let mut out = Vec::with_capacity(size);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&(w as u16).to_le_bytes());
    out.extend_from_slice(&(h as u16).to_le_bytes());
    let (cx, cy) = cursor
        .map(|(x, y)| (x as i16, y as i16))
        .unwrap_or((-1, -1));
    out.extend_from_slice(&cx.to_le_bytes());
    out.extend_from_slice(&cy.to_le_bytes());
    out.extend_from_slice(&(parts.len() as u16).to_le_bytes());
    for (r, jpeg) in parts {
        for v in [r.x, r.y, r.w, r.h] {
            out.extend_from_slice(&(v as u16).to_le_bytes());
        }
        out.extend_from_slice(&(jpeg.len() as u32).to_le_bytes());
        out.extend_from_slice(jpeg);
    }
    out
}

/// Maps a cursor position on the monitor to scaled frame pixels.
pub fn scale_cursor(
    cursor: Option<(i32, i32)>,
    mon_x: i32,
    mon_y: i32,
    mon_w: u32,
    mon_h: u32,
    w: u32,
    h: u32,
) -> Option<(i32, i32)> {
    let (cx, cy) = cursor?;
    let (lx, ly) = (cx - mon_x, cy - mon_y);
    if lx < 0 || ly < 0 || lx >= mon_w as i32 || ly >= mon_h as i32 {
        return None;
    }
    Some((
        (lx as i64 * w as i64 / mon_w as i64) as i32,
        (ly as i64 * h as i64 / mon_h as i64) as i32,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: u32, h: u32, bgra: [u8; 4]) -> Vec<u8> {
        bgra.repeat((w * h) as usize)
    }

    fn paint(img: &mut [u8], w: u32, x: u32, y: u32, rw: u32, rh: u32, bgra: [u8; 4]) {
        for yy in y..y + rh {
            for xx in x..x + rw {
                let i = ((yy * w + xx) * 4) as usize;
                img[i..i + 4].copy_from_slice(&bgra);
            }
        }
    }

    #[test]
    fn sizes_keep_shape_and_never_upscale() {
        assert_eq!(scaled_size(1920, 1080, 1280), (1280, 720));
        assert_eq!(scaled_size(1366, 768, 1280), (1280, 720));
        assert_eq!(scaled_size(800, 600, 1280), (800, 600));
        assert_eq!(scaled_size(2560, 1600, 960), (960, 600));
        assert_eq!(scaled_size(1001, 501, 2000), (1000, 500), "even sizes");
    }

    #[test]
    fn scaling_keeps_colours_and_ignores_the_unused_byte() {
        // GDI leaves the 4th byte at zero; the result must not turn black.
        let img = solid(200, 100, [10, 20, 200, 0]);
        let out = Scaler::default().scale(&img, 200, 100, 100, 50).unwrap();
        assert_eq!(out.len(), 100 * 50 * 4);
        let px = &out[(25 * 100 + 50) * 4..][..3];
        assert_eq!(px, &[10, 20, 200]);
    }

    #[test]
    fn first_frame_and_big_changes_are_sent_whole() {
        let a = solid(320, 200, [0, 0, 0, 255]);
        assert_eq!(
            changed_rects(None, &a, 320, 200),
            vec![Rect {
                x: 0,
                y: 0,
                w: 320,
                h: 200
            }]
        );
        let b = solid(320, 200, [255, 255, 255, 255]);
        assert_eq!(
            changed_rects(Some(&a), &b, 320, 200),
            vec![Rect {
                x: 0,
                y: 0,
                w: 320,
                h: 200
            }]
        );
        assert!(
            changed_rects(Some(&a), &a, 320, 200).is_empty(),
            "nothing changed"
        );
    }

    #[test]
    fn small_changes_become_tile_aligned_rectangles() {
        let (w, h) = (640, 400);
        let a = solid(w, h, [0, 0, 0, 255]);
        let mut b = a.clone();
        paint(&mut b, w, 70, 10, 100, 100, [0, 0, 255, 255]); // tiles x 1..2, y 0..1
        paint(&mut b, w, 600, 390, 5, 5, [0, 255, 0, 255]); // last, partial tiles
        let rects = changed_rects(Some(&a), &b, w, h);
        assert_eq!(
            rects,
            vec![
                Rect {
                    x: 64,
                    y: 0,
                    w: 128,
                    h: 128
                },
                Rect {
                    x: 576,
                    y: 384,
                    w: 64,
                    h: 16
                },
            ]
        );
    }

    #[test]
    fn frames_round_trip_and_jpeg_is_valid() {
        let (w, h) = (128, 64);
        let mut img = solid(w, h, [0, 0, 255, 0]); // red in BGRA
        paint(&mut img, w, 64, 0, 64, 64, [255, 0, 0, 0]); // blue right half
        let r = Rect {
            x: 64,
            y: 0,
            w: 64,
            h: 64,
        };
        let jpeg = encode_rect(&img, w, r, 80).unwrap();
        assert_eq!(&jpeg[..2], &[0xFF, 0xD8], "JPEG start marker");
        let msg = frame_message(7, w, h, Some((10, 20)), &[(r, jpeg.clone())]);
        assert_eq!(&msg[..4], MAGIC);
        assert_eq!(u32::from_le_bytes(msg[4..8].try_into().unwrap()), 7);
        assert_eq!(u16::from_le_bytes(msg[8..10].try_into().unwrap()), 128);
        assert_eq!(i16::from_le_bytes(msg[12..14].try_into().unwrap()), 10);
        assert_eq!(u16::from_le_bytes(msg[16..18].try_into().unwrap()), 1);
        assert_eq!(u16::from_le_bytes(msg[18..20].try_into().unwrap()), 64);
        assert_eq!(
            u32::from_le_bytes(msg[26..30].try_into().unwrap()) as usize,
            jpeg.len()
        );
        assert_eq!(msg.len(), 30 + jpeg.len());
        let none = frame_message(8, w, h, None, &[]);
        assert_eq!(i16::from_le_bytes(none[12..14].try_into().unwrap()), -1);
    }

    #[test]
    fn cursor_maps_to_scaled_monitor_pixels() {
        assert_eq!(
            scale_cursor(Some((960, 540)), 0, 0, 1920, 1080, 1280, 720),
            Some((640, 360))
        );
        // Second monitor to the right.
        assert_eq!(
            scale_cursor(Some((1920 + 100, 50)), 1920, 0, 1920, 1080, 960, 540),
            Some((50, 25))
        );
        assert_eq!(
            scale_cursor(Some((100, 50)), 1920, 0, 1920, 1080, 960, 540),
            None,
            "other monitor"
        );
        assert_eq!(scale_cursor(None, 0, 0, 10, 10, 10, 10), None);
    }
}
