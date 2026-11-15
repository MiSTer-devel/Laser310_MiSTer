//============================================================================
// Laser/VZ floppy controller (DD20 / DI-40 / DSE X-7304) and two drives.
//
// Controller, as MAME bus/vtech/memexp/floppy.cpp:
//   OUT 10h  latch: bits 0-3 stepper phases, bit 4 drive 1 select, bit 7 drive 2
//            select, bit 5 write data (a flux reversal on every change),
//            bit 6 /write request
//   IN 11h   shift register: shifts in the inverted "latching inverter" (a
//            flip-flop toggled by every flux reversal read from the disk), then
//            clears the inverter
//   IN 12h   bit 7 = latching inverter
//   IN 13h   bit 7 = write protect
// The drive is timed in CPU T-states (cpu_tick), so turbo speeds the disk up
// with the CPU. Bit cell = 115 T-states, the VZ DOS write loop (5B90h..: 4B90h
// in the DOS ROM); a 1 bit has a second flux 28 T-states into the cell (MAME
// vt_dsk.cpp: 9187 / 2237 units). Each track is 16 sectors of 154 bytes in the
// DOS's own layout, then an unformatted gap; sectors are interleaved
// 0 B 6 1 C 7 2 D 8 3 E 9 4 F A 5:
//   80 x6, 00, FE E7 18 C3, track, sector, track+sector, 80 x5, 00,
//   C3 18 E7 FE, 128 data bytes, 16-bit sum of the data (low byte first)
// Block RAM keeps only the 128 data bytes per sector (2 x 40 x 16 x 128 =
// 160 KB); the rest is generated, so any .dsk variant (98560, 99184, 99185 ...
// bytes, whatever the gaps) plays the same. Written flux is decoded back to
// bytes: a header (FE E7 18 C3 ...) selects the sector, a data mark
// (C3 18 E7 FE) and 128 bytes replace its data. Without a header in the write
// (normal sector writes) it is the sector whose header just passed the head.
//
// SD side: at mount the image is parsed like MAME vtech_dsk_format::load (find
// the marks, take track/sector from each header); each sector's file offset
// is kept. A written sector is written back in place: its 128 bytes and the
// two checksum bytes, read-modify-write of the 512-byte block(s) holding them,
// so the file keeps its own layout and size. Sectors the file doesn't have are
// kept in memory only.
//============================================================================
module vz_floppy
(
	input             clk,
	input             reset,
	input             enable,          // disk interface fitted (OSD), else ports read FFh

	input             cpu_tick,        // one pulse per CPU T-state
	input       [7:0] cpu_addr,
	input             cpu_iorq_n,
	input             cpu_rd_n,
	input             cpu_wr_n,
	input             cpu_m1_n,
	input       [7:0] cpu_dout,
	output reg  [7:0] io_dout,         // valid while cpu_addr is 10h-13h

	// SD, drives 0 and 1 (hps_io S1/S2)
	input       [1:0] img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg  [1:0] sd_rd,
	output reg  [1:0] sd_wr,
	input       [1:0] sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output reg  [7:0] sd_buff_din,
	input             sd_buff_wr,

	output            activity,        // a drive is selected (LED)
	// status for the sim
	output      [1:0] loaded,
	output      [5:0] track0,
	output      [5:0] track1,
	output reg [15:0] sectors_written
);

localparam CELL   = 7'd115;           // T-states per bit cell
localparam MARK   = 7'd28;            // second flux of a 1 bit
localparam GAP    = 9'd257;           // unformatted bytes after sector 15 (MAME: ~0.2 s revolution at 85 rpm)
localparam W_MARK = 8'd57;            // write decode: a flux sooner than this after the cell start is a 1 mark

function [3:0] smap(input [3:0] s);   // physical slot -> logical sector
	case (s)
		0: smap = 4'h0;  1: smap = 4'hB;  2: smap = 4'h6;  3: smap = 4'h1;
		4: smap = 4'hC;  5: smap = 4'h7;  6: smap = 4'h2;  7: smap = 4'hD;
		8: smap = 4'h8;  9: smap = 4'h3; 10: smap = 4'hE; 11: smap = 4'h9;
		12: smap = 4'h4; 13: smap = 4'hF; 14: smap = 4'hA; default: smap = 4'h5;
	endcase
