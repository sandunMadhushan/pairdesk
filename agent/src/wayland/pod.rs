// SPDX-License-Identifier: GPL-3.0-or-later
//! The few SPA "POD" values PipeWire needs from a screen-capture client,
//! built and read by hand (PairDesk loads PipeWire at run time and doesn't
//! link its C helpers).
//!
//! A POD is `size: u32, type: u32` followed by `size` bytes of body, padded
//! to 8 bytes. Objects hold properties (`key: u32, flags: u32, pod`);
//! choices hold `kind: u32, flags: u32`, a child header and packed values.

// Values from spa/utils/type.h, spa/param/*.h (checked against PipeWire 1.0).
pub const TYPE_ID: u32 = 3;
pub const TYPE_INT: u32 = 4;
pub const TYPE_RECTANGLE: u32 = 10;
pub const TYPE_FRACTION: u32 = 11;
pub const TYPE_OBJECT: u32 = 15;
pub const TYPE_CHOICE: u32 = 19;
pub const OBJECT_FORMAT: u32 = 0x40003;
pub const OBJECT_PARAM_BUFFERS: u32 = 0x40004;
pub const OBJECT_PARAM_META: u32 = 0x40005;
pub const PARAM_ENUM_FORMAT: u32 = 3;
pub const PARAM_FORMAT: u32 = 4;
pub const PARAM_BUFFERS: u32 = 5;
pub const PARAM_META: u32 = 6;
pub const FORMAT_MEDIA_TYPE: u32 = 1;
pub const FORMAT_MEDIA_SUBTYPE: u32 = 2;
pub const FORMAT_VIDEO_FORMAT: u32 = 0x20001;
pub const FORMAT_VIDEO_MODIFIER: u32 = 0x20002;
pub const FORMAT_VIDEO_SIZE: u32 = 0x20003;
pub const FORMAT_VIDEO_FRAMERATE: u32 = 0x20004;
pub const MEDIA_TYPE_VIDEO: u32 = 2;
pub const MEDIA_SUBTYPE_RAW: u32 = 1;
pub const VIDEO_RGBX: u32 = 7;
pub const VIDEO_BGRX: u32 = 8;
pub const VIDEO_RGBA: u32 = 11;
pub const VIDEO_BGRA: u32 = 12;
pub const BUFFERS_DATA_TYPE: u32 = 6;
pub const META_TYPE: u32 = 1;
pub const META_SIZE: u32 = 2;
pub const META_CURSOR: u32 = 5;
pub const DATA_MEM_PTR: u32 = 1;
pub const DATA_MEM_FD: u32 = 2;
const CHOICE_RANGE: u32 = 1;
const CHOICE_ENUM: u32 = 3;
const CHOICE_FLAGS: u32 = 4;

/// Bytes needed for cursor metadata with a `w`×`h` bitmap
/// (`spa_meta_cursor` + `spa_meta_bitmap` + RGBA pixels).
pub fn cursor_meta_size(w: i32, h: i32) -> i32 {
    28 + 20 + w * h * 4
}

#[derive(Default)]
pub struct Builder {
    buf: Vec<u8>,
}

impl Builder {
    fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_ne_bytes());
    }

    fn pad(&mut self) {
        while !self.buf.len().is_multiple_of(8) {
            self.buf.push(0);
        }
    }

    /// A complete value: header, body, padding.
    fn value(&mut self, ty: u32, body: &[u8]) {
        self.u32(body.len() as u32);
        self.u32(ty);
        self.buf.extend_from_slice(body);
        self.pad();
    }

    fn choice(&mut self, kind: u32, child_type: u32, child_size: u32, values: &[u8]) {
        self.u32(16 + values.len() as u32);
        self.u32(TYPE_CHOICE);
        self.u32(kind);
        self.u32(0);
        self.u32(child_size);
        self.u32(child_type);
        self.buf.extend_from_slice(values);
        self.pad();
    }

    fn prop(&mut self, key: u32) {
        self.u32(key);
        self.u32(0);
    }

    /// Wraps the properties written by `props` in an object.
    fn object(ty: u32, id: u32, props: impl FnOnce(&mut Builder)) -> Vec<u8> {
        let mut inner = Builder::default();
        inner.u32(ty);
        inner.u32(id);
        props(&mut inner);
        let mut b = Builder::default();
        b.value(TYPE_OBJECT, &inner.buf);
        b.buf
    }
}

