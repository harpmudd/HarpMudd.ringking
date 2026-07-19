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

# 0x28300 = variant byte, snooped by the FPGA during load. TWO independent bits:
#   bit0 board   0 = Ring King  (dedicated gfx4 bg, D800/E000 maps, AY at 02/03)
#                1 = King of Boxer (bg from the sprite gfx, F800/FC00, AY 08/0c)
#   bit1 palette 0 = Ring King's 2 packed proms (red = high nibble of region 0)
#                1 = 3 separate R/G/B proms
#   bit2 palette addressing: 1 = ringkingw's raw 'user1' proms, which store the
#                256 used entries spread 8-of-every-16 across 0x400. The FPGA undoes
#                that with a pure address bit-shuffle, so the ROM stays a plain copy.
# The two are NOT the same flag: ringking3 runs a King of Boxer BOARD but ships
# Ring-King-format proms.
#
# It must load BEFORE gfx2/gfx3, because the SDRAM write path remaps addresses per
# board -- hence the layout below puts those two regions last.
#   0x00000 main 48K | 0x0C000 video 16K | 0x10000 sound 48K | 0x1C000 sprite cpu 8K
#   0x1E000 gfx1 8K  | 0x20000 gfx4 32K (Ring King bg only)
#   0x28000 pal r0 | 0x28400 pal r1 | 0x28800 pal r2 | 0x28C00 variant  (0x400 each)
#   0x30000 gfx2 0x18000 | 0x48000 gfx3 0xC000   (both 0x8000/0x4000 ALIGNED so the
#   loader's SDRAM write index stays a pure bit-slice)
# The image is padded past the variant byte on purpose: a variant byte sitting in
# the image's LAST 32-bit word does not reliably land (see the multi-game notes).
VARIANT_OFFSET = 0x28C00
ROM_IMAGE_SIZE = 0x54010
PAL_R0, PAL_R1, PAL_R2 = 0x28000, 0x28400, 0x28800   # 0x400 each: ringkingw
                                                     # ships RAW 0x400 user1 proms
GFX1_OFF, GFX2_OFF, GFX3_OFF = 0x1E000, 0x30000, 0x48000
VAR_RINGKING = 0                 # Ring King board + packed proms
VAR_KINGOFB  = 1 | 2             # King of Boxer board + 3 separate proms
VAR_KOB_RKPAL = 1                # King of Boxer board + Ring King packed proms
VAR_KINGOFB_W = 1 | 2 | 4        # King of Boxer board + raw user1 proms

# The two supported sets run on IDENTICAL hardware (same machine config, video,
# PROMs and sound IO), so the FPGA needs no variant byte -- they differ only in
# the main + video CPU program ROMs. 14 of the 17 files are shared.
# (CRC32, size, description, image_offset)
COMMON_DEFS = [
    # sound Z80 (0000-BFFF) -- aligned to 0x10000 (pure-slice write index)
    (0x1d5d6c6b, 0x8000, "cx12.4ef  (sound 0000-7FFF)",  0x10000),
    (0x64c137a4, 0x4000, "20.j4     (sound 8000-BFFF)",  0x18000),
    # sprite Z80 (0000-1FFF)
    (0x880b8aa7, 0x2000, "cx00.4c   (sprite 0000-1FFF)", 0x1C000),
    # gfx1 characters (8K)
    (0xdbd7c1c2, 0x2000, "cx08.13b  (gfx1 chars)",       0x1E000),
    # gfx4 tiles (2x16K)
    (0x37a082cf, 0x4000, "cx09.17d  (gfx4 tiles 0)",     0x20000),
    (0xab9446c5, 0x4000, "cx10.17e  (gfx4 tiles 1)",     0x24000),
    # color PROMs. Ring King packs red+green into ONE prom (red = high nibble),
    # so it fills palette regions 0 and 1 and leaves region 2 unused; the King of
    # Boxer boards ship 3 separate proms and fill all three. See PAL_R/G/B below.
    (0x0e723a83, 0x0100, "82s135.2a (PROM red+green)",   0x28000),
    (0xd345cbb3, 0x0100, "82s129.1a (PROM blue)",        0x28400),
    # gfx2 sprites (3x32K) and gfx3 (3x16K) live AFTER the variant byte -- see the
    # layout note at the top: the loader is sequential and the SDRAM write path has
    # to know which board it is before these arrive.
    (0x506a2ed9, 0x8000, "cx04.11j  (gfx2 sprites 0)",   0x30000),
    (0x009dde6a, 0x8000, "cx02.8j   (gfx2 sprites 1)",   0x38000),
    (0xd819a3b2, 0x8000, "cx06.13j  (gfx2 sprites 2)",   0x40000),
    (0x682fd1c4, 0x4000, "cx03.9j   (gfx3 0)",           0x48000),
    (0x85130b46, 0x4000, "cx01.7j   (gfx3 1)",           0x4C000),
    (0xf7c4f3dc, 0x4000, "cx05.12j  (gfx3 2)",           0x50000),
]

