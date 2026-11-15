// vz_tape.sv - cassette player for the VZ200 / Laser 310 core.
//
// Streams the image mounted in the OSD Tape slot (hps_io SD block interface,
// 512-byte sectors, two sector buffers) and turns it into the level the
// machine's cassette comparator gives (keyboard port bit 6 = ~level).
//
//   .wav  RIFF WAVE: PCM 8-bit unsigned or 16-bit signed, or 32-bit float;
//         mono or stereo (left channel); any rate 2-192 kHz. The level is the
//         comparator MAME uses (vtech1.cpp): sample above +4% of full scale.
//   other the raw byte stream of a .cas (MAME vt_cas.cpp): 3600 samples/s,
//         each bit 6 samples MSB first, 1 = HL HL HL, 0 = HL HH LL, with 12
//         low samples after the first 00h byte (the name's end), after
//         800 samples of silence. This is the sim's waveform too.
//
// The tape plays while `play` is high (vz_deck: the CPU is in the ROM's tape
// routine). One sample is always prefetched, so SD and buffer latency never
// stretch a pulse; if the next sample is still missing when it is due the
// tape waits (counted in `underflows`). `fast` plays it 3x while the CPU runs
// 3x (TURBO_SPEED), so the ROM's loops see the same pulse widths (tape
// standard rule 7); a WAV needing more than 100 kB/s at 1x plays at 1x.
// Mounting and Rewind start at sample 0. The machine's reset leaves the tape
// where it is.
module vz_tape #(
    parameter int unsigned CLK_HZ = 42954545
) (
    input  logic        clk,
    // hps_io image slot (synchronous to clk)
    input  logic        img_mounted,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    input  logic        sd_ack,
    input  logic  [8:0] sd_buff_addr,
    input  logic  [7:0] sd_buff_dout,
    input  logic        sd_buff_wr,
    // deck
    input  logic        rewind,      // OSD Rewind tape (pulse)
    input  logic        play,        // deck plays
    input  logic        turbo_ok,    // OSD Tape speed 3x
    input  logic        invert,      // OSD Tape polarity: Inverted
    input  logic  [1:0] pitch,       // 0 Normal, 1 +6% (x17/16), 2 +12% (x9/8), 3 Auto: a deck's speed trim.
                                     // Auto (default) plays every tape at a 1.63 ms bit cell, measured
                                     // from its leader at mount (see CAL below).
    output logic        level,       // comparator output (1 = above threshold)
    // status
    output logic        loaded,      // a playable tape is mounted
    output logic        fast,        // playing at 3x now
    output logic        at_start,
    output logic        at_end,
    output logic [31:0] position,    // samples played
    output logic [31:0] length,      // samples on the tape
    output logic [17:0] hz,          // samples per second
    output logic        ready_pulse, // mount/rewind done, tape playable
    output logic        bad_pulse,   // mount rejected (format)
    output logic [15:0] underflows
);
    localparam logic [31:0] MAX_BYTES = 32'h1000_0000;
    localparam int CAS_LEAD = 800;

    // ---------------------------------------------------------------- sectors
    logic [7:0]  buffer[0:1023];
    logic [22:0] slot_tag[0:1];
    logic [1:0]  slot_ok;
    logic        fetching, fetch_slot, fetch_abort, ack_seen;
    logic [31:0] size;

    // byte reader: ga/greq -> gq/gdone
    logic [31:0] ga;
    logic        greq, gbusy, gdone;
    logic [1:0]  gwait;
    logic [7:0]  gq, rd_q;
    logic [9:0]  rd_addr;
    wire  [22:0] gsec = ga[31:9];
    wire         ghit = slot_ok[gsec[0]] && slot_tag[gsec[0]] == gsec;
    wire  [22:0] last_sector = 23'((size - 32'd1) >> 9);
    logic [22:0] want_next;      // prefetch the sector after the last one read

    always_ff @(posedge clk) begin
        if (sd_ack && sd_buff_wr) buffer[{fetch_slot, sd_buff_addr}] <= sd_buff_dout;
        rd_q <= buffer[rd_addr];
    end

    // ---------------------------------------------------------------- format
    typedef enum logic [3:0] {IDLE, START, RIFF, CHUNK, FMT, NEXT, CAL, RUN, DEAD} state_t;
    state_t      state;
    logic [7:0]  hb[0:15];       // bytes read by the parser
    logic [4:0]  hn, hk;         // how many to read, how many read
    logic [31:0] hbase;
    logic        hreading;
    logic [31:0] p;              // chunk offset
    logic [31:0] next_p;         // offset of the chunk after the fmt chunk
    logic [3:0]  chunks;
    logic        is_wav, have_fmt;
    logic [15:0] wfmt, wch, wbits;
    logic [31:0] wrate, data_off, data_len;
    logic [1:0]  fshift;         // bytes per frame = 1 << fshift
    logic [2:0]  nbytes;         // bytes of the first channel: 1, 2, 4

    function automatic logic [31:0] le32(input logic [7:0] b0, b1, b2, b3);
        return {b3, b2, b1, b0};
    endfunction
    wire [31:0] ck_len = le32(hb[4], hb[5], hb[6], hb[7]);
    wire        id_fmt  = hb[0] == "f" && hb[1] == "m" && hb[2] == "t" && hb[3] == " ";
    wire        id_data = hb[0] == "d" && hb[1] == "a" && hb[2] == "t" && hb[3] == "a";

    // ---------------------------------------------------------------- samples
    // producer: the level of sample `si` (the next one to play) into nlevel/nok
    logic [31:0] si;             // index of the next sample
    logic        nlevel, nok, ended;
    logic [7:0]  sb[0:3];
    logic [2:0]  sj;             // WAV: bytes of the next sample read
    // .cas generator state, for sample si
    logic [9:0]  c_lead;
    logic [31:0] c_byte;         // byte index
    logic [2:0]  c_bit;
    logic [2:0]  c_sub;
    logic [3:0]  c_gap;
    logic        c_nul, c_have;
    logic [7:0]  c_val;

    wire  [31:0] w_addr = data_off + (si << fshift) + {29'd0, sj};

    function automatic logic wav_level(input logic [7:0] b0, b1, b2, b3, input logic [2:0] n, input logic flt);
        if (flt) return !b3[7] && {b3, b2, b1, b0} > 32'h3D23D70A;        // > +0.04
        if (n == 3'd2) return !b1[7] && {b1, b0} > 16'd1310;            // > +1310 / 32768
        return b0 > 8'd133;                                              // > 128 + 5
    endfunction

    // ---------------------------------------------------------------- calibration
    // At mount the tape is read ahead from the start, as fast as the sectors
    // come, looking for the leader: 512 rising-edge intervals in a row between
    // 0.4 and 3 units (unit = 1/1800 s, a third of a 600-baud bit cell). The
    // leader is 80h bytes: 17 rising edges per 8 bit cells, so the cell is
    // span * 17 / 4096 samples. Auto plays the tape at the rate that makes the
    // cell 1.63 ms: cal_hz = span * 17 / 4096 / 1.63e-3 = span * 2607 / 1024,
    // clamped to 13/16..5/4 of the recorded rate. The ROM (TAPE_READ_BIT 378Fh)
    // loads cells of about 1.53-1.73 ms (60-tape sweep, docs in README). The
    // samples are never changed; only the rate they are played at (rule 8).
    // No leader within 10 s (or 2 MB) of tape: cal_hz = hz.
    logic [31:0] cal_hz;
    logic [15:0] cal_iv;
    logic [31:0] cal_span;
    logic [9:0]  cal_cnt;
    logic        cal_prev, cal_seen;
    wire  [31:0] hz32 = {14'd0, hz};
    wire         iv_ok = {16'd0, cal_iv} * 32'd4500 > hz32 && {16'd0, cal_iv} * 32'd600 < hz32;
    wire  [31:0] cal_raw = (cal_span * 32'd2607) >> 10;
    wire  [31:0] hz_lo = hz32 - (hz32 >> 3) - (hz32 >> 4);         // 13/16
    wire  [31:0] hz_hi = hz32 + (hz32 >> 2);                       // 5/4
    wire         cal_stop;       // leader measured, or out of budget
    wire         cal_finish;     // ... and no byte read in flight: rewind and play

    assign cal_stop   = state == CAL && (cal_cnt == 10'd512 || ended || si >= (hz32 << 3) + (hz32 << 1) ||
                                         (si << fshift) >= 32'h0020_0000);
    assign cal_finish = cal_stop && !gbusy && !gdone && !greq;

    // ---------------------------------------------------------------- clock
    logic [31:0] acc;
    wire  [31:0] sel_hz = pitch == 2'd3 ? cal_hz : hz32;
    wire  [31:0] rate_b = fast ? sel_hz * 32'd3 : sel_hz;
    wire  [31:0] rate_x = rate_b + (pitch == 2'd1 ? rate_b >> 4 : pitch == 2'd2 ? rate_b >> 3 : 32'd0);
    wire         byte_rate_ok = !is_wav || (({14'd0, hz} << fshift) <= 32'd100000);
    assign fast = play && turbo_ok && byte_rate_ok && loaded && !at_end;

    assign loaded   = state == RUN;
    assign position = si;
    assign at_start = si == 0;

    initial begin
        state = IDLE; slot_ok = 0; fetching = 0; fetch_abort = 0; ack_seen = 0; sd_rd = 0; sd_lba = 0;
        greq = 0; gbusy = 0; gdone = 0; gwait = 0; size = 0; level = 0; nok = 0; ended = 0; si = 0;
        acc = 0; length = 0; hz = 18'd3600; underflows = 0; at_end = 0; hreading = 0; is_wav = 0;
        ready_pulse = 0; bad_pulse = 0; want_next = 0; c_have = 0;
    end

    always_ff @(posedge clk) begin
        ready_pulse <= 0; bad_pulse <= 0; gdone <= 0;

        // ---- SD transfers
        if (fetching) begin
            if (sd_ack) begin sd_rd <= 0; ack_seen <= 1; end
            else if (ack_seen) begin
                fetching <= 0; ack_seen <= 0;
                if (!fetch_abort) slot_ok[fetch_slot] <= 1;
                fetch_abort <= 0;
            end
        end

        // ---- byte reader
        if (gbusy) begin
            if (ghit) begin
                if (gwait == 0) begin rd_addr <= {gsec[0], ga[8:0]}; gwait <= 1; end
                else if (gwait == 1) gwait <= 2;
                else begin gq <= rd_q; gdone <= 1; gbusy <= 0; gwait <= 0; want_next <= gsec + 23'd1; end
            end else begin
                gwait <= 0;
                if (!fetching) begin
                    sd_lba <= {9'd0, gsec}; sd_rd <= 1; fetching <= 1;
                    fetch_slot <= gsec[0]; slot_ok[gsec[0]] <= 0; slot_tag[gsec[0]] <= gsec;
                end
            end
        end else if (greq) begin
            gbusy <= 1; greq <= 0;
        end else if (!fetching && (state == RUN || state == CAL) && want_next <= last_sector &&
                     !(slot_ok[want_next[0]] && slot_tag[want_next[0]] == want_next) &&
                     // never evict the sector the next sample needs
                     want_next[0] != (is_wav ? w_addr[9] : c_byte[9])) begin
            sd_lba <= {9'd0, want_next}; sd_rd <= 1; fetching <= 1;
            fetch_slot <= want_next[0]; slot_ok[want_next[0]] <= 0; slot_tag[want_next[0]] <= want_next;
        end

        // ---- parser helper: read hn bytes from hbase into hb[]
        if (hreading && gdone) begin
            hb[hk[3:0]] <= gq;
            if (hk + 5'd1 == hn) hreading <= 0;
            else begin hk <= hk + 5'd1; ga <= hbase + {27'd0, hk} + 32'd1; greq <= 1; end
        end

        // ---- sample clock (only while the deck plays)
        if (state == RUN && play && !at_end) begin
            if (acc + rate_x >= CLK_HZ) begin
                acc <= acc + rate_x - CLK_HZ;
                if (nok) begin
                    level <= nlevel ^ invert; si <= si + 32'd1; nok <= 0; sj <= 0;
                end else if (ended) at_end <= 1;
                else if (underflows != 16'hFFFF) underflows <= underflows + 16'd1;
            end else acc <= acc + rate_x;
        end
        if (!play || state != RUN) level <= 0;     // a stopped deck gives silence

        // ---- state machine
        case (state)
            IDLE, DEAD: ;
            START: if (!fetching) begin
                // first 12 bytes: RIFF....WAVE ?
                if (size >= 32'd12) begin
                    hbase <= 0; hn <= 5'd12; hk <= 0; hreading <= 1; ga <= 0; greq <= 1;
                    state <= RIFF;
                end else begin is_wav <= 0; state <= NEXT; end
            end
            RIFF: if (!hreading && !greq && !gbusy) begin
                if (hb[0] == "R" && hb[1] == "I" && hb[2] == "F" && hb[3] == "F" &&
                    hb[8] == "W" && hb[9] == "A" && hb[10] == "V" && hb[11] == "E") begin
                    is_wav <= 1; p <= 32'd12; chunks <= 0; have_fmt <= 0;
                    hbase <= 32'd12; hn <= 5'd8; hk <= 0; hreading <= 1; ga <= 32'd12; greq <= 1;
                    state <= CHUNK;
                end else begin is_wav <= 0; state <= NEXT; end
            end
            CHUNK: if (!hreading && !greq && !gbusy) begin
                if (id_fmt && !have_fmt) begin
                    next_p <= p + 32'd8 + ck_len + {31'd0, ck_len[0]};   // hb[] is reused for the fmt fields
                    hbase <= p + 32'd8; hn <= 5'd16; hk <= 0; hreading <= 1; ga <= p + 32'd8; greq <= 1;
                    state <= FMT;
                end else if (id_data) begin
                    data_off <= p + 32'd8;
                    data_len <= ck_len > size - (p + 32'd8) ? size - (p + 32'd8) : ck_len;
                    state <= NEXT;
                end else if (chunks == 4'd15 || p + 32'd16 + ck_len >= size) begin
                    state <= DEAD; bad_pulse <= 1;
                end else begin
                    p <= p + 32'd8 + ck_len + {31'd0, ck_len[0]}; chunks <= chunks + 4'd1;
                    hbase <= p + 32'd8 + ck_len + {31'd0, ck_len[0]}; hn <= 5'd8; hk <= 0; hreading <= 1;
                    ga <= p + 32'd8 + ck_len + {31'd0, ck_len[0]}; greq <= 1;
                end
            end
            FMT: if (!hreading && !greq && !gbusy) begin
                wfmt <= {hb[1], hb[0]}; wch <= {hb[3], hb[2]};
                wrate <= le32(hb[4], hb[5], hb[6], hb[7]); wbits <= {hb[15], hb[14]};
                have_fmt <= 1;
                p <= next_p; chunks <= chunks + 4'd1;
                hbase <= next_p; hn <= 5'd8; hk <= 0; hreading <= 1; ga <= next_p; greq <= 1;
                state <= CHUNK;
            end
            NEXT: begin
                // decide the format, set the timebase and length, rewind
                si <= 0; nok <= 0; sj <= 0; ended <= 0; at_end <= 0; acc <= 0; level <= 0;
                c_lead <= 0; c_byte <= 0; c_bit <= 0; c_sub <= 0; c_gap <= 0; c_nul <= 0; c_have <= 0;
                if (!is_wav) begin
                    hz <= 18'd3600; length <= CAS_LEAD + (size << 5) + (size << 4) + 32'd12;  // 48 samples/byte
                    state <= CAL; cal_cnt <= 0; cal_span <= 0; cal_iv <= 0; cal_prev <= 0; cal_seen <= 0;
                end else if (have_fmt && wrate >= 32'd2000 && wrate <= 32'd192000 &&
                             (wch == 16'd1 || wch == 16'd2) &&
                             ((wfmt == 16'd1 && (wbits == 16'd8 || wbits == 16'd16)) ||
                              (wfmt == 16'd3 && wbits == 16'd32))) begin
                    hz <= 18'(wrate);
                    nbytes <= wbits == 16'd8 ? 3'd1 : wbits == 16'd16 ? 3'd2 : 3'd4;
                    fshift <= wbits == 16'd8 ? (wch == 16'd2 ? 2'd1 : 2'd0) :
                              wbits == 16'd16 ? (wch == 16'd2 ? 2'd2 : 2'd1) : (wch == 16'd2 ? 2'd3 : 2'd2);
                    length <= wbits == 16'd8 ? (wch == 16'd2 ? data_len >> 1 : data_len) :
                              wbits == 16'd16 ? (wch == 16'd2 ? data_len >> 2 : data_len >> 1) :
                                                (wch == 16'd2 ? data_len >> 3 : data_len >> 2);
                    state <= CAL; cal_cnt <= 0; cal_span <= 0; cal_iv <= 0; cal_prev <= 0; cal_seen <= 0;
                end else begin
                    state <= DEAD; bad_pulse <= 1;
                end
            end
            CAL: begin
                // consume samples as fast as they are produced (the producer below runs in CAL too)
                if (nok) begin
                    nok <= 0; sj <= 0; si <= si + 32'd1;
                    cal_prev <= nlevel;
                    if (cal_iv != 16'hFFFF) cal_iv <= cal_iv + 16'd1;
                    if (nlevel && !cal_prev) begin
                        cal_iv <= 16'd1;
                        if (cal_seen && iv_ok) begin
                            cal_span <= cal_span + {16'd0, cal_iv}; cal_cnt <= cal_cnt + 10'd1;
                        end else begin
                            cal_span <= 0; cal_cnt <= 0;
                        end
                        cal_seen <= 1;
                    end
                end
                if (cal_finish) begin
                    cal_hz <= cal_cnt != 10'd512 ? hz32 : cal_raw < hz_lo ? hz_lo : cal_raw > hz_hi ? hz_hi : cal_raw;
                    // rewind for play
                    si <= 0; nok <= 0; sj <= 0; ended <= 0; at_end <= 0; acc <= 0; level <= 0;
                    c_lead <= 0; c_byte <= 0; c_bit <= 0; c_sub <= 0; c_gap <= 0; c_nul <= 0; c_have <= 0;
                    state <= RUN; ready_pulse <= 1;
                end
            end
            default: ;
        endcase

        // ---- producer (CAL and RUN): the level of sample si into nlevel/nok
        if ((state == CAL && !cal_stop) || state == RUN) begin
            begin
                // produce the next sample
                if (!nok && !ended && !greq && !gbusy && !gdone) begin
                    if (si >= length) ended <= 1;
                    else if (is_wav) begin
                        ga <= w_addr; greq <= 1;
                    end else begin
                        if (c_lead != CAS_LEAD[9:0]) begin
                            nlevel <= 0; nok <= 1; c_lead <= c_lead + 10'd1;
                        end else if (c_gap != 0) begin
                            nlevel <= 0; nok <= 1; c_gap <= c_gap - 4'd1;
                        end else if (c_byte >= size) begin
                            ended <= 1;
                        end else if (!c_have) begin
                            ga <= c_byte; greq <= 1;
                        end else begin
                            // 1 = 1,0,1,0,1,0   0 = 1,0,1,1,0,0
                            nlevel <= c_val[3'd7 - c_bit] ? !c_sub[0] :
                                      (c_sub == 3'd0 || c_sub == 3'd2 || c_sub == 3'd3);
                            nok <= 1;
                            if (c_sub != 3'd5) c_sub <= c_sub + 3'd1;
                            else begin
                                c_sub <= 0; c_bit <= c_bit + 3'd1;
                                if (c_bit == 3'd7) begin
                                    c_byte <= c_byte + 32'd1; c_have <= 0;
                                    if (!c_nul && c_val == 8'h00) begin c_nul <= 1; c_gap <= 4'd12; end
                                end
                            end
                        end
                    end
                end
                if (gdone && !hreading) begin
                    if (is_wav) begin
                        sb[sj[1:0]] <= gq;
                        if (sj + 3'd1 == nbytes) begin
                            nlevel <= wav_level(sj == 3'd0 ? gq : sb[0], sj == 3'd1 ? gq : sb[1],
                                                sb[2], gq, nbytes, nbytes == 3'd4);
                            nok <= 1;
                        end else sj <= sj + 3'd1;
                    end else begin
                        c_val <= gq; c_have <= 1;
                    end
                end
            end
        end

        // ---- mount / rewind (last: wins over everything above)
        if (img_mounted || (rewind && state != IDLE)) begin
            slot_ok <= 0; gbusy <= 0; greq <= 0; gwait <= 0; hreading <= 0; nok <= 0; level <= 0;
            if (fetching) fetch_abort <= 1;
            if (img_mounted) begin
                size <= img_size > {32'd0, MAX_BYTES} ? MAX_BYTES : img_size[31:0];
                state <= img_size == 0 ? IDLE : START;
                underflows <= 0;
            end else state <= START;
        end
    end
endmodule