fn ne(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_ne_bytes()).collect()
}

/// The formats PairDesk can take: raw 32-bit RGB in memory (not GPU
/// buffers, so no `modifier`), any size and frame rate.
pub fn enum_format() -> Vec<u8> {
    Builder::object(OBJECT_FORMAT, PARAM_ENUM_FORMAT, |b| {
        b.prop(FORMAT_MEDIA_TYPE);
        b.value(TYPE_ID, &MEDIA_TYPE_VIDEO.to_ne_bytes());
        b.prop(FORMAT_MEDIA_SUBTYPE);
        b.value(TYPE_ID, &MEDIA_SUBTYPE_RAW.to_ne_bytes());
        b.prop(FORMAT_VIDEO_FORMAT);
        b.choice(
            CHOICE_ENUM,
            TYPE_ID,
            4,
            &ne(&[VIDEO_BGRX, VIDEO_BGRX, VIDEO_BGRA, VIDEO_RGBX, VIDEO_RGBA]),
        );
        b.prop(FORMAT_VIDEO_SIZE);
        b.choice(
            CHOICE_RANGE,
            TYPE_RECTANGLE,
            8,
            &ne(&[1920, 1080, 1, 1, 16384, 16384]),
        );
        b.prop(FORMAT_VIDEO_FRAMERATE);
        b.choice(CHOICE_RANGE, TYPE_FRACTION, 8, &ne(&[30, 1, 0, 1, 360, 1]));
    })
}

/// Buffers PairDesk can read: plain or shared memory.
pub fn buffers() -> Vec<u8> {
    Builder::object(OBJECT_PARAM_BUFFERS, PARAM_BUFFERS, |b| {
        b.prop(BUFFERS_DATA_TYPE);
        let mask = (1u32 << DATA_MEM_PTR) | (1u32 << DATA_MEM_FD);
        b.choice(CHOICE_FLAGS, TYPE_INT, 4, &ne(&[mask]));
    })
}

/// Asks for the pointer's position with each buffer.
pub fn cursor_meta() -> Vec<u8> {
    Builder::object(OBJECT_PARAM_META, PARAM_META, |b| {
        b.prop(META_TYPE);
        b.value(TYPE_ID, &META_CURSOR.to_ne_bytes());
        b.prop(META_SIZE);
        let sizes = [
            cursor_meta_size(64, 64),
            cursor_meta_size(1, 1),
            cursor_meta_size(1024, 1024),
        ];
        b.choice(CHOICE_RANGE, TYPE_INT, 4, &ne(&sizes.map(|s| s as u32)));
    })
}

/// What was agreed: pixel format and size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoFormat {
    pub format: u32,
    pub width: u32,
    pub height: u32,
    /// GPU buffers (`modifier` present): PairDesk can't read those.
    pub gpu: bool,
}

