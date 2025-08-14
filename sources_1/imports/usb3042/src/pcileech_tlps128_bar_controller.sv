//
// PCILeech FPGA.
// RTL8191SE
// PCIe BAR PIO controller.
//
// The PCILeech BAR PIO controller allows for easy user-implementation on top
// of the PCILeech AXIS128 PCIe TLP streaming interface.
// The controller consists of a read engine and a write engine and pluggable
// user-implemented PCIe BAR implementations (found at bottom of the file).
//
// Considerations:
// - The core handles 1 DWORD read + 1 DWORD write per CLK max. If a lot of
//   data is written / read from the TLP streaming interface the core may
//   drop packet silently.
// - The core reads 1 DWORD of data (without byte enable) per CLK.
// - The core writes 1 DWORD of data (with byte enable) per CLK.
// - All user-implemented cores must have the same latency in CLKs for the
//   returned read data or else undefined behavior will take place.
// - 32-bit addresses are passed for read/writes. Larger BARs than 4GB are
//   not supported due to addressing constraints. Lower bits (LSBs) are the
//   BAR offset, Higher bits (MSBs) are the 32-bit base address of the BAR.
// - DO NOT edit read/write engines.
// - DO edit pcileech_tlps128_bar_controller (to swap bar implementations).
// - DO edit the bar implementations (at bottom of the file, if neccessary).
//
// Example implementations exists below, swap out any of the example cores
// against a core of your use case, or modify existing cores.
// Following test cores exist (see below in this file):
// - pcileech_bar_impl_zerowrite4k = zero-initialized read/write BAR.
//     It's possible to modify contents by use of .coe file.
// - pcileech_bar_impl_loopaddr = test core that loops back the 32-bit
//     address of the current read. Does not support writes.
// - pcileech_bar_impl_none = core without any reply.
// 
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_bar_controller(
    input                   rst,
    input                   clk,
    input                   bar_en,
    input [15:0]            pcie_id,
    input [31:0]            base_address_register,
    output wire             int_enable,  // Cambiado a output
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source        tlps_out,
	
    input wire              cfg_bme_state,
	
    output interrupt_out,
    output [63:0] interrupt_address,
    output [31:0] interrupt_data,
    input interrupt_done

);
    
    // ------------------------------------------------------------------------
    // 1: TLP RECEIVE:
    // Receive incoming BAR requests from the TLP stream:
    // send them onwards to read and write FIFOs
    // ------------------------------------------------------------------------
    wire in_is_wr_ready;
    bit  in_is_wr_last;
    wire in_is_first    = tlps_in.tuser[0];
    wire in_is_bar      = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast && ((tlps_in.tdata[31:25] == 7'b0000000) || (tlps_in.tdata[31:25] == 7'b0010000) || (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last || (in_is_first && in_is_wr_ready && ((tlps_in.tdata[31:25] == 7'b0100000) || (tlps_in.tdata[31:25] == 7'b0110000) || (tlps_in.tdata[31:24] == 8'b01000010)));
    
    always @ ( posedge clk )
        if ( rst ) begin
            in_is_wr_last <= 0;
        end
        else if ( tlps_in.tvalid ) begin
            in_is_wr_last <= !tlps_in.tlast && in_is_wr;
        end
    
    wire [6:0]  wr_bar;
    wire [31:0] wr_addr;
    wire [3:0]  wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [6:0]  rd_req_bar;
    wire [31:0] rd_req_addr;
    wire [3:0]  rd_req_be;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;
        
    pcileech_tlps128_bar_rdengine i_pcileech_tlps128_bar_rdengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_rd ),
        .tlps_out       ( tlps_out                      ),
        // BAR reads:
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_bar     ( rd_req_bar                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_be      ( rd_req_be                     ),
        .rd_req_valid   ( rd_req_valid                  ),
        .rd_rsp_ctx     ( rd_rsp_ctx                    ),
        .rd_rsp_data    ( rd_rsp_data                   ),
        .rd_rsp_valid   ( rd_rsp_valid                  )
    );

    pcileech_tlps128_bar_wrengine i_pcileech_tlps128_bar_wrengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_wr ),
        .tlps_in_ready  ( in_is_wr_ready                ),
        // outgoing BAR writes:
        .wr_bar         ( wr_bar                        ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid                      )
    );
    
    wire [87:0] bar_rsp_ctx[7];
    wire [31:0] bar_rsp_data[7];
    wire        bar_rsp_valid[7];
    
    assign rd_rsp_ctx = bar_rsp_valid[0] ? bar_rsp_ctx[0] :
                        bar_rsp_valid[1] ? bar_rsp_ctx[1] :
                        bar_rsp_valid[2] ? bar_rsp_ctx[2] :
                        bar_rsp_valid[3] ? bar_rsp_ctx[3] :
                        bar_rsp_valid[4] ? bar_rsp_ctx[4] :
                        bar_rsp_valid[5] ? bar_rsp_ctx[5] :
                        bar_rsp_valid[6] ? bar_rsp_ctx[6] : 0;
    assign rd_rsp_data = bar_rsp_valid[0] ? bar_rsp_data[0] :
                        bar_rsp_valid[1] ? bar_rsp_data[1] :
                        bar_rsp_valid[2] ? bar_rsp_data[2] :
                        bar_rsp_valid[3] ? bar_rsp_data[3] :
                        bar_rsp_valid[4] ? bar_rsp_data[4] :
                        bar_rsp_valid[5] ? bar_rsp_data[5] :
                        bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = bar_rsp_valid[0] || bar_rsp_valid[1] || bar_rsp_valid[2] || bar_rsp_valid[3] || bar_rsp_valid[4] || bar_rsp_valid[5] || bar_rsp_valid[6];
    
    pcileech_bar_impl_Riffa i_bar0(
    .rst                   ( rst                           ),
    .clk                   ( clk                           ),
    .wr_addr               ( wr_addr                       ),
    .wr_be                 ( wr_be                         ),
    .wr_data               ( wr_data                       ),
    .wr_valid              ( wr_valid && wr_bar[0]         ),
    .rd_req_ctx            ( rd_req_ctx                    ),
    .rd_req_addr           ( rd_req_addr                   ),
    .rd_req_valid          ( rd_req_valid && rd_req_bar[0] ),
   // .int_enable     ( int_enable                    ),
    .base_address_register ( base_address_register         ),
    .rd_rsp_ctx            ( bar_rsp_ctx[0]                ),
    .rd_rsp_data           ( bar_rsp_data[0]               ),
    .rd_rsp_valid          ( bar_rsp_valid[0]              )
  /*  .cfg_bme_state         ( cfg_bme_state                 ),
	
    .interrupt_out  (interrupt_out),
    .interrupt_address (interrupt_address),
    .interrupt_data (interrupt_data),
    .interrupt_done (interrupt_done)*/
    );
    
    pcileech_bar_impl_loopaddr i_bar1(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[1]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[1] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[1]                ),
        .rd_rsp_data    ( bar_rsp_data[1]               ),
        .rd_rsp_valid   ( bar_rsp_valid[1]              )
    );
    
    pcileech_bar_impl_none i_bar2(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[2]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[2] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[2]                ),
        .rd_rsp_data    ( bar_rsp_data[2]               ),
        .rd_rsp_valid   ( bar_rsp_valid[2]              )
    );
    
    pcileech_bar_impl_none i_bar3(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[3]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[3] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[3]                ),
        .rd_rsp_data    ( bar_rsp_data[3]               ),
        .rd_rsp_valid   ( bar_rsp_valid[3]              )
    );
    
    pcileech_bar_impl_none i_bar4(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[4]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[4] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[4]                ),
        .rd_rsp_data    ( bar_rsp_data[4]               ),
        .rd_rsp_valid   ( bar_rsp_valid[4]              )
    );
    
    pcileech_bar_impl_none i_bar5(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[5]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[5] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[5]                ),
        .rd_rsp_data    ( bar_rsp_data[5]               ),
        .rd_rsp_valid   ( bar_rsp_valid[5]              )
    );
    
    pcileech_bar_impl_none i_bar6_optrom(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[6]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[6] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[6]                ),
        .rd_rsp_data    ( bar_rsp_data[6]               ),
        .rd_rsp_valid   ( bar_rsp_valid[6]              )
    );