# Ring King (US set 1) -- the Data East USA license set. romset: ringking.zip
RINGKING_DEFS = COMMON_DEFS + [
    (0x93e38c02, 0x8000, "cx13.9f   (main 0000-7FFF)",   0x00000),
    (0xa435acb0, 0x4000, "cx14.11f  (main 8000-BFFF)",   0x08000),
    (0x9f074746, 0x4000, "cx07.10c  (video 0000-3FFF)",  0x0C000),
]

# Ring King (US set 2) -- same board, different main/video program. romset: ringking2.zip
RINGKING2_DEFS = COMMON_DEFS + [
    (0x086921ea, 0x8000, "rkngm1.bin   (main 0000-7FFF)",  0x00000),
    (0xc0b636a4, 0x4000, "rkngm2.bin   (main 8000-BFFF)",  0x08000),
    (0xd9dc1a0a, 0x4000, "rkngtram.bin (video 0000-3FFF)", 0x0C000),
]

# name -> (defs, output .rom, description, needed romsets)
GAMES = {
    "ringking":  (RINGKING_DEFS,  "ringking.rom",  "Ring King (US set 1)",
                  "ringking.zip + kingofb.zip", VAR_RINGKING),
    "ringking2": (RINGKING2_DEFS, "ringking2.rom", "Ring King (US set 2)",
                  "ringking2.zip + kingofb.zip", VAR_RINGKING),
    # defs = None -> built by build_kingofb() (normalising path, see below)
    "kingofb":   (None, "kingofb.rom", "King of Boxer (World)", "kingofb.zip",
                  VAR_KINGOFB),
    "kingofbj":  (None, "kingofbj.rom", "King of Boxer (Japan)",
                  "kingofbj.zip + kingofb.zip", VAR_KINGOFB),
    "ringkingw": (None, "ringkingw.rom", "Ring King (US, Woodplace Inc.)",
                  "ringkingw.zip + kingofb.zip", VAR_KINGOFB_W),
    "ringking3": (None, "ringking3.rom", "Ring King (US set 3)",
                  "ringking3.zip + kingofb.zip", VAR_KOB_RKPAL),
}

# =============================================================================
# King of Boxer group (kingofb / kingofbj / ringkingw / ringking3)
# -----------------------------------------------------------------------------
# Same game, DIFFERENT board: the gfx ROMs use a completely different bit packing
# and the palette is 3 separate R/G/B PROMs instead of 2 packed ones. The pixel
# ART is identical to Ring King's -- only the packing differs -- so rather than
# give the FPGA a second decode path we NORMALISE here at build time: decode with
# the kingofb layout, re-encode into the Ring King layout. The core's existing
# gfx decode then renders these sets unchanged. (Verified by round-trip: decode
# -> re-encode -> decode is pixel-identical.)
#
# The one thing that cannot be normalised is the background: Ring King has a
# dedicated gfx4, kingofb has none and draws its bg out of the sprite gfx with a
# 10-bit code + bank. That stays an RTL variant (see core_game.vh / the variant
# byte), and gfx4 is simply left blank for these sets.
# =============================================================================

# kingofb native regions: (crc, size, dest_offset_within_region)
KINGOFB_GFX1 = [(0xe36d4f4f, 0x2000, 0x0000)]                       # chars (8K)
KINGOFB_GFX2 = [(0xce6580af, 0x4000, 0x00000), (0xcf74ea50, 0x4000, 0x04000),
                (0xd8b53975, 0x4000, 0x08000), (0x4ab506d2, 0x4000, 0x0c000),
                (0xecf95a2c, 0x4000, 0x10000), (0x8200cb2b, 0x4000, 0x14000)]
