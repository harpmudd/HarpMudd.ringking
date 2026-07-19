// ringking_game.v - Ring King (Woodplace / Data East, 1985, set `ringking`)
// FROM-SCRATCH BUILD. Oracle: MAME dataeast/kingobox.cpp (+ kingobox_v.cpp).
//
// STAGE 1 (this file): the QUAD-Z80 coordination + all four memory maps + the
// two shared-RAM windows + IRQ/NMI wiring + inputs. On-screen liveness = the
// FOREGROUND tilemap RAM (videoram2, written by the VIDEO cpu) rendered as
// GRAYSCALE BLOCKS (gray = char code), which proves: main boots, main<->video
// share1 works, the video cpu boots and writes VRAM, and the dual-clock raster
// runs -- all WITHOUT the gfx-ROM/palette pipeline (Stage 2) or audio (Stage 3).
//
// Clocks: clk_sys 48 MHz (all 4 Z80s via a shared 4 MHz = /12 enable); clk_vid
// 6 MHz (pixel + display read). Native 256x256, visible 256x224, ROT90.
//
// Coordination (from kingobox.cpp ringking_*_map + kingobox_v.cpp):
//   share1 = main D000-D7FF  <-> video C000-C7FF   (2KB true dual-port)
//   share2 = main C800-CFFF  <-> sprite C800-CFFF  (2KB true dual-port)
//   main D800 f800_w: bit5=NMI enable, bits4:3=palette bank, bit7=flip
//   main D801 -> INT to sprite ; D802 -> INT to video ; D803 -> soundlatch + INT to sound
//   vblank & nmi_en -> NMI to main+video+sprite (nmigate ALL_HIGH)
//   sound: periodic 6 kHz NMI + AY port A reads the soundlatch (Stage 3)

