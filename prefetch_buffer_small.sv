// Copyright 2015 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the “License”); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Markus Wegmann - markus.wegmann@technokrat.ch              //
//                                                                            //
// Design Name:    Prefetcher Buffer for 32 bit memory interface              //
// Project Name:   littleRISCV                                                //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Prefetch buffer to cache 16 bit instruction part.          //
//                 Reduces gate count but might increase CPI.                 //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////


`include "riscv_config.sv"



module riscv_prefetch_buffer
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_i,

  input  logic        branch_i,
  input  logic [31:0] addr_i,

  input  logic        ready_i,
  output logic        valid_o,
  output logic [31:0] rdata_o,
  output logic [31:0] addr_o,

  // goes to instruction memory / instruction cache
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_rvalid_i,

  // Prefetch Buffer Status
  output logic        busy_o
);
  

  /// Regs
  enum logic [1:0] {IDLE, WAIT_GNT, WAIT_RVALID, WAIT_ABORTED } CS, NS;

  logic [15:0]  last_instr_rdata_Q, last_instr_rdata_n; // A 16 bit register to store one compressed instruction or half full instruction for next fetch
  logic [31:0]  last_instr_addr_Q, last_instr_addr_n; // The adress from the last fetch
  logic         last_addr_valid_Q, last_addr_valid_n; // Content of registers is valid
  logic         last_addr_misaligned_Q, last_addr_misaligned_n; // Indicates whether we need to fetch the second part of an misaligned full instruction


  /// Combinational signals
  logic [31:0]  addr_next; // Calculate the next adress. This is THE actual process counter (PC)
  logic [31:0]  addr_selected; // The next address selected to be used

  logic instr_is_compressed; // Shows if current instruction fetch is compressed
  logic instr_is_misaligned;
  logic instr_part_in_fifo; // Indicates if address (mod 4) is already fetched.
  logic instr_part_in_fifo_is_compressed;


  assign busy_o = (CS != IDLE) || instr_req_o;

  assign instr_is_compressed = (instr_rdata_i[1:0] != 2'b11); // Check if instruction is not a 32 bit instruction and therefore compressed
  assign addr_is_misaligned = (addr_selected[1] == 1'b1); // Check if address is (addr/2 mod 2) == 1

  assign instr_part_in_fifo = ( last_addr_valid_Q && (addr_selected[31:2] == last_instr_addr_Q[31:2]) && addr_is_misaligned); // Check if addresses are the same word
  assign instr_part_in_fifo_is_compressed = (last_instr_rdata_Q[1:0] != 2'b11);


  // TODO: Remove UNKNOWN_ALIGNED value
  enum logic [2:0] {UNKNOWN_ALIGNED, FULL_INSTR_ALIGNED, C_INSTR_ALIGNED, C_INSTR_IN_REG, PART_INSTR_IN_REG} instruction_format;



  // Calculate next address
  always_comb
  begin
    unique case (instruction_format)
      UNKNOWN_ALIGNED:    addr_next = last_instr_addr_n;
      FULL_INSTR_ALIGNED: addr_next = last_instr_addr_n + 32'h4;
      C_INSTR_ALIGNED:    addr_next = last_instr_addr_n + 32'h2;
      C_INSTR_IN_REG:     addr_next = last_instr_addr_n + 32'h2;
      PART_INSTR_IN_REG:  addr_next = last_instr_addr_n + 32'h4;
      default:            addr_next = last_instr_addr_n;
    endcase
  end

  // Construct the outgoing instruction
  always_comb
  begin
    unique case (instruction_format)
      UNKNOWN_ALIGNED:    rdata_o = 32'h0000;
      FULL_INSTR_ALIGNED: rdata_o = instr_rdata_i;
      C_INSTR_ALIGNED:    rdata_o = {16'h0000, instr_rdata_i[15:0]};
      C_INSTR_IN_REG:     rdata_o = {16'h0000, last_instr_rdata_Q};
      PART_INSTR_IN_REG:  rdata_o = {instr_rdata_i[15:0], last_instr_rdata_Q};
      default:            rdata_o = 32'h0000;
    endcase
  end


  always_comb
  begin
    NS = CS;

    last_instr_rdata_n = last_instr_rdata_Q; // Throw away lower part to keep instruction register at 16 bit
    last_instr_addr_n = last_instr_addr_Q;
    last_addr_valid_n = last_addr_valid_Q;
    last_addr_misaligned_n = last_addr_misaligned_Q;

    valid_o = 0'b0;
    instr_req_o = 1'b0;
    instr_addr_o = 32'b0;

    addr_selected = addr_next;
    addr_o = last_instr_addr_Q;
    instruction_format = UNKNOWN_ALIGNED;


    unique case (CS)
      IDLE: begin
        last_addr_misaligned_n = 1'b0;

        if (req_i) begin

          if (branch_i)
            addr_selected = addr_i;


          // Check if already buffered
          if (instr_part_in_fifo && instr_part_in_fifo_is_compressed) begin
            instruction_format = C_INSTR_IN_REG;
            addr_o = addr_selected;
            valid_o = 1'b1;
            NS = IDLE;

          end else if (instr_part_in_fifo && ~instr_part_in_fifo_is_compressed) begin
            last_addr_misaligned_n = 1'b1;
            last_instr_addr_n = addr_selected;
            
            instr_req_o = 1'b1;
            instr_addr_o = {addr_selected[31:2] + 30'h1, 2'b00};

            if (instr_gnt_i)
              NS = WAIT_RVALID;
            else
              NS = WAIT_GNT;
          end
          
          else begin
            last_instr_addr_n = addr_selected;

            instr_req_o = 1'b1;
            instr_addr_o = {addr_selected[31:0], 2'b00};

            if (instr_gnt_i)
              NS = WAIT_RVALID;
            else
              NS = WAIT_GNT;
          end
        end
      end


      WAIT_GNT: begin
        if (last_addr_misaligned_Q) begin
          instr_req_o = 1'b1;
          instr_addr_o = {last_instr_addr_Q[31:2] + 30'h1, 2'b00};

          if (instr_gnt_i)
              NS = WAIT_RVALID;
          else
              NS = WAIT_GNT;
        end 

        else begin
          instr_req_o = 1'b1;
          instr_addr_o = {last_instr_addr_Q[31:2], 2'b00};

          if (instr_gnt_i)
              NS = WAIT_RVALID;
          else
              NS = WAIT_GNT;
        end
      end


      WAIT_RVALID: begin
        if (~branch_i) begin
          
          NS = WAIT_RVALID;

          if (instr_rvalid_i) begin

            // Regs
            last_instr_rdata_n = instr_rdata_i;
            last_addr_valid_n = 1'b1;
            last_addr_misaligned_n = 1'b0;


            // Output
            if (last_addr_misaligned_Q) begin

              instruction_format = PART_INSTR_IN_REG;
              addr_o = last_instr_addr_Q - 32'h2;
              valid_o = 1'b1;

              NS = IDLE; // Can go to IDLE as there is still information to process (and we do not want an unneccessary access if next instruction should be compressed)
            end

            else if (last_instr_addr_Q[1] == 1'b0) // If last address is aligned
              if (instr_rdata_i[1:0] != 2'b11) begin // If compressed
                instruction_format = C_INSTR_ALIGNED;
                addr_o = last_instr_addr_Q;
                valid_o = 1'b1;
                NS = IDLE; // Can go to IDLE as there is still information to process (and we do not want an unneccessary access if next instruction should be compressed as well)
              end

              else begin
                instruction_format = FULL_INSTR_ALIGNED;
                addr_o = last_instr_addr_Q;
                valid_o = 1'b1;

                instr_req_o = 1'b1;
                last_instr_addr_n = addr_selected;
                instr_addr_o = addr_selected;

                if (instr_gnt_i)
                  NS = WAIT_RVALID;
                else
                  NS = WAIT_GNT;
              end
            end
            
            else begin // If last address is misaligned
              if (instr_rdata_i[1:0] != 2'b11) begin // If compressed
              
                instruction_format = C_INSTR_IN_REG;
                addr_o = last_instr_addr_Q;
                valid_o = 1'b1;
                
                instr_req_o = 1'b1;
                last_instr_addr_n = addr_selected;
                instr_addr_o = addr_selected;

                if (instr_gnt_i)
                  NS = WAIT_RVALID;
                else
                  NS = WAIT_GNT;
              end

              else begin // Instruction is overlapping
                last_addr_misaligned_n = 1'b1;
                last_instr_addr_n = addr_selected;
                
                instr_req_o = 1'b1;
                instr_addr_o = {addr_selected[31:2] + 30'h1, 2'b00};

                if (instr_gnt_i)
                  NS = WAIT_RVALID;
                else
                  NS = WAIT_GNT;
              end
            end
          end
        end 

        else begin
          last_addr_valid_n = 1'b0;

          if (instr_rvalid_i)
            NS = IDLE;
          else
            NS = WAIT_ABORTED;
        end
      end


      WAIT_ABORTED: begin
        if (instr_rvalid_i)
          NS = IDLE;
        else
          NS = WAIT_ABORTED;
      end

      default: NS = IDLE;

    end
  end



  //////////////////////////////////////////////////////////////////////////////
  // registers                                                                //
  //////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk, negedge rst_n)
  begin
    if(rst_n == 1'b0)
    begin
      CS                  <= IDLE;

      last_instr_rdata_Q  <= 16'h00;
      last_instr_addr_Q   <= 32'h0000;
      last_addr_valid_Q   <= 1'b0;
      last_addr_misaligned_Q <= 1'b0;
    end  
    else begin
      CS                  <= NS;

      last_instr_rdata_Q  <= last_instr_rdata_n;
      last_instr_addr_Q   <= last_instr_addr_n;
      last_addr_valid_Q   <= last_addr_valid_n;
      last_addr_misaligned_Q <= last_addr_misaligned_n;
    end
  end

endmodule