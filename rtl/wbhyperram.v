////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	rtl/wbhyperram.v
//
// Project:	WB-HyperRAM, a wishbone controller for a hyperRAM interface
//
// Purpose:	Provides a WB interface to a HyperRAM chip, such as the
// 		S27KL0641, S27KS0641, S70KL1281, or S70KS1281 chips from
// 	Cypress.  The controller is designed for 100MHz operation, and to
// 	use DDR I/O (external to this module).  Hence the 8-bit data interface
// 	requires 16-data bits, and the 1-bit RWDS interface requires two bits.
// 	The 90-degree offset clock is assumed to be provided from elsewhere. 
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2018-2019, Gisselquist Technology, LLC
//
// This file is part of the WB-HyperRAM controller project.
//
// The WB-HyperRAM controller project is free software (firmware): you can
// redistribute it and/or modify it under the terms of the GNU Lesser General
// Public License as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// The WB-HyperRAM controller project is distributed in the hope that it will
// be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTIBILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser
// General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with this program.  (It's in the $(ROOT)/doc directory.  Run make
// with no target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	LGPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/lgpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype none
//
module wbhyperram(i_clk, i_reset,
		i_wb_cyc, i_wb_stb, i_wb_we, i_wb_addr, i_wb_data, i_wb_sel,
			o_wb_stall, o_wb_ack, o_wb_data,
		o_hram_reset_n, o_hram_cke, o_hram_csn,
		o_hram_rwctrl, o_hram_rwds, i_hram_rwds,
		o_hram_drive_data, o_hram_data, i_hram_data,
		//
		o_dbg_trigger, o_debug);
	localparam	DEFAULT_LATENCY_COUNT = 6;
	parameter	AW= 23-2; // 8MB
	parameter	CLOCK_RATE_HZ = 100_000_000;
	//
	// If we exploit WB/B4/pipeline, then we can allow a second request
	// before the first has been completed.  If this second request
	// direction remains unchanged, and if the address is for the next
	// address in memory, then we can keep the operation going and only
	// require two additional clocks per access, rather than starting up
	// all over again.
	parameter [0:0]	OPT_PIPE  = 1'b1;
	//
	// Many vendor I/O DDR primitives will have a delay associated with
	// them.  This delay extends from the time a value leaves our
	// design until it returns to our design.  We are not concerned with
	// delays on outputs--they can all be delayed the same by the vendor
	// primitives, but we do need to know about how long it takes to
	// the return path to come back to us, as in the delay between the
	// values set here and the values returned.
	//
	// For Xilinx, this number should be 3
	// For Altera, with registered I/O, this number should be 2
	parameter	RDDELAY = 0;
	//
`ifdef	FORMAL
	//
	// In order to cover various parts of this design, we'll modify
	// the design subtly to allow (for example) the reset cycle to
	// complete earlier.  Only used in FORMAL mode, and only if
	// F_OPT_COVER is set.
	parameter [0:0]	F_OPT_COVER = 1'b0;
`endif
	//
	localparam [0:0] RWDS_IN = 1'b0,
			RWDS_OUT = 1'b1;

	localparam	DW = 32;
	localparam	MIN_LATENCY_COUNT = (CLOCK_RATE_HZ <= 83_000_000) ? 3
			: (CLOCK_RATE_HZ <= 100_000_000) ? 4
			: (CLOCK_RATE_HZ <= 133_000_000) ? 5 : 6;
	localparam	CLOCK_PERIOD_NS = 1000_000_000 / CLOCK_RATE_HZ;
	localparam	
`ifdef	FORMAL
			CK_VCS= (F_OPT_COVER) ? 12 :(150_000 / CLOCK_PERIOD_NS),
			CK_RP = (F_OPT_COVER) ? 6
				: ((200+CLOCK_PERIOD_NS-1)/CLOCK_PERIOD_NS),
			// Maximum time CS# can be active
			CK_CSM = (F_OPT_COVER) ? 50 : (4_000 / CLOCK_PERIOD_NS);
`else
			CK_VCS = 150_000 / CLOCK_PERIOD_NS,
			// Minimum reset pulse width
			CK_RP = ((200+CLOCK_PERIOD_NS-1)/CLOCK_PERIOD_NS),
			// Maximum time CS# can be active
			CK_CSM = 4_000 / CLOCK_PERIOD_NS;
