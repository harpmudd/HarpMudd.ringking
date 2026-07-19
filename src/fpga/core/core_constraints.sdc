#
# user core constraints — Ring King Pocket core
#
# All clock domains are asynchronous to each other.
# ic = core_top instance in apf_top; mp1 = PLL instance in core_top.
#
# PLL general[0..4] = clk_sys(48) / clk_vid(6) / clk_vid_90(6@90) /
# spare(48) / spare(48). All four Z80s (T80) and the AY-3-8910 run as
# clock-ENABLES in clk_sys, so there is no slow-CPU domain to except —
# everything is single-cycle at 48 MHz. All PLL outputs are mutually async to
# each other and to the bridge.
#
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mclk_r }
