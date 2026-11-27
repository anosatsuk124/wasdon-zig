//! The same work units, symmetry, sieve wheel and sparse distance algorithm
//! as the Zig kernels. The scratch buffers are private to one Udon worker.
pub const MAX_SIDE: usize = 1024;

pub struct Grid {
    kind: i32,
    pub side: usize,
    cursor: usize,
    column_count: usize,
}

impl Grid {
    pub const fn new(kind: i32, side: usize) -> Self {
        Self {
            kind,
            side,
            cursor: 0,
            column_count: 0,
        }
    }

    pub fn done(&self) -> bool {
        match self.kind {
            0 => self.cursor >= self.side,
            1 => {
                let p = 3 + 2 * self.cursor;
                p * p >= 2 * self.side * self.side
            }
            _ => self.cursor >= 2 * self.side,
        }
    }

    pub fn step(&mut self, pixels: &mut [u8], columns: &mut [usize]) {
        let side = self.side;
        match self.kind {
            0 => {
                let end = (self.cursor + 8).min(side);
                julia_rows(pixels, side, self.cursor, end);
                self.cursor = end;
            }
            1 => {
                let mut p = 3 + 2 * self.cursor;
                let end = p + 16;
                if p == 3 {
                    seed_wheel(pixels);
                    p = 11;
                }
                while p < end && p * p < 2 * pixels.len() {
                    if pixels[p / 2] == 0 {
                        mark_multiples(pixels, p);
                    }
                    p += 2;
                }
                self.cursor = (p - 3) / 2;
            }
            _ if self.cursor < side => {
                let end = (self.cursor + 8).min(side);
                self.column_count += vertical_band(
                    pixels,
                    side,
                    self.cursor,
                    end,
                    &mut columns[self.column_count..],
                );
                self.cursor = end;
            }
            _ => {
                let start = self.cursor - side;
                let end = (start + 8).min(side);
                for row in pixels[start * side..end * side].chunks_exact_mut(side) {
                    distance_row(row, &columns[..self.column_count]);
                }
                self.cursor = side + end;
            }
        }
    }
}

fn julia_rows(pixels: &mut [u8], side: usize, start: usize, end: usize) {
    let scale = 3.0 / side as f64;
    for y in start..end {
        let (before, after) = pixels.split_at_mut(y * side);
        let row = &mut after[..side];
        if side.is_power_of_two() && y >= side.div_ceil(2) {
            let opposite = (side - 1 - y) * side;
            for (dst, src) in row
                .iter_mut()
                .zip(before[opposite..opposite + side].iter().rev())
            {
                *dst = *src;
            }
        } else {
            let im = (y as f64 + 0.5) * scale - 1.5;
            for (x, pixel) in row.iter_mut().enumerate() {
                *pixel = escape((x as f64 + 0.5) * scale - 1.5, im);
            }
        }
    }
}

fn escape(mut a: f64, mut b: f64) -> u8 {
    let mut aa = a * a;
    let mut bb = b * b;
    for base in (0..64).step_by(4) {
        for k in 0..4 {
            if aa + bb > 4.0 {
                return base + k;
            }
            b = (a + a) * b + 0.125;
            a = aa - bb - 0.75;
            aa = a * a;
            bb = b * b;
        }
    }
    64
}

const WHEEL: [[u8; 8]; 105] = {
    let mut words = [[0; 8]; 105];
    let mut i = 0;
    while i < 105 * 8 {
        let n = 2 * i + 1;
        if n % 3 == 0 || n % 5 == 0 || n % 7 == 0 {
            words[i / 8][i % 8] = 255;
        }
        i += 1;
    }
    words
};

fn seed_wheel(pixels: &mut [u8]) {
    let mut phase = 0;
    let mut chunks = pixels.chunks_exact_mut(8);
    for word in &mut chunks {
        word.copy_from_slice(&WHEEL[phase]);
        phase += 1;
        if phase == WHEEL.len() {
            phase = 0;
        }
    }
    for (dst, src) in chunks.into_remainder().iter_mut().zip(WHEEL[phase]) {
        *dst = src;
    }
    pixels[..4].copy_from_slice(&[255, 0, 0, 0]);
}