KINGOFB_GFX3 = [(0x3d472a22, 0x2000, 0x0000), (0xcc002ea9, 0x2000, 0x2000),
                (0x23c1b3ee, 0x2000, 0x4000), (0xd6b1b8fe, 0x2000, 0x6000),
                (0xfce71e5a, 0x2000, 0x8000), (0x3f68b991, 0x2000, 0xa000)]
# CPU ROMs are plain copies into our image layout
KINGOFB_CPU = [
    (0x6220bfa2, 0x4000, "22.d9  (main 0000-3FFF)",   0x00000),
    (0x5782fdd8, 0x4000, "23.e9  (main 4000-7FFF)",   0x04000),
    (0x3fb39489, 0x4000, "21.b9  (video 0000-3FFF)",  0x0C000),
    (0xc057e28e, 0x4000, "18.f4  (sound 0000-3FFF)",  0x10000),
    (0x060253dd, 0x4000, "19.h4  (sound 4000-7FFF)",  0x14000),
    (0x64c137a4, 0x4000, "20.j4  (sound 8000-BFFF)",  0x18000),
    (0x379f4f84, 0x2000, "17.j9  (sprite 0000-1FFF)", 0x1C000),
]
# 3 separate 4-bit PROMs: R, G, B
KINGOFB_PROMS = [(0xc58e5121, "R"), (0x5ab06f25, "G"), (0x1171743f, "B")]

# ---- the other three sets in the King of Boxer group -------------------------
# All run the same board as kingofb, so they all take the normalising path and the
# kob variant byte. They differ only in which ROMs they carry -- and, for the two
# Ring King ones, in how their colour PROMs are encoded.

# kingofbj (Japan): identical program ROMs to kingofb. Only the character ROM
# (Japanese text) and one sprite ROM differ -- everything else CRC-matches the
# parent, which is why kingofbj.zip holds just those two files.
KINGOFBJ_GFX1 = [(0x988a77bf, 0x2000, 0x0000)]              # 13.d14 (Japanese chars)
KINGOFBJ_GFX2 = [(0x7b6f390e, 0x4000, 0x00000)] + KINGOFB_GFX2[1:]   # 1.b1 differs

# ringkingw / ringking3 share a different tile (gfx3) set from kingofb's.
RK_GFX3 = [(0x019a88b0, 0x2000, 0x0000), (0xbfdc741a, 0x2000, 0x2000),
           (0x3cc7bdc5, 0x2000, 0x4000), (0x65f1281b, 0x2000, 0x6000),
           (0xaf5013e7, 0x2000, 0x8000), (0x1f6654d6, 0x2000, 0xa000)]

RINGKINGW_CPU = [
    (0x8263f517, 0x4000, "15.d9  (main 0000-3FFF)",   0x00000),
    (0xdaadd700, 0x4000, "16.e9  (main 4000-7FFF)",   0x04000),
    (0x76a73c95, 0x4000, "14.b9  (video 0000-3FFF)",  0x0C000),
    (0xc057e28e, 0x4000, "18.f4  (sound 0000-3FFF)",  0x10000),
    (0x060253dd, 0x4000, "19.h4  (sound 4000-7FFF)",  0x14000),
    (0x64c137a4, 0x4000, "20.j4  (sound 8000-BFFF)",  0x18000),
    (0x379f4f84, 0x2000, "17.j9  (sprite 0000-1FFF)", 0x1C000),
]
# ringkingw's PROMs sit in a 3 x 0x400 "user1" region in a different encoding.
RINGKINGW_USER1 = [(0x8ce34029, 0x400, 0x000), (0x54cfe913, 0x400, 0x400),
                   (0x913f5975, 0x400, 0x800)]              # prom2 R, prom3 G, prom1 B
# ...stored RAW (see VAR bit2): the FPGA does the 8-of-16 selection by address.

