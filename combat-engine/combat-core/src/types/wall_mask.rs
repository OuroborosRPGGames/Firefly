//! Pixel-level wall mask for line-of-sight ray-casting.
//!
//! Ruby source: `backend/app/services/battlemap/wall_mask_service.rb`.
//! The serializer decodes the room's PNG mask once and ships a packed byte
//! buffer. Each pixel is one byte with the following codes:
//!
//! | code | kind    | effect                               |
//! |------|---------|--------------------------------------|
//! | 0    | Floor   | transparent, passable                |
//! | 1    | Wall    | blocks LoS + movement                |
//! | 2    | Door    | movement-passable; LoS depends on state |
//! | 3    | Window  | blocks movement, transparent to LoS  |

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Pixel classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelKind {
    Floor,
    Wall,
    Door,
    Window,
}

impl PixelKind {
    fn from_code(code: u8) -> PixelKind {
        match code {
            1 => PixelKind::Wall,
            2 => PixelKind::Door,
            3 => PixelKind::Window,
            _ => PixelKind::Floor,
        }
    }
}

/// Hex geometry used by the wall mask to convert hex coordinates into pixel
/// coordinates. Must match Ruby `WallMaskService#hex_geometry`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HexGeometry {
    pub hex_size: f32,
    pub hex_height: f32,
    pub min_x: i32,
    pub min_y: i32,
    pub num_visual_rows: u32,
}

impl Default for HexGeometry {
    fn default() -> Self {
        Self {
            hex_size: 0.0,
            hex_height: 0.0,
            min_x: 0,
            min_y: 0,
            num_visual_rows: 0,
        }
    }
}

/// Decoded pixel grid for LoS ray-casts.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct WallMask {
    pub width: u32,
    pub height: u32,
    /// One byte per pixel, codes 0..=3. Serialized as base64 over JSON and as
    /// raw bytes over MessagePack.
    #[serde(
        serialize_with = "serialize_pixels",
        deserialize_with = "deserialize_pixels"
    )]
    pub pixels: Vec<u8>,
    pub hex_geometry: HexGeometry,
}

impl Default for WallMask {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            pixels: Vec::new(),
            hex_geometry: HexGeometry::default(),
        }
    }
}

impl WallMask {
    /// Look up pixel at `(px, py)`. Out-of-bounds reads clamp to the nearest
    /// valid pixel (matches Ruby `pixel_type` behavior).
    pub fn pixel_at(&self, px: i32, py: i32) -> PixelKind {
        if self.width == 0 || self.height == 0 || self.pixels.is_empty() {
            return PixelKind::Floor;
        }
        let x = px.clamp(0, self.width as i32 - 1) as u32;
        let y = py.clamp(0, self.height as i32 - 1) as u32;
        let idx = (y * self.width + x) as usize;
        PixelKind::from_code(*self.pixels.get(idx).unwrap_or(&0))
    }

    /// Ray-cast LoS from `(x1, y1)` to `(x2, y2)` in pixel coords using
    /// Bresenham's algorithm. Mirrors `WallMaskService#ray_los_clear?`
    /// (wall_mask_service.rb:72-89):
    /// - Endpoints are skipped (character hexes may overlap wall pixels).
    /// - WALL pixels block.
    /// - WINDOW pixels are transparent to LoS.
    /// - DOOR pixels block unless `door_open_fn(px, py)` returns true.
    ///
    /// `door_open_fn` is invoked at each door pixel; callers typically close
    /// over the fight state and look up the hex the pixel belongs to.
    pub fn ray_los_clear<F>(
        &self,
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        mut door_open_fn: F,
    ) -> bool
    where
        F: FnMut(i32, i32) -> bool,
    {
        if self.width == 0 || self.height == 0 || self.pixels.is_empty() {
            return true;
        }
        let dx = (x2 - x1).abs();
        let dy = (y2 - y1).abs();
        let sx: i32 = if x1 < x2 { 1 } else { -1 };
        let sy: i32 = if y1 < y2 { 1 } else { -1 };
        let mut err = dx - dy;
        let mut x = x1;
        let mut y = y1;
        let total = dx.max(dy);
        let mut idx = 0;

        loop {
            let at_endpoint = idx == 0 || idx == total;
            if !at_endpoint {
                match self.pixel_at(x, y) {
                    PixelKind::Wall => return false,
                    PixelKind::Window => {}
                    PixelKind::Door => {
                        if !door_open_fn(x, y) {
                            return false;
                        }
                    }
                    PixelKind::Floor => {}
                }
            }
            if x == x2 && y == y2 {
                break;
            }
            let e2 = 2 * err;
            if e2 > -dy {
                err -= dy;
                x += sx;
            }
            if e2 < dx {
                err += dx;
                y += sy;
            }
            idx += 1;
        }
        true
    }