`default_nettype none

module ringking_game (
    input  wire        clk_sys,     // 48 MHz
    input  wire        clk_vid,     // 6 MHz
    input  wire        reset,

    input  wire [18:0] dn_addr,     // ROM image load (byte address, image 0x4C200)
    input  wire [7:0]  dn_data,
    input  wire        dn_wr,
    input  wire        rom_loaded,

    output reg  [7:0]  vid_r,
    output reg  [7:0]  vid_g,
    output reg  [7:0]  vid_b,
    output reg         vid_hs,
    output reg         vid_vs,
    output reg         vid_hb,
    output reg         vid_vb,

    input  wire [31:0] cont1_key,   // Pocket P1
    input  wire [31:0] cont2_key,   // Pocket P2

    // sprite gfx (gfx2 bank0 + gfx3 bank1) live in SDRAM, fetched via core_game.vh.
    // Same clk_sys domain => plain req/ready handshake, no CDC.
    // word addr = {bank, A[14:0], hw}: hw0 = {plane1,plane0}, hw1 = {x,plane2}.
    output wire [16:0] sgfx_addr,
    output wire        sgfx_req,
    input  wire [15:0] sgfx_q,
    input  wire        sgfx_ready,

    output wire [15:0] audio
);
    // ===== Clock enables (single clk_sys domain) =============================
    // all four Z80s @ 4 MHz = clk_sys/12 ; AY-3-8910 @ 1.5 MHz = clk_sys/32.
    reg [3:0] div12 = 4'd0;
    always @(posedge clk_sys) div12 <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
    wire cen_cpu = (div12 == 4'd0);
    reg [4:0] div32 = 5'd0;
    always @(posedge clk_sys) div32 <= div32 + 5'd1;
    wire cen_ay = (div32 == 5'd0);

    // ===== Audio mix: AY (route 0.25) + 8-bit R2R DAC (route 0.125) = 2:1 =====
    // ay_snd 0..765 (3 ch x 255), dac_val 0..255. Scale to a comfortable level:
    // 765*21 + 255*32 = 24225 max, inside the 0x7FFF unipolar headroom. The chip
    // output is unipolar, so ^0x8000 centres it for the SIGNED_INPUT=0 i2s
    // (silence = 0x8000; the DC offset is removed by the AC-coupled output).
    wire [15:0] snd_mix = ({6'd0, ay_snd} * 16'd21) + ({8'd0, dac_val} * 16'd32);
    assign audio = snd_mix ^ 16'h8000;

    wire resetn = rom_loaded & ~reset;

    // ===== Board variant (snooped from the ROM image during load) =============
    // 0 = Ring King board, 1 = King of Boxer board. Same game, different board:
    // different memory maps, different AY IO ports, a scrambled spriteram offset,
    // and a bg that comes from the sprite gfx instead of a dedicated gfx4.
    // Gfx are stored in each board's NATIVE packing (so every set can ship an .mra);
    // the sprite/bg gfx are un-packed by the SDRAM load path in core_game.vh, and
    // the chars + palette are addressed per board right here.
    reg kob  = 1'b0;   // 1 = King of Boxer board
    reg palw = 1'b0;   // 1 = ringkingw raw user1 prom addressing
    reg pal3 = 1'b0;   // 1 = 3 separate R/G/B proms. NOT the same flag as kob:
                       // ringking3 is a KoB board shipping Ring-King-format proms.
    always @(posedge clk_sys) if (ld & (dn_addr == 19'h28C00)) begin
        kob    <= dn_data[0];   // 1 = King of Boxer board
        pal3   <= dn_data[1];   // 1 = 3 separate R/G/B proms (0 = Ring King packed)
        palw   <= dn_data[2];   // 1 = ringkingw raw 'user1' prom addressing
    end

    // =========================================================================
    // ROM image write ports (byte load, dn_addr into the flat image). All BRAM
    // ROM regions are power-of-2 aligned so each write uses a PURE BIT-SLICE
    // index -> clean M10K inference. (A non-aligned base forces a subtract in the
    // index, which defeats RAM inference and blows the ROM up into logic.)
    //   main   0x00000 (48K)   video 0x0C000 (16K)
    //   sound  0x10000 (48K)   sprite 0x1C000 (8K)   gfx1 0x1E000 (8K, Stage 2)
    // (gfx2/3/4 @0x20000+ go to SDRAM in Stage 2 -- not loaded here yet.)
    // =========================================================================
    wire ld = dn_wr & ~rom_loaded;

    // ---- MAIN program ROM (0000-BFFF = 48K) @ image 0x00000 ----------------
    reg [7:0] main_rom [0:49151];
    reg [7:0] main_rom_q;
    always @(posedge clk_sys) if (ld & (dn_addr < 19'h0C000)) main_rom[dn_addr[15:0]] <= dn_data;

    // ---- VIDEO program ROM (0000-3FFF = 16K) @ image 0x0C000 ---------------
    reg [7:0] vid_rom [0:16383];
    reg [7:0] vid_rom_q;
    always @(posedge clk_sys) if (ld & (dn_addr >= 19'h0C000) & (dn_addr < 19'h10000))
        vid_rom[dn_addr[13:0]] <= dn_data;

    // ---- SOUND program ROM (0000-BFFF = 48K) @ image 0x10000 (aligned slice) -
    reg [7:0] snd_rom [0:49151];
    reg [7:0] snd_rom_q;
    always @(posedge clk_sys) if (ld & (dn_addr >= 19'h10000) & (dn_addr < 19'h1C000))
        snd_rom[dn_addr[15:0]] <= dn_data;

    // ---- SPRITE program ROM (0000-1FFF = 8K) @ image 0x1C000 ---------------
    reg [7:0] spr_rom [0:8191];
    reg [7:0] spr_rom_q;
    always @(posedge clk_sys) if (ld & (dn_addr >= 19'h1C000) & (dn_addr < 19'h1E000))
        spr_rom[dn_addr[12:0]] <= dn_data;

    // =========================================================================
    // Shared true-dual-port RAMs -- instantiated tdp_ram (Intel-recommended
    // inferrable TDP template; see module at end of file). Inline 2-write-port
    // arrays do NOT infer M10K in Quartus Lite -- they fall back to per-bit
    // registers + 3:1 muxes = a massive logic blowup.
    // =========================================================================
    wire [7:0] s1_aq, s1_bq, s2_aq, s2_bq;
    // share1: port A = MAIN (D000-D7FF), port B = VIDEO (C000-C7FF)
    tdp_ram #(.DW(8), .AW(11)) u_share1 (
        .clk (clk_sys),
        .we_a (m_wr & m_sel_s1), .addr_a (m_addr[10:0]), .din_a (m_dout), .q_a (s1_aq),
        .we_b (v_wr & v_sel_s1), .addr_b (v_addr[10:0]), .din_b (v_dout), .q_b (s1_bq)
    );
    // share2: port A = MAIN (C800-CFFF), port B = SPRITE (C800-CFFF)
    tdp_ram #(.DW(8), .AW(11)) u_share2 (
        .clk (clk_sys),
        .we_a (m_wr & m_sel_s2),   .addr_a (m_addr[10:0]),  .din_a (m_dout),  .q_a (s2_aq),
        .we_b (sp_wr & sp_sel_s2), .addr_b (sp_addr[10:0]), .din_b (sp_dout), .q_b (s2_bq)
    );

    // =========================================================================
    // MAIN Z80
    // =========================================================================
    wire [15:0] m_addr;  wire [7:0] m_dout;  reg [7:0] m_din;
    wire        m_mreq_n, m_iorq_n, m_rd_n, m_wr_n, m_m1_n;
    reg         m_nmi_ff = 1'b0;

    T80s main_cpu (
        .RESET_n (resetn), .CLK (clk_sys), .CEN (cen_cpu), .WAIT_n (1'b1),
        .INT_n (1'b1), .NMI_n (~m_nmi_ff), .BUSRQ_n (1'b1),
        .M1_n (m_m1_n), .MREQ_n (m_mreq_n), .IORQ_n (m_iorq_n),
        .RD_n (m_rd_n), .WR_n (m_wr_n), .RFSH_n (), .HALT_n (), .BUSAK_n (),
        .OUT0 (1'b0), .A (m_addr), .DI (m_din), .DO (m_dout)
    );
    wire m_wr = cen_cpu & ~m_wr_n & ~m_mreq_n;

    // region selects. Same sizes on both boards, different bases:
    //             Ring King        King of Boxer
    //   share2    C800-CFFF        E000-E7FF
    //   share1    D000-D7FF        E800-EFFF
    //   inputs    E000-E005        FC00-FC05
    wire m_sel_rom  = (m_addr <  16'hC000);
    wire m_sel_work = (m_addr >= 16'hC000) && (m_addr < 16'hC400);
    wire m_sel_s2   = kob ? ((m_addr >= 16'hE000) && (m_addr < 16'hE800))
                          : ((m_addr >= 16'hC800) && (m_addr < 16'hD000));
    wire m_sel_s1   = kob ? ((m_addr >= 16'hE800) && (m_addr < 16'hF000))
                          : ((m_addr >= 16'hD000) && (m_addr < 16'hD800));
    wire m_sel_io   = kob ? ((m_addr >= 16'hFC00) && (m_addr < 16'hFC06))
                          : ((m_addr >= 16'hE000) && (m_addr < 16'hE006));
    wire m_sel_f7   = (m_addr >= 16'hF000) && (m_addr < 16'hF800);   // f000-f7ff ram

    // MAIN work ram (C000-C3FF, 1K) + F000-F7FF ram (2K)
    reg [7:0] m_work [0:1023];  reg [7:0] m_work_q;
    reg [7:0] m_f7ram [0:2047]; reg [7:0] m_f7_q;
    always @(posedge clk_sys) begin
        if (m_wr & m_sel_work) m_work[m_addr[9:0]] <= m_dout;
        m_work_q <= m_work[m_addr[9:0]];
        if (m_wr & m_sel_f7)   m_f7ram[m_addr[10:0]] <= m_dout;
        m_f7_q <= m_f7ram[m_addr[10:0]];
    end
    always @(posedge clk_sys) main_rom_q <= main_rom[m_addr[15:0]];

    // ---- control registers written by MAIN ---------------------------------
    reg [7:0] f800_reg = 8'h00;     // bit5 nmi_en, bits4:3 pal_bank, bit7 flip
    reg [7:0] scroll_y = 8'h00;
    reg [7:0] soundlatch = 8'h00;
    reg spr_int_set, vid_int_set, snd_int_set;   // 1-cyc pulses -> set target INT
    always @(posedge clk_sys) begin
        spr_int_set <= 1'b0; vid_int_set <= 1'b0; snd_int_set <= 1'b0;
        if (!resetn) begin f800_reg <= 8'h00; end
        else if (m_wr) begin
            if (kob) begin                              // King of Boxer board
                case (m_addr)
                    16'hF800: f800_reg <= m_dout;       // NMI enable + palette bank
                    16'hF802: scroll_y <= m_dout;
                    // F803 = scroll_interrupt_w: sprite INT *and* writes scroll_y
                    16'hF803: begin spr_int_set <= 1'b1; scroll_y <= m_dout; end
                    16'hF804: vid_int_set <= 1'b1;
                    16'hF807: begin soundlatch <= m_dout; snd_int_set <= 1'b1; end
                    default: ;
                endcase
            end else begin                              // Ring King board
                case (m_addr)
                    16'hD800: f800_reg   <= m_dout;     // f800_w
                    16'hD801: spr_int_set <= 1'b1;      // -> sprite INT
                    16'hD802: vid_int_set <= 1'b1;      // -> video INT
                    16'hD803: begin soundlatch <= m_dout; snd_int_set <= 1'b1; end
                    16'hE800: scroll_y   <= m_dout;
                    default: ;
                endcase
            end
        end
    end
    wire nmi_enable = f800_reg[5];
    wire [1:0] palette_bank = f800_reg[4:3];   // Stage 2
    wire flip_screen = f800_reg[7];            // Stage 2

    // ---- inputs. RK: E000 DSW1 E001 DSW2 E002 P1 E003 P2 E004 SYS E005 EXTRA.
    //               KoB: same order at FC00-FC05.
    // The bit ASSIGNMENTS are identical on both boards, but the POLARITY is not:
    // every ringking P1/P2/SYSTEM/EXTRA bit is IP_ACTIVE_LOW (idle = 1) while every
    // kingofb one is IP_ACTIVE_HIGH (idle = 0). So we build each port active-high
    // ("pressed = 1") and invert the whole thing for Ring King only.
    // MAME P1 bits: 0 up, 1 down, 2 RIGHT, 3 LEFT, 4 button1, 5 button2.
    // (cont keys: 0 up,1 down,2 left,3 right,4 A,5 B,6 X,14 select,15 start.)
    wire [7:0] p1_raw = {2'b00, cont1_key[4], cont1_key[5], cont1_key[2],
                         cont1_key[3], cont1_key[1], cont1_key[0]};  // bit2=right, bit3=left
    wire [7:0] p2_raw = {2'b00, cont2_key[4], cont2_key[5], cont2_key[2],
                         cont2_key[3], cont2_key[1], cont2_key[0]};
    wire [7:0] sys_raw   = {4'b0000, cont2_key[15], cont1_key[15],
                            cont2_key[14], cont1_key[14]};
    wire [7:0] extra_raw = {6'b000000, cont2_key[6], cont1_key[6]};  // BUTTON3 (P1 / cocktail)
    wire [7:0] p1    = kob ? p1_raw    : ~p1_raw;
    wire [7:0] p2    = kob ? p2_raw    : ~p2_raw;
    wire [7:0] sys   = kob ? sys_raw   : ~sys_raw;
    // Ring King's EXTRA is active-LOW and bit3 is COIN2: idle MUST be 1s, or COIN2
    // reads as jammed on and the game stops responding. KoB's is active-high (idle 0).
    wire [7:0] EXTRA = kob ? extra_raw : ~extra_raw;
    // MAME factory DIP defaults -- raw port values, so polarity does not apply here.
    //   kingofb DSW1 bit7 = PORT_SERVICE ACTIVE **HIGH** -> must read 0, else the game
    //   boots straight into its test grid. Ring King's service bit is active-LOW,
    //   which is the only reason the old 0xFF placeholder ever worked there.
    //   Ring King DSW1 bit6 is a PORT_BIT UNUSED, active-low -> idle 1 (hence 0xD7).
    wire [7:0] DSW1  = kob ? 8'h21 : 8'hD7;
    wire [7:0] DSW2  = kob ? 8'h00 : 8'hDF;
    reg [7:0] m_io_q;
    always @(*) case (m_addr[2:0])
        3'd0: m_io_q = DSW1; 3'd1: m_io_q = DSW2; 3'd2: m_io_q = p1;
        3'd3: m_io_q = p2;   3'd4: m_io_q = sys;  default: m_io_q = EXTRA;
    endcase

    // (share1/share2 port A reads s1_aq/s2_aq are driven in the consolidated
    //  true-dual-port blocks near the end of the module.)

    // MAIN data-in mux (registered sources; select on current addr)
    always @(*) begin
        if      (m_sel_rom)  m_din = main_rom_q;
        else if (m_sel_work) m_din = m_work_q;
        else if (m_sel_s2)   m_din = s2_aq;
        else if (m_sel_s1)   m_din = s1_aq;
        else if (m_sel_io)   m_din = m_io_q;
        else if (m_sel_f7)   m_din = m_f7_q;
        else                 m_din = 8'hFF;
    end

    // =========================================================================
    // VIDEO Z80  (owns fg videoram2/colorram2 + bg videoram/colorram)
    // =========================================================================
    wire [15:0] v_addr;  wire [7:0] v_dout;  reg [7:0] v_din;
    wire        v_mreq_n, v_iorq_n, v_rd_n, v_wr_n, v_m1_n;
    reg         v_nmi_ff = 1'b0, v_int_ff = 1'b0;

    T80s video_cpu (
        .RESET_n (resetn), .CLK (clk_sys), .CEN (cen_cpu), .WAIT_n (1'b1),
        .INT_n (~v_int_ff), .NMI_n (~v_nmi_ff), .BUSRQ_n (1'b1),
        .M1_n (v_m1_n), .MREQ_n (v_mreq_n), .IORQ_n (v_iorq_n),
        .RD_n (v_rd_n), .WR_n (v_wr_n), .RFSH_n (), .HALT_n (), .BUSAK_n (),
        .OUT0 (1'b0), .A (v_addr), .DI (v_din), .DO (v_dout)
    );
    wire v_wr = cen_cpu & ~v_wr_n & ~v_mreq_n;
    wire v_intack = ~v_m1_n & ~v_iorq_n;

    //             Ring King        King of Boxer
    //   share1    C000-C7FF        A000-A7FF
    //   fg vram   A000-A3FF        C800-CBFF
    //   fg cram   A400-A7FF        CC00-CFFF
    //   bg vram   A800-A8FF        C000-C0FF
    //   bg cram   AC00-ACFF        C400-C4FF
    wire v_sel_rom  = (v_addr <  16'h4000);
    wire v_sel_work = (v_addr >= 16'h8000) && (v_addr < 16'h8800);
    wire v_sel_fgv  = kob ? ((v_addr >= 16'hC800) && (v_addr < 16'hCC00))
                          : ((v_addr >= 16'hA000) && (v_addr < 16'hA400));
    wire v_sel_fgc  = kob ? ((v_addr >= 16'hCC00) && (v_addr < 16'hD000))
                          : ((v_addr >= 16'hA400) && (v_addr < 16'hA800));
    wire v_sel_bgv  = kob ? ((v_addr >= 16'hC000) && (v_addr < 16'hC100))
                          : ((v_addr >= 16'hA800) && (v_addr < 16'hA900));
    wire v_sel_bgc  = kob ? ((v_addr >= 16'hC400) && (v_addr < 16'hC500))
                          : ((v_addr >= 16'hAC00) && (v_addr < 16'hAD00));
    wire v_sel_s1   = kob ? ((v_addr >= 16'hA000) && (v_addr < 16'hA800))
                          : ((v_addr >= 16'hC000) && (v_addr < 16'hC800));

    reg [7:0] v_work [0:2047];  reg [7:0] v_work_q;
    always @(posedge clk_sys) begin
        if (v_wr & v_sel_work) v_work[v_addr[10:0]] <= v_dout;
        v_work_q <= v_work[v_addr[10:0]];
    end
    always @(posedge clk_sys) vid_rom_q <= vid_rom[v_addr[13:0]];

    // fg videoram2 (32x32 chars) = DUAL-CLOCK dual-port: port A = video cpu R/W
    // (clk_sys), port B = display read (clk_vid). Two clocks, two always blocks.
    reg [7:0] fgvram [0:1023];  reg [7:0] fgv_q;
    reg [9:0] disp_fg_addr;     reg [7:0] disp_fg_q;
    always @(posedge clk_sys) begin
        if (v_wr & v_sel_fgv) fgvram[v_addr[9:0]] <= v_dout;
        fgv_q <= fgvram[v_addr[9:0]];
    end
    always @(posedge clk_vid) disp_fg_q <= fgvram[disp_fg_addr];   // display port (clk_vid)
    // fg colorram2 = DUAL-CLOCK (port A video cpu R/W, port B display read at clk_vid)
    reg [7:0] fgcram [0:1023];  reg [7:0] fgc_q;  reg [7:0] disp_fc_q;
    always @(posedge clk_sys) begin
        if (v_wr & v_sel_fgc) fgcram[v_addr[9:0]] <= v_dout;
        fgc_q <= fgcram[v_addr[9:0]];
    end
    always @(posedge clk_vid) disp_fc_q <= fgcram[disp_fg_addr];   // display port (clk_vid)
    // bg videoram(code)/colorram(attr) = DUAL-CLOCK: port A video cpu R/W, port B
    // display read (bg tile pipeline). 256-entry 16x16 map.
    // KoB bg prefetch buffers (filled by the clk_sys FSM near the end of the file).
    reg [7:0] bgb_L0[0:1], bgb_L1[0:1], bgb_L2[0:1];
    reg [7:0] bgb_R0[0:1], bgb_R1[0:1], bgb_R2[0:1];
    reg [4:0] bgb_clr[0:1];
    wire      bg_sg_rdy, spr_sg_rdy;

    reg [7:0] bgvram [0:255];   reg [7:0] bgv_q;  reg [7:0] disp_bv_q;
    reg [7:0] bgcram [0:255];   reg [7:0] bgc_q;  reg [7:0] disp_bc_q;
    reg [7:0] disp_bg_addr;
    always @(posedge clk_sys) begin
        if (v_wr & v_sel_bgv) bgvram[v_addr[7:0]] <= v_dout;  bgv_q <= bgvram[v_addr[7:0]];
        if (v_wr & v_sel_bgc) bgcram[v_addr[7:0]] <= v_dout;  bgc_q <= bgcram[v_addr[7:0]];
    end
    always @(posedge clk_vid) begin
        disp_bv_q <= bgvram[disp_bg_addr];
        disp_bc_q <= bgcram[disp_bg_addr];
    end
    // gfx1 = character ROM (8K, image 0x1E000). Port A = clk_sys load-write, port
    // B = clk_vid display read (fg tile pipeline). Pure-slice load index.
    reg [7:0] gfx1 [0:8191];  reg [7:0] gfx1_q;  reg [12:0] gfx1_addr;
    always @(posedge clk_sys) if (ld & (dn_addr >= 19'h1E000) & (dn_addr < 19'h20000))
        gfx1[dn_addr[12:0]] <= dn_data;
    always @(posedge clk_vid) gfx1_q <= gfx1[gfx1_addr];

    // gfx4 = BG tiles (rk_bglayout, 32K image 0x44000). Split into two 16K halves
    // read in PARALLEL: byte A (bit0/bit1) in gfx4_lo (cx09, image 0x44000), byte
    // A+0x4000 (bit2) in gfx4_hi (cx10, image 0x48000). Same address A[13:0].
    reg [7:0] gfx4_lo [0:16383];  reg [7:0] g4lo_q;
    reg [7:0] gfx4_hi [0:16383];  reg [7:0] g4hi_q;  reg [13:0] gfx4_addr;
    always @(posedge clk_sys) begin
        if (ld & (dn_addr >= 19'h20000) & (dn_addr < 19'h24000)) gfx4_lo[dn_addr[13:0]] <= dn_data;
        if (ld & (dn_addr >= 19'h24000) & (dn_addr < 19'h28000)) gfx4_hi[dn_addr[13:0]] <= dn_data;
    end
    always @(posedge clk_vid) begin g4lo_q <= gfx4_lo[gfx4_addr]; g4hi_q <= gfx4_hi[gfx4_addr]; end

    // color PROMs (256 B each, image 0x4C000/0x4C100). PROM0: R=hi nibble, G=lo;
    // PROM1: B=lo nibble. Read at the composed pen; resnet 4->8 applied at output.
    reg [7:0] prom0 [0:1023]; reg [7:0] p0_q;
    reg [7:0] prom1 [0:1023]; reg [7:0] p1_q;  reg [7:0] pal_addr;
    reg [7:0] prom2 [0:1023]; reg [7:0] p2_q;   // King of Boxer's 3rd (blue) prom
    reg [7:0] spal_addr;
    // ringkingw ships RAW 'user1' proms: the 256 live entries sit 8-of-every-16
    // across 0x400. Undo that with a pure address bit-shuffle (verified exact).
    wire [9:0] pal_ixd = palw ? {pal_addr[7:6], 1'b0, pal_addr[5:3], 1'b0, pal_addr[2:0]}
                              : {2'b00, pal_addr};
    wire [9:0] pal_ixs = palw ? {spal_addr[7:6], 1'b0, spal_addr[5:3], 1'b0, spal_addr[2:0]}
                              : {2'b00, spal_addr};
    always @(posedge clk_sys) begin
        if (ld & (dn_addr >= 19'h28000) & (dn_addr < 19'h28400)) prom0[dn_addr[9:0]] <= dn_data;
        if (ld & (dn_addr >= 19'h28400) & (dn_addr < 19'h28800)) prom1[dn_addr[9:0]] <= dn_data;
        if (ld & (dn_addr >= 19'h28800) & (dn_addr < 19'h28C00)) prom2[dn_addr[9:0]] <= dn_data;
    end
    always @(posedge clk_vid) begin p0_q <= prom0[pal_ixd];
        p1_q <= prom1[pal_ixd]; p2_q <= prom2[pal_ixd]; end
    // 2nd PROM read port for the sprite path (256 B -> tiny even if it maps to logic)
    reg [7:0] sp0_q, sp1_q, sp2_q;
    always @(posedge clk_vid) begin sp0_q <= prom0[pal_ixs];
        sp1_q <= prom1[pal_ixs]; sp2_q <= prom2[pal_ixs]; end

    // gfx2 (sprites bank0) + gfx3 (bank1) now live in SDRAM -- they were 144K of
    // BRAM (96 M10K + 48) which the sound ROM needs back. The engine fetches them
    // over the sgfx_* port. Decode is unchanged: byte = code*32 + y + (x>=8?16:0),
    // bit = x&7, pix3 = {plane0(MSB),plane1,plane2(LSB)}.

    // spriteram engine read (spr_eaddr/spr_eq) is port B of the sprram tdp_ram
    // (declared in the SPRITE Z80 section). Engine drives spr_eaddr here.
    reg [9:0] spr_eaddr;

    // resnet 4-bit component -> 8-bit (R/G/B share the {1500,750,360,180}+470 net).
    // LINEAR model (a 0 bit grounds its resistor -> stays in the divider): V =
    // sum(bit/R) / (sum(1/R)+1/470), scaled so fg 51ohm full = 255. (A non-linear
    // "open-when-0" model made low nibbles far too bright = pale colors.)
    function [7:0] resnet; input [3:0] v; begin
        case (v)
          4'd0: resnet=8'd0;   4'd1: resnet=8'd15;  4'd2: resnet=8'd30;  4'd3: resnet=8'd45;
          4'd4: resnet=8'd63;  4'd5: resnet=8'd78;  4'd6: resnet=8'd93;  4'd7: resnet=8'd108;
          4'd8: resnet=8'd126; 4'd9: resnet=8'd141; 4'd10:resnet=8'd156; 4'd11:resnet=8'd171;
          4'd12:resnet=8'd189; 4'd13:resnet=8'd204; 4'd14:resnet=8'd219; default:resnet=8'd234;
        endcase
    end endfunction

    // (share1 port B read s1_bq is in the consolidated TDP block near the end.)

    always @(*) begin
        if      (v_sel_rom)  v_din = vid_rom_q;
        else if (v_sel_work) v_din = v_work_q;
        else if (v_sel_fgv)  v_din = fgv_q;
        else if (v_sel_fgc)  v_din = fgc_q;
        else if (v_sel_bgv)  v_din = bgv_q;
        else if (v_sel_bgc)  v_din = bgc_q;
        else if (v_sel_s1)   v_din = s1_bq;
        else if (v_intack)   v_din = 8'hFF;     // INT vector (RST38 / ignored in IM1)
        else                 v_din = 8'hFF;
    end

    // =========================================================================
    // SPRITE Z80  (owns spriteram)
    // =========================================================================
    wire [15:0] sp_addr;  wire [7:0] sp_dout;  reg [7:0] sp_din;
    wire        sp_mreq_n, sp_iorq_n, sp_rd_n, sp_wr_n, sp_m1_n;
    reg         sp_nmi_ff = 1'b0, sp_int_ff = 1'b0;

    T80s sprite_cpu (
        .RESET_n (resetn), .CLK (clk_sys), .CEN (cen_cpu), .WAIT_n (1'b1),
        .INT_n (~sp_int_ff), .NMI_n (~sp_nmi_ff), .BUSRQ_n (1'b1),
        .M1_n (sp_m1_n), .MREQ_n (sp_mreq_n), .IORQ_n (sp_iorq_n),
        .RD_n (sp_rd_n), .WR_n (sp_wr_n), .RFSH_n (), .HALT_n (), .BUSAK_n (),
        .OUT0 (1'b0), .A (sp_addr), .DI (sp_din), .DO (sp_dout)
    );
    wire sp_wr = cen_cpu & ~sp_wr_n & ~sp_mreq_n;
    wire sp_intack = ~sp_m1_n & ~sp_iorq_n;

    //              Ring King       King of Boxer
    //   share2     C800-CFFF       A000-A7FF
    //   spriteram  A000-A3FF       C000-C3FF
    //   a4 ram     A400-A43F       C400-C43F
    wire sp_sel_rom  = (sp_addr <  16'h2000);
    wire sp_sel_work = (sp_addr >= 16'h8000) && (sp_addr < 16'h8800);
    wire sp_sel_spr  = kob ? ((sp_addr >= 16'hC000) && (sp_addr < 16'hC400))
                           : ((sp_addr >= 16'hA000) && (sp_addr < 16'hA400));
    wire sp_sel_a4   = kob ? ((sp_addr >= 16'hC400) && (sp_addr < 16'hC440))
                           : ((sp_addr >= 16'hA400) && (sp_addr < 16'hA440));
    wire sp_sel_s2   = kob ? ((sp_addr >= 16'hA000) && (sp_addr < 16'hA800))
                           : ((sp_addr >= 16'hC800) && (sp_addr < 16'hD000));

    reg [7:0] sp_work [0:2047];  reg [7:0] sp_work_q;
    reg [7:0] sp_a4   [0:63];    reg [7:0] sp_a4_q;
    always @(posedge clk_sys) begin
        if (sp_wr & sp_sel_work) sp_work[sp_addr[10:0]] <= sp_dout;  sp_work_q <= sp_work[sp_addr[10:0]];
        if (sp_wr & sp_sel_a4)   sp_a4[sp_addr[5:0]]    <= sp_dout;  sp_a4_q   <= sp_a4[sp_addr[5:0]];
    end
    always @(posedge clk_sys) spr_rom_q <= spr_rom[sp_addr[12:0]];
    // spriteram = tdp_ram: port A = sprite CPU R/W, port B = sprite-engine read.
    wire [7:0] sprram_q, spr_eq;
    tdp_ram #(.DW(8), .AW(10)) u_sprram (
        .clk (clk_sys),
        .we_a (sp_wr & sp_sel_spr), .addr_a (sp_addr[9:0]), .din_a (sp_dout), .q_a (sprram_q),
        .we_b (1'b0),               .addr_b (spr_eaddr),    .din_b (8'd0),   .q_b (spr_eq)
    );

    // (share2 port B read s2_bq is in the consolidated TDP block near the end.)

    always @(*) begin
        if      (sp_sel_rom)  sp_din = spr_rom_q;
        else if (sp_sel_work) sp_din = sp_work_q;
        else if (sp_sel_spr)  sp_din = sprram_q;
        else if (sp_sel_a4)   sp_din = sp_a4_q;
        else if (sp_sel_s2)   sp_din = s2_bq;
        else if (sp_intack)   sp_din = 8'hFF;
        else                  sp_din = 8'hFF;
    end

    // =========================================================================
    // SOUND Z80 (Stage 1: runs, output ignored; Stage 3 = AY + DAC)
    // =========================================================================
    wire [15:0] sd_addr;  wire [7:0] sd_dout;  reg [7:0] sd_din;
    wire        sd_mreq_n, sd_iorq_n, sd_rd_n, sd_wr_n, sd_m1_n;
    reg         sd_nmi_ff = 1'b0, sd_int_ff = 1'b0;

    T80s sound_cpu (
        .RESET_n (resetn), .CLK (clk_sys), .CEN (cen_cpu), .WAIT_n (1'b1),
        .INT_n (~sd_int_ff), .NMI_n (~sd_nmi_ff), .BUSRQ_n (1'b1),
        .M1_n (sd_m1_n), .MREQ_n (sd_mreq_n), .IORQ_n (sd_iorq_n),
        .RD_n (sd_rd_n), .WR_n (sd_wr_n), .RFSH_n (), .HALT_n (), .BUSAK_n (),
        .OUT0 (1'b0), .A (sd_addr), .DI (sd_din), .DO (sd_dout)
    );
    wire sd_wr = cen_cpu & ~sd_wr_n & ~sd_mreq_n;
    wire sd_intack = ~sd_m1_n & ~sd_iorq_n;

    wire sd_sel_rom  = (sd_addr <  16'hC000);
    wire sd_sel_work = (sd_addr >= 16'hC000) && (sd_addr < 16'hC400);
    reg [7:0] sd_work [0:1023]; reg [7:0] sd_work_q;
    always @(posedge clk_sys) begin
        if (sd_wr & sd_sel_work) sd_work[sd_addr[9:0]] <= sd_dout;  sd_work_q <= sd_work[sd_addr[9:0]];
    end
    always @(posedge clk_sys) snd_rom_q <= snd_rom[sd_addr[15:0]];

    // ---- sound IO (ringking_sound_io_map, global_mask 0xFF) -----------------
    //   00 w = DAC ; 02 w = AY DATA ; 03 w = AY ADDRESS ; 02 r = AY data
    // MAME: map(0x02,0x03).w(data_address_w) -> ay8910_write_ym(~offset & 1), and
    // write_ym(1)=DATA / write_ym(0)=ADDRESS. So offset0 (io 0x02) = DATA and
    // offset1 (io 0x03) = ADDRESS ("BC1 tied to A0 puts data on 0, address on 1").
    // The read at 0x02 being data_r corroborates that 0x02 is the data port.
    // (Swapping these writes register numbers into the data port = pure noise.)
    // An IO cycle is IORQ low with M1 HIGH (M1 low + IORQ = interrupt ack).
    wire sd_io    = ~sd_iorq_n & sd_m1_n;
    wire sd_io_wr = cen_cpu & sd_io & ~sd_wr_n;
    wire sd_io_rd = sd_io & ~sd_rd_n;
    // King of Boxer puts the AY on 0x08 (data) / 0x0c (address) instead; DAC is 0x00 on both.
    wire ay_data_we = sd_io_wr & (sd_addr[7:0] == (kob ? 8'h08 : 8'h02));
    wire ay_addr_we = sd_io_wr & (sd_addr[7:0] == (kob ? 8'h0C : 8'h03));
    wire dac_we     = sd_io_wr & (sd_addr[7:0] == 8'h00);

    reg [7:0] dac_val = 8'd0;                      // 8-bit R2R DAC latch
    always @(posedge clk_sys) if (dac_we) dac_val <= sd_dout;

    wire [7:0] ay_dout;  wire [9:0] ay_snd;
    ay8910 u_ay (
        .clk (clk_sys), .cen (cen_ay), .rst (~resetn),
        .din (sd_dout), .addr_we (ay_addr_we), .data_we (ay_data_we),
        .dout (ay_dout), .port_a (soundlatch),     // reg 14 = sound latch
        .snd (ay_snd)
    );

    always @(*) begin
        if      (sd_io_rd)    sd_din = ay_dout;    // IO read (AY data @ 0x02)
        else if (sd_sel_rom)  sd_din = snd_rom_q;
        else if (sd_sel_work) sd_din = sd_work_q;
        else if (sd_intack)   sd_din = 8'hFF;
        else                  sd_din = 8'hFF;
    end

    // =========================================================================
    // Interrupt / NMI generation
    // =========================================================================
    // NMI to main/video/sprite = vblank & nmi_enable (edge via level -> T80 edge-detect)
    reg vbl_d;
    always @(posedge clk_sys) vbl_d <= vid_vb;
    wire vbl_rise = vid_vb & ~vbl_d;
    always @(posedge clk_sys) begin
        // assert NMI at vblank rising if enabled; hold through vblank, clear after
        if (!resetn) begin m_nmi_ff <= 0; v_nmi_ff <= 0; sp_nmi_ff <= 0; end
        else begin
            if (vbl_rise & nmi_enable) begin m_nmi_ff <= 1; v_nmi_ff <= 1; sp_nmi_ff <= 1; end
            else if (~vid_vb)          begin m_nmi_ff <= 0; v_nmi_ff <= 0; sp_nmi_ff <= 0; end
        end
    end

    // video/sprite/sound INT: set by main's write pulse, cleared on target INT-ack (HOLD_LINE)
    always @(posedge clk_sys) begin
        if (!resetn) v_int_ff <= 0;
        else if (vid_int_set) v_int_ff <= 1'b1;
        else if (v_intack)    v_int_ff <= 1'b0;
    end
    always @(posedge clk_sys) begin
        if (!resetn) sp_int_ff <= 0;
        else if (spr_int_set) sp_int_ff <= 1'b1;
        else if (sp_intack)   sp_int_ff <= 1'b0;
    end
    always @(posedge clk_sys) begin
        if (!resetn) sd_int_ff <= 0;
        else if (snd_int_set) sd_int_ff <= 1'b1;
        else if (sd_intack)   sd_int_ff <= 1'b0;
    end

    // sound periodic NMI @ ~6 kHz (48e6/8000 = 6000). NMI_n low for the second
    // half of each period => exactly one falling edge (one NMI) per period.
    reg [12:0] sndnmi_cnt = 13'd0;
    always @(posedge clk_sys) begin
        if (!resetn) begin sndnmi_cnt <= 0; sd_nmi_ff <= 0; end
        else begin
            sndnmi_cnt <= (sndnmi_cnt == 13'd7999) ? 13'd0 : sndnmi_cnt + 1'b1;
            sd_nmi_ff  <= (sndnmi_cnt >= 13'd4000);
        end
    end

    // =========================================================================
    // Video: 6 MHz pixel, 384x264 (~59 Hz), active 256x224. STAGE 2a = FOREGROUND
    // tilemap (videoram2 codes + colorram2 attrs + gfx1 chars), 1bpp, 8 primary
    // colors, transparent pen 0 (bg/sprites = Stage 2b/2c show through as black).
    //   scan  = TILEMAP_SCAN_COLS_FLIP_Y -> tile_index = col*32 + (31-row)
    //   tile  = colorram2[i]: bit0 = code hi, bit1 = bank, bits5:3 = color
    //           videoram2[i] = code lo (9-bit code = {attr0, code})
    //   gfx1  = 1bpp packed: bank0 uses byte bits 7-4, bank1 bits 3-0; the RIGHT
    //           half of a char row (cols 4-7) is at byte +0x1000; row -> +(7-py).
    //   colors= 8 RGB primaries: R=color[2], G=color[1], B=color[0].
    // Registered-output BRAMs => data is valid the cycle AFTER its address, so the
    // carried phase (px/py) is delayed 1 reg per read to stay aligned (the lkage
    // ROM-latency lesson). PIX_DELAY aligns blank/sync to the pixel; HW-tunable.
    // =========================================================================
    // MAME visarea y = 16..239: the 224 visible lines sit at tilemap y 16..239
    // (16px cropped top+bottom of the 256-tall map). VOFF=16 maps vcnt 0 -> y 16.
    // (ROT90 => this vertical raster axis is the Pocket's horizontal, so this is
    // the "left-side cutoff" fix.) Tune if the cut moves to the other edge.
    localparam [9:0] VOFF = 10'd16;       // vertical tile offset (visarea y start)
    reg [9:0] hcnt = 0, vcnt = 0;
    always @(posedge clk_vid) begin
        if (hcnt == 10'd383) begin
            hcnt <= 0;
            vcnt <= (vcnt == 10'd263) ? 10'd0 : vcnt + 1'b1;
        end else hcnt <= hcnt + 1'b1;
    end
    wire [9:0] vrow = vcnt + VOFF;

    // ---- fg fetch pipeline (self-aligning: +1 phase reg per BRAM read) --------
    reg [2:0] px0, py0, px0d, py0d;        // pixel phase @ tile-addr stage, +1 aligned
    reg       bnk_a, bnk_b;                // bank, cascaded to gfx1_q
    reg [2:0] col_a, col_b;                // col-in-char (px) to gfx1_q
    reg [2:0] clr_a, clr_b, clr_c;         // color, to output
    reg       pix_c;                       // decoded 1bpp pixel
    always @(posedge clk_vid) begin
        // s0: present tile RAM address (COLS_FLIP_Y) + latch phase
        disp_fg_addr <= {hcnt[7:3], ~vrow[7:3]};
        px0 <= hcnt[2:0];  py0 <= vrow[2:0];
        // align phase to disp_fg_q/disp_fc_q (valid 1 clk after their address)
        px0d <= px0;  py0d <= py0;
        // s2: tile code/attr valid -> gfx byte address; carry attrs + col phase
        // Ring King: code*8 + (7-py), right half (cols 4-7) at +0x1000, bank = nibble.
        // King of Boxer: 8 px per byte, bank IS the 0x1000 offset -> code*8 + py.
        gfx1_addr <= kob ? (({4'd0, disp_fc_q[0], disp_fg_q} << 3)
                            + {10'd0, py0d}
                            + (disp_fc_q[1] ? 13'h1000 : 13'd0))
                         : (({4'd0, disp_fc_q[0], disp_fg_q} << 3)   // code9 * 8
                            + {10'd0, (3'd7 - py0d)}                 // row: +(7-py)
                            + (px0d[2] ? 13'h1000 : 13'd0));         // right half
        bnk_a <= disp_fc_q[1];  clr_a <= disp_fc_q[5:3];  col_a <= px0d;
        // align attrs/col to gfx1_q (valid 1 clk after gfx1_addr)
        bnk_b <= bnk_a;  clr_b <= clr_a;  col_b <= col_a;
        // s4: gfx1_q valid -> decode the 1bpp pixel bit. MAME readbit(o) =
        // (rom[o/8] >> (7-(o&7)))&1, so charlayout1 xoffset {7,6,5,4} => col0=bit0..
        // col3=bit3 (bank0 = LOW nibble), charlayout2 {3,2,1,0} => bits 4-7 (bank1 =
        // HIGH nibble). bit = bank ? 4+(col&3) : (col&3).
        // KoB stores 8 px MSB-first in one byte: pixel x = bit (7-x).
        pix_c <= kob ? gfx1_q[3'd7 - col_b]
                     : gfx1_q[ bnk_b ? {1'b1, col_b[1:0]}    // bank1: bits 4-7
                                     : {1'b0, col_b[1:0]} ]; // bank0: bits 0-3
        clr_c <= clr_b;
    end

    // =========================================================================
    // BG tilemap (gfx4 rk_bglayout, 3bpp) + PROM palette, composited UNDER fg.
    //   scan COLS_FLIP_Y 16x16; code = bcol ? bgvram : 0; color = palbank*8+attr[6:4].
    //   gfx4 byte A = code*32 + xb(x>>2) + (15-y);  xb = [16,8192,0,8208][x>>2].
    //   bit0 = lo[A][x&3], bit1 = lo[A][(x&3)+4], bit2 = hi[A][x&3]; pix3={b2,b1,b0}.
    //   pen = color*8 + pix3; RGB = resnet(PROM0 hi/lo, PROM1 lo). Self-aligning
    //   (+1 phase reg per registered-BRAM read). scroll_y sign + PIX_DELAY = HW knobs.
    // =========================================================================
    wire [9:0] bg_v = vcnt + VOFF - {2'b0, scroll_y};   // MAME set_scrolly(-scroll_y)
    // KoB lookahead row: during the last tile of a line the lookahead wraps to col 0,
    // which the display uses on the NEXT line -> fetch it with the next line's row.
    wire [9:0] bg_v_la = (hcnt[7:4] == 4'd15) ? (bg_v + 10'd1) : bg_v;
    reg [3:0] bx_s0, by_s0, bx_s1, by_s1, bcol_s0, bcol_s1;
    reg [3:0] bx_s2, bx_s3, bcol_s2, bcol_s3;    // KoB: full x + tile parity out to s4
    reg [1:0] bxl_s2, bxl_s3;
    reg [4:0] bclr_s2, bclr_s3, bclr_s4;
    reg [2:0] pix3_s4;
    reg [7:0] bg_r, bg_g, bg_b;
    reg [13:0] xb_c;
    always @(*) case (bx_s1[3:2])                 // x-group -> gfx4 byte base
        2'd0: xb_c = 14'd16;   2'd1: xb_c = 14'd8192;
        2'd2: xb_c = 14'd0;    default: xb_c = 14'd8208;
    endcase
    // KoB bg pixel: bit-select out of the tile's 6 prefetched plane bytes. Same
    // decode as a sprite (bit = x&7, half = x[3], pix3 = {p0,p1,p2}) because KoB's
    // bg IS the sprite gfx. Buffer slot = the tile's parity; the clk_sys prefetch
    // only ever fills the slot clk_vid is not reading.
    wire       kob_par  = bcol_s3[0];
    wire [2:0] kb       = bx_s3[2:0];
    wire [2:0] kob_pix3 = bx_s3[3] ? {bgb_R0[kob_par][kb], bgb_R1[kob_par][kb], bgb_R2[kob_par][kb]}
                                   : {bgb_L0[kob_par][kb], bgb_L1[kob_par][kb], bgb_L2[kob_par][kb]};
    always @(posedge clk_vid) begin
        // s0: bg tile index (COLS_FLIP_Y 16x16) + phase.
        //     KoB addresses ONE TILE AHEAD so the SDRAM prefetch for tile T runs
        //     while the display is still on T-1.
        disp_bg_addr <= kob ? {(hcnt[7:4] + 4'd1), ~bg_v_la[7:4]} : {hcnt[7:4], ~bg_v[7:4]};
        bx_s0 <= hcnt[3:0];  by_s0 <= bg_v[3:0];  bcol_s0 <= hcnt[7:4];
        // s1: align phase to disp_bv_q / disp_bc_q
        bx_s1 <= bx_s0;  by_s1 <= by_s0;  bcol_s1 <= bcol_s0;
        // s2: code/attr valid -> gfx4 address A; carry color + x&3
        gfx4_addr <= ((bcol_s1 != 4'd0) ? {disp_bv_q, 5'd0} : 14'd0)   // code * 32
                     + xb_c + {10'd0, (4'd15 - by_s1)};                // xb + (15-y)
        bclr_s2 <= {palette_bank, disp_bc_q[6:4]};                     // color
        bxl_s2  <= bx_s1[1:0];   bx_s2 <= bx_s1;   bcol_s2 <= bcol_s1;
        // s3: align to g4lo_q / g4hi_q
        bclr_s3 <= bclr_s2;  bxl_s3 <= bxl_s2;
        bx_s3   <= bx_s2;    bcol_s3 <= bcol_s2;
        // s4: gfx bytes valid -> 3bpp pixel; carry color. Ring King reads gfx4 per
        //     pixel from BRAM; KoB has no gfx4 and takes the tile's bytes + colour
        //     from the SDRAM prefetch buffer instead.
        pix3_s4 <= kob ? kob_pix3
                       : {g4hi_q[bxl_s3], g4lo_q[{1'b1,bxl_s3}], g4lo_q[{1'b0,bxl_s3}]};
        bclr_s4 <= kob ? bgb_clr[kob_par] : bclr_s3;
        // s5: present pen -> PROM
        pal_addr <= {bclr_s4, pix3_s4};
        // s6: PROM valid -> resnet RGB
        bg_r <= resnet(pal3 ? p0_q[3:0] : p0_q[7:4]);
        bg_g <= resnet(pal3 ? p1_q[3:0] : p0_q[3:0]);
        bg_b <= resnet(pal3 ? p2_q[3:0] : p1_q[3:0]);
    end

    // =========================================================================
    // SPRITE line-buffer engine. Renders the sprites on the NEXT display line into
    // a double line buffer (clk_sys), which the display reads (clk_vid). Sprites
    // are 16x16 3bpp; bank0->gfx2, bank1->gfx3; byte=code*32+yrow+(col>=8?16:0),
    // bit=col&7, pix3={plane0(MSB),plane1,plane2(LSB)}; pen=color*8+pix3, transpen0.
    // sprite fmt (ringking, NO scramble): [0]=sy [1]=attr{1:0 code hi,2 bank,6:4
    // color,7 !flipy} [2]=sx [3]=code lo.
    // =========================================================================
    // line-start pulse (clk_vid) -> clk_sys; sampled display line.
    reg ls_tog = 1'b0;
    always @(posedge clk_vid) if (hcnt == 10'd383) ls_tog <= ~ls_tog;
    reg [2:0] ls_s;  reg [9:0] vc_s1, vc_s2;
    always @(posedge clk_sys) begin
        ls_s <= {ls_s[1:0], ls_tog};
        vc_s1 <= vcnt;  vc_s2 <= vc_s1;
    end
    wire line_start = ls_s[2] ^ ls_s[1];

    // double line buffer: {opaque, pen[7:0]} x 256 x 2 (dual-clock: engine W / disp R)
    reg [8:0] sprbuf [0:511];
    reg wsel = 1'b0;                         // buffer being written this line
    reg [8:0] sb_wdata;  reg [8:0] sb_waddr; reg sb_we;
    always @(posedge clk_sys) if (sb_we) sprbuf[sb_waddr] <= sb_wdata;
    reg [8:0] spr_disp_q;                    // display read (clk_vid)
    always @(posedge clk_vid) spr_disp_q <= sprbuf[{~wsel, hcnt[7:0]}];

    // engine FSM. Sprite gfx comes from SDRAM: per on-line sprite we issue FOUR
    // single-word reads -- {bank,A_L,0}={p1,p0} left, {bank,A_L,1}=p2 left, then the
    // same two for A_R = A_L+16 (right half). A = code*32 + yr.
    localparam SE_IDLE=4'd0, SE_CLR=4'd1, SE_RD=4'd2, SE_CHK=4'd3,
               SE_G0=4'd4, SE_G1=4'd5, SE_G2=4'd6, SE_G3=4'd7, SE_WR=4'd8;
    reg [16:0] sg_a;                       // current SDRAM word address
    reg        sg_rq = 1'b0;               // held high until spr_sg_rdy
    reg [14:0] a_left;                     // A for the left half
    // (sg_a/sg_rq now go through the SDRAM arbiter at the end of the module --
    //  the King of Boxer bg prefetch is a second requester on the same port.)
    reg [3:0]  se = SE_IDLE;
    reg [8:0]  clr_i;
    reg [7:0]  spr_i;
    reg [2:0]  rd_k;
    reg [7:0]  s_sy, s_attr, s_sx, s_code;
    reg [3:0]  wcol;
    reg [7:0]  rline;
    reg        bank_l;  reg [4:0] color_l;
    reg [7:0]  L0,L1,L2, R0,R1,R2;           // latched plane bytes (0=MSB..2=LSB)
    // King of Boxer scrambles the spriteram offset:
    //   roffs = bitswap<16>(offs,15..10,4,7,6,5,9,8,3,2,1,0) ^ 0x3c
    //   if (roffs & 0x200) roffs ^= 0x1c0
    // offs = spr_i*4, so offs[9:2] = spr_i and roffs stays 4-aligned. Folding the
    // 0x200 fixup in gives roffs[9:2] directly:
    wire [7:0] spr_scr = { spr_i[2],
                           spr_i[5] ^ spr_i[2],
                           spr_i[4] ^ spr_i[2],
                           spr_i[3] ^ spr_i[2],
                           ~spr_i[7], ~spr_i[6], ~spr_i[1], ~spr_i[0] };
    wire [7:0] spr_base = kob ? spr_scr : spr_i;

    // is this sprite on the target line? row = rline - sy.
    // flipy polarity is INVERTED between the boards: Ring King ~attr[7], KoB attr[7].
    wire [7:0] srow = rline - s_sy;
    wire       on_line = (srow < 8'd16);
    // Same test one cycle earlier, straight off the RAM output: at rd_k==2 spr_eq IS
    // byte0 (sy), the value s_sy is about to latch. Used only by the SE_RD early-out.
    wire [7:0] srow_e   = rline - spr_eq;
    wire       on_line_e = (srow_e < 8'd16);
    wire       spr_flipy = kob ? s_attr[7] : ~s_attr[7];
    wire [3:0] yr = spr_flipy ? (4'd15 - srow[3:0]) : srow[3:0];
    // combinational sprite pixel from latched plane bytes (bit = col&7, half = col[3])
    wire [2:0] cb = wcol[2:0];
    wire [2:0] sp_pix3 = wcol[3] ? {R0[cb], R1[cb], R2[cb]} : {L0[cb], L1[cb], L2[cb]};
    always @(posedge clk_sys) begin
        sb_we <= 1'b0;
        case (se)
            SE_IDLE: if (line_start) begin
                wsel  <= ~wsel;                  // swap: display now reads last-rendered
                rline <= vc_s2[7:0] + VOFF[7:0] + 8'd1;
                clr_i <= 9'd0;  se <= SE_CLR;
            end
            SE_CLR: begin                        // clear the new write buffer
                sb_waddr <= {wsel, clr_i[7:0]};  sb_wdata <= 9'd0;  sb_we <= 1'b1;
                if (clr_i[7:0] == 8'd255) begin spr_i <= 8'd0; rd_k <= 3'd0; se <= SE_RD; end
                else clr_i <= clr_i + 9'd1;
            end
            SE_RD: begin                         // read 4 sprite bytes. spr_eq is a
                // REGISTERED read: addr set at rd_k=K -> spr_eq usable at rd_k=K+2.
                // So present addr0..3 at rd_k 0..3, latch bytes at rd_k 2..5.
                spr_eaddr <= {spr_base, rd_k[1:0]};
                // field order differs by board:
                //   Ring King     : [0]=sy [1]=attr [2]=sx   [3]=code
                //   King of Boxer : [0]=sy [1]=sx   [2]=code [3]=attr
                case (rd_k)
                    3'd2: s_sy <= spr_eq;                          // byte0 = sy (both)
                    3'd3: if (kob) s_sx   <= spr_eq; else s_attr <= spr_eq;
                    3'd4: if (kob) s_code <= spr_eq; else s_sx   <= spr_eq;
                    3'd5: if (kob) s_attr <= spr_eq; else s_code <= spr_eq;
                endcase
                // EARLY-OUT. sy is byte0, so it is already on spr_eq at rd_k==2, and it
                // ALONE decides whether this slot is on the line -- the other 3 fields
                // only matter if it is. Bailing here costs an off-line slot 3 clk
                // instead of 7 (4 reads + SE_CHK). All 256 slots are scanned every line
                // (MAME does the same), and the vast majority are off-line, so this
                // frees ~1024 of the 3072 clk line: the headroom the KoB bg prefetch
                // was taking out of the sprite budget. Ring King gains it too.
                if ((rd_k == 3'd2) && !on_line_e) begin
                    if (spr_i == 8'd255) se <= SE_IDLE;
                    else begin spr_i <= spr_i + 8'd1; rd_k <= 3'd0; end
                end
                else if (rd_k == 3'd5) se <= SE_CHK;
                else rd_k <= rd_k + 3'd1;
            end
            SE_CHK: begin
                bank_l  <= s_attr[2];
                color_l <= {palette_bank, s_attr[6:4]};
                if (on_line) begin               // A_L = code*32 + yr
                    a_left <= {s_attr[1:0], s_code, 5'd0} + {11'd0, yr};
                    sg_a   <= {s_attr[2], ({s_attr[1:0], s_code, 5'd0} + {11'd0, yr}), 1'b0};
                    sg_rq  <= 1'b1;              // request {bank, A_L, 0}
                    se <= SE_G0;
                end else if (spr_i == 8'd255) se <= SE_IDLE;
                else begin spr_i <= spr_i + 8'd1; rd_k <= 3'd0; se <= SE_RD; end
            end
            SE_G0: if (spr_sg_rdy) begin          // {plane1, plane0} left
                L0 <= sgfx_q[7:0];  L1 <= sgfx_q[15:8];
                sg_a <= {bank_l, a_left, 1'b1};   // {bank, A_L, 1} -> plane2
                se <= SE_G1;                      // sg_rq stays high
            end
            SE_G1: if (spr_sg_rdy) begin          // plane2 left
                L2 <= sgfx_q[7:0];
                sg_a <= {bank_l, (a_left + 15'd16), 1'b0};   // right half
                se <= SE_G2;
            end
            SE_G2: if (spr_sg_rdy) begin          // {plane1, plane0} right
                R0 <= sgfx_q[7:0];  R1 <= sgfx_q[15:8];
                sg_a <= {bank_l, (a_left + 15'd16), 1'b1};
                se <= SE_G3;
            end
            SE_G3: if (spr_sg_rdy) begin          // plane2 right
                R2 <= sgfx_q[7:0];
                sg_rq <= 1'b0;                    // done fetching this sprite
                wcol  <= 4'd0;  se <= SE_WR;
            end
            SE_WR: begin                          // write 16 pixels (opaque only)
                sb_waddr <= {wsel, (s_sx + {4'd0, wcol})};
                sb_wdata <= {1'b1, color_l, sp_pix3};
                sb_we    <= (sp_pix3 != 3'd0);
                if (wcol == 4'd15) begin
                    if (spr_i == 8'd255) se <= SE_IDLE;
                    else begin spr_i <= spr_i + 8'd1; rd_k <= 3'd0; se <= SE_RD; end
                end else wcol <= wcol + 4'd1;
            end
            default: se <= SE_IDLE;
        endcase
    end

    // ---- align fg (delay 3) to the deeper bg pipeline (bg_r is 3 stages later) -
    reg pix_d1, pix_d2, pix_d3;  reg [2:0] clr_d1, clr_d2, clr_d3;
    always @(posedge clk_vid) begin
        pix_d1 <= pix_c;   pix_d2 <= pix_d1;   pix_d3 <= pix_d2;
        clr_d1 <= clr_c;   clr_d2 <= clr_d1;   clr_d3 <= clr_d2;
    end

    // ---- sprite display path: land RGB + opaque at delay 8 (aligned w/ bg & fg) -
    // spr_disp_q is delay1; carry {opaque,pen} to delay5, then PROM+resnet -> delay8.
    reg [8:0] sd1, sd2, sd3, sd4;
    reg sop6, sop7, sop8;  reg [7:0] spr_r, spr_g, spr_b;
    always @(posedge clk_vid) begin
        sd1 <= spr_disp_q; sd2 <= sd1; sd3 <= sd2; sd4 <= sd3;   // delay 2..5
        spal_addr <= sd4[7:0];  sop6 <= sd4[8];                  // delay6 (pen->PROM)
        sop7 <= sop6;                                            // delay7 (align sp_q)
        spr_r <= resnet(pal3 ? sp0_q[3:0] : sp0_q[7:4]);
        spr_g <= resnet(pal3 ? sp1_q[3:0] : sp0_q[3:0]);
        spr_b <= resnet(pal3 ? sp2_q[3:0] : sp1_q[3:0]);
        sop8  <= sop7;                                           // delay8
    end

    // ---- control (blank/sync) delayed to match; composite fg-over-bg ----------
    localparam PIX_DELAY = 8;             // HW-tune if the image is shifted
    reg [PIX_DELAY-1:0] hb_sr, vb_sr, hs_sr, vs_sr;
    always @(posedge clk_vid) begin
        hb_sr <= {hb_sr[PIX_DELAY-2:0], ~(hcnt < 10'd256)};
        vb_sr <= {vb_sr[PIX_DELAY-2:0], ~(vcnt < 10'd224)};
        hs_sr <= {hs_sr[PIX_DELAY-2:0], (hcnt >= 10'd296) && (hcnt < 10'd328)};
        vs_sr <= {vs_sr[PIX_DELAY-2:0], (vcnt >= 10'd234) && (vcnt < 10'd238)};
        vid_hb <= hb_sr[PIX_DELAY-1];
        vid_vb <= vb_sr[PIX_DELAY-1];
        vid_hs <= hs_sr[PIX_DELAY-1];
        vid_vs <= vs_sr[PIX_DELAY-1];
        // composite: fg (8 primaries) OVER sprite (PROM) OVER bg (PROM).
        if (pix_d3) begin                       // fg opaque
            vid_r <= clr_d3[2] ? 8'hFF : 8'h00;
            vid_g <= clr_d3[1] ? 8'hFF : 8'h00;
            vid_b <= clr_d3[0] ? 8'hFF : 8'h00;
        end else if (sop8) begin                // sprite opaque
            vid_r <= spr_r;  vid_g <= spr_g;  vid_b <= spr_b;
        end else begin                          // background
            vid_r <= bg_r;  vid_g <= bg_g;  vid_b <= bg_b;
        end
    end

    // =========================================================================
    // King of Boxer BG prefetch (clk_sys).
    // KoB has no gfx4 -- its bg is drawn out of the SPRITE gfx (gfx2/gfx3), which
    // lives in SDRAM, so it can't use Ring King's per-pixel gfx4 BRAM read. Instead
    // we fetch a tile's 6 plane bytes ONCE and bit-select across its 16 px.
    // Budget: disp_bg_addr looks a tile ahead, so the fetch for tile T runs while
    // the display is still on T-1 = 16 px = 128 clk_sys, against ~24 settle + ~60
    // for 4 SDRAM reads. Lands with margin even with the sprite engine busy.
    // The buffers ping-pong on tile parity, so clk_sys only ever writes the slot
    // clk_vid is not reading -- no CDC handshake needed. code/attr are quasi-static
    // for the full 128 clks, so syncing the 1-bit parity is enough to time when to
    // sample them; a multi-bit sync of disp_bg_addr itself could tear mid-change.
    // =========================================================================
    // The lookahead wraps to col 0 during the LAST tile of a line -- and that tile is
    // displayed on the NEXT line, so it must be fetched with the next line's row.
    // (bg_v_la is declared up with the bg pipeline, which also uses it for the
    //  tile index.) The same condition is the "col 0 -> code 0" gate.
    wire      bg_la_col0 = (hcnt[7:4] == 4'd15);
    // Only prefetch during ACTIVE display. hcnt runs to 383, so hcnt[7:4] cycles
    // through cols 0..7 again during hblank; left ungated, those fetches overwrite
    // the buffers holding the next line's first columns -- which showed up as a
    // band of the wrong tiles at one screen edge. Gating also cuts the bg's SDRAM
    // load from 24 tiles/line to 16, giving the sprite engine its budget back.
    wire      bg_pf_en = (hcnt < 10'd256);
    reg       h4_s1, h4_s2, h4_s3, lac0_s1, lac0_s2, pfen_s1, pfen_s2;
    reg [3:0] brow_s1, brow_s2;
    always @(posedge clk_sys) begin
        h4_s1   <= hcnt[4];      h4_s2   <= h4_s1;  h4_s3 <= h4_s2;
        lac0_s1 <= bg_la_col0;   lac0_s2 <= lac0_s1;
        pfen_s1 <= bg_pf_en;     pfen_s2 <= pfen_s1;
        brow_s1 <= bg_v_la[3:0]; brow_s2 <= brow_s1;
    end
    wire bg_new_tile = h4_s2 ^ h4_s3;      // a new lookahead tile is being addressed

    // code = (col != 0) ? videoram + (attr[1:0] << 8) : 0   [MAME get_bg_tile_info]
    wire [14:0] bg_code32 = lac0_s2 ? 15'd0 : {disp_bc_q[1:0], disp_bv_q, 5'd0};
    wire [14:0] bg_A_new  = bg_code32 + {11'd0, brow_s2};   // code*32 + y

    localparam BG_IDLE=3'd0, BG_WAIT=3'd1, BG_G0=3'd2, BG_G1=3'd3, BG_G2=3'd4, BG_G3=3'd5;
    reg [2:0]  bgs = BG_IDLE;
    reg [16:0] bg_sg_a;   reg bg_sg_rq = 1'b0;
    reg [14:0] bg_A;      reg bg_bank;  reg bg_wp;
    reg [5:0]  bg_dly;
    always @(posedge clk_sys) begin
        case (bgs)
            // Settle delay covers TWO things: disp_bg_addr -> disp_bv_q/disp_bc_q for
            // the new tile (2 clk_vid), and the display pipeline's ~4 clk_vid lag --
            // it is still reading the slot we are about to fill for a few px after the
            // tile boundary. 40 clk_sys = 5 clk_vid clears both, and still leaves
            // 88 of the 128 clk_sys tile for a ~60 clk fetch.
            BG_IDLE: if (kob & bg_new_tile & pfen_s2) begin bg_dly <= 6'd40; bgs <= BG_WAIT; end
            BG_WAIT: if (bg_dly != 6'd0) bg_dly <= bg_dly - 6'd1;
                     else begin
                         bg_wp           <= ~h4_s2;              // lookahead tile's parity
                         bg_bank         <= disp_bc_q[2];        // 0 -> gfx2, 1 -> gfx3
                         bgb_clr[~h4_s2] <= {palette_bank, disp_bc_q[6:4]};
                         bg_A            <= bg_A_new;
                         bg_sg_a         <= {disp_bc_q[2], bg_A_new, 1'b0};
                         bg_sg_rq        <= 1'b1;
                         bgs             <= BG_G0;
                     end
            BG_G0: if (bg_sg_rdy) begin                          // {plane1, plane0} left
                       bgb_L0[bg_wp] <= sgfx_q[7:0];  bgb_L1[bg_wp] <= sgfx_q[15:8];
                       bg_sg_a <= {bg_bank, bg_A, 1'b1};
                       bgs <= BG_G1;
                   end
            BG_G1: if (bg_sg_rdy) begin                          // plane2 left
                       bgb_L2[bg_wp] <= sgfx_q[7:0];
                       bg_sg_a <= {bg_bank, (bg_A + 15'd16), 1'b0};
                       bgs <= BG_G2;
                   end
            BG_G2: if (bg_sg_rdy) begin                          // {plane1, plane0} right
                       bgb_R0[bg_wp] <= sgfx_q[7:0];  bgb_R1[bg_wp] <= sgfx_q[15:8];
                       bg_sg_a <= {bg_bank, (bg_A + 15'd16), 1'b1};
                       bgs <= BG_G3;
                   end
            BG_G3: if (bg_sg_rdy) begin                          // plane2 right
                       bgb_R2[bg_wp] <= sgfx_q[7:0];
                       bg_sg_rq <= 1'b0;
                       bgs <= BG_IDLE;
                   end
            default: bgs <= BG_IDLE;
        endcase
    end

    // ---- SDRAM read arbiter. The sprite engine and the KoB bg prefetch share one
    // read port. The bg wins a tie: it has a hard per-tile deadline, while the
    // sprite engine is filling a line buffer a whole line ahead. The grant is
    // COMBINATIONAL when idle, so with the bg quiet (= every Ring King set) both
    // sgfx_addr and sgfx_req are exactly what the sprite engine drove before --
    // no added latency on the proven path.
    reg  sg_own = 1'b0;                     // owner of the in-flight read: 0=spr 1=bg
    reg  sg_busy = 1'b0;
    wire sel_bg = sg_busy ? sg_own : bg_sg_rq;
    always @(posedge clk_sys) begin
        if (!sg_busy) begin
            if (bg_sg_rq | sg_rq) begin sg_own <= bg_sg_rq; sg_busy <= 1'b1; end
        end else if (sgfx_ready) sg_busy <= 1'b0;
    end
    assign sgfx_addr = sel_bg ? bg_sg_a : sg_a;
    assign sgfx_req  = sg_busy ? 1'b1 : (bg_sg_rq | sg_rq);
    assign bg_sg_rdy  = sgfx_ready &  sg_own;
    assign spr_sg_rdy = sgfx_ready & ~sg_own;

    // keep misc regs "used" (avoid prune warnings)
    wire _unused = &{1'b0, flip_screen, m_m1_n, sd_dout, 1'b0};

endmodule

// =============================================================================
// ay8910 -- AY-3-8910 PSG (Ring King: 1.5 MHz, port A = soundlatch).
// 3 square tone channels + noise + envelope, mixed to one unipolar output.
//   tone f = cen/(16*period)  => counters step at cen/8.
//   reg7 mixer: bits0-2 = tone A/B/C DISABLE, bits3-5 = noise A/B/C DISABLE.
//   reg8/9/10 amplitude: [3:0] level, [4] = use envelope.
//   reg14 (port A) reads the sound latch.
// Envelope shape follows the datasheet rule shp={CONT,ATT,ALT,HOLD} -- CONT=0 must
// fall SILENT, HOLD stops at the ATT^ALT end, ALT reverses, else repeat. (Getting
// this wrong leaves channels stuck at full volume forever = permanent noise.)
// Amplitude 0 must map to level 0 (silent), not level 1.
// =============================================================================
`default_nettype none
module ay8910 (
    input  wire       clk,
    input  wire       cen,          // 1.5 MHz chip clock enable
    input  wire       rst,
    input  wire [7:0] din,
    input  wire       addr_we,      // latch register address
    input  wire       data_we,      // write register data
    output wire [7:0] dout,         // read register data
    input  wire [7:0] port_a,       // reg 14 = sound latch
    output wire [9:0] snd           // 3 channels summed (0..765)
);
    reg [3:0] raddr;
    reg [7:0] regs [0:15] /* synthesis ramstyle = "logic" */;
    integer i;
    always @(posedge clk) begin
        if (rst) begin for (i=0;i<16;i=i+1) regs[i] <= 8'd0; raddr <= 4'd0; end
        else begin
            if (addr_we) raddr <= din[3:0];
            if (data_we) regs[raddr] <= din;
        end
    end
    assign dout = (raddr == 4'd14) ? port_a : regs[raddr];

    // counters tick at cen/8 (tone period units are cen/16 -> toggle at 2x period)
    reg [2:0] pdiv;
    wire step = cen & (pdiv == 3'd7);
    always @(posedge clk) if (cen) pdiv <= pdiv + 3'd1;

    wire [11:0] perA = {regs[1][3:0], regs[0]};
    wire [11:0] perB = {regs[3][3:0], regs[2]};
    wire [11:0] perC = {regs[5][3:0], regs[4]};
    wire [4:0]  perN = regs[6][4:0];
    wire [7:0]  enab = regs[7];
    wire [15:0] perE = {regs[12], regs[11]};
    wire [3:0]  shp  = regs[13][3:0];

    reg [11:0] cntA, cntB, cntC;  reg toneA, toneB, toneC;
    always @(posedge clk) if (step) begin
        if (cntA >= perA) begin cntA<=12'd0; toneA<=~toneA; end else cntA<=cntA+12'd1;
        if (cntB >= perB) begin cntB<=12'd0; toneB<=~toneB; end else cntB<=cntB+12'd1;
        if (cntC >= perC) begin cntC<=12'd0; toneC<=~toneC; end else cntC<=cntC+12'd1;
    end

    // noise: 5-bit period counter + 17-bit LFSR (taps 0^3)
    reg [4:0] cntNo;  reg [16:0] lfsr = 17'h1FFFF;  reg noise_ff;
    always @(posedge clk) if (step) begin
        if (cntNo >= perN) begin
            cntNo<=5'd0; noise_ff<=~noise_ff;
            if (noise_ff) lfsr <= {lfsr[0]^lfsr[3], lfsr[16:1]};
        end else cntNo<=cntNo+5'd1;
    end
    wire noise = lfsr[0];

    // envelope: 16-bit period, 5-bit level, datasheet shape rule
    reg [15:0] cntE;  reg [4:0] envlvl;  reg env_hold, env_att;
    always @(posedge clk) begin
        if (data_we && (raddr == 4'd13)) begin        // writing shape restarts it
            cntE<=16'd0; env_hold<=1'b0; env_att<=din[2]; envlvl<=din[2]?5'd0:5'd31;
        end else if (step) begin
            if (cntE >= perE) begin
                cntE <= 16'd0;
                if (~env_hold) begin
                    if (env_att ? (envlvl==5'd31) : (envlvl==5'd0)) begin
                        if (~shp[3])      begin envlvl<=5'd0; env_hold<=1'b1; end   // CONT=0 -> silent
                        else if (shp[0])  begin envlvl<=(env_att^shp[1])?5'd31:5'd0; env_hold<=1'b1; end
                        else if (shp[1])  begin env_att<=~env_att; envlvl<=env_att?5'd30:5'd1; end
                        else                    envlvl<= env_att?5'd0:5'd31;        // repeat ramp
                    end else envlvl <= env_att ? (envlvl+5'd1) : (envlvl-5'd1);
                end
            end else cntE <= cntE + 16'd1;
        end
    end

    // level select: amplitude 0 -> silent; else vol*2|1 into the 32-step table
    function [4:0] amp2lvl; input [3:0] a; begin amp2lvl = (a==4'd0) ? 5'd0 : {a,1'b1}; end endfunction
    wire [4:0] lvlA = regs[8][4]  ? envlvl : amp2lvl(regs[8][3:0]);
    wire [4:0] lvlB = regs[9][4]  ? envlvl : amp2lvl(regs[9][3:0]);
    wire [4:0] lvlC = regs[10][4] ? envlvl : amp2lvl(regs[10][3:0]);

    wire chA = (toneA | enab[0]) & (noise | enab[3]);
    wire chB = (toneB | enab[1]) & (noise | enab[4]);
    wire chC = (toneC | enab[2]) & (noise | enab[5]);

    // log DAC: ymfm ssg.cpp s_amplitudes (exact YM2149 curve) scaled to 0..255/ch
    function [7:0] dac; input [4:0] l; begin
        case (l)
          5'd0:dac=0;   5'd1:dac=1;   5'd2:dac=1;   5'd3:dac=2;
          5'd4:dac=3;   5'd5:dac=3;   5'd6:dac=4;   5'd7:dac=5;
          5'd8:dac=6;   5'd9:dac=7;   5'd10:dac=8;  5'd11:dac=9;
          5'd12:dac=11; 5'd13:dac=13; 5'd14:dac=15; 5'd15:dac=17;
          5'd16:dac=21; 5'd17:dac=25; 5'd18:dac=29; 5'd19:dac=33;
          5'd20:dac=40; 5'd21:dac=48; 5'd22:dac=56; 5'd23:dac=64;
          5'd24:dac=78; 5'd25:dac=94; 5'd26:dac=109;5'd27:dac=127;
          5'd28:dac=155;5'd29:dac=186;5'd30:dac=220;default:dac=255;
        endcase
    end endfunction
    assign snd = {2'b0, chA ? dac(lvlA) : 8'd0} + {2'b0, chB ? dac(lvlB) : 8'd0}
               + {2'b0, chC ? dac(lvlC) : 8'd0};
endmodule

// =============================================================================
// tdp_ram -- true dual-port RAM, single clock. Intel/Altera-recommended
// inferrable template: each port in its OWN always block with WRITE-FIRST
// (read-new-data) semantics. Infers a single M10K TDP block. This exact shape
// is required -- inline 2-write-port arrays in the game module do NOT infer.
// =============================================================================
`default_nettype none
module tdp_ram #(parameter DW = 8, parameter AW = 11) (
    input  wire           clk,
    input  wire           we_a,
    input  wire [AW-1:0]  addr_a,
    input  wire [DW-1:0]  din_a,
    output reg  [DW-1:0]  q_a,
    input  wire           we_b,
    input  wire [AW-1:0]  addr_b,
    input  wire [DW-1:0]  din_b,
    output reg  [DW-1:0]  q_b
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we_a) begin mem[addr_a] <= din_a; q_a <= din_a; end
        else                                   q_a <= mem[addr_a];
    end
    always @(posedge clk) begin
        if (we_b) begin mem[addr_b] <= din_b; q_b <= din_b; end
        else                                   q_b <= mem[addr_b];
    end
endmodule