endmodule



// ------------------------------------------------------------------------
// BAR WRITE ENGINE:
// Receives BAR WRITE TLPs and output BAR WRITE requests.
// Holds a 2048-byte buffer.
// Input flow rate is 16bytes/CLK (max).
// Output flow rate is 4bytes/CLK.
// If write engine overflows incoming TLP is completely discarded silently.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_wrengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    output                  tlps_in_ready,
    // outgoing BAR writes:
    output bit [6:0]        wr_bar,
    output bit [31:0]       wr_addr,
    output bit [3:0]        wr_be,
    output bit [31:0]       wr_data,
    output bit              wr_valid
);

    wire            f_rd_en;
    wire [127:0]    f_tdata;
    wire [3:0]      f_tkeepdw;
    wire [8:0]      f_tuser;
    wire            f_tvalid;
    
    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tlast;
    
    bit [3:0]       be_first;
    bit [3:0]       be_last;
    bit             first_dw;
    bit [31:0]      addr;

    fifo_141_141_clk1_bar_wr i_fifo_141_141_clk1_bar_wr(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( {tlps_in.tuser[8:0], tlps_in.tkeepdw, tlps_in.tdata} ),
        .full           (                               ),
        .prog_empty     ( tlps_in_ready                 ),
        .rd_en          ( f_rd_en                       ),
        .dout           ( {f_tuser, f_tkeepdw, f_tdata} ),    
        .empty          (                               ),
        .valid          ( f_tvalid                      )
    );
    
    // STATE MACHINE:
    `define S_ENGINE_IDLE        3'h0
    `define S_ENGINE_FIRST       3'h1
    `define S_ENGINE_4DW_REQDATA 3'h2
    `define S_ENGINE_TX0         3'h4
    `define S_ENGINE_TX1         3'h5
    `define S_ENGINE_TX2         3'h6
    `define S_ENGINE_TX3         3'h7
    (* KEEP = "TRUE" *) bit [3:0] state = `S_ENGINE_IDLE;
    
    assign f_rd_en = (state == `S_ENGINE_IDLE) ||
                     (state == `S_ENGINE_4DW_REQDATA) ||
                     (state == `S_ENGINE_TX3) ||
                     ((state == `S_ENGINE_TX2 && !tkeepdw[3])) ||
                     ((state == `S_ENGINE_TX1 && !tkeepdw[2])) ||
                     ((state == `S_ENGINE_TX0 && !f_tkeepdw[1]));

    always @ ( posedge clk ) begin
        wr_addr     <= addr;
        wr_valid    <= ((state == `S_ENGINE_TX0) && f_tvalid) || (state == `S_ENGINE_TX1) || (state == `S_ENGINE_TX2) || (state == `S_ENGINE_TX3);
        
    end

    always @ ( posedge clk )
        if ( rst ) begin
            state <= `S_ENGINE_IDLE;
        end
        else case ( state )
            `S_ENGINE_IDLE: begin
                state   <= `S_ENGINE_FIRST;
            end
            `S_ENGINE_FIRST: begin
                if ( f_tvalid && f_tuser[0] ) begin
                    wr_bar      <= f_tuser[8:2];
                    tdata       <= f_tdata;
                    tkeepdw     <= f_tkeepdw;
                    tlast       <= f_tuser[1];
                    first_dw    <= 1;
                    be_first    <= f_tdata[35:32];
                    be_last     <= f_tdata[39:36];
                    if ( f_tdata[31:29] == 8'b010 ) begin       // 3 DW header, with data
                        addr    <= { f_tdata[95:66], 2'b00 };
                        state   <= `S_ENGINE_TX3;
                    end
                    else if ( f_tdata[31:29] == 8'b011 ) begin  // 4 DW header, with data
                        addr    <= { f_tdata[127:98], 2'b00 };
                        state   <= `S_ENGINE_4DW_REQDATA;
                    end 
                end
                else begin
                    state   <= `S_ENGINE_IDLE;
                end
            end 
            `S_ENGINE_4DW_REQDATA: begin
                state   <= `S_ENGINE_TX0;
            end
            `S_ENGINE_TX0: begin
                tdata       <= f_tdata;
                tkeepdw     <= f_tkeepdw;
                tlast       <= f_tuser[1];
                addr        <= addr + 4;
                wr_data     <= { f_tdata[0+00+:8], f_tdata[0+08+:8], f_tdata[0+16+:8], f_tdata[0+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (f_tkeepdw[1] ? 4'hf : be_last);
                state       <= f_tvalid ? (f_tkeepdw[1] ? `S_ENGINE_TX1 : `S_ENGINE_FIRST) : `S_ENGINE_IDLE;
            end
            `S_ENGINE_TX1: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[32+00+:8], tdata[32+08+:8], tdata[32+16+:8], tdata[32+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[2] ? 4'hf : be_last);
                state       <= tkeepdw[2] ? `S_ENGINE_TX2 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX2: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[64+00+:8], tdata[64+08+:8], tdata[64+16+:8], tdata[64+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[3] ? 4'hf : be_last);
                state       <= tkeepdw[3] ? `S_ENGINE_TX3 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX3: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[96+00+:8], tdata[96+08+:8], tdata[96+16+:8], tdata[96+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (!tlast ? 4'hf : be_last);
                state       <= !tlast ? `S_ENGINE_TX0 : `S_ENGINE_FIRST;
            end
        endcase

endmodule



// ------------------------------------------------------------------------
// BAR READ ENGINE:
// Receives BAR READ TLPs and output BAR READ requests.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_rdengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    IfAXIS128.source        tlps_out,
    // BAR reads:
    output [87:0]           rd_req_ctx,
    output [6:0]            rd_req_bar,
    output [31:0]           rd_req_addr,
    output                  rd_req_valid,
    output [3:0]            rd_req_be,        
    input  [87:0]           rd_rsp_ctx,
    input  [31:0]           rd_rsp_data,
    input                   rd_rsp_valid
);
    // ------------------------------------------------------------------------
    // 1: PROCESS AND QUEUE INCOMING READ TLPs:
    // ------------------------------------------------------------------------
    wire [10:0] rd1_in_dwlen    = (tlps_in.tdata[9:0] == 0) ? 11'd1024 : {1'b0, tlps_in.tdata[9:0]};
    wire [6:0]  rd1_in_bar      = tlps_in.tuser[8:2];
    wire [15:0] rd1_in_reqid    = tlps_in.tdata[63:48];
    wire [7:0]  rd1_in_tag      = tlps_in.tdata[47:40];
    wire [31:0] rd1_in_addr     = { ((tlps_in.tdata[31:29] == 3'b000) ? tlps_in.tdata[95:66] : tlps_in.tdata[127:98]), 2'b00 };
    wire [3:0]  rd1_in_be       = tlps_in.tdata[35:32];
    wire [73:0] rd1_in_data;
    assign rd1_in_data[73:63]   = rd1_in_dwlen;
    assign rd1_in_data[62:56]   = rd1_in_bar;   
    assign rd1_in_data[55:48]   = rd1_in_tag;
    assign rd1_in_data[47:32]   = rd1_in_reqid;
    assign rd1_in_data[31:0]    = rd1_in_addr;

    
    wire [3:0]  rd1_out_be;
    wire        rd1_out_be_valid;
    wire        rd1_out_rden;
    wire [73:0] rd1_out_data;
    wire        rd1_out_valid;
    
    fifo_74_74_clk1_bar_rd1 i_fifo_74_74_clk1_bar_rd1(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_data                   ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_data                  ),    
        .empty          (                               ),
        .valid          ( rd1_out_valid                 )
    );
 fifo_4_4_clk1_bar_rd1 i_fifo_4_4_clk1_bar_rd1 (
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_be                     ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_be                    ),
        .empty          (                               ),
        .valid          ( rd1_out_be_valid              )

    );
    
    // ------------------------------------------------------------------------
    // 2: PROCESS AND SPLIT READ TLPs INTO RESPONSE TLP READ REQUESTS AND QUEUE:
    //    (READ REQUESTS LARGER THAN 128-BYTES WILL BE SPLIT INTO MULTIPLE).
    // ------------------------------------------------------------------------
    
    wire [10:0] rd1_out_dwlen       = rd1_out_data[73:63];
    wire [4:0]  rd1_out_dwlen5      = rd1_out_data[67:63];
    wire [4:0]  rd1_out_addr5       = rd1_out_data[6:2];
    
    // 1st "instant" packet:
    wire [4:0]  rd2_pkt1_dwlen_pre  = ((rd1_out_addr5 + rd1_out_dwlen5 > 6'h20) || ((rd1_out_addr5 != 0) && (rd1_out_dwlen5 == 0))) ? (6'h20 - rd1_out_addr5) : rd1_out_dwlen5;
    wire [5:0]  rd2_pkt1_dwlen      = (rd2_pkt1_dwlen_pre == 0) ? 6'h20 : rd2_pkt1_dwlen_pre;
    wire [10:0] rd2_pkt1_dwlen_next = rd1_out_dwlen - rd2_pkt1_dwlen;
    wire        rd2_pkt1_large      = (rd1_out_dwlen > 32) || (rd1_out_dwlen != rd2_pkt1_dwlen);
    wire        rd2_pkt1_tiny       = (rd1_out_dwlen == 1);
    wire [11:0] rd2_pkt1_bc         = rd1_out_dwlen << 2;
    wire [85:0] rd2_pkt1;
    assign      rd2_pkt1[85:74]     = rd2_pkt1_bc;
    assign      rd2_pkt1[73:63]     = rd2_pkt1_dwlen;
    assign      rd2_pkt1[62:0]      = rd1_out_data[62:0];
    
    // Nth packet (if split should take place):
    bit  [10:0] rd2_total_dwlen;
    wire [10:0] rd2_total_dwlen_next = rd2_total_dwlen - 11'h20;
    
    bit  [85:0] rd2_pkt2;
    wire [10:0] rd2_pkt2_dwlen = rd2_pkt2[73:63];
    wire        rd2_pkt2_large = (rd2_total_dwlen > 11'h20);
    
    wire        rd2_out_rden;
    
    // STATE MACHINE:
    `define S2_ENGINE_REQDATA     1'h0
    `define S2_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state2 = `S2_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            state2 <= `S2_ENGINE_REQDATA;
        end
        else case ( state2 )
            `S2_ENGINE_REQDATA: begin
                if ( rd1_out_valid && rd2_pkt1_large ) begin
                    rd2_total_dwlen <= rd2_pkt1_dwlen_next;                             // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_pkt1_dwlen_next << 2;                        // byte-count
                    rd2_pkt2[73:63] <= (rd2_pkt1_dwlen_next > 11'h20) ? 11'h20 : rd2_pkt1_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd1_out_data[62:12];                             // various data
                    rd2_pkt2[11:0]  <= rd1_out_data[11:0] + (rd2_pkt1_dwlen << 2);      // base address (within 4k page)
                    state2 <= `S2_ENGINE_PROCESSING;
                end
            end
            `S2_ENGINE_PROCESSING: begin
                if ( rd2_out_rden ) begin
                    rd2_total_dwlen <= rd2_total_dwlen_next;                                // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_total_dwlen_next << 2;                           // byte-count
                    rd2_pkt2[73:63] <= (rd2_total_dwlen_next > 11'h20) ? 11'h20 : rd2_total_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd2_pkt2[62:12];                                     // various data
                    rd2_pkt2[11:0]  <= rd2_pkt2[11:0] + (rd2_pkt2_dwlen << 2);              // base address (within 4k page)
                    if ( !rd2_pkt2_large ) begin
                        state2 <= `S2_ENGINE_REQDATA;
                    end
                end
            end
        endcase
    
    assign rd1_out_rden = rd2_out_rden && (((state2 == `S2_ENGINE_REQDATA) && (!rd1_out_valid || rd2_pkt1_tiny)) || ((state2 == `S2_ENGINE_PROCESSING) && !rd2_pkt2_large));

    wire [85:0] rd2_in_data  = (state2 == `S2_ENGINE_REQDATA) ? rd2_pkt1 : rd2_pkt2;
    wire        rd2_in_valid = rd1_out_valid || ((state2 == `S2_ENGINE_PROCESSING) && rd2_out_rden);
    wire [3:0]  rd2_in_be       = rd1_out_be;
    wire        rd2_in_be_valid = rd1_out_valid;

    bit  [85:0] rd2_out_data;
    bit         rd2_out_valid;
    bit  [3:0]  rd2_out_be;
    bit         rd2_out_be_valid;
    always @ ( posedge clk ) begin
        rd2_out_data    <= rd2_in_valid ? rd2_in_data : rd2_out_data;
        rd2_out_valid   <= rd2_in_valid && !rst;
        rd2_out_be       <= rd2_in_be_valid ? rd2_in_be : rd2_out_data;
        rd2_out_be_valid <= rd2_in_be_valid && !rst;  
    end

    // ------------------------------------------------------------------------
    // 3: PROCESS EACH READ REQUEST PACKAGE PER INDIVIDUAL 32-bit READ DWORDS:
    // ------------------------------------------------------------------------

    wire [4:0]  rd2_out_dwlen   = rd2_out_data[67:63];
    wire        rd2_out_last    = (rd2_out_dwlen == 1);
    wire [9:0]  rd2_out_dwaddr  = rd2_out_data[11:2];
    
    wire        rd3_enable;
    
    bit [3:0]   rd3_process_be;
    bit         rd3_process_valid;
    bit         rd3_process_first;
    bit         rd3_process_last;
    bit [4:0]   rd3_process_dwlen;
    bit [9:0]   rd3_process_dwaddr;
    bit [85:0]  rd3_process_data;
    wire        rd3_process_next_last = (rd3_process_dwlen == 2);
    wire        rd3_process_nextnext_last = (rd3_process_dwlen <= 3);
    assign rd_req_be    = rd3_process_be;
    assign rd_req_ctx   = { rd3_process_first, rd3_process_last, rd3_process_data };
    assign rd_req_bar   = rd3_process_data[62:56];
    assign rd_req_addr  = { rd3_process_data[31:12], rd3_process_dwaddr, 2'b00 };
    assign rd_req_valid = rd3_process_valid;
    
    // STATE MACHINE:
    `define S3_ENGINE_REQDATA     1'h0
    `define S3_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state3 = `S3_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            rd3_process_valid   <= 1'b0;
            state3              <= `S3_ENGINE_REQDATA;
        end
        else case ( state3 )
            `S3_ENGINE_REQDATA: begin
                if ( rd2_out_valid ) begin
                    rd3_process_valid       <= 1'b1;
                    rd3_process_first       <= 1'b1;                    // FIRST
                    rd3_process_last        <= rd2_out_last;            // LAST (low 5 bits of dwlen == 1, [max pktlen = 0x20))
                    rd3_process_dwlen       <= rd2_out_dwlen;           // PKT LENGTH IN DW
                    rd3_process_dwaddr      <= rd2_out_dwaddr;          // DWADDR OF THIS DWORD
                    rd3_process_data[85:0]  <= rd2_out_data[85:0];      // FORWARD / SAVE DATA
                    if ( rd2_out_be_valid ) begin
                        rd3_process_be <= rd2_out_be;
                    end else begin
                        rd3_process_be <= 4'hf;
                    end
                    if ( !rd2_out_last ) begin
                        state3 <= `S3_ENGINE_PROCESSING;
                    end
                end
                else begin
                    rd3_process_valid       <= 1'b0;
                end
            end
            `S3_ENGINE_PROCESSING: begin
                rd3_process_first           <= 1'b0;                    // FIRST
                rd3_process_last            <= rd3_process_next_last;   // LAST
                rd3_process_dwlen           <= rd3_process_dwlen - 1;   // LEN DEC
                rd3_process_dwaddr          <= rd3_process_dwaddr + 1;  // ADDR INC
                if ( rd3_process_next_last ) begin
                    state3 <= `S3_ENGINE_REQDATA;
                end
            end
        endcase

    assign rd2_out_rden = rd3_enable && (
        ((state3 == `S3_ENGINE_REQDATA) && (!rd2_out_valid || rd2_out_last)) ||
        ((state3 == `S3_ENGINE_PROCESSING) && rd3_process_nextnext_last));
    
    // ------------------------------------------------------------------------
    // 4: PROCESS RESPONSES:
    // ------------------------------------------------------------------------
    
    wire        rd_rsp_first    = rd_rsp_ctx[87];
    wire        rd_rsp_last     = rd_rsp_ctx[86];
    
    wire [9:0]  rd_rsp_dwlen    = rd_rsp_ctx[72:63];
    wire [11:0] rd_rsp_bc       = rd_rsp_ctx[85:74];
    wire [15:0] rd_rsp_reqid    = rd_rsp_ctx[47:32];
    wire [7:0]  rd_rsp_tag      = rd_rsp_ctx[55:48];
    wire [6:0]  rd_rsp_lowaddr  = rd_rsp_ctx[6:0];
    wire [31:0] rd_rsp_addr     = rd_rsp_ctx[31:0];
    wire [31:0] rd_rsp_data_bs  = { rd_rsp_data[7:0], rd_rsp_data[15:8], rd_rsp_data[23:16], rd_rsp_data[31:24] };
    
    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];
    
    always @ ( posedge clk )
        if ( rst ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 0;
        end
        else if ( rd_rsp_valid && rd_rsp_first ) begin
            tkeepdw         <= 4'b1111;
            tlast           <= rd_rsp_last;
            first           <= 1'b1;
            tdata[31:0]     <= { 22'b0100101000000000000000, rd_rsp_dwlen };            // format, type, length
            tdata[63:32]    <= { pcie_id[7:0], pcie_id[15:8], 4'b0, rd_rsp_bc };        // pcie_id, byte_count
            tdata[95:64]    <= { rd_rsp_reqid, rd_rsp_tag, 1'b0, rd_rsp_lowaddr };      // req_id, tag, lower_addr
            tdata[127:96]   <= rd_rsp_data_bs;
        end
        else begin
            tlast   <= rd_rsp_valid && rd_rsp_last;
            tkeepdw <= tvalid ? (rd_rsp_valid ? 4'b0001 : 4'b0000) : (rd_rsp_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= 0;
            if ( rd_rsp_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= rd_rsp_data_bs;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= rd_rsp_data_bs;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= rd_rsp_data_bs;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= rd_rsp_data_bs;   
            end
        end
    
    // 2.1 - submit to output fifo - will feed into mux/pcie core.
    fifo_134_134_clk1_bar_rdrsp i_fifo_134_134_clk1_bar_rdrsp(
        .srst           ( rst                       ),
        .clk            ( clk                       ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid                    ),
        .rd_en          ( tlps_out.tready           ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .prog_empty     ( rd3_enable                ),
        .valid          ( tlps_out.tvalid           )
    );
    
    assign tlps_out.tuser[1] = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 0;
    
    // 2.2 - packet count:
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast;
    wire        pkt_count_inc   = tvalid && tlast;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0);
    
    always @ ( posedge clk ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end

endmodule


// ------------------------------------------------------------------------
// Example BAR implementation that does nothing but drop any read/writes
// silently without generating a response.
// This is only recommended for placeholder designs.
// Latency = N/A.
// ------------------------------------------------------------------------
module pcileech_bar_impl_none(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    initial rd_rsp_ctx = 0;
    initial rd_rsp_data = 0;
    initial rd_rsp_valid = 0;

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of "address loopback" which can be useful
// for testing. Any read to a specific BAR address will result in the
// address as response.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_loopaddr(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input [87:0]        rd_req_ctx,
    input [31:0]        rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]      rd_req_ctx_1;
    bit [31:0]      rd_req_addr_1;
    bit             rd_req_valid_1;
    
    always @ ( posedge clk ) begin
        rd_req_ctx_1    <= rd_req_ctx;
        rd_req_addr_1   <= rd_req_addr;
        rd_req_valid_1  <= rd_req_valid;
        rd_rsp_ctx      <= rd_req_ctx_1;
        rd_rsp_data     <= 32'h0;
        rd_rsp_valid    <= rd_req_valid_1;
    end    

endmodule

// ------------------------------------------------------------------------
// Example BAR implementation of a 4kB writable initial-zero BAR.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_zerowrite4k(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;
    
    always @ ( posedge clk ) begin
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= doutb; 
    end
    
    bram_bar_zero4k i_bram_bar_zero4k(
        // Port A - write:
        .addra  ( wr_addr[11:2]     ),
        .clka   ( clk               ),
        .dina   ( wr_data           ),
        .ena    ( wr_valid          ),
        .wea    ( wr_be             ),
        // Port A - read (2 CLK latency):
        .addrb  ( rd_req_addr[11:2] ),
        .clkb   ( clk               ),
        .doutb  ( doutb             ),
        .enb    ( rd_req_valid      )
    );

endmodule

`define MAC_RANDOM_NUM1 13
`define MAC_RANDOM_NUM2 2
`define MAC_RANDOM_NUM3 13
`define MAC_RANDOM_NUM4 9
`define MAC_RANDOM_NUM5 7
`define MAC_RANDOM_NUM6 5

// ------------------------------------------------------------------------
// pcileech wifi BAR implementation
// Works with rtl81xx chips
// ------------------------------------------------------------------------
module pcileech_bar_impl_USB3042(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    input  [31:0]       base_address_register,
    
    //input  wire        int_enable,
    // outgoing BAR read replies:
    output reg [87:0]   rd_rsp_ctx,
    output reg [31:0]   rd_rsp_data,
    output reg          rd_rsp_valid,
    
    output reg          interrupt_out,
    output reg [63:0]   interrupt_address,
    output reg [31:0]   interrupt_data,
    input wire          interrupt_done,
	
	// incoming bus master state
	input wire          cfg_bme_state
	
);
	
                     
    reg [87:0]      drd_req_ctx;
    reg [31:0]      drd_req_addr;
    reg             drd_req_valid;
                  
    reg [31:0]      dwr_addr;
    reg [31:0]      dwr_data;
    reg             dwr_valid;
               
    reg [31:0]      data_32;
   
	//定义寄存�?
	  //0x800地址
//============定义寄存�?===========
reg [31:0]      data_0800;
reg [31:0]      data_0020;
reg [31:0]      data_0024;
reg             read_0024;
reg [31:0]      data_0450;
reg [31:0]      read_0450_counter;
reg [31:0]      data_0804;

   
	
    time number = 0;
    
    reg [31:0] msix_pba_wr;
    reg [31:0] msix_pba_int; 
    reg pba_wr_valid;        
    reg pba_int_valid;       
    
//    reg [31:0] debug_cnt;

    reg [31:0] msix_table [0:15];
    reg [31:0] msix_address_high [0:15];                                
    reg [31:0] msix_table_data [0:15];
    reg [31:0] msix_vector_control [0:15];
    
    wire [31:0] msix_pba;

    always @ (posedge clk) begin
        if (rst) begin
          //============寄存器初始化===========
            data_0800   <= 32'h801;
            data_0020   <= 32'h0;
            read_0024   <= 1'b0;
            data_0450   <= 32'h202e1;
            read_0450_counter <= 0;
            data_0804   <= 32'he0000000;
       					
            number <= 0;
            for (int i = 0; i < 16; i++) begin
                msix_table[i] <= 32'h00000000;
            end
            
            for (int i = 0; i < 16; i++) begin
                msix_address_high[i] <= 32'h00000000;
            end
            
            for (int i = 0; i < 16; i++) begin
                msix_table_data[i] <= 32'h00000000;
            end
            
            for (int i = 0; i < 16; i++) begin
                msix_vector_control[i] <= 32'h00000000;
            end
            
            msix_pba_wr <= 32'h00000000;
            pba_wr_valid <= 1'b0;
            
//            debug_cnt <= 0;
            
        end else begin
            number          <= number + 1;
            drd_req_ctx     <= rd_req_ctx;
            drd_req_valid   <= rd_req_valid;
            dwr_valid       <= wr_valid;
            drd_req_addr    <= rd_req_addr;
            rd_rsp_ctx      <= drd_req_ctx;
            rd_rsp_valid    <= drd_req_valid;
            dwr_addr        <= wr_addr;
            dwr_data        <= wr_data;
        
            pba_wr_valid <= 1'b0;
        
  if (drd_req_valid) begin
            case (({drd_req_addr[31:24], drd_req_addr[23:16], drd_req_addr[15:08], drd_req_addr[07:00]} 
                  - (base_address_register & 32'hFFFFFFF0)) & 32'h7FFF)          
				//============读请�?===========
                16'h0000 : rd_rsp_data <= 32'h1100020;
                16'h0014 : rd_rsp_data <= 32'h1800;
                16'h0018 : rd_rsp_data <= 32'h1000;
                16'h0004 : rd_rsp_data <= 32'h400087f;
                16'h0010 : rd_rsp_data <= 32'h200ef81;
                16'h0800 : rd_rsp_data <= data_0800;
                16'h0820 : rd_rsp_data <= 32'h3011002;
                16'h0824 : rd_rsp_data <= 32'h20425355;
                16'h0828 : rd_rsp_data <= 32'h201;
                16'h0860 : rd_rsp_data <= 32'h2000802;
                16'h0864 : rd_rsp_data <= 32'h20425355;
                16'h0868 : rd_rsp_data <= 32'h190203;
                16'h0880 : rd_rsp_data <= 32'ha;
                16'h0028 : rd_rsp_data <= 32'h1;
                16'h0020 : begin
                    rd_rsp_data <= data_0020;
                    if (data_0020 == 32'h2) begin
                        data_0020 <= 32'h0;
                    end
                end
                16'h0024 : rd_rsp_data <= data_0024;
                16'h0008 : rd_rsp_data <= 32'hfc0000fa;
                16'h0420 : rd_rsp_data <= 32'ha0002a0;
                16'h0430 : rd_rsp_data <= 32'ha0002a0;
                16'h0440 : rd_rsp_data <= 32'h2a0;
				16'h0450 : rd_rsp_data <= 32'h2a0;
                /* 
                16'h0450 : begin
                    case (data_0450)
                        32'h202f1 : begin
                            if (read_0450_counter < 1) begin
                                rd_rsp_data <= 32'h2e1;
                                read_0450_counter <= read_0450_counter + 1;
                            end 
                            else if ((read_0450_counter > 0) && (read_0450_counter < 4036)) begin
                                rd_rsp_data <= 32'h331;
                                read_0450_counter <= read_0450_counter + 1;
                            end 
                            else if (read_0450_counter > 4035) begin
                                rd_rsp_data <= 32'h200a03;
                            end
                        end
                        32'ha21 : begin
                            if (read_0450_counter < 2) begin
                                rd_rsp_data <= 32'ha03;
                                read_0450_counter <= read_0450_counter + 1;
                            end
                            else if (read_0450_counter > 1) begin
                                rd_rsp_data <= 32'h202e1;
                            end
                        end
                        32'h200a21 : rd_rsp_data <= 32'ha03;
                        32'h200 : rd_rsp_data <= 32'h202e1;
                        32'h20200 : rd_rsp_data <= 32'h2e1;
                        32'h210 : begin
                            read_0450_counter <= 1;
                            rd_rsp_data <= (read_0450_counter == 0) ? 32'h331 : 32'h200a03;
                        end
                        32'h200200 : rd_rsp_data <= 32'ha03;
                    endcase
                end */
                16'h000c : rd_rsp_data <= 32'h200000a;
                16'h001c : rd_rsp_data <= 32'h3f;
                16'h0804 : rd_rsp_data <= data_0804;
				
				//dump
				16'h0034 : rd_rsp_data <= 32'h00000002;
				16'h0038 : rd_rsp_data <= 32'h00000008;
				16'h0050 : rd_rsp_data <= 32'h41250000;
				16'h0054 : rd_rsp_data <= 32'h00000004;
				16'h0058 : rd_rsp_data <= 32'h0000007F;
				16'h08A8 : rd_rsp_data <= 32'h00000080;
				16'h1000 : rd_rsp_data <= 32'h00003F62;
				16'h1020 : rd_rsp_data <= 32'h00000002;
				16'h1024 : rd_rsp_data <= 32'h00C800C8;
				16'h1028 : rd_rsp_data <= 32'h00000004;
				16'h1030 : rd_rsp_data <= 32'h412D2000;
				16'h1034 : rd_rsp_data <= 32'h00000004;
				16'h1038 : rd_rsp_data <= 32'h412D30B0;
				16'h103C : rd_rsp_data <= 32'h00000004;
				16'h1040 : rd_rsp_data <= 32'h00000002;
				16'h1044 : rd_rsp_data <= 32'h00C800C8;
				16'h1048 : rd_rsp_data <= 32'h00000004;
				16'h1050 : rd_rsp_data <= 32'h412D2200;
				16'h1054 : rd_rsp_data <= 32'h00000004;
				16'h1058 : rd_rsp_data <= 32'h412DC040;
				16'h105C : rd_rsp_data <= 32'h00000004;
				16'h1060 : rd_rsp_data <= 32'h00000002;
				16'h1064 : rd_rsp_data <= 32'h00C800C8;
				16'h1068 : rd_rsp_data <= 32'h00000004;
				16'h1070 : rd_rsp_data <= 32'h412D2400;
				16'h1074 : rd_rsp_data <= 32'h00000004;
				16'h1078 : rd_rsp_data <= 32'h412E4020;
				16'h107C : rd_rsp_data <= 32'h00000004;
				16'h1080 : rd_rsp_data <= 32'h00000002;
				16'h1084 : rd_rsp_data <= 32'h00C800C8;
				16'h1088 : rd_rsp_data <= 32'h00000004;
				16'h1090 : rd_rsp_data <= 32'h412D2600;
				16'h1094 : rd_rsp_data <= 32'h00000004;
				16'h1098 : rd_rsp_data <= 32'h412F4040;
				16'h109C : rd_rsp_data <= 32'h00000004;
				16'h10A0 : rd_rsp_data <= 32'h00000002;
				16'h10A4 : rd_rsp_data <= 32'h000000C8;
				16'h10A8 : rd_rsp_data <= 32'h00000004;
				16'h10B0 : rd_rsp_data <= 32'h412D2800;
				16'h10B4 : rd_rsp_data <= 32'h00000004;
				16'h10B8 : rd_rsp_data <= 32'h412FC000;
				16'h10BC : rd_rsp_data <= 32'h00000004;
				16'h10C0 : rd_rsp_data <= 32'h00000002;
				16'h10C4 : rd_rsp_data <= 32'h00C800C8;
				16'h10C8 : rd_rsp_data <= 32'h00000004;
				16'h10D0 : rd_rsp_data <= 32'h412D2A00;
				16'h10D4 : rd_rsp_data <= 32'h00000004;
				16'h10D8 : rd_rsp_data <= 32'h4123F040;
				16'h10DC : rd_rsp_data <= 32'h00000004;
				16'h10E0 : rd_rsp_data <= 32'h00000002;
				16'h10E4 : rd_rsp_data <= 32'h00C800C8;
				16'h10E8 : rd_rsp_data <= 32'h00000004;
				16'h10F0 : rd_rsp_data <= 32'h412D2C00;
				16'h10F4 : rd_rsp_data <= 32'h00000004;
				16'h10F8 : rd_rsp_data <= 32'h41247170;
				16'h10FC : rd_rsp_data <= 32'h00000004;
				16'h1104 : rd_rsp_data <= 32'h020E0FA0;
				16'h3004 : rd_rsp_data <= 32'h40000000;
				16'h3008 : rd_rsp_data <= 32'h12FC0100;
				16'h3010 : rd_rsp_data <= 32'h091873E2;
				16'h3018 : rd_rsp_data <= 32'h47E23080;
				16'h301C : rd_rsp_data <= 32'h314C2170;



                16'h2000 : rd_rsp_data <= msix_table[0][31:0];
                16'h2004 : rd_rsp_data <= msix_address_high[0][31:0];
                16'h2008 : rd_rsp_data <= msix_table_data[0][31:0];
                16'h200C : rd_rsp_data <= msix_vector_control[0][31:0];
                16'h2010 : rd_rsp_data <= msix_table[1][31:0];
                16'h2014 : rd_rsp_data <= msix_address_high[1][31:0];
                16'h2018 : rd_rsp_data <= msix_table_data[1][31:0];
                16'h201C : rd_rsp_data <= msix_vector_control[1][31:0];
                16'h2020 : rd_rsp_data <= msix_table[2][31:0];
                16'h2024 : rd_rsp_data <= msix_address_high[2][31:0];
                16'h2028 : rd_rsp_data <= msix_table_data[2][31:0];
                16'h202C : rd_rsp_data <= msix_vector_control[2][31:0];
                16'h2030 : rd_rsp_data <= msix_table[3][31:0];
                16'h2034 : rd_rsp_data <= msix_address_high[3][31:0];
                16'h2038 : rd_rsp_data <= msix_table_data[3][31:0];
                16'h203C : rd_rsp_data <= msix_vector_control[3][31:0];
                16'h2040 : rd_rsp_data <= msix_table[4][31:0];
                16'h2044 : rd_rsp_data <= msix_address_high[4][31:0];
                16'h2048 : rd_rsp_data <= msix_table_data[4][31:0];
                16'h204C : rd_rsp_data <= msix_vector_control[4][31:0];
                16'h2050 : rd_rsp_data <= msix_table[5][31:0];
                16'h2054 : rd_rsp_data <= msix_address_high[5][31:0];
                16'h2058 : rd_rsp_data <= msix_table_data[5][31:0];
                16'h205C : rd_rsp_data <= msix_vector_control[5][31:0];
                16'h2060 : rd_rsp_data <= msix_table[6][31:0];
                16'h2064 : rd_rsp_data <= msix_address_high[6][31:0];
                16'h2068 : rd_rsp_data <= msix_table_data[6][31:0];
                16'h206C : rd_rsp_data <= msix_vector_control[6][31:0];
                16'h2070 : rd_rsp_data <= msix_table[7][31:0];
                16'h2074 : rd_rsp_data <= msix_address_high[7][31:0];
                16'h2078 : rd_rsp_data <= msix_table_data[7][31:0];
                16'h207C : rd_rsp_data <= msix_vector_control[7][31:0];
                16'h2080 : rd_rsp_data <= msix_table[8][31:0];
                16'h2084 : rd_rsp_data <= msix_address_high[8][31:0];
                16'h2088 : rd_rsp_data <= msix_table_data[8][31:0];
                16'h208C : rd_rsp_data <= msix_vector_control[8][31:0];
                16'h2090 : rd_rsp_data <= msix_table[9][31:0];
                16'h2094 : rd_rsp_data <= msix_address_high[9][31:0];
                16'h2098 : rd_rsp_data <= msix_table_data[9][31:0];
                16'h209C : rd_rsp_data <= msix_vector_control[9][31:0];
                16'h20A0 : rd_rsp_data <= msix_table[10][31:0];
                16'h20A4 : rd_rsp_data <= msix_address_high[10][31:0];
                16'h20A8 : rd_rsp_data <= msix_table_data[10][31:0];
                16'h20AC : rd_rsp_data <= msix_vector_control[10][31:0];
                16'h20B0 : rd_rsp_data <= msix_table[11][31:0];
                16'h20B4 : rd_rsp_data <= msix_address_high[11][31:0];
                16'h20B8 : rd_rsp_data <= msix_table_data[11][31:0];
                16'h20BC : rd_rsp_data <= msix_vector_control[11][31:0];
                16'h20C0 : rd_rsp_data <= msix_table[12][31:0];
                16'h20C4 : rd_rsp_data <= msix_address_high[12][31:0];
                16'h20C8 : rd_rsp_data <= msix_table_data[12][31:0];
                16'h20CC : rd_rsp_data <= msix_vector_control[12][31:0];
                16'h20D0 : rd_rsp_data <= msix_table[13][31:0];
                16'h20D4 : rd_rsp_data <= msix_address_high[13][31:0];
                16'h20D8 : rd_rsp_data <= msix_table_data[13][31:0];
                16'h20DC : rd_rsp_data <= msix_vector_control[13][31:0];
                16'h20E0 : rd_rsp_data <= msix_table[14][31:0];
                16'h20E4 : rd_rsp_data <= msix_address_high[14][31:0];
                16'h20E8 : rd_rsp_data <= msix_table_data[14][31:0];
                16'h20EC : rd_rsp_data <= msix_vector_control[14][31:0];
                16'h20F0 : rd_rsp_data <= msix_table[15][31:0];
                16'h20F4 : rd_rsp_data <= msix_address_high[15][31:0];
                16'h20F8 : rd_rsp_data <= msix_table_data[15][31:0];
                16'h20FC : rd_rsp_data <= msix_vector_control[15][31:0];
	
                //msi-x pba
                16'h3000 :begin 
                              rd_rsp_data <= msix_pba;
                          end

                default : rd_rsp_data <= 32'h00000000;
            endcase

        end else if (dwr_valid) begin
            case (({dwr_addr[31:24], dwr_addr[23:16], dwr_addr[15:08], dwr_addr[07:00]} - (base_address_register & 32'hFFFFFFF0)) & 32'h7FFF)
                

                //============写请�?===========
                16'h0020 : begin
                    case (dwr_data)
                        32'h0 : begin
                            data_0800   <= 32'h1000801;
                            case (read_0024)
                                1'b0 : begin
                                    data_0024 <= 32'h10;
                                    read_0024 <= 1'b1;
                                end 
                                default: data_0024 <= 32'h11;
                            endcase
                        end
                        32'h2 : begin
                            data_0024 <= 32'h1;
                            data_0020 <= dwr_data;
                        end
                        32'h1 : begin
                            data_0020 <= dwr_data;
                            data_0024 <= 32'h10;
                        end
                        32'h2005 : begin
                            data_0024 <= 32'h18;
                        end
                        default: data_0020 <= dwr_data;
                    endcase
                end
                
                /* 16'h0450 : begin
                    data_0450 <= dwr_data;
                    read_0450_counter <= 0;
                end */
                16'h0804 : data_0804 <= 32'he0010000;
                
                16'h2000 : msix_table[0][31:0]          <= dwr_data;
                16'h2004 : msix_address_high[0][31:0]   <= dwr_data;
                16'h2008 : msix_table_data[0][31:0]     <= dwr_data;
                16'h200C : msix_vector_control[0][31:0] <= dwr_data;
                16'h2010 : msix_table[1][31:0]          <= dwr_data;
                16'h2014 : msix_address_high[1][31:0]   <= dwr_data;
                16'h2018 : msix_table_data[1][31:0]     <= dwr_data;
                16'h201C : msix_vector_control[1][31:0] <= dwr_data;
                16'h2020 : msix_table[2][31:0]          <= dwr_data;
                16'h2024 : msix_address_high[2][31:0]   <= dwr_data;
                16'h2028 : msix_table_data[2][31:0]     <= dwr_data;
                16'h202C : msix_vector_control[2][31:0] <= dwr_data;
                16'h2030 : msix_table[3][31:0]          <= dwr_data;
                16'h2034 : msix_address_high[3][31:0]   <= dwr_data;
                16'h2038 : msix_table_data[3][31:0]     <= dwr_data;
                16'h203C : msix_vector_control[3][31:0] <= dwr_data;
                16'h2040 : msix_table[4][31:0]          <= dwr_data;
                16'h2044 : msix_address_high[4][31:0]   <= dwr_data;
                16'h2048 : msix_table_data[4][31:0]     <= dwr_data;
                16'h204C : msix_vector_control[4][31:0] <= dwr_data;
                16'h2050 : msix_table[5][31:0]          <= dwr_data;
                16'h2054 : msix_address_high[5][31:0]   <= dwr_data;
                16'h2058 : msix_table_data[5][31:0]     <= dwr_data;
                16'h205C : msix_vector_control[5][31:0] <= dwr_data;
                16'h2060 : msix_table[6][31:0]          <= dwr_data;
                16'h2064 : msix_address_high[6][31:0]   <= dwr_data;
                16'h2068 : msix_table_data[6][31:0]     <= dwr_data;
                16'h206C : msix_vector_control[6][31:0] <= dwr_data;
                16'h2070 : msix_table[7][31:0]          <= dwr_data;
                16'h2074 : msix_address_high[7][31:0]   <= dwr_data;
                16'h2078 : msix_table_data[7][31:0]     <= dwr_data;
                16'h207C : msix_vector_control[7][31:0] <= dwr_data;
                16'h2080 : msix_table[8][31:0]          <= dwr_data;
                16'h2084 : msix_address_high[8][31:0]   <= dwr_data;
                16'h2088 : msix_table_data[8][31:0]     <= dwr_data;
                16'h208C : msix_vector_control[8][31:0] <= dwr_data;
                16'h2090 : msix_table[9][31:0]          <= dwr_data;
                16'h2094 : msix_address_high[9][31:0]   <= dwr_data;
                16'h2098 : msix_table_data[9][31:0]     <= dwr_data;
                16'h209C : msix_vector_control[9][31:0] <= dwr_data;
                16'h20A0 : msix_table[10][31:0]          <= dwr_data;
                16'h20A4 : msix_address_high[10][31:0]   <= dwr_data;
                16'h20A8 : msix_table_data[10][31:0]     <= dwr_data;
                16'h20AC : msix_vector_control[10][31:0] <= dwr_data;
                16'h20B0 : msix_table[11][31:0]          <= dwr_data;
                16'h20B4 : msix_address_high[11][31:0]   <= dwr_data;
                16'h20B8 : msix_table_data[11][31:0]     <= dwr_data;
                16'h20BC : msix_vector_control[11][31:0] <= dwr_data;
                16'h20C0 : msix_table[12][31:0]          <= dwr_data;
                16'h20C4 : msix_address_high[12][31:0]   <= dwr_data;
                16'h20C8 : msix_table_data[12][31:0]     <= dwr_data;
                16'h20CC : msix_vector_control[12][31:0] <= dwr_data;
                16'h20D0 : msix_table[13][31:0]          <= dwr_data;
                16'h20D4 : msix_address_high[13][31:0]   <= dwr_data;
                16'h20D8 : msix_table_data[13][31:0]     <= dwr_data;
                16'h20DC : msix_vector_control[13][31:0] <= dwr_data;
                16'h20E0 : msix_table[14][31:0]          <= dwr_data;
                16'h20E4 : msix_address_high[14][31:0]   <= dwr_data;
                16'h20E8 : msix_table_data[14][31:0]     <= dwr_data;
                16'h20EC : msix_vector_control[14][31:0] <= dwr_data;
                16'h20F0 : msix_table[15][31:0]          <= dwr_data;
                16'h20F4 : msix_address_high[15][31:0]   <= dwr_data;
                16'h20F8 : msix_table_data[15][31:0]     <= dwr_data;
                16'h20FC : msix_vector_control[15][31:0] <= dwr_data;
				        
                16'h3000: begin
                            msix_pba_wr <= dwr_data;
                            pba_wr_valid <= 1'b1;
                         end
                default : dwr_data <= dwr_data;
            endcase
        end
   end      
    
end



    reg [31:0] interrupt_counter;
    reg [31:0] clear_counter;
    reg interrupt_active;
    
    wire [63:0] msi_address = {msix_address_high[0][31:0], msix_table[0][31:0]};
    wire [31:0] msi_data = msix_table_data[0][31:0];//wire [31:0] msi_data = msix_table_data;
    wire vector_control = msix_vector_control[0][0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            interrupt_counter <= 0;
            clear_counter <= 0;
            interrupt_active <= 0;
            interrupt_out <= 0;
            interrupt_address <= 0;
            interrupt_data <= 0;
            msix_pba_int <= 32'h00000000;
            pba_int_valid <= 1'b0;
//            debug_cnt <= 0;
        end else begin
            pba_int_valid <= 1'b0;
            
            if (interrupt_counter < 32'd100000000) begin
                interrupt_counter <= interrupt_counter + 1;
            end else begin
                interrupt_counter <= 0;
                if (!interrupt_active && !vector_control) begin
                    interrupt_active <= 1;
                    interrupt_out <= 1;
                    interrupt_address <= msi_address;
                    interrupt_data <= msi_data;
                    msix_pba_int[0] <= 1'b1;
                    pba_int_valid <= 1'b1;
                end
            end
            
            if(interrupt_done) begin
                interrupt_out <= 0;
//                debug_cnt <= debug_cnt + 1'b1;
                msix_pba_int[0] <= 1'b0;
                pba_int_valid <= 1'b1;
            end

            if (interrupt_active) begin
                if (clear_counter < 32'd997) begin
                    clear_counter <= clear_counter + 1;
                end else begin
                    clear_counter <= 0;
                    interrupt_active <= 0;
                    interrupt_out <= 0;
                    msix_pba_int[0] <= 1'b0;
                    pba_int_valid <= 1'b1;
                end
            end
        end
    end

    reg [31:0] msix_pba_reg;
    
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            msix_pba_reg <= 32'h00000000;
        end else if (pba_wr_valid) begin
            msix_pba_reg <= msix_pba_wr;
        end else if (pba_int_valid) begin
            msix_pba_reg <= msix_pba_int;
        end
    end

    assign msix_pba = msix_pba_reg;
                      
endmodule
module pcileech_bar_impl_Riffa (
 input rst,
 input clk,
 // incoming BAR writes:
 input [31:0] wr_addr,
 input [3:0] wr_be,
 input [31:0] wr_data,
 input wr_valid,
 // incoming BAR reads:
 input [87:0] rd_req_ctx,
 input [31:0] rd_req_addr,
 input rd_req_valid,
 input [31:0] base_address_register,
 // outgoing BAR read replies:
 output reg [87:0] rd_rsp_ctx,
 output reg [31:0] rd_rsp_data,
 output reg rd_rsp_valid
);
 
 reg [87:0] drd_req_ctx;
 reg [31:0] drd_req_addr;
 reg drd_req_valid;
 
 reg [31:0] dwr_addr;
 reg [31:0] dwr_data;
 reg dwr_valid;
 
 reg [31:0] data_32;
 
 time number = 0;
 
 always @ (posedge clk) begin
 if (rst)
 number <= 0;
 
 number <= number + 1;
 drd_req_ctx <= rd_req_ctx;
 drd_req_valid <= rd_req_valid;
 dwr_valid <= wr_valid;
 drd_req_addr <= rd_req_addr;
 rd_rsp_ctx <= drd_req_ctx;
 rd_rsp_valid <= drd_req_valid;
 dwr_addr <= wr_addr;
 dwr_data <= wr_data;

 if (drd_req_valid) begin
 case (  {drd_req_addr [31:24], drd_req_addr [23:16], drd_req_addr [15:08], drd_req_addr [07:00]}  & 12'h3FF)
 16'h0028 : rd_rsp_data <= {   9'b0,               // [31:23] ����
    4'd4,               // [22:19] bus_width = 128b (4 * 32b)
    3'd1,               // [18:16] max_read_size = 256B
    3'd1,               // [15:13] max_payload_size = 256B
    2'b01,              // [12:11] link_rate = 5.0GT/s
    6'd1,               // [10:5]  link_width = x1
    1'b1,               // [4]     bus_master_en = 1
    4'd1               // [3:0]   num_chnls = 1
};
 endcase
 end else if (dwr_valid) begin
 case (  {drd_req_addr [31:24], drd_req_addr [23:16], drd_req_addr [15:08], drd_req_addr [07:00]}  & 12'h3FF)
 //Dont be scared
 endcase
 end else begin
 rd_rsp_data <= 32'h00000000;
 end
 end
 
endmodule