/// Reads the negotiated `Format` object.
pub fn parse_format(pod: &[u8]) -> Option<VideoFormat> {
    let rd = |at: usize| -> Option<u32> {
        Some(u32::from_ne_bytes(pod.get(at..at + 4)?.try_into().ok()?))
    };
    let size = rd(0)? as usize;
    if rd(4)? != TYPE_OBJECT || pod.len() < 8 + size || rd(8)? != OBJECT_FORMAT {
        return None;
    }
    let end = 8 + size;
    let mut at = 16; // after header, object type and id
    let mut out = VideoFormat {
        format: 0,
        width: 0,
        height: 0,
        gpu: false,
    };
    while at + 16 <= end {
        let key = rd(at)?;
        let vsize = rd(at + 8)? as usize;
        let mut vtype = rd(at + 12)?;
        let mut body = at + 16;
        if body + vsize > end {
            return None;
        }
        // A fixed choice ("None") holds its value as the first entry.
        if vtype == TYPE_CHOICE && vsize >= 16 {
            vtype = rd(body + 12)?;
            body += 16;
        }
        match (key, vtype) {
            (FORMAT_VIDEO_FORMAT, TYPE_ID) => out.format = rd(body)?,
            (FORMAT_VIDEO_SIZE, TYPE_RECTANGLE) => {
                out.width = rd(body)?;
                out.height = rd(body + 4)?;
            }
            (FORMAT_VIDEO_MODIFIER, _) => out.gpu = true,
            _ => {}
        }
        at += 16 + vsize.div_ceil(8) * 8;
    }
    (out.format != 0 && out.width > 0 && out.height > 0).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(b: &[u8]) -> Vec<u32> {
        b.chunks(4)
            .map(|c| u32::from_ne_bytes(c.try_into().unwrap()))
            .collect()
    }

    // Expected words come from PipeWire's own C builder (spa_pod_builder_add_object
    // with the same arguments), printed once and copied here.
    #[test]
    fn builds_the_same_bytes_as_pipewire() {
        assert_eq!(
            words(&enum_format()),
            vec![
                224, 15, 0x40003, 3, //
                1, 0, 4, 3, 2, 0, //
                2, 0, 4, 3, 1, 0, //
                0x20001, 0, 36, 19, 3, 0, 4, 3, 8, 8, 12, 7, 11, 0, //
                0x20003, 0, 40, 19, 1, 0, 8, 10, 1920, 1080, 1, 1, 16384, 16384, //
                0x20004, 0, 40, 19, 1, 0, 8, 11, 30, 1, 0, 1, 360, 1,
            ]
        );
        assert_eq!(
            words(&buffers()),
            vec![48, 15, 0x40004, 5, 6, 0, 20, 19, 4, 0, 4, 4, 6, 0]
        );
        assert_eq!(
            words(&cursor_meta()),
            vec![
                80, 15, 0x40005, 6, //
                1, 0, 4, 3, 5, 0, //
                2, 0, 28, 19, 1, 0, 4, 4, 16432, 52, 4194352, 0,
            ]
        );
    }

    #[test]
    fn every_pod_is_padded_to_8_bytes() {
        for pod in [enum_format(), buffers(), cursor_meta()] {
            assert_eq!(pod.len() % 8, 0);
            assert_eq!(words(&pod)[0] as usize + 8, pod.len());
        }
    }

    fn negotiated(with_modifier: bool, as_choice: bool) -> Vec<u8> {
        Builder::object(OBJECT_FORMAT, PARAM_FORMAT, |b| {
            b.prop(FORMAT_MEDIA_TYPE);
            b.value(TYPE_ID, &MEDIA_TYPE_VIDEO.to_ne_bytes());
            b.prop(FORMAT_VIDEO_FORMAT);
            if as_choice {
                b.choice(0, TYPE_ID, 4, &ne(&[VIDEO_RGBA]));
            } else {
                b.value(TYPE_ID, &VIDEO_BGRX.to_ne_bytes());
            }
            if with_modifier {
                b.prop(FORMAT_VIDEO_MODIFIER);
                b.value(5, &0u64.to_ne_bytes());
            }
            b.prop(FORMAT_VIDEO_SIZE);
            b.value(TYPE_RECTANGLE, &ne(&[1280, 800]));
        })
    }

    #[test]
    fn reads_the_agreed_format() {
        assert_eq!(
            parse_format(&negotiated(false, false)),
            Some(VideoFormat {
                format: VIDEO_BGRX,
                width: 1280,
                height: 800,
                gpu: false
            })
        );
        assert_eq!(
            parse_format(&negotiated(false, true)).unwrap().format,
            VIDEO_RGBA
        );
        assert!(parse_format(&negotiated(true, false)).unwrap().gpu);
        assert_eq!(parse_format(&buffers()), None, "not a format");
        let mut cut = negotiated(false, false);
        cut.truncate(40);
        assert_eq!(parse_format(&cut), None);
    }
}