endfunction

// sector index (drive, track, sector) -> 0..1279, byte address = index*128 + n
function [10:0] sidx(input d, input [5:0] t, input [3:0] s);
	sidx = (d ? 11'd640 : 11'd0) + {1'b0, t, s};
endfunction

// ---------------------------------------------------------------------------
// Sector data RAM: port A = drive engine, port B = SD side
// ---------------------------------------------------------------------------
reg  [17:0] a_addr;  reg [7:0] a_din;  reg a_we;  reg [7:0] a_q;
reg  [17:0] b_addr;  reg [7:0] b_din;  reg b_we;  reg [7:0] b_q;
reg   [7:0] mem[0:163839];
// Quartus true dual-port template (new data on a same-port write)
always @(posedge clk) begin
	if (a_we) begin mem[a_addr] <= a_din; a_q <= a_din; end
	else a_q <= mem[a_addr];
end
always @(posedge clk) begin
	if (b_we) begin mem[b_addr] <= b_din; b_q <= b_din; end
	else b_q <= mem[b_addr];
end

// ---------------------------------------------------------------------------
// Controller and drives
// ---------------------------------------------------------------------------
reg   [7:0] latch;
reg   [7:0] cyl[2];                   // head position in half tracks, per drive (MAME m_current_cyl)
reg   [6:0] ptrk[2];                  // physical track
reg         inv;                      // latching inverter
reg   [7:0] shifter;
reg   [1:0] ready;                    // image loaded
reg   [1:0] wprot;

wire        sel_ok = latch[4] | latch[7];
wire        drv    = ~latch[4];       // drive 1 select wins, as MAME
wire  [6:0] trk    = ptrk[drv];
wire  [5:0] trk6   = trk[5:0];
wire        writing = sel_ok & ~latch[6];

assign activity = enable & sel_ok;
assign loaded   = ready;
assign track0   = ptrk[0][5:0];
assign track1   = ptrk[1][5:0];

// CPU port accesses: one event per IN/OUT
wire io_fdc = enable && cpu_m1_n && !cpu_iorq_n && cpu_addr[7:2] == 6'b000100;
wire wr_now = io_fdc && !cpu_wr_n && cpu_addr[1:0] == 2'd0;
wire rd_now = io_fdc && !cpu_rd_n && cpu_addr[1:0] == 2'd1;
reg  wr_old, rd_old;
wire wr_ev = wr_now & ~wr_old;
wire rd11_ev = rd_now & ~rd_old;

always @(*) begin
	case (cpu_addr[1:0])
		2'd1:    io_dout = shifter;
		2'd2:    io_dout = {inv, 7'd0};
		2'd3:    io_dout = {sel_ok ? wprot[drv] : 1'b0, 7'd0};
		default: io_dout = 8'hFF;
	endcase
end

// rotation: cell T-state, bit, byte within sector (or gap), sector slot
reg   [6:0] ct;
reg   [2:0] bc;
reg   [8:0] idx;
reg   [4:0] slot;                     // 0-15 sectors, 16 gap
reg   [7:0] cur;                      // byte under the head
reg  [15:0] chk;                      // running data sum of the current sector
reg   [3:0] last_sid;                 // sector whose header last passed the head
reg         last_ok;

