// =============================================================================
// core_game.vh — PER-GAME logic, `included into the frozen core_top.v shell.
//
// This is the ONLY core file you edit per port. The shell provides: clk_74a,
// the APF bridge (reset_n, bridge_*), dataslot_allcomplete, and expects this
// file to provide pll_locked_s, rom_loaded_s, and drive the video_*/audio_*
// outputs. Everything here is inside module core_top — all shell nets are in
// scope (forward references are fine; Verilog module-item order is irrelevant).
//
// Fill the 6 sections below. Delete guidance comments when done.
// SDRAM ports: also add `define USE_SDRAM at the top of the .qsf and drive the
// dram_* pins from here.
// =============================================================================

// -- 1. PLL / clocks ----------------------------------------------------------
// Author mf_pllbase_0002.v for your frequencies. outclk_0 = clk_sys (game),
// the rest are pixel/aux clocks. Add outclk_3 wire if you need a 4th clock.
wire clk_sys;
wire clk_vid;
wire clk_vid_90;
wire pll_locked;
wire pll_locked_s;

mf_pllbase mp1 (
    .refclk   (clk_74a),
    .rst      (1'b0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_vid),
    .outclk_2 (clk_vid_90),
    .locked   (pll_locked)
);

synch_3 s_pll (pll_locked, pll_locked_s, clk_74a);

// -- 2. ROM load via APF bridge ----------------------------------------------
// Set ADDRESS_SIZE so (ADDRESS_SIZE+1) bits cover your ROM image size.
wire [18:0] dn_addr;              // 19-bit: image up to 0x4C200
wire [7:0]  dn_data;
wire        dn_wr;
reg         rom_loaded_74 = 1'b0;
wire        rom_loaded;
wire        rom_loaded_s = rom_loaded_74;

synch_3 s_rom_to_sys (rom_loaded_74, rom_loaded, clk_sys);

data_loader #(
    .ADDRESS_MASK_UPPER_4 (4'h0),
    .ADDRESS_SIZE         (18),   // write_addr[18:0] = 19-bit dn_addr
    .OUTPUT_WORD_SIZE     (1)
) u_rom_loader (
    .clk_74a (clk_74a), .clk_memory (clk_sys),
    .bridge_wr (bridge_wr), .bridge_endian_little (bridge_endian_little),
    .bridge_addr (bridge_addr), .bridge_wr_data (bridge_wr_data),
    .write_en (dn_wr), .write_addr (dn_addr), .write_data (dn_data)
);

always @(posedge clk_74a) if (dataslot_allcomplete) rom_loaded_74 <= 1'b1;

// -- 3. Reset -----------------------------------------------------------------
wire reset_n_sys;
synch_3 s_resetn (reset_n, reset_n_sys, clk_sys);
reg  [7:0] reset_ctr = 8'hFF;
wire       game_reset_n = (reset_ctr == 8'h0) && rom_loaded && reset_n_sys;
wire       game_reset   = !game_reset_n;
always @(posedge clk_sys) begin
    if (!pll_locked)        reset_ctr <= 8'hFF;
    else if (reset_ctr)     reset_ctr <= reset_ctr - 1'd1;
end

// -- 4. Controls --------------------------------------------------------------
// cont1_key: [0]up [1]down [2]left [3]right [4]A [5]B [6]X [7]Y [14]select [15]start
wire m_coin   = cont1_key[14] | cont2_key[14];
wire m_start1 = cont1_key[15];
wire m_start2 = cont2_key[15];
// TODO: map dpad + buttons to your game's input ports/matrix.

// -- 5. Game core -------------------------------------------------------------
wire [7:0]  vid_r, vid_g, vid_b;
wire        vid_hs, vid_vs, vid_hblank, vid_vblank;
wire [15:0] audio_raw;

ringking_game u_game (
    .clk_sys    (clk_sys),
    .clk_vid    (clk_vid),
    .reset      (game_reset),

    .dn_addr    (dn_addr),
    .dn_data    (dn_data),
    .dn_wr      (dn_wr),
    .rom_loaded (rom_loaded),

    .vid_r (vid_r), .vid_g (vid_g), .vid_b (vid_b),
    .vid_hs (vid_hs), .vid_vs (vid_vs),
    .vid_hb (vid_hblank), .vid_vb (vid_vblank),

    .cont1_key (cont1_key),
    .cont2_key (cont2_key),
    .audio (audio_raw)
);

// -- 6. Video output ----------------------------------------------------------
// Expand RGB to 24-bit; register on clk_vid. If the core flips blanking
// mid-line, resample vblank per-line at the hblank boundary (see berzerk).
// game core outputs 8-bit RGB directly (Stage 1 = grayscale liveness)
wire [23:0] rgb_out = (vid_hblank | vid_vblank) ? 24'h0 : {vid_r, vid_g, vid_b};

reg [23:0] vid_rgb_r;
reg        vid_hs_r, vid_vs_r, vid_de_r;
always @(posedge clk_vid) begin
    vid_rgb_r <= rgb_out;
    vid_hs_r  <= vid_hs;
    vid_vs_r  <= vid_vs;
    vid_de_r  <= ~(vid_hblank | vid_vblank);
end
assign video_rgb = vid_rgb_r;
assign video_rgb_clock = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;
assign video_de = vid_de_r;
assign video_skip = 1'b0;
assign video_vs = vid_vs_r;
assign video_hs = vid_hs_r;

// -- 7. Audio (box-filter decimate to ~48 kHz I2S) ----------------------------
reg  [9:0]  aud_div   = 10'd0;
reg  [25:0] aud_accum = 26'd0;
reg  [15:0] audio_s   = 16'd0;
always @(posedge clk_sys) begin
    aud_div <= aud_div + 1'd1;
    if (aud_div == 10'd0) begin
        audio_s   <= aud_accum[25:10];
        aud_accum <= {10'd0, audio_raw};
    end else aud_accum <= aud_accum + {10'd0, audio_raw};
end

sound_i2s #(.CHANNEL_WIDTH(16), .SIGNED_INPUT(0)) u_sound_i2s (
    .clk_74a (clk_74a), .clk_audio (clk_sys),
    .audio_l (audio_s), .audio_r (audio_s),
    .audio_mclk (audio_mclk), .audio_dac (audio_dac), .audio_lrck (audio_lrck)
);