    /// Convert hex coordinates to pixel coordinates. Mirrors
    /// `WallMaskService#hex_to_pixel` (flat-top hex, Y-flipped, odd-col stagger).
    pub fn hex_to_pixel(&self, hex_x: i32, hex_y: i32) -> (i32, i32) {
        let g = &self.hex_geometry;
        let col = hex_x - g.min_x;
        let visual_row_raw = ((hex_y - g.min_y) as f32 / 4.0).floor() as i32;
        let visual_row = (g.num_visual_rows as i32 - 1) - visual_row_raw;
        let stagger = if col.rem_euclid(2) == 1 {
            -g.hex_height / 2.0
        } else {
            0.0
        };
        let px = (g.hex_size + col as f32 * g.hex_size * 1.5).round() as i32;
        let py = (g.hex_height / 2.0
            + visual_row as f32 * g.hex_height
            + stagger)
            .round() as i32;
        let max_x = self.width.saturating_sub(1) as i32;
        let max_y = self.height.saturating_sub(1) as i32;
        (px.clamp(0, max_x), py.clamp(0, max_y))
    }
}

// ---- serde helpers ---------------------------------------------------------

fn serialize_pixels<S>(pixels: &[u8], serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    // Human-readable (JSON) → base64. Binary (msgpack, etc.) → raw bytes.
    if serializer.is_human_readable() {
        let encoded = base64_encode(pixels);
        serializer.serialize_str(&encoded)
    } else {
        serializer.serialize_bytes(pixels)
    }
}

fn deserialize_pixels<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::{Error, Visitor};
    use std::fmt;

    struct PixelVisitor;
    impl<'de> Visitor<'de> for PixelVisitor {
        type Value = Vec<u8>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a base64 string or byte array")
        }
        fn visit_str<E: Error>(self, v: &str) -> Result<Vec<u8>, E> {
            base64_decode(v).map_err(E::custom)
        }
        fn visit_string<E: Error>(self, v: String) -> Result<Vec<u8>, E> {
            self.visit_str(&v)
        }
        fn visit_bytes<E: Error>(self, v: &[u8]) -> Result<Vec<u8>, E> {
            Ok(v.to_vec())
        }
        fn visit_byte_buf<E: Error>(self, v: Vec<u8>) -> Result<Vec<u8>, E> {
            Ok(v)
        }
        fn visit_seq<A>(self, mut seq: A) -> Result<Vec<u8>, A::Error>
        where
            A: serde::de::SeqAccess<'de>,
        {
            let mut out = Vec::new();
            while let Some(b) = seq.next_element::<u8>()? {
                out.push(b);
            }
            Ok(out)
        }
    }
    deserializer.deserialize_any(PixelVisitor)
}

// ---- minimal base64 (dependency-free) --------------------------------------