# ringking3 is the only set with a THIRD main program ROM (48K, not 32K).
RINGKING3_CPU = [
    (0x63627b8b, 0x4000, "14.d9  (main 0000-3FFF)",   0x00000),
    (0xe7557489, 0x4000, "15.e9  (main 4000-7FFF)",   0x04000),
    (0xa3b3bb16, 0x4000, "16.f9  (main 8000-BFFF)",   0x08000),
    (0xf33f94a2, 0x4000, "13.b9  (video 0000-3FFF)",  0x0C000),
    (0xc057e28e, 0x4000, "18.f4  (sound 0000-3FFF)",  0x10000),
    (0x060253dd, 0x4000, "19.h4  (sound 4000-7FFF)",  0x14000),
    (0x64c137a4, 0x4000, "20.j4  (sound 8000-BFFF)",  0x18000),
    (0x379f4f84, 0x2000, "17.j9  (sprite 0000-1FFF)", 0x1C000),
]
# ringking3 carries Ring King's 2 PROMs (R hi-nibble / G lo-nibble packed, + B).
RINGKING3_PROMS = [(0x0e723a83, "R+G"), (0xd345cbb3, "B")]

# Per-set regions. proms = (kind, defs); kind picks how to get R/G/B out of them:
#   "rgb"   3 separate 4-bit PROMs, already in kingofb layout
#   "user1" 3 x 0x400 PROMs needing MAME's init_ringkingw re-encode
#   "rk"    Ring King's 2 packed PROMs, needing MAME's init_ringking3 expand
KOB_SETS = {
    "kingofb":   dict(cpu=KINGOFB_CPU,   gfx1=KINGOFB_GFX1,  gfx2=KINGOFB_GFX2,
                      gfx3=KINGOFB_GFX3, proms=("rgb",   KINGOFB_PROMS)),
    "kingofbj":  dict(cpu=KINGOFB_CPU,   gfx1=KINGOFBJ_GFX1, gfx2=KINGOFBJ_GFX2,
                      gfx3=KINGOFB_GFX3, proms=("rgb",   KINGOFB_PROMS)),
    "ringkingw": dict(cpu=RINGKINGW_CPU, gfx1=KINGOFB_GFX1,  gfx2=KINGOFB_GFX2,
                      gfx3=RK_GFX3,      proms=("user1", RINGKINGW_USER1)),
    "ringking3": dict(cpu=RINGKING3_CPU, gfx1=KINGOFBJ_GFX1, gfx2=KINGOFB_GFX2,
                      gfx3=RK_GFX3,      proms=("rk",    RINGKING3_PROMS)),
}


def _rdbit(buf, o):
    return (buf[o >> 3] >> (7 - (o & 7))) & 1


def _wrbit(buf, o, v):
    if v:
        buf[o >> 3] |= 1 << (7 - (o & 7))


def _assemble(found, parts, size):
    """Concatenate raw ROMs into a native region. Returns None if any is missing."""
    buf = bytearray(size)
    for crc, sz, off in parts:
        d = found.get(crc)
        if d is None or len(d) != sz:
            return None
        buf[off:off + sz] = d
    return buf


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


def flat_defs(game):
    """Flat (crc,size,desc,offset) list for a King of Boxer group set, so the .mra
    generator can treat it like any other set. Every region is a plain copy now."""
    r = KOB_SETS[game]
    out = list(r["cpu"])
    for key, base in (("gfx1", GFX1_OFF), ("gfx2", GFX2_OFF), ("gfx3", GFX3_OFF)):
        for crc, sz, off in r[key]:
            out.append((crc, sz, f"{game} {key}+0x{off:X}", base + off))
    kind, defs = r["proms"]
    if kind == "user1":
        for (crc, sz, off), base in zip(defs, (PAL_R0, PAL_R1, PAL_R2)):
            out.append((crc, sz, f"{game} user1 prom", base))
    else:
        for (crc, tag), base in zip(defs, (PAL_R0, PAL_R1, PAL_R2)):
            out.append((crc, 0x100, f"{game} prom {tag}", base))
    return out


