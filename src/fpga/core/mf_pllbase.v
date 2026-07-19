// mf_pllbase.v - PLL wrapper for the Ring King Pocket core.
// 74.25 MHz in -> 48 (clk_sys) + 6 (clk_vid) + 6@90 (clk_vid_90).
// outclk_3/4 are spares the megafunction generates; this core leaves them
// unconnected (see core_game.vh, which wires only outclk_0/1/2 and locked).
`timescale 1 ps / 1 ps
module mf_pllbase (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,  // 48 MHz - clk_sys (CPUs, SDRAM, audio, loader)
    output wire  outclk_1,  //  6 MHz - clk_vid (pixel + video BRAM)
    output wire  outclk_2,  //  6 MHz 90deg - APF DDR video clock
    output wire  outclk_3,  // 48 MHz - spare, unused
    output wire  outclk_4,  // 48 MHz - spare, unused
    output wire  locked
);

mf_pllbase_0002 mf_pllbase_inst (
    .refclk   (refclk),
    .rst      (rst),
    .outclk_0 (outclk_0),
    .outclk_1 (outclk_1),
    .outclk_2 (outclk_2),
    .outclk_3 (outclk_3),
    .outclk_4 (outclk_4),
    .locked   (locked)
);

endmodule