wire        in_gap = slot[4];
wire  [3:0] sid    = smap(slot[3:0]);
wire        rd_on  = enable & sel_ok & ~writing & ready[drv] & (trk < 7'd40);

// next byte position
wire        nb_wrap  = in_gap ? (idx == GAP - 9'd1) : (idx == 9'd153);
wire  [8:0] n_idx    = nb_wrap ? 9'd0 : idx + 9'd1;
wire  [4:0] n_slot   = !nb_wrap ? slot : in_gap ? 5'd0 : slot + 5'd1;
wire  [3:0] n_sid    = smap(n_slot[3:0]);
wire  [7:0] n_trk8   = {1'b0, trk};
wire  [8:0] n_di     = n_idx - 9'd24;     // data byte index
wire [15:0] chk_n    = chk + {8'd0, cur}; // sum including the byte under the head
wire  [7:0] n_sid8   = {4'b0, n_sid};

// value of the next byte (data from RAM, a_q addressed with the next position)
reg   [7:0] n_val;
always @(*) begin
	case (n_idx)
		9'd6, 9'd19:   n_val = 8'h00;
		9'd7, 9'd23:   n_val = 8'hFE;
		9'd8, 9'd22:   n_val = 8'hE7;
		9'd9, 9'd21:   n_val = 8'h18;
		9'd10, 9'd20:  n_val = 8'hC3;
		9'd11:         n_val = n_trk8;
		9'd12:         n_val = n_sid8;
		9'd13:         n_val = n_trk8 + n_sid8;
		9'd152:        n_val = chk_n[7:0];
		9'd153:        n_val = chk[15:8];
		default:       n_val = (n_idx >= 9'd24 && n_idx < 9'd152) ? a_q : 8'h80;
	endcase
end

// write decoder
reg   [7:0] wtick;
reg         w_have, w_mark;
reg   [7:0] w_sh;
reg   [2:0] w_nb;
reg  [39:0] w_win;                    // last 5 bytes written
reg   [1:0] p_state;                  // 0 idle, 1 header, 2 data
reg   [7:0] p_cnt;
reg   [7:0] p_trk, p_sid;
reg   [3:0] dest;  reg dest_ok;
reg         dset;  reg [10:0] dset_idx;   // to the SD side: sector written

localparam P_IDLE = 2'd0, P_HDR = 2'd1, P_DATA = 2'd2;

// one decoded bit -> byte -> marks/sector data
task automatic w_bit(input b);
	reg [7:0] byt;
	begin
		byt = {w_sh[6:0], b};
		w_sh <= byt;
		w_nb <= w_nb + 3'd1;
		if (w_nb == 3'd7) begin
			w_win <= {w_win[31:0], byt};
			case (p_state)
				P_IDLE:
					if ({w_win[31:0], byt} == 40'h00FEE718C3) begin p_state <= P_HDR; p_cnt <= 0; end
					else if ({w_win[31:0], byt} == 40'h00C318E7FE && dest_ok) begin p_state <= P_DATA; p_cnt <= 0; end
				P_HDR: begin
					p_cnt <= p_cnt + 8'd1;
					if (p_cnt == 0) p_trk <= byt;
					if (p_cnt == 1) p_sid <= byt;
					if (p_cnt == 2) begin
						p_state <= P_IDLE;
						if (byt == p_trk + p_sid) begin dest <= p_sid[3:0]; dest_ok <= 1; end
					end
				end
				P_DATA: begin
					p_cnt <= p_cnt + 8'd1;
					if (!wprot[drv] && trk < 7'd40) begin
						a_addr <= {sidx(drv, trk6, dest), p_cnt[6:0]};
						a_din  <= byt;
						a_we   <= 1;
					end
					if (p_cnt == 8'd127) begin
						p_state <= P_IDLE;
						if (!wprot[drv] && trk < 7'd40) begin
							dset <= 1; dset_idx <= sidx(drv, trk6, dest);
							sectors_written <= sectors_written + 16'd1;
						end
					end
				end
				default: p_state <= P_IDLE;
			endcase
		end
	end
endtask

// stepper (MAME latch_w): phases are bits 0-3, half-track position in cyl
function [7:0] step(input [7:0] c, input [3:0] ph);
	reg [1:0] cph;  reg [7:0] cn;
	begin
		cph = c[1:0];
		cn = c;
		if (!ph[cph]) begin
			if (cn < 8'd168 && ph[cph + 2'd1]) cn = cn + 8'd1;
			if (cn != 0     && ph[cph + 2'd3]) cn = cn - 8'd1;
		end
		step = cn;
	end
endfunction

wire  [7:0] c0  = (latch[4])              ? cyl[0] : {ptrk[0], 1'b0};
wire  [7:0] c1  = (!latch[4] && latch[7])  ? cyl[1] : {ptrk[1], 1'b0};
wire  [7:0] st0 = step(c0, cpu_dout[3:0]);
wire  [7:0] st1 = step(c1, cpu_dout[3:0]);

always @(posedge clk) begin
	wr_old <= wr_now;
	rd_old <= rd_now;
	a_we   <= 0;
	dset   <= 0;

	if (reset) begin
		latch <= 8'h40;  inv <= 0;  shifter <= 0;
		cyl[0] <= 0;  cyl[1] <= 0;  ptrk[0] <= 0;  ptrk[1] <= 0;
		ct <= 0;  bc <= 0;  idx <= 0;  slot <= 0;  cur <= 8'h80;  chk <= 0;  last_ok <= 0;
		w_have <= 0;  p_state <= P_IDLE;  dest_ok <= 0;
		sectors_written <= 0;
	end else begin
		// ---- rotation and read flux
		if (cpu_tick) begin
			if (wtick != 8'hFF) wtick <= wtick + 8'd1;
			if (ct == CELL - 7'd1) begin
				ct <= 0;
				bc <= bc + 3'd1;
				if (bc == 3'd7) begin
					idx  <= n_idx;
					slot <= n_slot;
					cur  <= n_val;
					if (n_idx == 9'd24) chk <= 0;
					else if (n_idx > 9'd24 && n_idx <= 9'd152 && !n_slot[4]) chk <= chk + {8'd0, cur};
					if (n_idx == 9'd14 && !n_slot[4]) begin last_sid <= smap(n_slot[3:0]); last_ok <= 1; end
					if (n_slot[4]) last_ok <= 0;
				end
			end else
				ct <= ct + 7'd1;

			// flux: every cell start, and 28 T-states in for a 1
			if (rd_on && !in_gap && (ct == 0 || (ct == MARK && cur[3'd7 - bc]))) inv <= ~inv;
		end
		// RAM address for the next byte's data (engine reads; writes below take over for one clock)
		a_addr <= {sidx(drv, trk6, n_sid), n_di[6:0]};

		// ---- IN 11h: shift in the inverted inverter, clear it
		if (rd11_ev) begin
`ifdef VZ_FDC_DEBUG
			$display("FDC rd11 inv %d shifter %02x cur %02x bc %d ct %d idx %d slot %d rd_on %d", inv, {shifter[6:0], ~inv}, cur, bc, ct, idx, slot, rd_on);
`endif
			shifter <= {shifter[6:0], ~inv};
			inv <= 0;
		end

		// ---- OUT 10h
		if (wr_ev) begin
			latch <= cpu_dout;
			// the selected drive steps; a newly selected drive starts from its
			// track (MAME: m_current_cyl = get_cyl() << 1)
			if (cpu_dout[4]) begin
				cyl[0] <= st0;
				if (st0 != c0 && !st0[0]) ptrk[0] <= st0[7:1];
			end else if (cpu_dout[7]) begin
				cyl[1] <= st1;
				if (st1 != c1 && !st1[0]) ptrk[1] <= st1[7:1];
			end
			// write gate on: start decoding; target = sector under the head
			if (latch[6] && !cpu_dout[6]) begin
				w_have <= 0;  w_nb <= 0;  w_win <= 0;  p_state <= P_IDLE;
				dest <= last_sid;  dest_ok <= last_ok;
			end
			// flux written
			if (!cpu_dout[6] && !latch[6] && (cpu_dout[5] ^ latch[5])) begin
				if (w_have && wtick < W_MARK)
					w_mark <= 1;
				else begin
					if (w_have) w_bit(w_mark);
					w_have <= 1;  w_mark <= 0;  wtick <= 0;
				end
			end
			// write gate off: the last cell
			if (!latch[6] && cpu_dout[6] && w_have) begin
				w_bit(w_mark);
				w_have <= 0;
			end
		end
	end
end

// ---------------------------------------------------------------------------
// SD side: mount (parse the image), write back written sectors
// ---------------------------------------------------------------------------
reg  [18:0] offs[0:1279];             // file offset of each sector's data, bit 18 = present
reg  [10:0] o_addr;  reg [18:0] o_din;  reg o_we;  reg [18:0] o_q;
always @(posedge clk) begin
	if (o_we) offs[o_addr] <= o_din;
	o_q <= offs[o_addr];
end

reg   [7:0] blk[0:511];               // one SD block for write-back
reg   [8:0] k_addr;  reg [7:0] k_din;  reg k_we;
always @(posedge clk) begin
	if (k_we) blk[k_addr] <= k_din;
	sd_buff_din <= blk[sd_buff_addr];
end

reg [1279:0] dirty;
reg   [1:0] mnt_req;
reg  [17:0] mnt_size[2];
reg   [1:0] mnt_ro;

localparam S_IDLE = 4'd0, S_CLEAR = 4'd1, S_LREAD = 4'd2, S_LWAIT = 4'd3, S_LNEXT = 4'd4,
           S_WSCAN = 4'd5, S_WOFF = 4'd6, S_WREAD = 4'd7, S_WRWAIT = 4'd8, S_WPATCH = 4'd9,
           S_WPATCH2 = 4'd10, S_WWRITE = 4'd11, S_WWWAIT = 4'd12, S_WOFF0 = 4'd13;
reg   [3:0] s;
reg         sd;                       // drive being served
reg  [17:0] cnt;
reg  [17:0] fsize;
reg   [8:0] lba;
reg  [39:0] l_win;
reg   [1:0] l_mode;                   // 0 idle, 1 header, 2 look for data, 3 data
reg   [7:0] l_cnt;
reg   [7:0] l_trk;
reg  [10:0] l_sec;
reg  [10:0] scan;
reg  [17:0] w_off;
reg   [7:0] w_i;
reg  [15:0] w_sum;
reg         w_second;
reg         ack_old;

wire [17:0] fpos = {lba, sd_buff_addr};
wire        md   = !mnt_req[0];          // drive to mount next

always @(posedge clk) begin
	b_we <= 0;  o_we <= 0;  k_we <= 0;
	if (dset) dirty[dset_idx] <= 1;

	if (img_mounted[0]) begin mnt_req[0] <= 1; mnt_size[0] <= |img_size[63:18] ? 18'h3FFFF : img_size[17:0]; mnt_ro[0] <= img_readonly; end
	if (img_mounted[1]) begin mnt_req[1] <= 1; mnt_size[1] <= |img_size[63:18] ? 18'h3FFFF : img_size[17:0]; mnt_ro[1] <= img_readonly; end


	case (s)
	S_IDLE: begin
		sd_rd <= 0;  sd_wr <= 0;
		if (mnt_req[0] | mnt_req[1]) begin
			sd <= md;
			mnt_req[md] <= 0;
			ready[md] <= 0;
			fsize <= mnt_size[md];
			wprot[md] <= mnt_ro[md];
			cnt <= 0;
			s <= S_CLEAR;
		end else if (|dirty) begin
			scan <= 0;
			s <= S_WSCAN;
		end
	end

	// zero the drive's sectors and offsets, then read the file
	S_CLEAR: begin
		b_addr <= {sidx(sd, 6'd0, 4'd0), 7'd0} + cnt;  b_din <= 0;  b_we <= 1;
		if (cnt < 18'd640) begin o_addr <= sidx(sd, 6'd0, 4'd0) + cnt[10:0]; o_din <= 0; o_we <= 1; end
		if (cnt < 18'd640) dirty[sidx(sd, 6'd0, 4'd0) + cnt[10:0]] <= 0;
		cnt <= cnt + 18'd1;
		if (cnt == 18'd81919) begin
			lba <= 0;  l_mode <= 0;  l_win <= 0;
			s <= (fsize == 0) ? S_IDLE : S_LREAD;   // size 0 = ejected
		end
	end
	S_LREAD: begin
		sd_lba <= {23'd0, lba};
		sd_rd[sd] <= 1;
		if (sd_ack[sd]) begin sd_rd <= 0; s <= S_LWAIT; end
	end
	S_LWAIT: begin
		// parse each byte as it arrives (MAME vtech_dsk_format::load)
		if (sd_buff_wr && sd_ack[sd] && fpos < fsize) begin
			l_win <= {l_win[31:0], sd_buff_dout};
			case (l_mode)
			2'd0: if ({l_win[31:0], sd_buff_dout} == 40'h00FEE718C3) begin l_mode <= 1; l_cnt <= 0; end
			2'd1: begin
				l_cnt <= l_cnt + 8'd1;
				if (l_cnt == 0) l_trk <= sd_buff_dout;
				if (l_cnt == 1) l_sec <= sidx(sd, l_trk[5:0], sd_buff_dout[3:0]);
				if (l_cnt == 2) l_mode <= (sd_buff_dout == l_trk + l_win[7:0] && l_trk < 8'd40) ? 2'd2 : 2'd0;
			end
			2'd2: if ({l_win[31:0], sd_buff_dout} == 40'h00FEE718C3) begin l_mode <= 1; l_cnt <= 0; end
			      else if ({l_win[31:0], sd_buff_dout} == 40'h00C318E7FE) begin
					l_mode <= 3;  l_cnt <= 0;
					o_addr <= l_sec;  o_din <= {1'b1, fpos + 18'd1};  o_we <= 1;
			      end
			2'd3: begin
				b_addr <= {l_sec, l_cnt[6:0]};  b_din <= sd_buff_dout;  b_we <= 1;
				l_cnt <= l_cnt + 8'd1;
				if (l_cnt == 8'd127) l_mode <= 0;
			end
			endcase
		end
		if (!sd_ack[sd]) s <= S_LNEXT;
	end
	S_LNEXT: begin
		if ({lba + 9'd1, 9'd0} >= fsize || lba == 9'h1FF) begin
			ready[sd] <= 1;
			s <= S_IDLE;
		end else begin
			lba <= lba + 9'd1;
			s <= S_LREAD;
		end
	end

	// write-back: first dirty sector
	S_WSCAN: begin
		if (dirty[scan]) begin
			dirty[scan] <= 0;           // cleared now: a write during the write-back marks it again
			sd <= (scan >= 11'd640);
			o_addr <= scan;
			l_sec <= scan;
			s <= S_WOFF0;
		end else if (scan == 11'd1279) s <= S_IDLE;
		else scan <= scan + 11'd1;
	end
	S_WOFF0: s <= S_WOFF;               // o_q follows o_addr
	S_WOFF: begin
		if (!o_q[18] || !ready[sd]) s <= S_IDLE;   // not in the file: memory only
		else begin
			w_off <= o_q[17:0];
			lba <= o_q[17:9];
			w_second <= 0;
			s <= S_WREAD;
		end
	end
	S_WREAD: begin
		sd_lba <= {23'd0, lba};
		sd_rd[sd] <= 1;
		if (sd_ack[sd]) begin sd_rd <= 0; s <= S_WRWAIT; end
	end
	S_WRWAIT: begin
		if (sd_buff_wr && sd_ack[sd]) begin k_addr <= sd_buff_addr; k_din <= sd_buff_dout; k_we <= 1; end
		if (!sd_ack[sd]) begin w_i <= 0; w_sum <= 0; b_addr <= {l_sec, 7'd0}; s <= S_WPATCH; end
	end
	S_WPATCH: s <= S_WPATCH2;           // b_q follows b_addr
	S_WPATCH2: begin
		// byte w_i of the sector record (128 data + 2 checksum) at file offset w_off + w_i
		if ((w_off + w_i) >> 9 == {9'd0, lba}) begin
			k_addr <= w_off[8:0] + w_i;
			k_din  <= w_i < 8'd128 ? b_q : w_i == 8'd128 ? w_sum[7:0] : w_sum[15:8];
			k_we   <= 1;
		end
		if (w_i < 8'd128) w_sum <= w_sum + {8'd0, b_q};
		w_i <= w_i + 8'd1;
		b_addr <= {l_sec, w_i[6:0] + 7'd1};
		if (w_i == 8'd129) s <= S_WWRITE;
		else s <= S_WPATCH;
	end
	S_WWRITE: begin
		sd_lba <= {23'd0, lba};
		sd_wr[sd] <= 1;
		if (sd_ack[sd]) begin sd_wr <= 0; s <= S_WWWAIT; end
	end
	S_WWWAIT: if (!sd_ack[sd]) begin
		// the record may run into the next block
		if (!w_second && ((w_off + 18'd129) >> 9) != {9'd0, lba}) begin
			w_second <= 1;
			lba <= lba + 9'd1;
			s <= S_WREAD;
		end else
			s <= S_IDLE;
	end
	default: s <= S_IDLE;
	endcase

	// not reset by the CPU reset: the disks stay mounted
end

endmodule
