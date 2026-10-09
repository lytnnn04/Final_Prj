`timescale 1ns / 1ps

// Engine lặp nhỏ gọn dùng chung cho BIST, Kauth, Subkey H, GMAC J0, Tweak T0
module aes_128_setup_iterative (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] data_in,
    input  wire [127:0] key_in,
    output wire [127:0] data_out,
    output reg          busy,
    output reg          done
);
    localparam ST_IDLE          = 2'd0;
    localparam ST_KEY_LOOKUP    = 2'd1;
    localparam ST_STATE_LOOKUP  = 2'd2;
    localparam ST_ROUND_CAPTURE = 2'd3;

    reg [1:0]   state;
    reg [3:0]   round_idx;
    reg [127:0] state_reg;
    reg [127:0] round_key_reg;
    reg [127:0] result_reg;

    reg [7:0]   sbox_addr_a [0:7];
    reg [7:0]   sbox_addr_b [0:7];
    wire [7:0]  sbox_q_a [0:7];
    wire [7:0]  sbox_q_b [0:7];
    wire [127:0] state_sub;

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : setup_sbox_banks
            aes_sbox_m20k_dp u_sbox (
                .clk(clk), .en(1'b1),
                .addr_a(sbox_addr_a[b]), .addr_b(sbox_addr_b[b]),
                .q_a(sbox_q_a[b]),       .q_b(sbox_q_b[b])
            );
            assign state_sub[127 - 16*b -: 8] = sbox_q_a[b];
            assign state_sub[119 - 16*b -: 8] = sbox_q_b[b];
        end
    endgenerate

    integer a_idx;
    always @(*) begin
        for (a_idx = 0; a_idx < 8; a_idx = a_idx + 1) begin
            sbox_addr_a[a_idx] = 8'b0;
            sbox_addr_b[a_idx] = 8'b0;
        end
        if (state == ST_KEY_LOOKUP) begin
            sbox_addr_a[0] = round_key_reg[23:16];
            sbox_addr_b[0] = round_key_reg[15:8];
            sbox_addr_a[1] = round_key_reg[7:0];
            sbox_addr_b[1] = round_key_reg[31:24];
        end else if (state == ST_STATE_LOOKUP) begin
            for (a_idx = 0; a_idx < 8; a_idx = a_idx + 1) begin
                sbox_addr_a[a_idx] = state_reg[127 - 16*a_idx -: 8];
                sbox_addr_b[a_idx] = state_reg[119 - 16*a_idx -: 8];
            end
        end
    end

    function [7:0] get_rcon(input [3:0] r);
        case (r)
            4'd1: get_rcon = 8'h01; 4'd2: get_rcon = 8'h02;
            4'd3: get_rcon = 8'h04; 4'd4: get_rcon = 8'h08;
            4'd5: get_rcon = 8'h10; 4'd6: get_rcon = 8'h20;
            4'd7: get_rcon = 8'h40; 4'd8: get_rcon = 8'h80;
            4'd9: get_rcon = 8'h1b; default: get_rcon = 8'h36;
        endcase
    endfunction

    wire [31:0] subword = {sbox_q_a[0], sbox_q_b[0], sbox_q_a[1], sbox_q_b[1]};
    wire [31:0] w0 = round_key_reg[127:96];
    wire [31:0] w1 = round_key_reg[95:64];
    wire [31:0] w2 = round_key_reg[63:32];
    wire [31:0] w3 = round_key_reg[31:0];
    wire [31:0] w4 = w0 ^ subword ^ {get_rcon(round_idx), 24'b0};
    wire [31:0] w5 = w4 ^ w1;
    wire [31:0] w6 = w5 ^ w2;
    wire [31:0] w7 = w6 ^ w3;
    wire [127:0] next_round_key = {w4, w5, w6, w7};

    wire [127:0] shifted;
    wire [127:0] mixed;
    aes_shift_rows u_shift (.in(state_sub), .out(shifted));
    aes_mix_columns u_mix  (.state_in(shifted), .state_out(mixed));

    assign data_out = result_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            round_idx     <= 4'd0;
            state_reg     <= 128'b0;
            round_key_reg <= 128'b0;
            result_reg    <= 128'b0;
            busy          <= 1'b0;
            done          <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        state_reg     <= data_in ^ key_in;
                        round_key_reg <= key_in;
                        round_idx     <= 4'd1;
                        busy          <= 1'b1;
                        state         <= ST_KEY_LOOKUP;
                    end
                end
                ST_KEY_LOOKUP: state <= ST_STATE_LOOKUP;
                ST_STATE_LOOKUP: begin
                    round_key_reg <= next_round_key;
                    state         <= ST_ROUND_CAPTURE;
                end
                ST_ROUND_CAPTURE: begin
                    if (round_idx == 4'd10) begin
                        result_reg <= shifted ^ round_key_reg;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        state_reg <= mixed ^ round_key_reg;
                        round_idx <= round_idx + 1'b1;
                        state     <= ST_KEY_LOOKUP;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
