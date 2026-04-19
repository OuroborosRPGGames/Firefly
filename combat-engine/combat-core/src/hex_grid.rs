use crate::types::hex::Direction;

/// Check if given (x, y) coordinates are valid hex coordinates in the offset
/// system.
///
/// Rules:
/// - Y must always be even (0, 2, 4, ...).
/// - When `(y/2) % 2 == 0` (y = 0, 4, 8, 12, ...), X must be even.
/// - When `(y/2) % 2 != 0` (y = 2, 6, 10, 14, ...), X must be odd.
pub fn valid_hex_coords(x: i32, y: i32) -> bool {
    if y % 2 != 0 {
        return false;
    }
    let half_y = y / 2;
    if half_y % 2 == 0 {
        x % 2 == 0
    } else {
        // x must be odd: x % 2 != 0, but handle negatives correctly
        x.rem_euclid(2) == 1
    }
}

/// Snap arbitrary (x, y) to the nearest valid hex coordinates.
///
/// First snaps Y to the nearest even number, then snaps X to the correct
/// parity for that row.
pub fn to_hex_coords(x: i32, y: i32) -> (i32, i32) {
    // Snap Y to nearest even
    let hex_y = ((y as f64 / 2.0).round() as i32) * 2;

    let half_y = hex_y / 2;
    let hex_x = if half_y.rem_euclid(2) == 0 {
        // X should be even
        ((x as f64 / 2.0).round() as i32) * 2
    } else {
        // X should be odd
        (((x as f64 - 1.0) / 2.0).round() as i32) * 2 + 1
    };

    (hex_x, hex_y)
}

/// Calculate the hex distance between two coordinates.
///
/// Diagonal moves cover +/-1 in X and +/-2 in Y. North/south moves cover
/// +/-4 in Y. Distance is the minimum number of single-hex steps.
pub fn hex_distance(x1: i32, y1: i32, x2: i32, y2: i32) -> i32 {
    let dx = (x2 - x1).abs();
    let dy = (y2 - y1).abs();

    if dy <= 2 * dx {
        dx
    } else {
        dx + (dy - 2 * dx) / 4
    }
}

/// Return the 6 neighbors of a hex coordinate in clockwise order starting
/// from north: N, NE, SE, S, SW, NW.
///
/// All returned coordinates are guaranteed to be valid hex coordinates.
pub fn hex_neighbors(x: i32, y: i32) -> Vec<(i32, i32)> {
    if !valid_hex_coords(x, y) {
        return Vec::new();
    }

    let offsets = [
        (0, 4),   // N
        (1, 2),   // NE
        (1, -2),  // SE
        (0, -4),  // S
        (-1, -2), // SW
        (-1, 2),  // NW
    ];

    offsets
        .iter()
        .map(|(dx, dy)| (x + dx, y + dy))
        .filter(|(nx, ny)| valid_hex_coords(*nx, *ny))
        .collect()
}

/// Reverse a compass direction (N ↔ S, NE ↔ SW, NW ↔ SE).
///
/// Ruby: `{ n: :s, ne: :sw, se: :nw, s: :n, sw: :ne, nw: :se }`
/// (combat_resolution_service.rb:2183).
pub fn reverse_direction(dir: Direction) -> Direction {
    match dir {
        Direction::N => Direction::S,
        Direction::NE => Direction::SW,
        Direction::SE => Direction::NW,
        Direction::S => Direction::N,
        Direction::SW => Direction::NE,
        Direction::NW => Direction::SE,
    }
}

/// Return the neighbor of (x, y) in the given direction.
pub fn hex_neighbor_by_direction(x: i32, y: i32, dir: Direction) -> (i32, i32) {
    let (dx, dy) = match dir {
        Direction::N => (0, 4),
        Direction::NE => (1, 2),
        Direction::SE => (1, -2),
        Direction::S => (0, -4),
        Direction::SW => (-1, -2),
        Direction::NW => (-1, 2),
    };
    (x + dx, y + dy)
}

/// Determine which compass direction best describes the vector from
/// (x1, y1) to (x2, y2).
///
/// Returns `None` if the two points are identical. Uses dot-product
/// comparison against normalized direction unit vectors.
pub fn direction_between(x1: i32, y1: i32, x2: i32, y2: i32) -> Option<Direction> {
    if x1 == x2 && y1 == y2 {
        return None;
    }

    let dx = (x2 - x1) as f64;
    let dy = (y2 - y1) as f64;
    let mag = (dx * dx + dy * dy).sqrt();
    let ndx = dx / mag;
    let ndy = dy / mag;

    let inv_sqrt5 = 1.0 / 5.0_f64.sqrt();
    let two_inv_sqrt5 = 2.0 * inv_sqrt5;

    let directions: [(Direction, f64, f64); 6] = [
        (Direction::N, 0.0, 1.0),
        (Direction::NE, inv_sqrt5, two_inv_sqrt5),
        (Direction::SE, inv_sqrt5, -two_inv_sqrt5),
        (Direction::S, 0.0, -1.0),
        (Direction::SW, -inv_sqrt5, -two_inv_sqrt5),
        (Direction::NW, -inv_sqrt5, two_inv_sqrt5),
    ];

    let mut best_dir = Direction::N;
    let mut best_dot = f64::NEG_INFINITY;

    for (dir, vx, vy) in &directions {
        let dot = ndx * vx + ndy * vy;
        if dot > best_dot {
            best_dot = dot;
            best_dir = *dir;
        }
    }

    Some(best_dir)
}

