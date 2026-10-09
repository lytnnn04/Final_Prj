`timescale 1ns / 1ps

// Hai S-box tổ hợp + thanh ghi DFF ở đầu ra.
// Giữ latency 1 clock-enable để setup và key schedule không lệch dữ liệu.
module aes_sbox_pair_sync (
    input  wire       clk,
    input  wire       en,
    input  wire [7:0] data_a,
    input  wire [7:0] data_b,
    output reg  [7:0] q_a,
    output reg  [7:0] q_b
);
    wire [7:0] sub_a, sub_b;
    aes_sbox_comb u_a (.data_in(data_a), .data_out(sub_a));
    aes_sbox_comb u_b (.data_in(data_b), .data_out(sub_b));
    always @(posedge clk) begin
        if (en) begin
            q_a <= sub_a;
            q_b <= sub_b;
        end
    end
endmodule

// 16 S-box song song + DFF. en=0 giữ nguyên tất cả các byte.
module aes_sub_bytes_sync (
    input  wire         clk,
    input  wire         en,
    input  wire [127:0] state_in,
    output reg  [127:0] state_out
);
    wire [127:0] substituted;
    genvar byte_index;
    generate
        for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1) begin : bytes
            aes_sbox_comb u_sbox (
                .data_in(state_in[127 - 8*byte_index -: 8]),
                .data_out(substituted[127 - 8*byte_index -: 8])
            );
        end
    endgenerate
    always @(posedge clk) begin
        if (en) state_out <= substituted;
    end
endmodule

module aes_inv_sub_bytes_sync (
    input  wire         clk,
    input  wire         en,
    input  wire [127:0] state_in,
    output reg  [127:0] state_out
);
    wire [127:0] substituted;
    genvar byte_index;
    generate
        for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1) begin : bytes
            aes_inv_sbox_comb u_sbox (
                .data_in(state_in[127 - 8*byte_index -: 8]),
                .data_out(substituted[127 - 8*byte_index -: 8])
            );
        end
    endgenerate
    always @(posedge clk) begin
        if (en) state_out <= substituted;
    end
endmodule
