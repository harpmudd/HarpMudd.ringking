"""
pack_rom.py — Build a flat ROM image for the HarpMudd Ring King core.

Target set = ringking (US set 1): empty_init, NO ROM descramble (the ringkingw /
ringking3 sets need init_* unscrambling — we deliberately target the plain set).
Ring King is a clone of King of Boxer, so the romset spans ringking.zip (the
CX-* ROMs) + parent kingofb.zip (20.j4). Files are matched by CRC32 across every
.zip in the romset dir, so both zips must be present. All 17 CRC-verified against
MAME dataeast/kingobox.cpp.

Flat ROM image layout (byte offset = dn_addr in the FPGA):
  0x00000  main Z80    48K  (cx13 32K@0 + cx14 16K@0x8000; CPU maps 0000-BFFF)
  0x0C000  video Z80   16K  (cx07; video CPU maps 0000-3FFF)
  0x10000  sound Z80   48K  (cx12 32K@0 + 20.j4 16K@0x8000; CPU maps 0000-BFFF)
  0x1C000  sprite Z80   8K  (cx00; sprite CPU maps 0000-1FFF)
  0x1E000  gfx1 chars   8K  (cx08)
  (BRAM ROM offsets are power-of-2 aligned so the FPGA loader writes each with a
   pure bit-slice index -> clean M10K inference. A non-aligned base like 0x12000
   forces a subtract in the write index, which fails RAM inference = logic blowup.)
  0x20000  gfx2 sprites 96K (cx04 + cx02 + cx06, 3x32K)
  0x38000  gfx3         48K (cx03 + cx01 + cx05, 3x16K)
  0x44000  gfx4 tiles   32K (cx09 + cx10, 2x16K)
  0x4C000  color PROMs 512B (82s135 RG @0 + 82s129 B @0x100)
Image ends at 0x4C200.

NOTE (architecture, decided in core_game.vh not here): total image ~312 KB. The
big gfx2/3/4 (176 KB) likely belong in SDRAM, not M10K — the Pocket Cyclone V has
~385 KB of block RAM and everything else (CPU ROMs, work/shared RAM, char gfx,
palette, line buffers) needs room too. pack_rom is agnostic: it builds the flat
image the loader streams; the loader decides which regions land in BRAM vs SDRAM.

Usage:  python pack_rom.py
"""

import sys
import zipfile
import zlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ZIP_DIR = next(
    (d for d in (os.environ.get("HARPMUDD_ROMS"),
                 os.path.join(os.path.dirname(HERE), "Downloaded_Artifacts"))
     if d and os.path.isdir(d)),
    HERE)
ASSETS_DIR     = os.path.join(HERE, "dist", "Assets", "ringking", "common")
OUT_ROM        = os.path.join(ASSETS_DIR, "ringking.rom")
ROM_IMAGE_SIZE = 0x4C200

# (CRC32, size, description, image_offset)
ROM_DEFS = [
    # main Z80 (0000-BFFF)
    (0x93e38c02, 0x8000, "cx13.9f   (main 0000-7FFF)",   0x00000),
    (0xa435acb0, 0x4000, "cx14.11f  (main 8000-BFFF)",   0x08000),
    # video Z80 (0000-3FFF)
    (0x9f074746, 0x4000, "cx07.10c  (video 0000-3FFF)",  0x0C000),
    # sound Z80 (0000-BFFF) -- aligned to 0x10000 (pure-slice write index)
    (0x1d5d6c6b, 0x8000, "cx12.4ef  (sound 0000-7FFF)",  0x10000),
    (0x64c137a4, 0x4000, "20.j4     (sound 8000-BFFF)",  0x18000),
    # sprite Z80 (0000-1FFF)
    (0x880b8aa7, 0x2000, "cx00.4c   (sprite 0000-1FFF)", 0x1C000),
    # gfx1 characters (8K)
    (0xdbd7c1c2, 0x2000, "cx08.13b  (gfx1 chars)",       0x1E000),
    # gfx2 sprites (3x32K)
    (0x506a2ed9, 0x8000, "cx04.11j  (gfx2 sprites 0)",   0x20000),
    (0x009dde6a, 0x8000, "cx02.8j   (gfx2 sprites 1)",   0x28000),
    (0xd819a3b2, 0x8000, "cx06.13j  (gfx2 sprites 2)",   0x30000),
    # gfx3 (3x16K)
    (0x682fd1c4, 0x4000, "cx03.9j   (gfx3 0)",           0x38000),
    (0x85130b46, 0x4000, "cx01.7j   (gfx3 1)",           0x3C000),
    (0xf7c4f3dc, 0x4000, "cx05.12j  (gfx3 2)",           0x40000),
    # gfx4 tiles (2x16K)
    (0x37a082cf, 0x4000, "cx09.17d  (gfx4 tiles 0)",     0x44000),
    (0xab9446c5, 0x4000, "cx10.17e  (gfx4 tiles 1)",     0x48000),
    # color PROMs (82s135 = red+green, 82s129 = blue)
    (0x0e723a83, 0x0100, "82s135.2a (PROM red+green)",   0x4C000),
    (0xd345cbb3, 0x0100, "82s129.1a (PROM blue)",        0x4C100),
]


def crc32_of(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def load_dir_by_crc(zip_dir):
    found = {}
    for zname in sorted(f for f in os.listdir(zip_dir) if f.lower().endswith('.zip')):
        try:
            with zipfile.ZipFile(os.path.join(zip_dir, zname)) as zf:
                for info in zf.infolist():
                    found[crc32_of(zf.read(info.filename))] = zf.read(info.filename)
        except Exception as e:
            print(f"  WARNING: could not read {zname}: {e}")
    return found


def build(found):
    print("\n=== Ring King (ringking) -> ringking.rom ===")
    image = bytearray(b"\xFF" * ROM_IMAGE_SIZE)
    errors = []
    for (crc, size, d, offset) in ROM_DEFS:
        if crc in found:
            data = found[crc]
            if len(data) != size:
                errors.append(f"  WRONG SIZE  {d}: expected {size}, got {len(data)}")
                continue
            image[offset:offset + size] = data
            print(f"  OK   {d}  @ 0x{offset:05X}")
        else:
            errors.append(f"  MISSING     {d}  (CRC {crc:08x})")
    if errors:
        print("  -- MISSING/INVALID:")
        for e in errors:
            print(e)
        return False
    os.makedirs(os.path.dirname(OUT_ROM), exist_ok=True)
    with open(OUT_ROM, "wb") as f:
        f.write(image)
    print(f"  SUCCESS: {len(image)} bytes -> {OUT_ROM}")
    return True


def main():
    print(f"Scanning zips in: {DEFAULT_ZIP_DIR}")
    found = load_dir_by_crc(DEFAULT_ZIP_DIR)
    sys.exit(0 if build(found) else 1)


if __name__ == "__main__":
    main()
