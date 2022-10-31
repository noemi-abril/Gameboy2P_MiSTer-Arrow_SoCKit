//
//
// sdram controller implementation for the MiST/MiSTer boards
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2017 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

//
//
// This SDRAM module provides/writes the data in 8 cycles of clock.
// So, with 64MHz of system clock, it can emulate 8MHz asynchronous DRAM.
//
//

module sdram
(

	// interface to the MT48LC16M16 chip
	inout  reg [15:0] sd_data,    // 16 bit bidirectional data bus
	output reg [12:0]	sd_addr,    // 13 bit multiplexed address bus
	output     [1:0] 	sd_dqm,     // two byte masks
	output reg [1:0] 	sd_ba,      // two banks
	output 				sd_cs,      // a single chip select
	output 				sd_we,      // write enable
	output 				sd_ras,     // row address select
	output 				sd_cas,     // columns address select
	output 				sd_clk,

	// cpu/chipset interface
	input 		 		init,			// init signal after FPGA config to initialize RAM
	input 		 		clk,		   // sdram is accessed at 64MHz
	input             sync,

	input      [15:0] din,			// data input from chipset/cpu
	output reg [15:0] dout,			// data output to chipset/cpu
	input      [23:0] addr,       // 24 bit word address
	input       [1:0] ds,         // upper/lower data strobe
	input 		 		oe,         // cpu/chipset requests read
	input 		 		we,         // cpu/chipset requests write
	output 		 		ack,        // data ready
   
   output reg [15:0] dout2,	   // data output to chipset/cpu
   input      [23:0] addr2,      // 24 bit word address
   input 		 		oe2,        // cpu/chipset requests read
   output 		 		ack2        // data ready
);

localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 3 cycles@128MHz
localparam BURST_LENGTH   = 3'b000; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 


// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

// The state machine runs at 128Mhz synchronous to the 8 Mhz chipset clock.
// It wraps from T15 to T0 on the rising edge of clk_8

localparam STATE_FIRST     = 3'd0;   // first state in cycle
localparam STATE_CMD_START = 3'd1;   // state in which a new command can be started
localparam STATE_CMD_CONT  = STATE_CMD_START + RASCAS_DELAY; // command can be continued
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 4'd1;
localparam STATE_HIGHZ     = STATE_READ - 4'd1; // disable output to prevent contention


// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 8Mhz cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
reg [4:0] reset;
always @(posedge clk) begin
	if(init)	reset <= 5'h1f;
	else if((stage == STATE_FIRST) && (reset != 0))
		reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [3:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = sd_cmd[3];
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];

assign sd_dqm = sd_addr[12:11];

reg  [1:0] mode;
reg [15:0] din_r;
reg  [2:0] stage;

reg channel = 0;

reg [23:0] addr_last;
reg [23:0] addr2_last;

always @(posedge clk) begin
	reg [12:0] addr_r;
	reg        old_sync;
	
	if(|stage) stage <= stage + 1'd1;

	old_sync <= sync;
	if(~old_sync && sync) stage <= 1; // normal operation with read/write and refresh

	sd_cmd <= CMD_INHIBIT;  // default: idle
	sd_data <= 16'hZZZZ;

	if(reset != 0) begin
		// initialization takes place at the end of the reset phase
		if(stage == STATE_CMD_START) begin

			if(reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr[10] <= 1'b1;      // precharge all banks
			end
				
			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end
			
		end
		mode <= 0;
	end else begin

		// normal operation
		if(stage == STATE_CMD_START) begin
         ack  <= 1'b0;
         ack2 <= 1'b0;
         
         if(oe  && (addr_last  == addr )) ack  <= 1'b1;
         if(oe2 && (addr2_last == addr2)) ack2 <= 1'b1;
         
			if(we || (oe & (addr_last != addr))) begin

				mode    <= {we, oe};
            channel <= 1'b0;

				// RAS phase
				sd_cmd  <= CMD_ACTIVE;
				sd_addr <= { 1'b0, addr[19:8] };
				sd_ba   <= addr[21:20];

				din_r   <= din;
				addr_r  <= { we ? ~ds : 2'b00, 2'b10, addr[22], addr[7:0] };  // auto precharge
            
            if (oe) addr_last = addr;
			end
         else if(oe2 && (addr2_last != addr2)) begin

				mode    <= 2'b01;
            channel <= 1'b1;

				// RAS phase
				sd_cmd  <= CMD_ACTIVE;
				sd_addr <= { 1'b0, addr2[19:8] };
				sd_ba   <= addr2[21:20];
            
				addr_r  <= { 2'b00, 2'b10, addr2[22], addr2[7:0] };  // auto precharge
            
            addr2_last = addr2;
			end
			else begin
				sd_cmd <= CMD_AUTO_REFRESH;
				mode   <= 0;
			end
		end

		// CAS phase 
		if(stage == STATE_CMD_CONT && mode) begin
			sd_cmd  <= mode[1] ? CMD_WRITE : CMD_READ;
			sd_addr <= addr_r;
			if(mode[1]) sd_data <= din_r;
		end

		if(stage == STATE_HIGHZ) begin
			sd_addr[12:11] <= 2'b11; // disable chip output
			mode[1] <= 0;            // disable data output
		end

		if(stage == STATE_READ && mode) begin
         if (channel) begin
            dout2 <= sd_data;
            ack2  <= 1'b1;
         end 
         else begin
            dout <= sd_data;
            ack  <= 1'b1;
         end
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(sd_clk),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
