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
`dataeast/kingobox.cpp` and `kingobox_v.cpp`. Notable pieces, all implemented
from the hardware description:

- **Quad Z80** (the `T80` core) on clock-enables in a single clock domain, with
  the two true-dual-port shared-RAM windows (main↔video, main↔sprite), the
  main-driven interrupts, and the vblank NMI gated by the `f800` latch.
- **Three graphics layers:** a 1bpp packed-nibble character/foreground tilemap,
  a 3bpp background tilemap with vertical scroll and palette banking, and a
  16×16 3bpp sprite engine (both gfx banks) driven by a double line-buffer.
  All tilemaps use the hardware's column-major, Y-flipped scan order.
- **Colour** through the original resistor-weighted PROM palette, modelled as
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
| **A** | Punch / action |
| **B** | Punch / action |
| **Start** | 1P Start |
| **Select** | Insert coin |

## Games

Two sets run on this one core — pick the game from the Pocket menu:

| Game | Romset |
|---|---|
| **Ring King (US set 1)** | `ringking.zip` + `kingofb.zip` |
| **Ring King (US set 2)** | `ringking2.zip` + `kingofb.zip` |

Both are the same board, so both run on the same bitstream; they differ only in
the main and video CPU program ROMs. (`ringking`/`ringking2` are clones of
`kingofb` and take a file from the parent, hence the second zip.)

## ROMs

ROMs are **not** included — nothing in this repo contains copyrighted data.
Supply your own MAME romsets, then build the `.rom` images:

```
python pack_rom.py            # builds every set it can find
python pack_rom.py ringking   # or just one
```

It matches the required files by CRC32 and writes `ringking.rom` /
`ringking2.rom` into `Assets/ringking/common/`. A set whose romset you don't
have is simply skipped. Copy the contents of `dist/` to your Pocket SD card.

## Credits

- **Original arcade game:** Woodplace Inc. / Data East USA (1985)
- **MAME** — indispensable hardware reference (`dataeast/kingobox.cpp`)
- **Z80 CPU core:** `T80`
- **SDRAM controller:** agg23
- **FPGA core & Analogue Pocket build:** HarpMudd

## About / Support

I'm into retro games and the Analogue Pocket, always cooking up something new.
I love being part of a community built on sharing and the love of games — so if
any of my projects bring you joy, grab me a coffee; it fuels the next thing.

☕ **[buymeacoffee.com/harpmudd](https://buymeacoffee.com/harpmudd)**
