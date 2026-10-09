`timescale 1ns / 1ps

module ghash_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    input  wire         invalidate_table,
    input  wire         table_start,
    input  wire         valid,
    input  wire [127:0] block_in,
    input  wire [127:0] hash_subkey,
    output reg  [127:0] accumulator,
    output wire         busy,
    output wire         ready,
    output reg          done,
    output reg          table_ready
);
    localparam [127:0] GHASH_R = 128'he1000000000000000000000000000000;
    localparam GH_IDLE    = 2'd0;
    localparam GH_CAPTURE = 2'd1;
    localparam GH_PARTIAL = 2'd2;
    localparam GH_FINAL   = 2'd3;

    // 16 Bảng M20K độc lập tương ứng 16 vị trí byte
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table0  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table1  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table2  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table3  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table4  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table5  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table6  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table7  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table8  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table9  [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table10 [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table11 [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table12 [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table13 [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table14 [0:255];
    (* ramstyle = "M20K, no_rw_check" *) reg [127:0] h_table15 [0:255];

    reg         table_building;
    reg [7:0]   table_write_addr;
    reg [2:0]   table_build_bit;
    reg [4:0]   table_build_phase;
    reg [127:0] table_h;
    reg [127:0] table_build_z;
    reg [127:0] table_build_v;

    reg [1:0] state;
    reg [127:0] h_q0,  h_q1,  h_q2,  h_q3;
    reg [127:0] h_q4,  h_q5,  h_q6,  h_q7;
    reg [127:0] h_q8,  h_q9,  h_q10, h_q11;
    reg [127:0] h_q12, h_q13, h_q14, h_q15;

    reg [127:0] h_snap0,  h_snap1,  h_snap2,  h_snap3;
    reg [127:0] h_snap4,  h_snap5,  h_snap6,  h_snap7;
    reg [127:0] h_snap8,  h_snap9,  h_snap10, h_snap11;
    reg [127:0] h_snap12, h_snap13, h_snap14, h_snap15;
    reg [127:0] partial0, partial1, partial2, partial3;

    function [127:0] ghash_shift_one(input [127:0] val);
        ghash_shift_one = val[0] ? ((val >> 1) ^ GHASH_R) : (val >> 1);
    endfunction

    wire table_build_selected = table_write_addr[7 - table_build_bit];
    wire [127:0] table_base_next  = table_build_selected ? (table_build_z ^ table_build_v) : table_build_z;
    wire [127:0] table_shift_next = ghash_shift_one(table_build_z);
    wire [127:0] table_v_next     = ghash_shift_one(table_build_v);
    wire table_write_fire         = table_building && (table_build_bit == 3'd7);

    always @(posedge clk) begin
        if (table_write_fire) begin
            case (table_build_phase)
                5'd0:  h_table0  [table_write_addr] <= table_base_next;
                5'd1:  h_table1  [table_write_addr] <= table_shift_next;
                5'd2:  h_table2  [table_write_addr] <= table_shift_next;
                5'd3:  h_table3  [table_write_addr] <= table_shift_next;
                5'd4:  h_table4  [table_write_addr] <= table_shift_next;
                5'd5:  h_table5  [table_write_addr] <= table_shift_next;
                5'd6:  h_table6  [table_write_addr] <= table_shift_next;
                5'd7:  h_table7  [table_write_addr] <= table_shift_next;
                5'd8:  h_table8  [table_write_addr] <= table_shift_next;
                5'd9:  h_table9  [table_write_addr] <= table_shift_next;
                5'd10: h_table10 [table_write_addr] <= table_shift_next;
                5'd11: h_table11 [table_write_addr] <= table_shift_next;
                5'd12: h_table12 [table_write_addr] <= table_shift_next;
                5'd13: h_table13 [table_write_addr] <= table_shift_next;
                5'd14: h_table14 [table_write_addr] <= table_shift_next;
                5'd15: h_table15 [table_write_addr] <= table_shift_next;
                default: ;
            endcase
        end
    end

    wire final_stage = (state == GH_FINAL);
    assign ready = table_ready && !table_building && ((state == GH_IDLE) || final_stage) && !clear && !invalidate_table;
    wire accept = valid && ready;
    wire [127:0] final_result = partial0 ^ partial1 ^ partial2 ^ partial3;
    wire [127:0] accept_base  = final_stage ? final_result : accumulator;
    wire [127:0] accept_mixed = accept_base ^ block_in;
    wire [127:0] lookup_x     = accept ? accept_mixed : 128'b0;

    always @(posedge clk) begin
        h_q0  <= h_table0  [lookup_x[127:120]];
        h_q1  <= h_table1  [lookup_x[119:112]];
        h_q2  <= h_table2  [lookup_x[111:104]];
        h_q3  <= h_table3  [lookup_x[103:96]];
        h_q4  <= h_table4  [lookup_x[95:88]];
        h_q5  <= h_table5  [lookup_x[87:80]];
        h_q6  <= h_table6  [lookup_x[79:72]];
        h_q7  <= h_table7  [lookup_x[71:64]];
        h_q8  <= h_table8  [lookup_x[63:56]];
        h_q9  <= h_table9  [lookup_x[55:48]];
        h_q10 <= h_table10 [lookup_x[47:40]];
        h_q11 <= h_table11 [lookup_x[39:32]];
        h_q12 <= h_table12 [lookup_x[31:24]];
        h_q13 <= h_table13 [lookup_x[23:16]];
        h_q14 <= h_table14 [lookup_x[15:8]];
        h_q15 <= h_table15 [lookup_x[7:0]];
    end

    assign busy = table_building || (state != GH_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator       <= 128'b0;
            table_ready       <= 1'b0;
            table_building    <= 1'b0;
            table_write_addr  <= 8'b0;
            table_build_bit   <= 3'b0;
            table_build_phase <= 5'b0;
            table_h           <= 128'b0;
            table_build_z     <= 128'b0;
            table_build_v     <= 128'b0;
            state             <= GH_IDLE;
            done              <= 1'b0;
        end else begin
            done <= 1'b0;
            if (invalidate_table) begin
                accumulator    <= 128'b0;
                table_ready    <= 1'b0;
                table_building <= 1'b0;
                state          <= GH_IDLE;
            end else if (table_start) begin
                table_ready       <= 1'b0;
                table_building    <= 1'b1;
                table_write_addr  <= 8'b0;
                table_build_bit   <= 3'b0;
                table_build_phase <= 5'b0;
                table_h           <= hash_subkey;
                table_build_z     <= 128'b0;
                table_build_v     <= hash_subkey;
                accumulator       <= 128'b0;
                state             <= GH_IDLE;
            end else if (table_building) begin
                if (table_build_phase == 5'd0) begin
                    if (table_build_bit == 3'd7) begin
                        table_build_phase <= 5'd1;
                        table_build_bit   <= 3'd0;
                        table_build_z     <= table_base_next;
                    end else begin
                        table_build_bit <= table_build_bit + 1'b1;
                        table_build_z   <= table_base_next;
                        table_build_v   <= table_v_next;
                    end
                end else begin
                    table_build_z <= table_shift_next;
                    if (table_build_bit == 3'd7) begin
                        table_build_bit <= 3'd0;
                        if (table_build_phase == 5'd15) begin
                            if (table_write_addr == 8'hff) begin
                                table_building <= 1'b0;
                                table_ready    <= 1'b1;
                            end else begin
                                table_write_addr  <= table_write_addr + 1'b1;
                                table_build_phase <= 5'd0;
                                table_build_z     <= 128'b0;
                                table_build_v     <= table_h;
                            end
                        end else begin
                            table_build_phase <= table_build_phase + 1'b1;
                        end
                    end else begin
                        table_build_bit <= table_build_bit + 1'b1;
                    end
                end
            end else if (clear) begin
                accumulator <= 128'b0;
                state       <= GH_IDLE;
            end else begin
                case (state)
                    GH_IDLE: begin
                        if (accept) state <= GH_CAPTURE;
                    end
                    GH_CAPTURE: begin
                        h_snap0  <= h_q0;  h_snap1  <= h_q1;
                        h_snap2  <= h_q2;  h_snap3  <= h_q3;
                        h_snap4  <= h_q4;  h_snap5  <= h_q5;
                        h_snap6  <= h_q6;  h_snap7  <= h_q7;
                        h_snap8  <= h_q8;  h_snap9  <= h_q9;
                        h_snap10 <= h_q10; h_snap11 <= h_q11;
                        h_snap12 <= h_q12; h_snap13 <= h_q13;
                        h_snap14 <= h_q14; h_snap15 <= h_q15;
                        state <= GH_PARTIAL;
                    end
                    GH_PARTIAL: begin
                        partial0 <= h_snap0  ^ h_snap1  ^ h_snap2  ^ h_snap3;
                        partial1 <= h_snap4  ^ h_snap5  ^ h_snap6  ^ h_snap7;
                        partial2 <= h_snap8  ^ h_snap9  ^ h_snap10 ^ h_snap11;
                        partial3 <= h_snap12 ^ h_snap13 ^ h_snap14 ^ h_snap15;
                        state <= GH_FINAL;
                    end
                    GH_FINAL: begin
                        accumulator <= final_result;
                        done        <= 1'b1;
                        state       <= accept ? GH_CAPTURE : GH_IDLE;
                    end
                    default: state <= GH_IDLE;
                endcase
            end
        end
    end
endmodule
