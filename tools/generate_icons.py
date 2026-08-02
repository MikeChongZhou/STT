#!/usr/bin/env python3
import os
import struct
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def write_png(path, width, height, pixels):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    rows = []
    stride = width * 4
    for y in range(height):
        rows.append(b"\x00" + bytes(pixels[y * stride : (y + 1) * stride]))
    raw = b"".join(rows)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def point_in_polygon(x, y, polygon):
    inside = False
    j = len(polygon) - 1
    for i, point in enumerate(polygon):
        xi, yi = point
        xj, yj = polygon[j]
        if (yi > y) != (yj > y):
            x_intersect = (xj - xi) * (y - yi) / ((yj - yi) or 1) + xi
            if x < x_intersect:
                inside = not inside
        j = i
    return inside


def blend(dst, src):
    sr, sg, sb, sa = src
    if sa == 255:
        return [sr, sg, sb, sa]
    dr, dg, db, da = dst
    alpha = sa / 255.0
    out_a = alpha + da / 255.0 * (1 - alpha)
    if out_a == 0:
        return [0, 0, 0, 0]
    return [
        int((sr * alpha + dr * da / 255.0 * (1 - alpha)) / out_a),
        int((sg * alpha + dg * da / 255.0 * (1 - alpha)) / out_a),
        int((sb * alpha + db * da / 255.0 * (1 - alpha)) / out_a),
        int(out_a * 255),
    ]


def set_pixel(pixels, width, x, y, color):
    if x < 0 or y < 0 or x >= width:
        return
    idx = (y * width + x) * 4
    pixels[idx : idx + 4] = blend(pixels[idx : idx + 4], color)


def fill_rect(pixels, width, height, x, y, w, h, color):
    x0 = max(0, int(x))
    y0 = max(0, int(y))
    x1 = min(width, int(x + w))
    y1 = min(height, int(y + h))
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            set_pixel(pixels, width, xx, yy, color)


LETTER_PATTERNS = {
    "S": [
        "11111",
        "10000",
        "10000",
        "11110",
        "00001",
        "00001",
        "11110",
    ],
    "T": [
        "11111",
        "00100",
        "00100",
        "00100",
        "00100",
        "00100",
        "00100",
    ],
    "G": [
        "11111",
        "10000",
        "10000",
        "10111",
        "10001",
        "10001",
        "11111",
    ],
}


