# Ring King — Analogue Pocket

An Analogue Pocket core for the Woodplace / Data East *Ring King* arcade
hardware, by **HarpMudd**, built on the openFPGA framework.

## The Game

*Ring King* (Data East USA, 1985 — known in Japan as *King of Boxer*) is a
top-down boxing game. You fight your way up the rankings against a queue of
increasingly vicious contenders, throwing high and low punches, ducking,
weaving and pounding away at a stamina bar until somebody hits the canvas.
Knock your opponent down and the referee starts the count; survive the rounds
and you climb toward the championship belt.

## Hardware

Woodplace / Data East "King of Boxer" board set:

| Part | Role |
|---|---|
| Zilog Z80 (×4) | Main + video + sprite + sound CPUs (4 MHz each) |
| AY-3-8910 | Sound — 3-channel PSG (1.5 MHz) |
| 8-bit R2R DAC | Sound — sampled audio |
| Display | Vertical (ROT90) CRT, 256×224 visible, RGB |

The unusual part is the CPU count: **four Z80s**. The main CPU runs the game and
hands work to a dedicated video CPU and a dedicated sprite CPU through two
shared-RAM windows, while a fourth Z80 drives the audio. There is no protection
MCU and no encryption.

## The Build

The RTL was written by reverse-mapping the original behaviour out of MAME's
`dataeast/kingobox.cpp` and `kingobox_v.cpp` — Ernesto Corvi's driver, which is
what makes a build like this possible at all. Notable pieces, all implemented
from the hardware description:

- **Quad Z80** (the `T80` core) on clock-enables in a single clock domain, with
  the two true-dual-port shared-RAM windows (main↔video, main↔sprite), the
  main-driven interrupts, and the vblank NMI gated by the `f800` latch.
- **Three graphics layers:** a 1bpp packed-nibble character/foreground tilemap,
  a 3bpp background tilemap with vertical scroll and palette banking, and a
  16×16 3bpp sprite engine (both gfx banks) driven by a double line-buffer.
  All tilemaps use the hardware's column-major, Y-flipped scan order.
- **Color** through the original resistor-weighted PROM palette, modelled as
  the real linear resistor-ladder DAC.
- **Sprite graphics streamed from SDRAM**, with the three bitplanes interleaved
  so a single fetch yields a whole pixel.
- **AY-3-8910** (tone / noise / envelope with the full datasheet shape rules,
  port A wired to the sound latch) plus the 8-bit R2R DAC, mixed at the board's
  ratio.

## Controls

| Pocket | Action |
|---|---|
| **D-Pad** | Move (8-way) |
| **A** | Hook / Uppercut |
| **B** | Straight / Jab |
| **X** | Defense / Block |
| **Start** | 1P Start |
| **Select** | Insert coin |

Two players use two controllers — the second pad's **Start** is 2P start.

## Games

All six known sets run on this one core — pick the game from the Pocket menu:

| Game | Romset |
|---|---|
| **Ring King (US set 1)** | `ringking.zip` + `kingofb.zip` |
| **Ring King (US set 2)** | `ringking2.zip` + `kingofb.zip` |
| **Ring King (US set 3)** | `ringking3.zip` + `kingofb.zip` |
| **Ring King (US, Woodplace)** | `ringkingw.zip` + `kingofb.zip` |
| **King of Boxer (World)** | `kingofb.zip` |
| **King of Boxer (Japan)** | `kingofbj.zip` + `kingofb.zip` |

That's every set in MAME's `kingobox` driver. All but `kingofb` are clones that
take files from the parent, hence the second zip.

Each set ships a `.mra` recipe alongside its `.rom`, so you can build the ROM
yourself from your own MAME zips with the standard MiSTer `mra` tool:

```
mra ringking.mra
```

The `.mra` and the bundled `pack_rom.py` produce byte-identical images — both are
verified against each other on every build.

*King of Boxer* is the same game on **different hardware** — the original
Woodplace release, which Data East later relicensed as *Ring King*. The boards
shuffle their memory maps, sound chip ports, sprite format, input polarity,
graphics packing and palette format, so the core reads a variant byte at load
time and switches all of that at runtime.

The artwork is pixel-identical between the boards — only the *packing* differs.
Every set ships in its original ROM layout and the core adapts to it: the
graphics differences turn out to be pure addressing (plane offsets, code stride,
bit order), so the sprite/background gfx are re-addressed as they stream into
SDRAM and the characters and palette are addressed per board on read. Keeping
the ROMs in their native layout is what lets every set ship a `.mra`.

## ROMs

ROMs are **not** included — nothing in this repo contains copyrighted data.
Supply your own MAME romsets, then build the `.rom` images:

```
python pack_rom.py            # builds every set it can find
python pack_rom.py ringking   # or just one
```

It matches the required files by CRC32 and writes each set's `.rom` into
`Assets/ringking/common/`. A set whose romset you don't have is simply skipped.
Copy the contents of `dist/` to your Pocket SD card.

## Credits

This core stands on other people's work. Named properly:

**The original game** — *King of Boxer* / *Ring King*, Woodplace Inc. and
Data East USA, 1985.

**Ernesto Corvi** — wrote MAME's `kingobox` driver, which documents this
hardware. Every register, memory map, graphics layout and palette formula in
this core was derived from reading that driver. Without it there would be
nothing to build from. (`dataeast/kingobox.cpp`, BSD-3-Clause.)

**The T80 Z80 CPU core** — not a person, but a twenty-year lineage:

| | |
|---|---|
| **Daniel Wallner** | original author, 2001–2002 (OpenCores) |
| **MikeJ** | v300 rework, 2005 (fpgaarcade.com) |
| **Sean Riddle** | v301 — 8080/Z80 parity and overflow flags |
| **TobiFlex** | v303 — undocumented DDCB/FDCB opcodes, 2010 |
| **Sorgelig** | v350 "T80(c)" — timing accuracy; passes ZEXDOC/ZEXALL/Z80Full |

**Adam Gastineau (agg23)** — the SDRAM controller this core streams its sprite
and background graphics through, plus the `data_loader`, `sound_i2s` and
`sync_fifo` building blocks. MIT.

**Analogue** — the Analogue Pocket openFPGA framework (APF), used under the
Pocket EULA.

**HarpMudd** — the FPGA implementation and the Pocket build.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party HDL (the `T80` CPU core and
agg23's SDRAM controller) keeps its own copyright notices in the source
headers; no arcade ROM data is included anywhere in this repository.

## About / Support

I'm into retro games and the Analogue Pocket, always cooking up something new.
I love being part of a community built on sharing and the love of games — so if
any of my projects bring you joy, grab me a coffee; it fuels the next thing.

☕ **[buymeacoffee.com/harpmudd](https://buymeacoffee.com/harpmudd)**
