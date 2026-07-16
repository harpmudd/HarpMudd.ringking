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

# 0x4C200 = board variant byte, snooped by the FPGA during load:
#   0 = Ring King board (dedicated gfx4 bg, D800/E000 maps, AY at 02/03)
#   1 = King of Boxer board (bg from the sprite gfx, F800/FC00 maps, AY at 08/0c)
# The image is padded past it on purpose: a variant byte sitting in the image's
# LAST 32-bit word does not reliably land (see the multi-game notes).
VARIANT_OFFSET = 0x4C200
ROM_IMAGE_SIZE = 0x4C210
VAR_RINGKING = 0
VAR_KINGOFB  = 1

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
                  "ringkingw.zip + kingofb.zip", VAR_KINGOFB),
    "ringking3": (None, "ringking3.rom", "Ring King (US set 3)",
                  "ringking3.zip + kingofb.zip", VAR_KINGOFB),
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


def normalise_kingofb_gfx(g1, g2, g3):
    """kingofb packing -> Ring King packing (same pixels, different bit layout)."""
    # ---- chars: kingofb charlayout (bank = a 0x1000 byte offset, MSB-first x)
    #      -> rk_charlayout1/2 (bank = nibble; right half of a row at byte +0x1000)
    out1 = bytearray(0x2000)
    for bank in range(2):
        for code in range(512):
            for y in range(8):
                for x in range(8):
                    px = _rdbit(g1, (bank * 0x1000 + code * 8 + y) * 8 + x)
                    if not px:
                        continue
                    byte = code * 8 + (7 - y) + (0x1000 if x >= 4 else 0)
                    bit = (4 + (x & 3)) if bank else (x & 3)
                    out1[byte] |= 1 << bit
    # ---- 16x16 3bpp: kingofb spritelayout/tilelayout -> rk_spritelayout/rk_tilelayout
    def conv16(src, ntiles, kb_unit, rk_unit, out_size):
        out = bytearray(out_size)
        kb_plane = [2 * kb_unit * 8, 1 * kb_unit * 8, 0]
        kb_x = [3 * kb_unit * 8 + i for i in range(8)] + list(range(8))
        rk_plane = [0, 1 * rk_unit * 8, 2 * rk_unit * 8]
        rk_x = [7, 6, 5, 4, 3, 2, 1, 0] + [16 * 8 + i for i in (7, 6, 5, 4, 3, 2, 1, 0)]
        for code in range(ntiles):
            for y in range(16):
                yo = y * 8
                for x in range(16):
                    for p in range(3):
                        if _rdbit(src, code * 128 + kb_plane[p] + kb_x[x] + yo):
                            _wrbit(out, code * 256 + rk_plane[p] + rk_x[x] + yo, 1)
        return out
    out2 = conv16(g2, 1024, 0x4000, 0x8000, 0x18000)   # sprites
    out3 = conv16(g3, 512,  0x2000, 0x4000, 0x0C000)   # tiles
    return out1, out2, out3


def init_ringkingw_proms(user1):
    """MAME init_ringkingw: re-encode the 3 x 0x400 'user1' PROMs into kingofb's
    3 x 0x100 R/G/B layout. Only the first 8 of every 16 entries are used, and the
    result is 4 blocks of 0x40 -- hence the i-skip and the k loop."""
    r, g, b = bytearray(0x100), bytearray(0x100), bytearray(0x100)
    i = 0
    for j in range(0x40):
        if (i & 0xF) == 8:
            i += 8
        for k in range(4):
            r[j + 0x40 * k] = user1[i + 0x000 + 0x100 * k]
            g[j + 0x40 * k] = user1[i + 0x400 + 0x100 * k]
            b[j + 0x40 * k] = user1[i + 0x800 + 0x100 * k]
        i += 1
    return r, g, b


def init_ringking3_proms(rg, bb):
    """MAME init_ringking3: Ring King packs red in the HIGH nibble and green in the
    LOW nibble of one PROM. Expand it back into separate R/G so the kingofb path can
    treat every set identically. (Round trip is exact: normalise_kingofb_proms then
    re-packs R<<4|G, giving the original byte straight back.)"""
    r = bytearray((v >> 4) & 0x0F for v in rg)
    g = bytearray(v & 0x0F for v in rg)
    b = bytearray(v & 0x0F for v in bb)
    return r, g, b


def normalise_kingofb_proms(r, g, b):
    """3 x 4-bit PROMs (R/G/B) -> our 2-PROM packed format: [0]=R<<4|G, [1]=B."""
    p0 = bytearray(0x100)
    p1 = bytearray(0x100)
    for i in range(0x100):
        p0[i] = ((r[i] & 0x0F) << 4) | (g[i] & 0x0F)
        p1[i] = b[i] & 0x0F
    return p0, p1


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

    # native gfx regions
    g1 = _assemble(found, regions["gfx1"], 0x2000)
    g2 = _assemble(found, regions["gfx2"], 0x18000)
    g3 = _assemble(found, regions["gfx3"], 0x0C000)

    # colour PROMs -> R/G/B, however this set happens to encode them
    prom_kind, prom_defs = regions["proms"]
    rgb = None
    if prom_kind == "user1":
        user1 = _assemble(found, prom_defs, 0x0C00)
        if user1 is not None:
            rgb = init_ringkingw_proms(user1)
            print("  re-encoding 'user1' PROMs (init_ringkingw)...")
    else:
        raw = [found.get(c) for c, _ in prom_defs]
        if not any(p is None for p in raw):
            if prom_kind == "rk":
                rgb = init_ringking3_proms(raw[0], raw[1])
                print("  expanding Ring King's packed PROMs (init_ringking3)...")
            else:
                rgb = tuple(raw)
    if g1 is None or g2 is None or g3 is None or rgb is None:
        print(f"  MISSING gfx/PROM ROMs -- {game} needs: {romsets}")
        return False

    print("  normalising gfx (kingofb packing -> Ring King packing)...")
    n1, n2, n3 = normalise_kingofb_gfx(g1, g2, g3)
    image[0x1E000:0x1E000 + len(n1)] = n1       # gfx1 chars
    image[0x20000:0x20000 + len(n2)] = n2       # gfx2 sprites
    image[0x38000:0x38000 + len(n3)] = n3       # gfx3 tiles
    # gfx4 (0x44000) intentionally left blank: this board has no dedicated bg gfx,
    # it draws the bg out of the sprite gfx (an RTL variant, not a data one).
    p0, p1 = normalise_kingofb_proms(*rgb)
    image[0x4C000:0x4C100] = p0
    image[0x4C100:0x4C200] = p1
    image[VARIANT_OFFSET] = variant
    print("  OK   gfx1/gfx2/gfx3 normalised, 3 PROMs -> 2 packed")

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