`endif
	// localparam	CK_RWR_STALL = (CK_RWR>3) ? (CK_RWR-3) : 0;
	//
	// I really need to learn to use $clog2
	localparam	CSM_BITS = (CK_CSM > 255) ? 9
				: ((CK_CSM > 127) ? 8
				: ((CK_CSM > 63) ? 7
				: ((CK_CSM > 31) ? 6 : 5))),
			VCS_BITS = (CK_VCS > 32767) ? 16
				: ((CK_VCS > 16383) ? 15
				: ((CK_VCS >  8191) ? 14
				: ((CK_VCS >  4095) ? 13
				: ((CK_VCS >  2047) ? 12
				: ((CK_VCS >  1023) ? 11
				: ((CK_VCS >   511) ? 10
				: ((CK_VCS >   255) ?  9
				: ((CK_VCS >   127) ?  8
				: ((CK_VCS >    63) ?  7
				: ((CK_VCS >    31) ? 6 : 5)))))))))),
			RP_BITS = 5;
	input	wire	i_clk, i_reset;
	//
	// WB interface
	input	wire	i_wb_cyc, i_wb_stb, i_wb_we;
	input	wire	[AW:0]		i_wb_addr; // Top bit selects dev regs
	input	wire	[DW-1:0]	i_wb_data;
	input	wire	[DW/8-1:0]	i_wb_sel;
	//
	output	reg			o_wb_stall, o_wb_ack;
	output	reg	[DW-1:0]	o_wb_data;
	//
	// HyperRAM interface
	output	reg		o_hram_reset_n, o_hram_cke, o_hram_csn;
	output	reg		o_hram_rwctrl;
	output	reg	[1:0]	o_hram_rwds;
	input	wire	[1:0]	i_hram_rwds;
	output	reg		o_hram_drive_data;
	output	reg	[15:0]	o_hram_data;
	input	wire	[15:0]	i_hram_data;
	//
	// Debug port
	output	reg		o_dbg_trigger;
	output	reg	[31:0]	o_debug;

	reg	[2:0]	latency;
	reg		fixed_latency;
	reg	[47:0]	cmd_reg;
	reg	[31:0]	data_reg;
	reg	[3:0]	data_mask;
	reg		pre_ack;
	//
	reg	[3:0]	state_ctr;
	// verilator lint_off UNUSED
	wire		write_stb, read_stb;
	// verilator lint_on  UNUSED
	reg	[1:0]	cmd_ctr;
	reg		last_cke;

	reg	cmd_output, pipe_req;
	wire	dev_addr, mem_addr, start_stb,
			pipe_stb, bus_stb;
	reg	cti_dev, cti_write;	// Cycle type indication


	//
	//
	assign	dev_addr  = !i_wb_addr[AW];
	assign	mem_addr  =  i_wb_addr[AW];
	assign	bus_stb   = (i_wb_stb)&&(!o_wb_stall);
	assign	start_stb = (bus_stb)&&( o_hram_csn);
	assign	pipe_stb  = (bus_stb)&&(pipe_req);
	assign	read_stb  = (bus_stb)&&(!i_wb_we);
	assign	write_stb = (bus_stb)&&( i_wb_we);


	reg	[CSM_BITS-1:0]	chip_select_count;
	reg			chip_select_warning;

	/////////////////////////////////////////////////////////////
	//
	// Handle device reset
	//
	//
	reg	[RP_BITS-1:0]	reset_low_counter;
	reg	[VCS_BITS-1:0]	reset_recovery;
	reg			maintenance_stall;

	initial	reset_low_counter = CK_RP[RP_BITS-1:0];
	always @(posedge i_clk)
	if (i_reset)
		reset_low_counter <= CK_RP[RP_BITS-1:0];
	else if (reset_low_counter > 0)
		reset_low_counter <= reset_low_counter - 1'b1;

	initial	o_hram_reset_n = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_hram_reset_n <= 1'b0;
	else
		o_hram_reset_n <= (reset_low_counter == 0);

	initial	reset_recovery = CK_VCS[VCS_BITS-1:0];
	always @(posedge i_clk)
	if (!o_hram_reset_n)
		reset_recovery <= CK_VCS[VCS_BITS-1:0];
	else if (reset_recovery > 0)
		reset_recovery <= reset_recovery - 1'b1;

	initial	maintenance_stall = 1'b1;
	always @(posedge i_clk)
	if ((i_reset)||(!o_hram_reset_n))
		maintenance_stall <= 1'b1;
	else if (reset_recovery > 0)
		maintenance_stall <= 1'b1;
	else
		maintenance_stall <= 1'b0;

		

	/////////////////////////////////////////////////////////////
	//
	// Recognize ongoing transactions for the next word
	//
	//
	generate if (OPT_PIPE)
	begin : PIPED_REQUESTS
		reg	[AW-1:0]	next_addr;

		initial	chip_select_count = 0;
		always @(posedge i_clk)
		if (o_hram_csn)
			chip_select_count <= 0;
		else
			chip_select_count <= chip_select_count + 1'b1;

		always @(posedge i_clk)
		if (o_hram_csn)
			chip_select_warning <= 1'b0;
		else
			chip_select_warning
				<= (chip_select_count > CK_CSM[CSM_BITS-1:0]-9);

		always @(posedge i_clk)
		if (bus_stb)
			next_addr <= i_wb_addr[AW-1:0] + 1'b1;

		initial	pipe_req = 1'b0;
		always @(posedge i_clk)
			pipe_req <= (i_wb_stb)&&(o_wb_stall)
				// &&(!o_hram_csn)
				&&(!chip_select_warning)
				&&(i_wb_we == cti_write)
				&&(mem_addr)&&(!cti_dev)
				&&(!cmd_output)&&(state_ctr == 2)
				&&(pre_ack)
				&&((cti_write)||(i_hram_rwds[1]))
				&&(i_wb_addr[AW-1:0] == next_addr);

	end else begin : NO_PIPE

		always @(*)
		begin
			chip_select_count   = 0;
			chip_select_warning = 0;
			pipe_req = 0;
		end

		// Verilator lint_off UNUSED
		wire	[CSM_BITS-1:0]	unused_pipe;
		assign	unused_pipe = chip_select_count;
		// Verilator lint_on UNUSED

	end endgenerate

	initial { cti_dev, cti_write } <= 2'b01;
	always @(posedge i_clk)
	if (start_stb)
		{ cti_dev, cti_write } <= { dev_addr, i_wb_we };
	else if ((!o_hram_cke)||(last_cke))
		{ cti_dev, cti_write } <= 2'b01;

	initial	o_hram_csn = 1'b1;
	always @(posedge i_clk)
	if (i_reset)
		o_hram_csn <= 1'b1;
	else if ((bus_stb)||(cmd_output))
		o_hram_csn <= 1'b0;
	else if (last_cke)
		o_hram_csn <= 1'b1;

	always @(*)
		o_hram_cke = !o_hram_csn;


	//
	//
	//
	//

	//////////////////////////
	//
	// o_wb_stall
	//
	reg	r_stall;
	initial	r_stall = 1'b1;
	always @(posedge i_clk)
	if ((i_reset)||(maintenance_stall))
		r_stall <= 1'b1;
	else if (chip_select_warning)
		r_stall <= 1'b1;
	else if (bus_stb)
		r_stall <= 1'b1;
	else if ((cmd_ctr>0)||(state_ctr > 1))
		r_stall <= 1'b1;
	else if (last_cke)
		r_stall <= 1'b0;
	else
		r_stall <= (o_hram_cke);

	always @(*)
		o_wb_stall = (r_stall)&&((!OPT_PIPE)||(!pipe_req)
					||((!cti_write)&&(!i_hram_rwds[1])));

	//////////////////////////
	//
	// Command register output
	//
	initial	cmd_ctr = 0;
	initial	cmd_output = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
	begin
		cmd_ctr    <= 0;
		cmd_output <= 0;
	end else if (start_stb)
	begin
		cmd_ctr <= 3;
		cmd_output <= 1'b1;
	end else if (cmd_ctr != 0)
	begin
		cmd_ctr <= cmd_ctr - 1'b1;
		cmd_output <= (cmd_ctr > 1);
	end

	// Command data output
	//
	always @(posedge i_clk)
	if (bus_stb)
		cmd_reg <= { (!i_wb_we), dev_addr, 1'b1,
			{ {(29-(AW-2)){1'b0}}, i_wb_addr[AW-1:2] },
			13'h0, i_wb_addr[1:0], 1'b0 };
	else
		cmd_reg <= { cmd_reg[31:0], 16'h00 };

	reg	latency_stb;
	generate if (RDDELAY <= 2)
	begin
		always @(*)
			latency_stb = 0;
	end else begin
		reg	latency_pipe[RDDELAY-1:0];

		initial	latency_pipe = 0;
		always @(posedge i_clk)
		if (i_wb_stb && !o_wb_stall && i_hram_csn && !fixed_latency)
			latency_pipe <= 1;
		else
			latency_pipe <= latency_pipe << 1;

		always @(*)
			latency_stb = latency_pipe[RDDELAY-1];
	end endgenerate
	//////////////////////////
	//
	// Read/write state counter output
	//
	//
	initial	state_ctr = 0;
	always @(posedge i_clk)
	if (i_reset)
		state_ctr <= 0;
	else if (start_stb)
		state_ctr <= 1;
	else if (cmd_output)
	begin
		casez({((i_hram_rwds[0]&&(RDDELAY<=2))||fixed_latency), cti_dev, cti_write})
		3'b0?0: state_ctr <= 1 + { 1'b0, latency };
		3'b001: state_ctr <= 1 + { 1'b0, latency };
		3'b?11: state_ctr <= 1;
		3'b1?0: state_ctr <= 1 + { latency, 1'b0 };
		3'b101: state_ctr <= 1 + { latency, 1'b0 };
		default: state_ctr <= 1;
		endcase
	end else if (latency_stb && i_hram_rwds[0])
		state_ctr <= state_ctr + latency - 1'b1;
	else if (pipe_stb)
		state_ctr <= 2;
	else if (state_ctr > 2)
		state_ctr <= state_ctr - 1'b1;
	else if ((state_ctr > 0)&&((cti_write)||(i_hram_rwds == 2'b10)))
		state_ctr <= state_ctr - 1'b1;

	reg	write_data_shift;
	always @(posedge i_clk)
		write_data_shift <= (!o_hram_csn)&&(state_ctr <= 3)
			&&(!cmd_output)&&(cti_write);

	always @(posedge i_clk)
	if (bus_stb)
	begin
		data_reg  <= i_wb_data;
		data_mask <= i_wb_sel;
		if (dev_addr)
			data_reg[31:16] <= i_wb_data[15:0];
	end else if (write_data_shift)
	begin
		data_reg  <= { data_reg[15:0], 16'h0 };
		data_mask <= { data_mask[1:0], 2'b00 };
	end

	reg	cfg_write;
	always @(posedge i_clk)
	if ((start_stb)&&(dev_addr)&&(i_wb_we)&&(i_wb_addr[AW-1:0]==0))
		cfg_write <= 1'b1;
	else if (bus_stb)
		cfg_write <= 1'b0;
	else if (!o_hram_cke)
		cfg_write <= 1'b0;

	initial latency = DEFAULT_LATENCY_COUNT;
	initial fixed_latency = 1'b1;
	always @(posedge i_clk)
	if (!o_hram_reset_n)
	begin
		latency <= DEFAULT_LATENCY_COUNT;
		fixed_latency <= 1'b1;
	end else if ((!o_hram_csn)&&(!cmd_output)&&(cfg_write))
	begin
		latency <= DEFAULT_LATENCY_COUNT;
		fixed_latency <= 1'b1;
		//
		case(data_reg[7:4])
		4'h0: latency <= 5;
		4'h1: latency <= 6;
		4'he: latency <= 3;
		4'hf: latency <= 4;
		default: latency <= 6;
		endcase

		if (AW <= 22)
			fixed_latency <= data_reg[3];
	end

	initial	o_hram_drive_data = 1'b1;
	always @(posedge i_clk)
	if (i_reset)
		o_hram_drive_data <= 1'b1;
	else if ((start_stb)||(cmd_output))
		o_hram_drive_data <= 1'b1;
	else if (cti_write) // Any write operation
		o_hram_drive_data <= 1'b1;
	else if (state_ctr>1) //  Pipelined read operation
		o_hram_drive_data <= 1'b0;
	else if ((!o_hram_csn)&&(i_hram_rwds != 2'b10)) // Read operation
		o_hram_drive_data <= 1'b0;
	else
		// Bus cycle is over
		o_hram_drive_data <= 1'b1;

	reg	[4-1:0] block_ack_count;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc)||(start_stb))
		block_ack_count <= 3+RDDELAY;
	else if (block_ack_count > 0)
		block_ack_count <= block_ack_count -1;

	reg	block_ack;

	initial	block_ack = 1'b1;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc)||(start_stb))
		block_ack <= 1'b1;
	else if (block_ack_count > 0)
		block_ack <= 1'b1;
	else
		block_ack <= 1'b0;

	initial	pre_ack = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc))
		pre_ack <= 1'b0;
	else if ((i_wb_stb)&&(!o_wb_stall))
		pre_ack <= 1'b1;

	initial	o_wb_ack = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(!i_wb_cyc))
		o_wb_ack <= 1'b0;
	else if (cti_write)
		o_wb_ack <= (pre_ack)&&(!cmd_output)&&(state_ctr == 1);
	else
		o_wb_ack <= (pre_ack)&&(!block_ack)&&(o_hram_rwctrl != RWDS_OUT)
				&&(i_hram_rwds==2'b10)&&(state_ctr == 1);

	always @(*)
	if (cmd_output)
		o_hram_data = cmd_reg[47:32];
	else
		o_hram_data = data_reg[31:16];

	//
	// Control the direction of the rwds signal
	//
	initial	o_hram_rwctrl = RWDS_OUT;
	always @(posedge i_clk)
	if ((i_reset)||(!o_hram_reset_n))
		o_hram_rwctrl <= RWDS_OUT;
	else if ((start_stb)||(cmd_output))
		o_hram_rwctrl <= RWDS_IN;
	else if (last_cke)
		o_hram_rwctrl <= RWDS_OUT;
	else if (cti_dev)
		o_hram_rwctrl <= RWDS_IN;
	else if ((cti_write)||(o_hram_csn))
		o_hram_rwctrl <= RWDS_OUT;
	else
		o_hram_rwctrl <= RWDS_IN;

	always @(*)
		o_hram_rwds = (write_data_shift) ? (~data_mask[3:2]) : (2'b00);

	always @(*)
		last_cke = (o_hram_cke)&&(!cmd_output)
				&&(state_ctr == 1)
				&&((cti_write)||(i_hram_rwds[1]))
				&&((o_wb_stall)||(!i_wb_stb));

	always @(posedge i_clk)
	if ((o_hram_cke)&&(i_hram_rwds == 2'b10))
		o_wb_data <= { o_wb_data[15:0], i_hram_data };

	always @(posedge i_clk)
	if ((!o_hram_csn)||((i_wb_stb)&&(!o_wb_stall)))
		o_debug <= { 1'b0, i_wb_cyc, i_wb_stb, i_wb_we,
				dev_addr, o_wb_ack, o_wb_stall,!o_hram_reset_n,
				i_wb_addr[11:0], i_wb_data[11:0] };
	else
		o_debug <= { 1'b1, o_hram_csn, o_hram_cke, o_hram_rwctrl,
			o_hram_rwds, i_hram_rwds,
			o_hram_drive_data, o_wb_ack, o_wb_data[5:0],
			(o_hram_drive_data) ? o_hram_data : i_hram_data };

	initial	o_dbg_trigger = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_dbg_trigger <= 1'b0;
	else
		o_dbg_trigger <= (i_wb_stb)&&(!o_wb_stall);


	// Verilator lint_off UNUSED
	wire	[1:0]	unused;
	assign	unused = { mem_addr, cti_dev };
	// Verilator lint_on  UNUSED

////////////////////////////////////////////////////////////////////////////////
//
//
//	Formal property section
//
//	Does not contain synthesizable code
//
//
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	localparam	F_LGDEPTH = 4;

	reg			f_past_valid;
	reg	[47:0]		lcl_fv_cmd;
	wire	[(F_LGDEPTH-1):0]	f_nreqs, f_nacks, f_outstanding;

	wire	[31:0]		fvh_vcs_count, fvh_rp_count, fvh_csm_count;
	wire	[15:0]		fv_cfgword, fv_data;
	wire	[AW:0]		fv_addr, fv_current_addr;
	wire	[47:0]		fv_cmd;
	reg	[31:0]	fbus_data;
	reg	[3:0]	fbus_sel;

	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(posedge i_clk)
	if (write_stb)
		{ fbus_sel, fbus_data } <= { i_wb_sel, i_wb_data };

	always @(*)
	begin
		assert(latency >= MIN_LATENCY_COUNT);
		assert(latency <= DEFAULT_LATENCY_COUNT);
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_wb_cyc))&&(!$past(i_reset))
			&&($past(pre_ack))
			&&((cti_write)||($past(i_hram_rwds)==2'b10))
			&&(!$past(cmd_output))&&($past(state_ctr)==1))
		assert(o_wb_ack);

	//
	// Interface verification
	//
	// Wishbone
	fwb_slave #(.AW(AW+1), .DW(DW), .F_MAX_STALL(31), .F_MAX_ACK_DELAY(25),
			.F_LGDEPTH(F_LGDEPTH), .F_MAX_REQUESTS(0))
		busproperties(i_clk, i_reset,
			i_wb_cyc, i_wb_stb, i_wb_we, i_wb_addr, i_wb_data,
				i_wb_sel,
			o_wb_ack, o_wb_stall, o_wb_data, 1'b0,
			f_nreqs, f_nacks, f_outstanding);

	//
	// Interface verification
	//
	// HyperRAM
	f_hyperram #(.AW(AW+1), .CLOCK_SPEED_HZ(CLOCK_RATE_HZ),
			.F_OPT_COVER(F_OPT_COVER), .RDDELAY(RDDELAY))
		hyperramp(i_clk,
			o_hram_reset_n, o_hram_cke, o_hram_csn,
			o_hram_rwctrl, o_hram_rwds, i_hram_rwds,
			o_hram_drive_data,
				o_hram_data, i_hram_data,
			fv_cmd, fv_addr, fv_data, fv_current_addr,
			fvh_vcs_count, fvh_rp_count, fvh_csm_count,
			fv_cfgword);

	//
	//
	// CSM Counter
	//
	//
	always @(*)
	if (!OPT_PIPE)
		assert(fvh_csm_count < 64);
	else if ((OPT_PIPE)&&(!o_hram_csn))
		assert((chip_select_count == fvh_csm_count[CSM_BITS-1:0])
			&&(fvh_csm_count[31:CSM_BITS]==0));

	//
	// Read stalls
	//
	// While the number of read stalls is probably not constrained like
	// this at all, and more likely read stalls are few and far between
	// (i.e., when the row address changes), this will generalize the
	// concept, while still allowing us to prove our logic.
	reg	[4:0]	f_read_stalls;
	initial	f_read_stalls = 0;
	always @(posedge i_clk)
	if ((o_hram_csn)||(cti_write)||(maintenance_stall))
		f_read_stalls <= 0;
	else if ((! (&f_read_stalls))&&(!o_hram_rwctrl)&&(!i_hram_rwds[1])
		&&(state_ctr < 3))
		f_read_stalls <= f_read_stalls + 1;

	always @(posedge i_clk)
	if (!OPT_PIPE)
		assert(f_read_stalls < 16);

	//
	// Clock Enable
	//
	// This is a confusing piece of logic, primarily because the DDR
	// primitives will create an outgoing clock from this clock enable,
	// but the enable will get delayed by IODELAY counts
	always @(*)
	if ((!o_hram_cke)&&(!o_hram_cke))
		assert(o_hram_csn);

	always @(*)
	if (state_ctr == 0)
		assert(!o_hram_cke);

	always @(*)
	if (last_cke)
		assert(o_hram_cke);

	// o_hram_cke should go low following any last_cke
	always @(posedge i_clk)
	if ((f_past_valid)&&($past(last_cke)))
		assert(!o_hram_cke);

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&(o_hram_csn))
		assert(!o_hram_cke);

	//
	// VCS counter
	//
	generate if (!F_OPT_COVER)
	begin
		always @(posedge i_clk)
		if ((!f_past_valid)||($past(!o_hram_reset_n)))
		begin
			assert(reset_recovery == CK_VCS);
			assert(fvh_vcs_count == 0);
		end else if (o_hram_reset_n) begin
			if (fvh_vcs_count > CK_VCS)
				assert(reset_recovery == 0);
			else
				assert(reset_recovery ==(CK_VCS-fvh_vcs_count));
		end
	end endgenerate

	//
	// Latency and fixed latency checks
	//
	always @(posedge i_clk)
	if (((!f_past_valid)||(!$past(i_reset)))
		&&((o_hram_csn)||(!cti_dev)||(!cti_write)))
	begin
		case(fv_cfgword[7:4])
		4'h0: assert(latency == 3'h5);
		4'h1: assert(latency == 3'h6);
		4'he: assert(latency == 3'h3);
		4'hf: assert(latency == 3'h4);
		endcase

		assert(fixed_latency == fv_cfgword[3]);
	end

	//
	//
	//
	always @(*)
	if ((!o_hram_csn)&&(cmd_output))
	begin
		if ((!cti_write)||(!cti_dev))
			assert(cfg_write == 0);
		else if (lcl_fv_cmd[44:0] != 0)
			assert(cfg_write == 0);
		else
			assert(cfg_write);
	end

	always @(*)
	if (maintenance_stall)
		assume(!i_wb_cyc);

	always @(*)
	if ((i_wb_cyc)&&(!o_hram_csn)&&(pre_ack))
		assert(f_outstanding > 0);
	else
		assert((f_outstanding == 0)||(!pre_ack)||(o_wb_ack));

	always @(*)
	if (!pre_ack)
		assert(!o_wb_ack);

	always @(*)
		assert(cmd_output == (cmd_ctr != 0));

	always @(*)
	if (pipe_stb)
		assert(state_ctr == 1);

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(o_hram_cke))&&(!$past(o_hram_cke))
			&&(!o_hram_cke)&&($past(state_ctr)==0))
		assert(o_hram_csn);


	always @(*)
	if (o_wb_ack)
		assert((state_ctr == 0)||(state_ctr == 2));

	always @(posedge i_clk)
	if (i_wb_cyc)
	begin
		if (!pre_ack)
			assert(f_outstanding == 0);
		else if (!o_hram_csn)
			assert(f_outstanding > 0);
		if (OPT_PIPE)
			assert(f_outstanding <= 2);
		else
			assert(f_outstanding <= 1);

		if (f_outstanding == 2)
			assert((OPT_PIPE)&&(o_wb_ack));

		if (state_ctr == 0)
			assert((o_wb_ack)||(f_outstanding == 0));

		if (state_ctr == 1)
			assert((!pre_ack)||(f_outstanding == 1));
	end

	//
	//
	// Address matching
	//
	reg	[DW-1:0]	f_wb_data_copy;
	reg	[DW/8-1:0]	f_wb_sel_copy;
	reg	[AW-1:0]	f_wb_addr_copy;

	initial	f_wb_data_copy = 0;
	always @(posedge i_clk)
	begin
		if ((i_wb_stb)&&(!o_wb_stall))
			f_wb_addr_copy <= i_wb_addr;

		if ((i_wb_stb)&&(!o_wb_stall)&&(i_wb_we))
		begin
			f_wb_data_copy <= i_wb_data;
			f_wb_sel_copy  <= i_wb_sel;
		end

		if ((!cmd_output)&&(!cti_write)&&(!cti_dev)&&(i_hram_rwds[1]))
		begin
			if ((i_hram_rwds == 2'b10)&&(state_ctr == 2))
				assert({f_wb_addr_copy, 1'b0}==$past(fv_current_addr,RDDELAY));
			if ((i_hram_rwds == 2'b10)&&(state_ctr == 1))
				assert({f_wb_addr_copy, 1'b1}==$past(fv_current_addr,RDDELAY));
		end
	end

	// Incoming data matching
	always @(posedge i_clk)
	if ((o_wb_ack)&&(!cti_write)&&(!cti_dev)
		&&($past(f_wb_addr_copy) == fv_addr[AW:1]))
	begin
		if (!$past(fv_addr[0]))
			assert(o_wb_data[31:16] == fv_data);
		else
			assert(o_wb_data[15:0] == fv_data);
	end

	// Outoing data write verification
	always @(posedge i_clk)
	if ((o_wb_ack)&&($past((cti_write)&&(!cti_dev))))
	begin
		assert((state_ctr == 2)||(state_ctr == 0));
		assert($past(o_hram_drive_data));
		assert($past(o_hram_rwctrl));
		assert($past(f_wb_data_copy[15:0])==$past(o_hram_data));
		assert($past(f_wb_sel_copy[1:0])== ~$past(o_hram_rwds[1:0]));
		//
		assert($past(o_hram_drive_data,2));
		assert($past(o_hram_rwctrl,2));
		assert($past(f_wb_data_copy[31:16])==$past(o_hram_data,2));
		assert($past(f_wb_sel_copy[3:2])== ~$past(o_hram_rwds[1:0],2));
	end

	always @(posedge i_clk)
	if ((!o_hram_csn)&&(!cmd_output)&&(cti_write)&&(!cti_dev))
	begin
		if (state_ctr == 2)
			assert({ f_wb_addr_copy, 1'b0 } == fv_current_addr);
		if (state_ctr == 1)
			assert({ f_wb_addr_copy, 1'b1 } == fv_current_addr);
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&($past(o_wb_ack))
		&&($past({cti_dev, cti_write },2)==2'b01)
		&&($past(f_wb_addr_copy,2)==fv_addr[AW:1]))
		// &&($past(state_ctr,8)==3) // This passes
	begin
		if ((!fv_addr[0])&&($past(f_wb_sel_copy[3],2)))
			assert(fv_data[15:8] == $past(f_wb_data_copy[31:24],2));
		if ((!fv_addr[0])&&($past(f_wb_sel_copy[2],2)))
			assert(fv_data[7:0] == $past(f_wb_data_copy[23:16],2));

		if ((fv_addr[0])&&($past(f_wb_sel_copy[1],2)))
			assert(fv_data[15:8] == $past(f_wb_data_copy[15:8],2));
		if ((fv_addr[0])&&($past(f_wb_sel_copy[0],2)))
			assert(fv_data[7:0] == $past(f_wb_data_copy[7:0],2));
	end


	generate if (F_OPT_COVER)
	begin : GEN_COVER

		always @(posedge i_clk)
		if ((f_past_valid)&&($past(i_wb_cyc)&&(i_wb_cyc)&&(!i_wb_stb)))
			assume($stable(i_wb_we));

	end endgenerate

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(o_hram_csn))&&(cmd_ctr > 0))
		assume($stable(i_hram_rwds));

	always @(*)
	if (o_hram_rwctrl == RWDS_OUT)
		assume(i_hram_rwds == o_hram_rwds);

	always @(*)
	if ((!o_hram_csn)&&(cti_dev))
		assert(o_hram_rwctrl == RWDS_IN);

	always @(*)
	if (o_hram_csn)
		assert(o_hram_drive_data);

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_reset)))
		assert(o_hram_csn);

	always @(posedge i_clk)
	if (start_stb)
		lcl_fv_cmd <= { (!i_wb_we), dev_addr, 1'b1,
			{ {(29-(AW-2)){1'b0}}, i_wb_addr[AW-1:2] },
			13'h0, i_wb_addr[1:0], 1'b0 };

	always @(*)
	if (!o_hram_csn)
	begin
		assert(cti_write != lcl_fv_cmd[47]);
		assert(cti_dev   == lcl_fv_cmd[46]);
		assert(lcl_fv_cmd[45]);
		assert(lcl_fv_cmd[15:3] == 0);
		assert(lcl_fv_cmd[0] == 0);

		if (!cmd_output)
			assert(lcl_fv_cmd[47:32] == fv_cmd[47:32]);
	end

	always @(*)
		assert(chip_select_count < CK_CSM);

	always @(*)
	if ((!OPT_PIPE)&&((write_stb)||(read_stb)))
		assert(start_stb);

	always @(*)
	if (o_hram_cke)
	begin
		assert(!o_hram_csn);
		if (!o_hram_cke)
			assert(o_wb_stall);
	end

	always @(*)
	if ((o_hram_reset_n)&&(!o_hram_csn))
		assert((maintenance_stall) || (state_ctr > 0));

	///////////////////////
	//
	// Cover
	//
	///////////////////////
	always @(posedge i_clk)
		cover(maintenance_stall == 1'b0);

	always @(*)
		cover(pre_ack && block_ack);
	always @(*)
		cover(pre_ack && !block_ack);

	always @(posedge i_clk)
	if (o_wb_ack)
	begin
		cover(f_startread[13]);
		cover(f_startwrite[13]);
	end else if ((f_past_valid)&&($past(o_wb_ack)))
	begin
		cover((!i_wb_cyc)&&($past(o_wb_ack))&&($past(i_wb_we)));
		cover((!i_wb_cyc)&&($past(o_wb_ack))&&($past(!i_wb_we)));
	end

	generate if (OPT_PIPE)
	begin : COVER_PIPE
		always @(posedge i_clk)
		if (f_past_valid)
		begin

		cover(pipe_req && (|f_startread));
		cover(($past(pipe_stb)) && !cti_write);
		cover(($past(pipe_stb,3))&&($past(pipe_stb)) &&  cti_write);
		cover(($past(pipe_stb,3))&&($past(pipe_stb)) && !cti_write);
		// cover((i_wb_stb)&&(chip_select_warning));	// will fail
		// cover(chip_select_count == (CK_CSM[CSM_BITS-1:0]-6));
		cover(pipe_req);
		cover(pipe_stb);
		cover(f_piperead[0]);
		cover(f_pipewrite[0]);
		cover(f_piperead[1]);
		cover(f_pipewrite[1]);
		cover(o_wb_ack && f_piperead[2]);
		cover(o_wb_ack && f_pipewrite[2]);
		end
	end endgenerate

	reg	[2:0]	f_cmdseq;

	initial	f_cmdseq = 0;
	always @(posedge i_clk)
	if (i_reset)
		f_cmdseq <= 0;
	else begin
		f_cmdseq <= { f_cmdseq[1:0], (start_stb) };

		if (|f_cmdseq)
		begin
			assert(o_wb_stall);	
			assert(!o_hram_csn);	
			assert(o_hram_drive_data);	
			assert(o_hram_cke);	
			assert(o_hram_rwctrl == RWDS_IN);	
			assert(cmd_output);
			if (!f_cmdseq[0])
			begin
				assert($stable(lcl_fv_cmd));
				assert($stable({ cti_dev, cti_write }));
			end
		end

		if (f_cmdseq[0])
		begin
			assert(o_hram_data == lcl_fv_cmd[47:32]);
			assert(cmd_ctr == 3);
		end

		if (f_cmdseq[1])
		begin
			assert(o_hram_data == lcl_fv_cmd[31:16]);
			assert(cmd_ctr == 2);
		end

		if (f_cmdseq[2])
		begin
			assert(o_hram_data == lcl_fv_cmd[15: 0]);
			assert(cmd_ctr == 1);
		end

		cover(f_cmdseq[2] && ({ cti_dev, cti_write } == 2'b00));
		cover(f_cmdseq[2] && ({ cti_dev, cti_write } == 2'b01));
		cover(f_cmdseq[2] && ({ cti_dev, cti_write } == 2'b10));
		cover(f_cmdseq[2] && ({ cti_dev, cti_write } == 2'b11));
	end

	reg	[1:0]	f_devwrite;
	initial	f_devwrite = 0;
	always @(posedge i_clk)
	if (i_reset)
		f_devwrite <= 0;
	else begin
		f_devwrite <= { f_devwrite[0],
			(({ cti_dev, cti_write } == 2'b11) && f_cmdseq[2]) };

		if (f_devwrite[0])
		begin
			assert(o_wb_stall);
			//
			assert(!o_hram_csn);	
			assert(o_hram_drive_data);	
			assert(o_hram_cke);	
			assert(o_hram_rwctrl == RWDS_IN);
			//
			assert(!cmd_output);
			assert(cti_write);
			assert(cti_dev);
			assert(o_hram_data == fbus_data[15:0]);
			assert(state_ctr ==1);
		end

		if (f_devwrite[1])
		begin
			assert( o_wb_ack || !$past(pre_ack)||!$past(i_wb_cyc));
			assert(!o_wb_stall);
			//
			assert(o_hram_csn);
		end else if (|f_devwrite)
			assert(!o_wb_ack);

		if (|f_devwrite)
		begin
			assert(f_startread == 0);
			assert(f_cmdseq    == 0);
		end

		cover(f_devwrite[1] && o_wb_ack);
	end

	reg	[13:0]	f_startread;
	reg	[31:0]	f_startread_data;

	initial	f_startread = 0;
	always @(posedge i_clk)
	if (i_reset)
		f_startread <= 0;
	else begin
		f_startread <= { f_startread[12:0], 1'b0 };
		if (|f_startread[12:11])
		begin
			f_startread[13:11] <= f_startread[13:11];
			if (i_hram_rwds == 2'b10)
				f_startread[13:11] <= { f_startread[12:11], 1'b0 };
		end

		if (|f_startread)
		begin
			assert(f_devwrite == 0);
			assert(f_cmdseq == 0);
			if (!f_startread[13])
				assert(cti_write == 0);
		end

		// latency can be 3-6
		if (f_cmdseq[2] && !cti_write)
		begin
			if (i_hram_rwds[0]||fixed_latency)
				f_startread[13-(1 + { latency, 1'b0 })] <= 1'b1;
			else
				f_startread[13-(1 + { 1'b0, latency })] <= 1'b1;
		end

		if (|f_startread[12:0])
		begin
			assert(!o_wb_ack);
			if (!OPT_PIPE || !f_startread[12])
				assert(o_wb_stall);

			assert(!o_hram_csn);
			assert( o_hram_cke);
			if (!$past(f_cmdseq[2]))
				assert(!o_hram_drive_data);
			assert( o_hram_rwds == RWDS_IN);

			assert(!cmd_output);
			assert(!cti_write);
		end

		if (f_startread[ 8])
			assert(state_ctr == 5);

		if (f_startread[ 9])
			assert(state_ctr == 4);

		if (f_startread[10])
			assert(state_ctr == 3);

		if (f_startread[11])
		begin
			assert(state_ctr == 2);
			f_startread_data[31:16] <= i_hram_data;
		end

		if (f_startread[12])
		begin
			assert(state_ctr == 1);
			f_startread_data[15: 0] <= i_hram_data;
		end

		if (f_startread[13])
		begin
			assert((state_ctr == 0)||(state_ctr == 2));
			assert( o_wb_ack || !$past(pre_ack)||!$past(i_wb_cyc));
			assert(o_wb_data == f_startread_data);
		end

		cover(f_startread[13] && o_wb_ack);
	end

	reg	[2:0]	f_piperead;
	initial	f_piperead = 0;
	always @(posedge i_clk)
	if ((!OPT_PIPE)||(i_reset))
		f_piperead <= 0;
	else begin
		if (i_hram_rwds[1])
			f_piperead <= { f_piperead[1:0], 1'b0 };
		else
			f_piperead[2] <= 1'b0;
		if ((f_startread[12]||f_piperead[1])&&i_wb_stb && !o_wb_stall)
		begin
			assert(state_ctr == 1);
			f_piperead[0] <= 1'b1;
		end
	end

	always @(*)
	begin
		if (!OPT_PIPE)
			assert(f_piperead == 0);

		if (f_piperead[0])
		begin
			assert(state_ctr == 2);
			assert(!cti_write);
			assert(o_wb_stall);
		end 

		if (f_piperead[1])
		begin
			assert(state_ctr == 1);
			assert(!cti_write);
			assert(!o_wb_ack);
			assert(!f_piperead[2]);
			assert(!f_piperead[0]);
		end 

		if (f_piperead[2])
		begin
			assert(state_ctr == 0 || (f_piperead[0]));
		end 
	end


	reg	[13:0]	f_startwrite;
	reg	[31:0]	f_startwrite_data;
	initial	f_startwrite = 0;
	always @(posedge i_clk)
	if (i_reset)
		f_startwrite = 0;
	else begin
		f_startwrite <= { f_startwrite[12:0], 1'b0 };
		// latency can be 3-6
		if (f_cmdseq[2] && !cti_dev && cti_write)
		begin
			if (i_hram_rwds[0]||fixed_latency)
				f_startwrite[13-(1 + { latency, 1'b0 })]<= 1'b1;
			else
				f_startwrite[13-(1 + { 1'b0, latency })]<= 1'b1;
		end

		if (|f_startwrite)
		begin
			assert(f_devwrite  == 0);
			assert(f_cmdseq    == 0);
			assert(f_startread == 0);
			assert(cti_write);
			assert(!cti_dev);
		end

		if (|f_startwrite[12:0])
		begin
			assert(!o_wb_ack);
			if (!OPT_PIPE)
				assert( o_wb_stall);
			else if (|f_startwrite[11:0])
				assert(o_wb_stall);
			//
			assert(!o_hram_csn);
			assert( o_hram_cke);
			assert(cti_write);
			assert(!cti_dev);
			assert(!cmd_output);
			assert(o_hram_drive_data);
			if (|f_startwrite[12:11])
				assert(o_hram_rwctrl == RWDS_OUT);
		end

		if (f_startwrite[11])
		begin
			assert(o_hram_data == fbus_data[31:16]);
			assert(o_hram_rwds == ~fbus_sel[3:2]);
			assert(state_ctr == 2);
		end

		if (f_startwrite[12])
		begin
			assert(o_hram_data == fbus_data[15:0]);
			assert(o_hram_rwds == ~fbus_sel[1:0]);
			assert(state_ctr == 1);
		end

		/*
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(start_stb)&&(write_stb)&&(!dev_addr)
		##1 ((!i_hram_rwds[0])
				throughout COMMAND_SEQ)
		|=> (!o_hram_csn)&&(o_hram_rwctrl == RWDS_IN)
		##1 (!o_hram_csn)&&(o_hram_rwctrl == RWDS_OUT)
			&&(o_hram_rwds == 2'b11) [*2:15]
		##1 ((!o_wb_ack && (f_latency_count == 0)) throughout WRITE_WORD_SEQ)
		##1 (o_wb_ack)&&( (o_hram_csn)
			||((OPT_PIPE)&&($past(write_stb)))));

		*/
	end

	reg	[2:0]	f_pipewrite;
	initial	f_pipewrite = 0;
	always @(posedge i_clk)
	if ((!OPT_PIPE)||(i_reset))
		f_pipewrite <= 0;
	else begin
		f_pipewrite <= { f_pipewrite[1:0], 1'b0 };

		if ((f_startwrite[12]||f_pipewrite[1])&&i_wb_stb && !o_wb_stall)
		begin
			assert(state_ctr == 1);
			assert(!cti_dev);
			assert(cti_write);
			f_pipewrite[0] <= 1'b1;
		end
	end

	always @(*)
	begin
		if (!OPT_PIPE)
			assert(f_pipewrite == 0);

		if (|f_pipewrite)
			assert(f_piperead == 0);

		if (f_pipewrite[0])
		begin
			assert(state_ctr == 2);
			assert(cti_write);
			assert(!cti_dev);
			assert(o_wb_stall);
		end 

		if (f_pipewrite[1])
		begin
			assert(state_ctr == 1);
			assert(cti_write);
			assert(!cti_dev);
			assert(!o_wb_ack);
			assert(!f_piperead[2]);
			assert(!f_piperead[0]);
		end 

		if (f_pipewrite[2])
		begin
			assert(state_ctr == 0 || (f_pipewrite[0]));
		end 
	end



	always @(*)
	if (!o_hram_csn && !maintenance_stall)
		assert((|f_startread) || (|f_startwrite)
			||(|f_piperead)
			||(|f_pipewrite)
			||(|f_devwrite)
			||(|f_cmdseq));

	always @(*)
	if (maintenance_stall)
	begin
		assert(f_startread      == 0);
		assert(f_startwrite     == 0);
	end
`ifdef	VERIFIC


	sequence	COMMAND_SEQ;
		((o_wb_stall)&&(!o_hram_csn)&&(cmd_output)
			&&(o_hram_drive_data)&&(o_hram_cke)
			&&(o_hram_rwctrl==RWDS_IN) throughout
		(o_hram_data == lcl_fv_cmd[47:32])&&(cmd_ctr == 3)
		##1 (o_hram_data == lcl_fv_cmd[31:16])&&(cmd_ctr == 2)
		##1 (o_hram_data == lcl_fv_cmd[15: 0])&&(cmd_ctr == 1));
	endsequence

	sequence	DEV_WRITE_SEQ;
		((!o_hram_csn)&&(cti_write)&&(cti_dev)&&(!cmd_output)
			&&(o_hram_drive_data)&&(o_hram_cke)
			&&(o_hram_rwctrl==RWDS_IN)
		&&(o_hram_data == fbus_data[15:0])
			&&(state_ctr == 1)&&(o_wb_stall))
		##1 (o_wb_ack)&&(o_hram_csn);
	endsequence

	sequence	WRITE_WORD_SEQ;
		(((!o_hram_csn)&&(cti_write)&&(!cti_dev)&&(!cmd_output)
			&&(o_hram_drive_data)&&(o_hram_cke)
			&&(o_hram_rwctrl==RWDS_OUT)) throughout
		(o_hram_data == fbus_data[31:16])
			&&(o_hram_rwds == (~fbus_sel[3:2]))&&(state_ctr == 2)
			&&(o_wb_stall)
		##1 (o_hram_data == fbus_data[15:0])
			&&(o_hram_rwds == (~fbus_sel[1:0]))&&(state_ctr == 1)
			&&((o_wb_stall)||(OPT_PIPE)));
	endsequence

	sequence	READ_WORD_SEQ;
		(((!o_hram_csn)&&(!cti_write)&&(!cmd_output)
			&&(!o_hram_drive_data)&&(o_hram_cke)
			&&(o_hram_rwctrl==RWDS_IN)) throughout
		((state_ctr == 2)&&(o_wb_stall)
			throughout (i_hram_rwds != 2'b10) [*0:4]
				##1 (i_hram_rwds == 2'b10))
		##1 ((o_wb_data[15:0] == $past(i_hram_data[15:0]))
			&&(state_ctr == 1)&&((o_wb_stall)||(OPT_PIPE))
			throughout
				(i_hram_rwds != 2'b10) [*0:4]
				##1 (i_hram_rwds == 2'b10)));
	endsequence

	// Command write
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(start_stb) |=> COMMAND_SEQ);

	// Device register write
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(start_stb)&&(dev_addr)&&(write_stb)
		|=> COMMAND_SEQ
		##1 DEV_WRITE_SEQ);

	//
	// Memory write
	//
	// Memory write: Double latency count
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(start_stb)&&(write_stb)&&(!dev_addr)
		##1(((i_hram_rwds[0])||(fixed_latency)) throughout COMMAND_SEQ)
		|=> (o_hram_rwctrl == RWDS_IN)
		##1 (o_hram_rwds == 2'b11)&&(o_hram_rwctrl == RWDS_OUT)
			&&(data_reg  == fbus_data)&&(data_mask == fbus_sel)
			[*2:15]
		##1 WRITE_WORD_SEQ
		##1 (o_wb_ack)&&((o_hram_csn)
			||((OPT_PIPE)&&($past(write_stb)))));

	// Memory write: Single latency count
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(start_stb)&&(write_stb)&&(!dev_addr)
		##1 ((!i_hram_rwds[0])
				throughout COMMAND_SEQ)
		|=> (!o_hram_csn)&&(o_hram_rwctrl == RWDS_IN)
		##1 (!o_hram_csn)&&(o_hram_rwctrl == RWDS_OUT)
			&&(o_hram_rwds == 2'b11) [*2:15]
		##1 ((!o_wb_ack && (f_latency_count == 0)) throughout WRITE_WORD_SEQ)
		##1 (o_wb_ack)&&( (o_hram_csn)
			||((OPT_PIPE)&&($past(write_stb)))));

	//
	// Memory write, pipelined
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		(pipe_stb)&&(write_stb)
		|-> (state_ctr == 1)&&(!dev_addr)
		##1 WRITE_WORD_SEQ
		##1 (o_wb_ack)&&(
			(o_hram_csn)
			||((OPT_PIPE)&&($past(write_stb)))));

	//
	// Memory operations go through a command sequence too
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((start_stb)&&(read_stb)) |=> COMMAND_SEQ);

	//
	// Memory read, single latency
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((start_stb)&&(read_stb))
		##1(((!i_hram_rwds[0])&&(!fixed_latency)) throughout COMMAND_SEQ)
		|=> (!o_hram_csn)&&(o_hram_cke)
			&&(o_hram_rwctrl == RWDS_IN)
		##1 (!o_hram_csn)&&(o_hram_cke)&&(!o_hram_drive_data)
			&&(state_ctr > 3)
			&&(o_hram_rwctrl == RWDS_IN)
			&&(f_latency_count > 0) [*2:15]
		##1 (!o_hram_csn)&&(o_hram_cke)&&(!o_hram_drive_data)
			&&(f_latency_count == 0)
			&&(state_ctr == 3)&&(o_hram_rwctrl == RWDS_IN)
		##1 ((!o_wb_ack) throughout READ_WORD_SEQ)
		##1 (o_wb_ack)&&(o_wb_data[31:16] == $past(i_hram_data,2))
			&&(o_wb_data[15:0] == $past(i_hram_data))
			&&((o_hram_csn)||((OPT_PIPE)&&($past(read_stb)))));

	//
	// Memory read, double latency
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((start_stb)&&(read_stb))
		##1 ((i_hram_rwds[0])||(fixed_latency) throughout COMMAND_SEQ)
		|=> (!o_hram_csn)&&(o_hram_cke)
			&&(o_hram_rwctrl == RWDS_IN)
		##1 (!o_hram_csn)&&(o_hram_cke)&&(!o_hram_drive_data)
			&&(state_ctr > 3)
			&&(o_hram_rwctrl == RWDS_IN) [*2:15]
		##1 (!o_hram_csn)&&(o_hram_cke)&&(!o_hram_drive_data)
			&&(state_ctr == 3)
			&&(o_hram_rwctrl == RWDS_IN)
		##1 ((!o_wb_ack) throughout READ_WORD_SEQ)
		##1 (o_wb_ack)&&(o_wb_data[31:16] == $past(i_hram_data,2))
			&&(o_wb_data[15:0] == $past(i_hram_data))
			&&((o_hram_csn)||((OPT_PIPE)&&($past(read_stb)))));

	//
	// Memory read, initial, value check
	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((start_stb)&&(read_stb)&&({i_wb_addr, 1'b0} == fv_addr))
		|=> (i_hram_rwds != 2'b10)
			&&(f_latency_count > 0) [*2:15]
		##1 ((f_latency_count == 0) throughout (READ_WORD_SEQ))
		##1 (o_wb_ack)&&(o_wb_data[31:16] == fv_data));

	assert property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((start_stb)&&(read_stb)&&({i_wb_addr, 1'b1} == fv_addr))
		|=> (i_hram_rwds != 2'b10)
			&&(f_latency_count == 0)
			[*2:15]
		##1 ((f_latency_count == 0) throughout (READ_WORD_SEQ))
		##1 (o_wb_ack)&&(o_wb_data[15:0] == fv_data));

	//
	// Memory read, pipelined
	assert	property (@(posedge i_clk)
		disable iff ((i_reset)||(!i_wb_cyc))
		((pipe_stb)&&(read_stb))
		|-> (state_ctr == 1)
		##1 READ_WORD_SEQ
		##1 (o_wb_ack)&&(o_wb_data[31:16] == $past(i_hram_data,2))
			&&(o_wb_data[15:0] == $past(i_hram_data))
			&&((o_hram_csn)||((OPT_PIPE)&&($past(read_stb)))));

`endif	// VERIFIC


	always @(*)
	if ((start_stb)&&(dev_addr)&&(i_wb_we)&&(i_wb_addr==0))
	begin
		assume(i_wb_data[11:8] == 4'hf);
		assume((i_wb_data[7:5] == 3'b000)||(i_wb_data[7:5] == 3'b111));
	end
	always @(*)
		assume(latency >= MIN_LATENCY_COUNT);
	// always @(*) assume(!dev_addr);
	// always @(*) assert(!cti_dev);
	// always @(*) assume(!i_wb_we);
`endif	// FORMAL
endmodule