/// Return all hex coordinates along a line from (x1, y1) to (x2, y2).
///
/// Uses linear interpolation with enough sample points to catch every hex
/// the line passes through, snapping each sample to the nearest valid hex.
/// The result is deduplicated and includes both endpoints.
pub fn hexes_in_line(x1: i32, y1: i32, x2: i32, y2: i32) -> Vec<(i32, i32)> {
    let distance = hex_distance(x1, y1, x2, y2);
    if distance == 0 {
        return vec![(x1, y1)];
    }

    let mut results: Vec<(i32, i32)> = Vec::new();

    for i in 0..=distance {
        let t = i as f64 / distance as f64;
        let lerp_x = x1 as f64 + (x2 - x1) as f64 * t;
        let lerp_y = y1 as f64 + (y2 - y1) as f64 * t;
        let snapped = to_hex_coords(lerp_x.round() as i32, lerp_y.round() as i32);
        if results.last() != Some(&snapped) {
            results.push(snapped);
        }
    }

    results
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- valid_hex_coords ---
    #[test]
    fn test_valid_coords_y0() {
        assert!(valid_hex_coords(0, 0)); // y/2=0 even, x=0 even
        assert!(valid_hex_coords(2, 0)); // y/2=0 even, x=2 even
        assert!(!valid_hex_coords(1, 0)); // y/2=0 even, x=1 odd -> invalid
    }

    #[test]
    fn test_valid_coords_y2() {
        assert!(valid_hex_coords(1, 2)); // y/2=1 odd, x=1 odd
        assert!(valid_hex_coords(3, 2)); // y/2=1 odd, x=3 odd
        assert!(!valid_hex_coords(0, 2)); // y/2=1 odd, x=0 even -> invalid
        assert!(!valid_hex_coords(2, 2)); // y/2=1 odd, x=2 even -> invalid
    }

    #[test]
    fn test_valid_coords_y4() {
        assert!(valid_hex_coords(0, 4)); // y/2=2 even, x=0 even
        assert!(!valid_hex_coords(1, 4)); // y/2=2 even, x=1 odd -> invalid
    }

    #[test]
    fn test_odd_y_always_invalid() {
        assert!(!valid_hex_coords(0, 1));
        assert!(!valid_hex_coords(1, 3));
        assert!(!valid_hex_coords(0, 5));
    }

    // --- hex_distance ---
    #[test]
    fn test_distance_same_point() {
        assert_eq!(hex_distance(0, 0, 0, 0), 0);
    }

    #[test]
    fn test_distance_neighbors() {
        assert_eq!(hex_distance(0, 0, 1, 2), 1); // NE neighbor
        assert_eq!(hex_distance(0, 0, 0, 4), 1); // N neighbor
        assert_eq!(hex_distance(0, 0, 1, -2), 1); // SE neighbor
    }

    #[test]
    fn test_distance_two_away() {
        assert_eq!(hex_distance(0, 0, 2, 4), 2);
        assert_eq!(hex_distance(0, 0, 0, 8), 2); // two steps north
        assert_eq!(hex_distance(0, 0, 2, 0), 2); // two steps east
    }

    // --- hex_neighbors ---
    #[test]
    fn test_neighbors_count() {
        let n = hex_neighbors(0, 0);
        assert_eq!(n.len(), 6);
        for (x, y) in &n {
            assert!(
                valid_hex_coords(*x, *y),
                "neighbor ({},{}) is invalid",
                x,
                y
            );
            assert_eq!(
                hex_distance(0, 0, *x, *y),
                1,
                "neighbor ({},{}) not distance 1",
                x,
                y
            );
        }
    }

    #[test]
    fn test_neighbors_y2() {
        let n = hex_neighbors(1, 2);
        assert_eq!(n.len(), 6);
        for (x, y) in &n {
            assert!(valid_hex_coords(*x, *y));
        }
    }

    // --- to_hex_coords ---
    #[test]
    fn test_snap_valid_stays() {
        assert_eq!(to_hex_coords(0, 0), (0, 0));
        assert_eq!(to_hex_coords(1, 2), (1, 2));
    }

    #[test]
    fn test_snap_invalid_to_nearest() {
        let (hx, hy) = to_hex_coords(1, 1);
        assert!(valid_hex_coords(hx, hy));
    }

    // --- direction_between ---
    #[test]
    fn test_direction_north() {
        assert_eq!(direction_between(0, 0, 0, 4), Some(Direction::N));
    }

    #[test]
    fn test_direction_south() {
        assert_eq!(direction_between(0, 4, 0, 0), Some(Direction::S));
    }

    #[test]
    fn test_direction_ne() {
        assert_eq!(direction_between(0, 0, 1, 2), Some(Direction::NE));
    }

    #[test]
    fn test_direction_same_point() {
        assert_eq!(direction_between(0, 0, 0, 0), None);
    }

    // --- hex_neighbor_by_direction ---
    #[test]
    fn test_neighbor_by_direction_roundtrip() {
        let dirs = [
            Direction::N,
            Direction::NE,
            Direction::SE,
            Direction::S,
            Direction::SW,
            Direction::NW,
        ];
        for dir in &dirs {
            let (nx, ny) = hex_neighbor_by_direction(0, 0, *dir);
            assert!(valid_hex_coords(nx, ny));
            assert_eq!(hex_distance(0, 0, nx, ny), 1);
        }
    }

    // --- hexes_in_line ---
    #[test]
    fn test_line_to_self() {
        let line = hexes_in_line(0, 0, 0, 0);
        assert_eq!(line.len(), 1);
    }

    #[test]
    fn test_line_to_neighbor() {
        let line = hexes_in_line(0, 0, 0, 4);
        assert!(line.len() >= 2);
        assert!(line.contains(&(0, 0)));
        assert!(line.contains(&(0, 4)));
        for (x, y) in &line {
            assert!(valid_hex_coords(*x, *y));
        }
    }
}