const B64: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = chunk.get(1).copied().unwrap_or(0);
        let b2 = chunk.get(2).copied().unwrap_or(0);
        out.push(B64[(b0 >> 2) as usize] as char);
        out.push(B64[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64[(b2 & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    fn val(c: u8) -> Result<u8, String> {
        Ok(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(format!("invalid base64 char: {}", c as char)),
        })
    }

    let bytes: Vec<u8> = input.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let mut i = 0;
    while i < bytes.len() {
        if i + 1 >= bytes.len() {
            return Err("truncated base64".into());
        }
        let c0 = val(bytes[i])?;
        let c1 = val(bytes[i + 1])?;
        out.push((c0 << 2) | (c1 >> 4));
        if i + 2 < bytes.len() && bytes[i + 2] != b'=' {
            let c2 = val(bytes[i + 2])?;
            out.push(((c1 & 0x0f) << 4) | (c2 >> 2));
            if i + 3 < bytes.len() && bytes[i + 3] != b'=' {
                let c3 = val(bytes[i + 3])?;
                out.push(((c2 & 0x03) << 6) | c3);
            }
        }
        i += 4;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mask_4x4() -> WallMask {
        // Row 0..3 floor except (2,1) = wall
        let mut pixels = vec![0u8; 16];
        pixels[1 * 4 + 2] = 1; // wall
        WallMask {
            width: 4,
            height: 4,
            pixels,
            hex_geometry: HexGeometry {
                hex_size: 1.0,
                hex_height: 1.732,
                min_x: 0,
                min_y: 0,
                num_visual_rows: 2,
            },
        }
    }

    #[test]
    fn test_pixel_at_floor_and_wall() {
        let m = mask_4x4();
        assert_eq!(m.pixel_at(0, 0), PixelKind::Floor);
        assert_eq!(m.pixel_at(2, 1), PixelKind::Wall);
    }

    #[test]
    fn test_pixel_at_clamps_out_of_bounds() {
        let m = mask_4x4();
        assert_eq!(m.pixel_at(-5, -5), PixelKind::Floor);
        assert_eq!(m.pixel_at(999, 999), PixelKind::Floor);
    }

    #[test]
    fn test_pixel_at_empty_mask_is_floor() {
        let m = WallMask::default();
        assert_eq!(m.pixel_at(0, 0), PixelKind::Floor);
    }

    #[test]
    fn test_json_roundtrip_uses_base64() {
        let m = mask_4x4();
        let json = serde_json::to_string(&m).unwrap();
        // Encoded as base64 string, not raw byte array.
        assert!(json.contains("\"pixels\":\""), "json should contain base64 string: {json}");
        let back: WallMask = serde_json::from_str(&json).unwrap();
        assert_eq!(back.width, m.width);
        assert_eq!(back.height, m.height);
        assert_eq!(back.pixels, m.pixels);
        assert_eq!(back.pixel_at(2, 1), PixelKind::Wall);
    }

    #[test]
    fn test_base64_roundtrip_arbitrary_bytes() {
        let data: Vec<u8> = (0..=255).collect();
        let encoded = base64_encode(&data);
        let decoded = base64_decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    fn mask_with(width: u32, height: u32, setups: &[(i32, i32, u8)]) -> WallMask {
        let mut pixels = vec![0u8; (width * height) as usize];
        for (x, y, kind) in setups {
            let idx = (*y as u32 * width + *x as u32) as usize;
            pixels[idx] = *kind;
        }
        WallMask {
            width,
            height,
            pixels,
            hex_geometry: HexGeometry::default(),
        }
    }

    #[test]
    fn test_ray_los_clear_floor_path() {
        let m = mask_with(10, 1, &[]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| false);
        assert!(clear);
    }

    #[test]
    fn test_ray_los_blocked_by_wall() {
        let m = mask_with(10, 1, &[(5, 0, 1)]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| false);
        assert!(!clear);
    }

    #[test]
    fn test_ray_los_window_transparent() {
        let m = mask_with(10, 1, &[(5, 0, 3)]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| false);
        assert!(clear, "windows are transparent to LoS");
    }

    #[test]
    fn test_ray_los_door_closed_blocks() {
        let m = mask_with(10, 1, &[(5, 0, 2)]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| false);
        assert!(!clear, "closed door blocks LoS");
    }

    #[test]
    fn test_ray_los_door_open_clears() {
        let m = mask_with(10, 1, &[(5, 0, 2)]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| true);
        assert!(clear, "open door is transparent");
    }

    #[test]
    fn test_ray_los_skips_endpoints() {
        // Wall at origin and destination — still clears because endpoints skipped.
        let m = mask_with(10, 1, &[(0, 0, 1), (9, 0, 1)]);
        let clear = m.ray_los_clear(0, 0, 9, 0, |_, _| false);
        assert!(clear);
    }

    #[test]
    fn test_ray_los_empty_mask_clears() {
        let m = WallMask::default();
        assert!(m.ray_los_clear(0, 0, 5, 5, |_, _| false));
    }

    #[test]
    fn test_hex_to_pixel_origin() {
        let m = mask_4x4();
        // hex (0,0) maps to (hex_size, hex_height/2 + (num_rows-1)*hex_height) with no stagger
        let (px, py) = m.hex_to_pixel(0, 0);
        // col=0 → even → no stagger. visual_row_raw=0, visual_row=1.
        // px = 1.0 + 0*1.5 = 1 → 1
        // py = 0.866 + 1*1.732 = 2.598 → round = 3, clamped to 3 (height-1=3)
        assert_eq!(px, 1);
        assert_eq!(py, 3);
    }
}
