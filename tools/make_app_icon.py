#!/usr/bin/env python3
import math
import os
import struct
import zlib


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESOURCES = os.path.join(ROOT, "Resources")
ICONSET = os.path.join(RESOURCES, "AulaF75Bar.iconset")
ICNS = os.path.join(RESOURCES, "AulaF75Bar.icns")


def clamp(value, lower=0, upper=255):
    return max(lower, min(upper, int(round(value))))


def mix(a, b, t):
    return tuple(clamp(a[i] * (1.0 - t) + b[i] * t) for i in range(4))


def rounded_rect_alpha(px, py, x0, y0, x1, y1, radius):
    qx = abs(px - (x0 + x1) * 0.5) - max(0.0, (x1 - x0) * 0.5 - radius)
    qy = abs(py - (y0 + y1) * 0.5) - max(0.0, (y1 - y0) * 0.5 - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    distance = outside + inside - radius
    return max(0.0, min(1.0, 0.5 - distance * 1.8))


def circle_alpha(px, py, cx, cy, radius):
    distance = math.hypot(px - cx, py - cy) - radius
    return max(0.0, min(1.0, 0.5 - distance * 1.8))


def blend(dst, src, alpha):
    alpha = max(0.0, min(1.0, alpha)) * (src[3] / 255.0)
    inv = 1.0 - alpha
    return (
        clamp(src[0] * alpha + dst[0] * inv),
        clamp(src[1] * alpha + dst[1] * inv),
        clamp(src[2] * alpha + dst[2] * inv),
        255,
    )


def fill_rounded(img, size, rect, radius, top, bottom):
    x0, y0, x1, y1 = [v * size for v in rect]
    radius *= size
    left = max(0, int(math.floor(x0)) - 2)
    right = min(size, int(math.ceil(x1)) + 2)
    top_y = max(0, int(math.floor(y0)) - 2)
    bottom_y = min(size, int(math.ceil(y1)) + 2)
    for y in range(top_y, bottom_y):
        t = 0.0 if y1 == y0 else max(0.0, min(1.0, ((y + 0.5) - y0) / (y1 - y0)))
        color = mix(top, bottom, t)
        for x in range(left, right):
            alpha = rounded_rect_alpha(x + 0.5, y + 0.5, x0, y0, x1, y1, radius)
            if alpha > 0.0:
                img[y][x] = blend(img[y][x], color, alpha)


def fill_circle(img, size, cx, cy, radius, color):
    cx *= size
    cy *= size
    radius *= size
    left = max(0, int(math.floor(cx - radius)) - 2)
    right = min(size, int(math.ceil(cx + radius)) + 2)
    top_y = max(0, int(math.floor(cy - radius)) - 2)
    bottom_y = min(size, int(math.ceil(cy + radius)) + 2)
    for y in range(top_y, bottom_y):
        for x in range(left, right):
            alpha = circle_alpha(x + 0.5, y + 0.5, cx, cy, radius)
            if alpha > 0.0:
                img[y][x] = blend(img[y][x], color, alpha)


def draw_pixel_text(img, size, text, x, y, scale, color):
    glyphs = {
        "F": ("111", "100", "110", "100", "100"),
        "7": ("111", "001", "010", "010", "010"),
        "5": ("111", "100", "111", "001", "111"),
        "M": ("101", "111", "111", "101", "101"),
        "A": ("010", "101", "111", "101", "101"),
        "X": ("101", "101", "010", "101", "101"),
        " ": ("0", "0", "0", "0", "0"),
    }
    cursor = x
    cell = scale
    gap = scale * 0.34
    for char in text:
        rows = glyphs.get(char.upper())
        if not rows:
            continue
        width = len(rows[0])
        for row, bits in enumerate(rows):
            for col, bit in enumerate(bits):
                if bit == "1":
                    x0 = cursor + col * cell
                    y0 = y + row * cell
                    fill_rounded(img, size, (x0, y0, x0 + cell * 0.74, y0 + cell * 0.74), cell * 0.16, color, color)
        cursor += width * cell + gap


def make_icon(size):
    img = [[(0, 0, 0, 0) for _ in range(size)] for _ in range(size)]

    fill_rounded(img, size, (0.055, 0.055, 0.945, 0.945), 0.205, (28, 36, 52, 255), (17, 125, 128, 255))
    fill_rounded(img, size, (0.13, 0.12, 0.87, 0.22), 0.09, (255, 255, 255, 36), (255, 255, 255, 12))

    fill_rounded(img, size, (0.085, 0.265, 0.915, 0.765), 0.085, (248, 249, 253, 255), (211, 221, 236, 255))
    fill_rounded(img, size, (0.105, 0.285, 0.895, 0.745), 0.065, (255, 255, 255, 70), (255, 255, 255, 12))

    # F75 Max signature: tiny screen just left of the rotary knob.
    fill_rounded(img, size, (0.575, 0.315, 0.704, 0.452), 0.026, (24, 29, 39, 255), (16, 19, 29, 255))
    fill_rounded(img, size, (0.596, 0.337, 0.682, 0.430), 0.012, (65, 231, 138, 255), (36, 168, 234, 255))
    fill_rounded(img, size, (0.604, 0.356, 0.674, 0.371), 0.004, (255, 87, 147, 245), (255, 206, 72, 245))
    fill_rounded(img, size, (0.622, 0.381, 0.660, 0.397), 0.004, (240, 248, 255, 230), (240, 248, 255, 200))

    fill_circle(img, size, 0.795, 0.376, 0.094, (248, 247, 239, 255))
    fill_circle(img, size, 0.795, 0.376, 0.073, (192, 199, 212, 255))
    fill_circle(img, size, 0.795, 0.376, 0.052, (244, 240, 225, 255))

    key_light = (236, 240, 248, 255)
    key_mid = (199, 211, 229, 255)
    key_blue = (119, 167, 216, 255)
    key_pink = (232, 207, 226, 255)
    rows = [
        (0.15, 0.485, 12, 0.044, 0.038, 0.011),
        (0.15, 0.548, 11, 0.048, 0.040, 0.012),
        (0.15, 0.615, 10, 0.053, 0.042, 0.013),
    ]
    for row_index, (x_start, y0, count, key_w, key_h, gap) in enumerate(rows):
        for col in range(count):
            x0 = x_start + col * (key_w + gap)
            color = key_light if (row_index + col) % 4 else key_mid
            if col in (1, 7):
                color = key_pink
            if col in (4, 5):
                color = key_blue
            fill_rounded(img, size, (x0, y0, x0 + key_w, y0 + key_h), 0.012, color, color)

    fill_rounded(img, size, (0.19, 0.680, 0.305, 0.722), 0.014, key_light, key_light)
    fill_rounded(img, size, (0.323, 0.680, 0.674, 0.722), 0.014, key_blue, (94, 147, 201, 255))
    fill_rounded(img, size, (0.692, 0.680, 0.830, 0.722), 0.014, key_light, key_light)
    draw_pixel_text(img, size, "F75 MAX", 0.398, 0.690, 0.0068, (255, 255, 255, 240))
    return img


def write_png(path, img):
    height = len(img)
    width = len(img[0])
    raw = bytearray()
    for row in img:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend((r, g, b, a))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def png_bytes(img):
    height = len(img)
    width = len(img[0])
    raw = bytearray()
    for row in img:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend((r, g, b, a))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    return png


def write_icns(path, images):
    chunks = []
    for kind, size in (
        (b"icp4", 16),
        (b"icp5", 32),
        (b"icp6", 64),
        (b"ic07", 128),
        (b"ic08", 256),
        (b"ic09", 512),
        (b"ic10", 1024),
    ):
        payload = png_bytes(images[size])
        chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
    total = 8 + sum(len(chunk) for chunk in chunks)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", total))
        for chunk in chunks:
            f.write(chunk)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    images = {size: make_icon(size) for size in (16, 32, 64, 128, 256, 512, 1024)}
    targets = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in targets.items():
        write_png(os.path.join(ICONSET, name), images[size])
    write_icns(ICNS, images)


if __name__ == "__main__":
    main()
