// vz_overlay.sv - one box in the bottom-left corner of the picture for the
// tape status bar and the next-step hints (~/dev2/tape-standard.md rules
// 19-28). Mixed into the 6847's RGB before video_mixer; it never changes the
// machine. Text uses the MC6847's internal font (vz_intfont.svh). Everything
// runs on the 42.95 MHz clock (clk_sys == CLK_VIDEO), so the status needs no
// clock-domain handshake.
//
// What it shows, first match wins:
//  1. Tape overlay On, the deck playing:   TAPE > 0:09/ 1:24 x3  and a 64-step bar
//  2. Load hints On, after a BASIC .VZ snapshot (header type F0h) loaded:
//         NAME FROM THE HEADER              (if the header has one)
//         TYPE RUN <ret>
//     until Return, a reset or the next download. A machine-code .VZ starts
//     by itself and shows nothing.
//  3. Tape overlay On, the deck stopped:
//     - tape at its start (mounted / rewound):  TYPE CRUN <ret>
//       CRUN loads and starts both BASIC and machine-code programs (ROM
//       372Eh; CLOAD also starts machine code, 36C7h). This is a guess the
//       tape does not state; tools/vztape_scan.py found F0/F1 as the first
//       file of every tape in the corpus that decodes (see README).
//     - after CLOAD of a BASIC program (the ROM returned to READY without
//       running it, 36E0h):                     TYPE RUN <ret>
//     each until Return.
module vz_overlay (
    input  logic        clk,
    input  logic        reset,        // machine reset
    input  logic        hint_en,      // OSD Load hints
    input  logic        tape_en,      // OSD Tape overlay
    // .VZ download (hps_io ioctl)
    input  logic        dn_download,
    input  logic  [7:0] dn_index,
    input  logic [15:0] dn_addr,
    input  logic  [7:0] dn_data,
    input  logic        dn_wr,
    // tape
    input  logic        tape_loaded,
    input  logic        tape_playing,
    input  logic        tape_fast,
    input  logic        tape_at_start,
    input  logic [31:0] tape_pos,
    input  logic [31:0] tape_len,
    input  logic [17:0] tape_hz,
    input  logic        tape_ready,   // pulse: mounted or rewound
    input  logic        basic_cloaded,// pulse: CPU fetched 36E0h
    // keyboard: key_strobe toggles on every PS/2 event
    input  logic        key_strobe,
    input  logic        key_pressed,
    input  logic  [7:0] key_code,
    // video
    input  logic        ce_pix,
    input  logic        hblank, vblank,
    input  logic  [7:0] r_in, g_in, b_in,
    output logic  [7:0] r_out, g_out, b_out,
    // for the simulator's checks
    output logic        show_vz,      // .VZ hint on screen
    output logic        show_bar,     // tape status bar on screen
    output logic  [1:0] show_tape     // tape hint on screen: 1 CRUN, 2 RUN
);
    localparam int NAME = 16;         // .VZ header bytes 4-19

    wire return_key;
    logic old_strobe;
    assign return_key = key_strobe != old_strobe && key_pressed && key_code == 8'h5A;  // Return, keypad Enter

    // ---- .VZ hint --------------------------------------------------------
    logic [7:0]      name [NAME];
    logic [NAME-1:0] cut;             // at or after the name's 00h
    logic [7:0]      vz_type;
    logic            vz_dl, old_download, pending, want_vz;

    // printable in the font: 20h-5Fh, lower case folded to upper case
    function automatic logic [7:0] fold(input logic [7:0] c);
        if (c >= 8'h61 && c <= 8'h7A) return c - 8'h20;
        if (c >= 8'h20 && c <= 8'h5F) return c;
        return 8'h20;
    endfunction

    // ---- tape hints ------------------------------------------------------
    logic crun_done, want_run;

    initial begin
        want_vz = 0; pending = 0; vz_dl = 0; old_download = 0; old_strobe = 0; vz_type = 0; cut = 0;
        crun_done = 0; want_run = 0;
        for (int i = 0; i < NAME; i++) name[i] = 8'h20;
    end

    always_ff @(posedge clk) begin
        old_download <= dn_download;
        old_strobe   <= key_strobe;
        if (dn_download && !old_download) begin
            vz_dl <= dn_index == 8'd1;
            want_vz <= 0; pending <= 0; cut <= '0;
            for (int i = 0; i < NAME; i++) name[i] <= 8'h20;
        end
        if (dn_download && dn_wr && vz_dl && dn_addr >= 16'd4 && dn_addr < 16'd20) begin
            name[dn_addr[3:0] - 4'd4] <= fold(dn_data);
            cut[dn_addr[3:0] - 4'd4] <= dn_data == 8'h00 || (dn_addr != 16'd4 && cut[dn_addr[3:0] - 4'd5]);
        end
        if (dn_download && dn_wr && vz_dl && dn_addr == 16'd21) vz_type <= dn_data;
        if (!dn_download && old_download && vz_dl) pending <= 1;
        if (pending) begin pending <= 0; want_vz <= vz_type == 8'hF0; end

        if (tape_ready) begin crun_done <= 0; want_run <= 0; end
        if (basic_cloaded && tape_loaded) want_run <= 1;

        if (return_key) begin
            want_vz <= 0; want_run <= 0;
            if (tape_loaded && tape_at_start) crun_done <= 1;
        end
        if (reset) begin want_vz <= 0; pending <= 0; want_run <= 0; end
    end

    assign show_bar = tape_en && tape_loaded && tape_playing;
    assign show_vz  = !show_bar && hint_en && want_vz;
    assign show_tape = show_bar || show_vz || !tape_en || !tape_loaded || tape_playing ? 2'd0 :
                       want_run ? 2'd2 : (tape_at_start && !crun_done) ? 2'd1 : 2'd0;

    // ---- tape times (BCD m:ss, saturating at 99:59) and bar fill ---------
    logic [15:0] elapsed, total;
    logic [17:0] frac;
    logic [31:0] last_pos, last_len, rem, cell_count;
    logic [17:0] last_hz;
    logic [6:0]  fill;
    logic        computing;
    initial begin
        elapsed = 0; total = 0; frac = 0; last_pos = 0; last_len = 0; last_hz = 0;
        rem = 0; cell_count = 0; fill = 0; computing = 0;
    end

    function automatic logic [15:0] bcd_tick(input logic [15:0] t);
        logic [15:0] n;
        n = t;
        if (t == 16'h9959) return t;
        if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
        else begin
            n[3:0] = 0;
            if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
            else begin
                n[7:4] = 0;
                if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
                else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
            end
        end
        return n;
    endfunction

    wire [31:0] cell_bits = tape_len[31:6] == 0 ? 32'd1 : {6'd0, tape_len[31:6]};
    always_ff @(posedge clk) begin
        last_pos <= tape_pos;
        if (tape_pos == 0 || tape_pos < last_pos) begin
            elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
        end else if (tape_pos != last_pos) begin
            if (frac + 18'd1 >= tape_hz) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
            else frac <= frac + 18'd1;
            if (cell_count + 32'd1 >= cell_bits) begin
                cell_count <= 0;
                if (fill != 7'd64) fill <= fill + 7'd1;
            end else cell_count <= cell_count + 32'd1;
        end
        last_len <= tape_len; last_hz <= tape_hz;
        if (tape_len != last_len || tape_hz != last_hz) begin
            rem <= tape_len; total <= 0; computing <= tape_hz != 0;
        end else if (computing) begin
            if (rem >= {14'd0, tape_hz}) begin rem <= rem - {14'd0, tape_hz}; total <= bcd_tick(total); end
            else computing <= 0;
        end
    end

    // ---- picture position (measured, rule 23) ----------------------------
    logic [10:0] x, width;
    logic [9:0]  y, height;
    logic        line_active, old_hblank, old_vblank;
    initial begin x = 0; y = 0; width = 0; height = 0; line_active = 0; old_hblank = 0; old_vblank = 0; end

    always_ff @(posedge clk) if (ce_pix) begin
        old_hblank <= hblank; old_vblank <= vblank;
        if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
        if (hblank && !old_hblank) begin
            if (line_active) begin width <= x; y <= y + 10'd1; end
            x <= 0; line_active <= 0;
        end
        if (vblank && !old_vblank) begin height <= y; y <= 0; end
    end

    `include "vz_intfont.svh"

    // ---- text ------------------------------------------------------------
    localparam logic [7:0] RET = 8'h01, PLAY = 8'h03;
    localparam logic [8*11-1:0] T_RUN  = {"TYPE RUN ", RET, " "};
    localparam logic [8*11-1:0] T_CRUN = {"TYPE CRUN ", RET};

    logic [4:0] name_w;
    always_comb begin
        name_w = 5'd0;
        for (int i = 0; i < NAME; i++) if (!cut[i] && name[i] != 8'h20) name_w = 5'(i + 1);
    end
    wire        two   = show_vz && name_w != 0;           // two text lines
    wire        visible = show_bar || show_vz || show_tape != 0;
    wire [4:0]  chars = show_bar ? 5'd21 :
                        show_tape == 2'd1 ? 5'd11 :
                        show_tape == 2'd2 ? 5'd10 :
                        name_w > 5'd10 ? name_w : 5'd10;

    // doubled on wide / tall pictures (rule 21)
    wire        sx = width >= 11'd512, sy = height >= 10'd300;
    wire [10:0] box_w = {3'd0, chars, 3'd0} + 11'd4;
    wire [9:0]  box_h = show_bar ? 10'd18 : two ? 10'd22 : 10'd12;
    wire [10:0] x0 = 11'd4;
    wire [9:0]  y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
    wire [10:0] dx = x - x0;
    wire [9:0]  dy = y - y0;
    wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
    wire [9:0]  ly = sy ? {1'b0, dy[9:1]} : dy;
    wire        in_box = visible && height > 10'd40 && x >= x0 && y >= y0 && lx < box_w && ly < box_h;

    wire        row2 = two && ly >= 10'd12;
    wire [10:0] tx   = lx - 11'd2;
    wire [9:0]  ty   = ly - (row2 ? 10'd12 : 10'd2);
    wire [4:0]  col  = tx[7:3];

    function automatic logic [7:0] dig(input logic [3:0] d, input logic blank_zero);
        return blank_zero && d == 0 ? 8'h20 : 8'h30 + {4'd0, d};
    endfunction
    logic [7:0] st_ch;     // "TAPE > m:ss/ m:ss x3"
    always_comb begin
        case (col)
            5'd0: st_ch = "T";  5'd1: st_ch = "A";  5'd2: st_ch = "P";  5'd3: st_ch = "E";
            5'd5: st_ch = PLAY;
            5'd7: st_ch = dig(elapsed[15:12], 1'b1);  5'd8: st_ch = dig(elapsed[11:8], 1'b0);
            5'd9: st_ch = ":";  5'd10: st_ch = dig(elapsed[7:4], 1'b0);  5'd11: st_ch = dig(elapsed[3:0], 1'b0);
            5'd12: st_ch = "/";
            5'd13: st_ch = dig(total[15:12], 1'b1);  5'd14: st_ch = dig(total[11:8], 1'b0);
            5'd15: st_ch = ":";  5'd16: st_ch = dig(total[7:4], 1'b0);  5'd17: st_ch = dig(total[3:0], 1'b0);
            5'd19: st_ch = tape_fast ? "X" : " ";  5'd20: st_ch = tape_fast ? "3" : " ";
            default: st_ch = " ";
        endcase
    end
    wire [7:0] hint_ch =
        col >= 5'd11 ? 8'h20 :
        show_tape == 2'd1 ? T_CRUN[8*11-1 - 8*col -: 8] :
        show_tape == 2'd2 || !two || row2 ? T_RUN[8*11-1 - 8*col -: 8] :
        8'h20;
    wire [7:0] name_ch = col >= 5'(NAME) || cut[col[3:0]] ? 8'h20 : name[col[3:0]];
    wire [7:0] ch = show_bar ? st_ch : (two && !row2) ? name_ch : hint_ch;

    logic [7:0] glyph_row;
    always_comb begin
        case (ch)
            RET:  glyph_row = 8'(64'h02022262FE602000 >> (8 * (7 - ty[2:0])));
            PLAY: glyph_row = 8'(64'h4060707870604000 >> (8 * (7 - ty[2:0])));
            default: glyph_row = ch >= 8'h20 && ch < 8'h60 ? intfont(ch[5:0], {1'b0, ty[2:0]} + 4'd2) : 8'h00;
        endcase
    end
    wire text_on  = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
    wire bar_area = show_bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
    wire bar_on   = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

    always_comb begin
        {r_out, g_out, b_out} = {r_in, g_in, b_in};
        if (in_box)
            {r_out, g_out, b_out} = text_on && !bar_area ? 24'hFFFFFF : bar_on ? 24'h44CC44 :
                                    bar_area ? 24'h333333 : 24'h000000;
    end
endmodule