def draw_letters(pixels, width, height):
    word = "STG"
    cell = max(1, width // 34)
    letter_w = cell * 5
    letter_h = cell * 7
    gap = cell * 2
    total_w = letter_w * len(word) + gap * (len(word) - 1)
    start_x = (width - total_w) // 2
    start_y = int(height * 0.39)
    color = [248, 252, 255, 255]
    shadow = [12, 43, 74, 130]
    for offset_x, offset_y, draw_color in [(cell // 2, cell // 2, shadow), (0, 0, color)]:
        x = start_x + offset_x
        for letter in word:
            pattern = LETTER_PATTERNS[letter]
            for row, line in enumerate(pattern):
                for col, value in enumerate(line):
                    if value == "1":
                        fill_rect(
                            pixels,
                            width,
                            height,
                            x + col * cell,
                            start_y + offset_y + row * cell,
                            cell,
                            cell,
                            draw_color,
                        )
            x += letter_w + gap


def make_icon(size):
    width = height = size
    pixels = bytearray([0, 0, 0, 0] * width * height)
    outer = [
        (0.50 * width, 0.055 * height),
        (0.83 * width, 0.18 * height),
        (0.765 * width, 0.63 * height),
        (0.50 * width, 0.925 * height),
        (0.235 * width, 0.63 * height),
        (0.17 * width, 0.18 * height),
    ]
    inner = [
        (0.50 * width, 0.095 * height),
        (0.785 * width, 0.205 * height),
        (0.725 * width, 0.605 * height),
        (0.50 * width, 0.865 * height),
        (0.275 * width, 0.605 * height),
        (0.215 * width, 0.205 * height),
    ]

    for y in range(height):
        for x in range(width):
            if point_in_polygon(x + 0.5, y + 0.5, outer):
                set_pixel(pixels, width, x, y, [7, 47, 82, 255])
            if point_in_polygon(x + 0.5, y + 0.5, inner):
                t = y / max(1, height - 1)
                r = int(16 + 16 * (1 - t))
                g = int(112 + 70 * (1 - t))
                b = int(148 + 74 * (1 - t))
                set_pixel(pixels, width, x, y, [r, g, b, 255])

    shine = [
        (0.31 * width, 0.20 * height),
        (0.50 * width, 0.12 * height),
        (0.69 * width, 0.20 * height),
        (0.63 * width, 0.25 * height),
        (0.50 * width, 0.20 * height),
        (0.37 * width, 0.25 * height),
    ]
    for y in range(height):
        for x in range(width):
            if point_in_polygon(x + 0.5, y + 0.5, shine):
                set_pixel(pixels, width, x, y, [255, 255, 255, 45])

    draw_letters(pixels, width, height)
    return pixels


def write_ico(path, png_paths):
    entries = []
    blobs = []
    offset = 6 + 16 * len(png_paths)
    for size, png_path in png_paths:
        with open(png_path, "rb") as f:
            blob = f.read()
        width_byte = 0 if size >= 256 else size
        entries.append((width_byte, width_byte, len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    data = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    for width_byte, height_byte, length, image_offset in entries:
        data.extend(struct.pack("<BBBBHHII", width_byte, height_byte, 0, 0, 1, 32, length, image_offset))
    for blob in blobs:
        data.extend(blob)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def write_icns(path, chunks):
    body = bytearray()
    for chunk_type, png_path in chunks:
        with open(png_path, "rb") as f:
            blob = f.read()
        body.extend(chunk_type.encode("ascii"))
        body.extend(struct.pack(">I", len(blob) + 8))
        body.extend(blob)
    data = b"icns" + struct.pack(">I", len(body) + 8) + body
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def main():
    shared_dir = os.path.join(ROOT, "assets", "icons")
    mac_iconset = os.path.join(ROOT, "macos", "Assets", "AppIcon.iconset")
    windows_assets = os.path.join(ROOT, "windows", "ScreenTimeGuardian", "Assets")
    ios_iconset = os.path.join(
        ROOT,
        "iOS",
        "ScreenTimeGuardianIOS",
        "ScreenTimeGuardianIOS",
        "Assets.xcassets",
        "AppIcon.appiconset",
    )

    for size in [16, 20, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 256, 512, 1024]:
        path = os.path.join(shared_dir, f"stg-{size}.png")
        write_png(path, size, size, make_icon(size))

    mac_names = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    os.makedirs(mac_iconset, exist_ok=True)
    for size, name in mac_names:
        write_png(os.path.join(mac_iconset, name), size, size, make_icon(size))
    write_icns(
        os.path.join(ROOT, "macos", "Assets", "AppIcon.icns"),
        [
            ("icp4", os.path.join(mac_iconset, "icon_16x16.png")),
            ("icp5", os.path.join(mac_iconset, "icon_32x32.png")),
            ("icp6", os.path.join(mac_iconset, "icon_32x32@2x.png")),
            ("ic07", os.path.join(mac_iconset, "icon_128x128.png")),
            ("ic08", os.path.join(mac_iconset, "icon_256x256.png")),
            ("ic09", os.path.join(mac_iconset, "icon_512x512.png")),
            ("ic10", os.path.join(mac_iconset, "icon_512x512@2x.png")),
        ],
    )

    ico_pngs = []
    for size in [16, 32, 48, 256]:
        path = os.path.join(windows_assets, f"stg-{size}.png")
        write_png(path, size, size, make_icon(size))
        ico_pngs.append((size, path))
    write_ico(os.path.join(windows_assets, "stg.ico"), ico_pngs)

    os.makedirs(ios_iconset, exist_ok=True)
    ios_images = [
        ("Icon-20@2x.png", 40, "20x20", "2x", "iphone"),
        ("Icon-20@3x.png", 60, "20x20", "3x", "iphone"),
        ("Icon-29@2x.png", 58, "29x29", "2x", "iphone"),
        ("Icon-29@3x.png", 87, "29x29", "3x", "iphone"),
        ("Icon-40@2x.png", 80, "40x40", "2x", "iphone"),
        ("Icon-40@3x.png", 120, "40x40", "3x", "iphone"),
        ("Icon-60@2x.png", 120, "60x60", "2x", "iphone"),
        ("Icon-60@3x.png", 180, "60x60", "3x", "iphone"),
        ("Icon-76@2x.png", 152, "76x76", "2x", "ipad"),
        ("Icon-83.5@2x.png", 167, "83.5x83.5", "2x", "ipad"),
        ("Icon-1024.png", 1024, "1024x1024", "1x", "ios-marketing"),
    ]
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for filename, pixels, logical_size, scale, idiom in ios_images:
        write_png(os.path.join(ios_iconset, filename), pixels, pixels, make_icon(pixels))
        contents["images"].append(
            {
                "filename": filename,
                "idiom": idiom,
                "scale": scale,
                "size": logical_size,
            }
        )
    import json

    with open(os.path.join(ios_iconset, "Contents.json"), "w", encoding="utf-8") as f:
        json.dump(contents, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
