// mf_pllbase.v - PLL wrapper for Super Pac-Man Pocket core
// 74.25 MHz in -> 24.576 (clk_sys) + 6.144 (clk_vid) + 6.144@90 (clk_vid_90)
//                 + 1.536 (clk_e) + 1.536@270 (clk_q)  [6809E E/Q quadrature]
`timescale 1 ps / 1 ps
module mf_pllbase (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,  // 24.576 MHz - clk_sys
    output wire  outclk_1,  //  6.144 MHz - clk_vid (pixel + game BRAM)
    output wire  outclk_2,  //  6.144 MHz 90deg - APF DDR video clock
    output wire  outclk_3,  //  1.536 MHz - 6809E E
    output wire  outclk_4,  //  1.536 MHz 270deg - 6809E Q
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
