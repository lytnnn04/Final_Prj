`timescale 1ns / 1ps

// Biến đổi ShiftRows chuẩn AES
module aes_shift_rows (
    input  wire [127:0] in,
    output wire [127:0] out
);
    // Hàng 0: Không dịch
    assign out[127:120] = in[127:120];
    assign out[95:88]   = in[95:88];
    assign out[63:56]   = in[63:56];
    assign out[31:24]   = in[31:24];
    // Hàng 1: Dịch trái 1 byte
    assign out[119:112] = in[87:80];
    assign out[87:80]   = in[55:48];
    assign out[55:48]   = in[23:16];
    assign out[23:16]   = in[119:112];
    // Hàng 2: Dịch trái 2 byte
    assign out[111:104] = in[47:40];
    assign out[79:72]   = in[15:8];
    assign out[47:40]   = in[111:104];
    assign out[15:8]    = in[79:72];
    // Hàng 3: Dịch trái 3 byte
    assign out[103:96]  = in[7:0];
    assign out[71:64]   = in[103:96];
    assign out[39:32]   = in[71:64];
    assign out[7:0]     = in[39:32];
endmodule

// Biến đổi Inverse ShiftRows chuẩn AES
module aes_inv_shift_rows (
    input  wire [127:0] in,
    output wire [127:0] out
);
    assign out[127:120] = in[127:120];
    assign out[95:88]   = in[95:88];
    assign out[63:56]   = in[63:56];
    assign out[31:24]   = in[31:24];

    assign out[119:112] = in[23:16];
    assign out[87:80]   = in[119:112];
    assign out[55:48]   = in[87:80];
    assign out[23:16]   = in[55:48];

    assign out[111:104] = in[47:40];
    assign out[79:72]   = in[15:8];
    assign out[47:40]   = in[111:104];
    assign out[15:8]    = in[79:72];

    assign out[103:96]  = in[71:64];
    assign out[71:64]   = in[39:32];
    assign out[39:32]   = in[7:0];
    assign out[7:0]     = in[103:96];
endmodule

// Nhân MixColumns cho 1 cột 32-bit
module aes_mix_column_32 (
    input  wire [31:0] col_in,
    output wire [31:0] col_out
);
    wire [7:0] s0 = col_in[31:24];
    wire [7:0] s1 = col_in[23:16];
    wire [7:0] s2 = col_in[15:8];
    wire [7:0] s3 = col_in[7:0];

    function [7:0] xtime(input [7:0] b);
        xtime = (b[7]) ? ((b << 1) ^ 8'h1b) : (b << 1);
    endfunction

    assign col_out[31:24] = xtime(s0) ^ (xtime(s1) ^ s1) ^ s2 ^ s3;
    assign col_out[23:16] = s0 ^ xtime(s1) ^ (xtime(s2) ^ s2) ^ s3;
    assign col_out[15:8]  = s0 ^ s1 ^ xtime(s2) ^ (xtime(s3) ^ s3);
    assign col_out[7:0]   = (xtime(s0) ^ s0) ^ s1 ^ s2 ^ xtime(s3);
endmodule

module aes_mix_columns (
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    genvar i;
    generate
        for(i = 0; i < 4; i = i + 1) begin : mix_loop
            aes_mix_column_32 u_col (
                .col_in  (state_in [127 - 32*i : 96 - 32*i]),
                .col_out (state_out[127 - 32*i : 96 - 32*i])
            );
        end
    endgenerate
endmodule

// Nhân Inverse MixColumns cho 1 cột 32-bit
module aes_inv_mix_column_32 (
    input  wire [31:0] col_in,
    output wire [31:0] col_out
);
    wire [7:0] s0 = col_in[31:24];
    wire [7:0] s1 = col_in[23:16];
    wire [7:0] s2 = col_in[15:8];
    wire [7:0] s3 = col_in[7:0];

    function [7:0] xtime(input [7:0] b);
        xtime = (b[7]) ? ((b << 1) ^ 8'h1b) : (b << 1);
    endfunction

    function [7:0] mul9 (input [7:0] b); mul9  = xtime(xtime(xtime(b))) ^ b; endfunction
    function [7:0] mul11(input [7:0] b); mul11 = xtime(xtime(xtime(b))) ^ xtime(b) ^ b; endfunction
    function [7:0] mul13(input [7:0] b); mul13 = xtime(xtime(xtime(b))) ^ xtime(xtime(b)) ^ b; endfunction
    function [7:0] mul14(input [7:0] b); mul14 = xtime(xtime(xtime(b))) ^ xtime(xtime(b)) ^ xtime(b); endfunction

    assign col_out[31:24] = mul14(s0) ^ mul11(s1) ^ mul13(s2) ^ mul9(s3);
    assign col_out[23:16] = mul9(s0)  ^ mul14(s1) ^ mul11(s2) ^ mul13(s3);
    assign col_out[15:8]  = mul13(s0) ^ mul9(s1)  ^ mul14(s2) ^ mul11(s3);
    assign col_out[7:0]   = mul11(s0) ^ mul13(s1) ^ mul9(s2)  ^ mul14(s3);
endmodule

module aes_inv_mix_columns (
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    genvar i;
    generate
        for(i = 0; i < 4; i = i + 1) begin : inv_mix_loop
            aes_inv_mix_column_32 u_col (
                .col_in  (state_in [127 - 32*i : 96 - 32*i]),
                .col_out (state_out[127 - 32*i : 96 - 32*i])
            );
        end
    endgenerate
endmodule

// Phép nhân Tweak với alpha trong GF(2^128) theo chuẩn IEEE 1619
module gf_mult_alpha (
    input  wire [127:0] din,
    output wire [127:0] dout
);
    wire [7:0] b  [0:15];
    wire [7:0] nb [0:15];
    genvar k;
    generate
        for (k = 0; k < 16; k = k + 1) begin : unpack
            assign b[k] = din[127 - 8*k : 120 - 8*k];
        end
    endgenerate

    assign nb[0] = {b[0][6:0], 1'b0} ^ (b[15][7] ? 8'h87 : 8'h00);
    generate
        for (k = 1; k < 16; k = k + 1) begin : shift_chain
            assign nb[k] = {b[k][6:0], 1'b0} ^ (b[k-1][7] ? 8'h01 : 8'h00);
        end
    endgenerate

    generate
        for (k = 0; k < 16; k = k + 1) begin : pack
            assign dout[127 - 8*k : 120 - 8*k] = nb[k];
        end
    endgenerate
endmodule