def build_kingofb(game, found):
    """King of Boxer group: plain CPU ROMs + NORMALISED gfx/palette."""
    _, out_name, desc, romsets, variant = GAMES[game]
    out_rom = os.path.join(ASSETS_DIR, out_name)
    print(f"\n=== {desc} ({game}) -> {out_name} ===")
    image = bytearray(b"\xFF" * ROM_IMAGE_SIZE)

    regions = KOB_SETS[game]

    # CPU ROMs (plain copies)
    for (crc, size, d, offset) in regions["cpu"]:
        data = found.get(crc)
        if data is None or len(data) != size:
            print(f"  MISSING/BAD  {d}  (CRC {crc:08x})")
            print(f"  -- {game} needs: {romsets}")
            return False
        image[offset:offset + size] = data
        print(f"  OK   {d}  @ 0x{offset:05X}")

    # gfx regions -- PLAIN COPIES in the board's NATIVE packing. The FPGA addresses
    # this layout directly (different byte address + MSB-first bit order), so there
    # is no repacking here. That is what lets every set have an .mra: the recipe
    # only ever concatenates whole files.
    g1 = _assemble(found, regions["gfx1"], 0x2000)
    g2 = _assemble(found, regions["gfx2"], 0x18000)
    g3 = _assemble(found, regions["gfx3"], 0x0C000)

    # colour PROMs, straight into the 3 palette regions
    prom_kind, prom_defs = regions["proms"]
    pal = None
    if prom_kind == "user1":
        raw = [found.get(c) for c, _, _ in prom_defs]
        if not any(p is None for p in raw):
            pal = tuple(raw)                      # RAW 0x400 blocks; FPGA re-addresses
            print("  storing raw 'user1' PROMs (FPGA does the 8-of-16 selection)...")
    else:
        raw = [found.get(c) for c, _ in prom_defs]
        if not any(p is None for p in raw):
            pal = tuple(raw) if prom_kind == "rgb" else (raw[0], raw[1], None)
    if g1 is None or g2 is None or g3 is None or pal is None:
        print(f"  MISSING gfx/PROM ROMs -- {game} needs: {romsets}")
        return False

    image[GFX1_OFF:GFX1_OFF + len(g1)] = g1     # chars   (native)
    image[GFX2_OFF:GFX2_OFF + len(g2)] = g2     # sprites (native)
    image[GFX3_OFF:GFX3_OFF + len(g3)] = g3     # tiles   (native)
    # gfx4 (0x20000) intentionally left blank: this board has no dedicated bg gfx,
    # it draws the bg out of the sprite gfx (an RTL variant, not a data one).
    for off, data in zip((PAL_R0, PAL_R1, PAL_R2), pal):
        if data is not None:
            image[off:off + len(data)] = data
    image[VARIANT_OFFSET] = variant
    print(f"  OK   gfx1/gfx2/gfx3 native, palette -> regions (variant {variant})")

    os.makedirs(os.path.dirname(out_rom), exist_ok=True)
    with open(out_rom, "wb") as f:
        f.write(image)
    print(f"  SUCCESS: {len(image)} bytes -> {out_rom}")
    return True


def build(game, found):
    defs, out_name, desc, romsets, variant = GAMES[game]
    if defs is None:                 # King of Boxer group uses the normalising path
        return build_kingofb(game, found)
    out_rom = os.path.join(ASSETS_DIR, out_name)
    print(f"\n=== {desc} ({game}) -> {out_name} ===")
    image = bytearray(b"\xFF" * ROM_IMAGE_SIZE)
    errors = []
    for (crc, size, d, offset) in sorted(defs, key=lambda x: x[3]):
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
        print(f"  -- {game} needs: {romsets}")
        return False
    image[VARIANT_OFFSET] = variant
    os.makedirs(os.path.dirname(out_rom), exist_ok=True)
    with open(out_rom, "wb") as f:
        f.write(image)
    print(f"  SUCCESS: {len(image)} bytes (variant {variant}) -> {out_rom}")
    return True


def main():
    print(f"Scanning zips in: {DEFAULT_ZIP_DIR}")
    found = load_dir_by_crc(DEFAULT_ZIP_DIR)
    # `python pack_rom.py [game ...]` -- default: build every set we can.
    wanted = [a for a in sys.argv[1:] if not a.startswith("-")] or list(GAMES)
    unknown = [g for g in wanted if g not in GAMES]
    if unknown:
        print(f"Unknown set(s): {', '.join(unknown)}.  Known: {', '.join(GAMES)}")
        sys.exit(2)
    results = {g: build(g, found) for g in wanted}
    print("\n=== Summary ===")
    for g, ok in results.items():
        print(f"  {'OK     ' if ok else 'SKIPPED'} {g}  ({GAMES[g][2]})")
    # A missing optional romset is not fatal -- succeed if at least one set built.
    sys.exit(0 if any(results.values()) else 1)


if __name__ == "__main__":
    main()
