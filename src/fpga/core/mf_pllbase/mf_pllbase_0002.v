// mf_pllbase_0002.v - altera_pll for The Legend of Kage (lkage) Pocket core.
// Input 74.25 MHz. lkage clocks (CPUs/YM run off clk_sys via clock-enables):
//   main Z80 6 MHz (12MHz/2), sound Z80 4 MHz (8/2), 2x YM2203 4 MHz (8/2),
//   pixel 6 MHz (12/2). clk_sys=48 MHz -> 6 MHz = /8 enable, 4 MHz = /12 enable.
//   outclk_0: 48.000 MHz (clk_sys - CPUs, YM, BRAM, ROM loader, bridge, audio)
//   outclk_1:  6.000 MHz (clk_vid - pixel clock + all video BRAM)
//   outclk_2:  6.000 MHz 90deg (clk_vid_90 - APF DDR video clock)
//   outclk_3: 48.000 MHz (spare, unused)
//   outclk_4: 48.000 MHz (spare, unused)
`timescale 1ns/10ps
module mf_pllbase_0002 (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire outclk_4,
    output wire locked
);

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(5),
        .output_clock_frequency0("48.000000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("6.000000 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("6.000000 MHz"),
        .phase_shift2("41667 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("48.000000 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),
        .output_clock_frequency4("48.000000 MHz"),
        .phase_shift4("0 ps"),
        .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"),
        .phase_shift5("0 ps"),
        .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"),
        .phase_shift6("0 ps"),
        .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"),
        .phase_shift7("0 ps"),
        .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"),
        .phase_shift8("0 ps"),
        .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"),
        .phase_shift9("0 ps"),
        .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"),
        .phase_shift10("0 ps"),
        .duty_cycle10(50),
        .output_clock_frequency11("0 MHz"),
        .phase_shift11("0 ps"),
        .duty_cycle11(50),
        .output_clock_frequency12("0 MHz"),
        .phase_shift12("0 ps"),
        .duty_cycle12(50),
        .output_clock_frequency13("0 MHz"),
        .phase_shift13("0 ps"),
        .duty_cycle13(50),
        .output_clock_frequency14("0 MHz"),
        .phase_shift14("0 ps"),
        .duty_cycle14(50),
        .output_clock_frequency15("0 MHz"),
        .phase_shift15("0 ps"),
        .duty_cycle15(50),
        .output_clock_frequency16("0 MHz"),
        .phase_shift16("0 ps"),
        .duty_cycle16(50),
        .output_clock_frequency17("0 MHz"),
        .phase_shift17("0 ps"),
        .duty_cycle17(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );

endmodule