fn mark_multiples(pixels: &mut [u8], p: usize) {
    // Within a block of 30 multipliers, only 1,7,11,13,17,19,23,29
    // survive the marks for 2, 3 and 5. The array stores odd values.
    const OFFSETS: [i32; 8] = [0, 3, 5, 6, 8, 9, 11, 14];
    let p = p as i32;
    let end = pixels.len() as i32;
    let square = p * p / 2;
    let stride = 15 * p;
    let mut i = p * (p / 30 * 30 + 1) / 2;
    let marked = pixels[0]; // the byte marking 1 as nonprime since seed_wheel
    if i < square {
        for offset in OFFSETS {
            let j = i + offset * p;
            if j >= square && j < end {
                pixels[j as usize] = marked;
            }
        }
        i += stride;
    }
    let base = pixels.as_mut_ptr();
    while i < end - 14 * p {
        // The largest offset in this complete block is 14*p. All indices
        // fit in i32 for grids up to MAX_SIDE and are inside this slice.
        for offset in OFFSETS {
            unsafe {
                *base.add((i + offset * p) as usize) = marked;
            }
        }
        i += stride;
    }
    for offset in OFFSETS {
        let j = i + offset * p;
        if j >= end {
            break;
        }
        pixels[j as usize] = marked;
    }
}

fn vertical_band(
    pixels: &mut [u8],
    side: usize,
    start: usize,
    end: usize,
    columns: &mut [usize],
) -> usize {
    let mut empty = u64::MAX;
    if end - start == 8 {
        for row in pixels.chunks_exact(side) {
            empty &= u64::from_le_bytes(row[start..end].try_into().unwrap());
        }
    } else {
        for x in start..end {
            if pixels.chunks_exact(side).any(|r| r[x] == 0) {
                empty &= !(255u64 << (8 * (x - start)));
            }
        }
    }
    let mut count = 0;
    for x in start..end {
        let occupied = empty as u8 == 0;
        empty >>= 8;
        if !occupied {
            continue;
        }
        columns[count] = x;
        count += 1;
        let mut carry = 255i32;
        for row in pixels.chunks_exact_mut(side) {
            carry = (carry + 1).min(row[x] as i32);
            row[x] = carry as u8;
        }
        carry = 255;
        for row in pixels.rchunks_exact_mut(side) {
            carry = (carry + 1).min(row[x] as i32);
            row[x] = carry as u8;
        }
    }
    count
}

fn distance_row(row: &mut [u8], columns: &[usize]) {
    let Some((&first, rest)) = columns.split_first() else {
        return;
    };
    let mut previous = first;
    let mut distance = row[previous] as usize;
    for &x in rest {
        distance = (row[x] as usize).min(distance + (x - previous));
        row[x] = distance as u8;
        previous = x;
    }
    ramp::<true>(&mut row[previous + 1..], distance);
    for &x in columns[..columns.len() - 1].iter().rev() {
        let gap = previous - x;
        let left = (row[x] as usize).min(distance + gap);
        row[x] = left as u8;
        let split = ((gap + distance - left) / 2).min(gap - 1);
        let (rising, falling) = row[x + 1..previous].split_at_mut(split);
        ramp::<true>(rising, left);
        ramp::<false>(falling, distance);
        previous = x;
        distance = left;
    }
    ramp::<false>(&mut row[..previous], distance);
}

// Fill four consecutive distances per scalar store. The saturated tail
// already holds 255 from the input and needs no writes.
fn ramp<const FORWARD: bool>(out: &mut [u8], base: usize) {
    let n = out.len().min(255 - base);
    let pattern = if FORWARD { 0x04030201 } else { 0x01020304 };
    let mut word = (base as u32 * 0x01010101).wrapping_add(pattern);
    let mut i = 0;
    while i + 4 <= n {
        let at = if FORWARD { i } else { out.len() - i - 4 };
        out[at..at + 4].copy_from_slice(&word.to_le_bytes());
        word = word.wrapping_add(0x04040404);
        i += 4;
    }
    while i < n {
        let at = if FORWARD { i } else { out.len() - i - 1 };
        out[at] = (base + i + 1) as u8;
        i += 1;
    }
}
