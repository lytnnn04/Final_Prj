`timescale 1ns / 1ps

// Nghịch đảo trong GF(2^8), modulo x^8 + x^4 + x^3 + x + 1 (0x11b).
// Toàn bộ module là logic tổ hợp, không có bảng tra hoặc phần tử nhớ.
// Với a != 0: a^(-1) = a^254. Quy ước AES: inverse(0) = 0.
module aes_gf256_inverse (
    input  wire [7:0] value,
    output wire [7:0] inverse
);
    // Reduction tuyến tính: x^8 = x^4 + x^3 + x + 1.
    function [7:0] reduce_polynomial(input [14:0] polynomial);
        reg [10:0] high_part, first_fold;
        reg [7:0] overflow, second_fold;
        begin
            high_part = {4'b0, polynomial[14:8]};
            first_fold = (high_part ^ (high_part << 1)) ^
                         ((high_part << 3) ^ (high_part << 4));
            overflow = {5'b0, first_fold[10:8]};
            second_fold = (overflow ^ (overflow << 1)) ^
                          ((overflow << 3) ^ (overflow << 4));
            reduce_polynomial = polynomial[7:0] ^ first_fold[7:0] ^ second_fold;
        end
    endfunction

    // Bình phương trong trường nhị phân chỉ cần chèn các hệ số 0 rồi XOR.
    // Không dùng multiplier tổng quát để tính a*a.
    function [7:0] square(input [7:0] a);
        begin
            square = reduce_polynomial({a[7],1'b0,a[6],1'b0,a[5],1'b0,a[4],1'b0,
                                        a[3],1'b0,a[2],1'b0,a[1],1'b0,a[0]});
        end
    endfunction

    // Tích không nhớ: 8 partial products AND, cộng bằng cây XOR 3 tầng.
    function [7:0] multiply(input [7:0] a, input [7:0] b);
        reg [14:0] partial [0:7];
        reg [14:0] pair0, pair1, pair2, pair3;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                partial[i] = {7'b0, (b & {8{a[i]}})} << i;
            pair0 = partial[0] ^ partial[1];
            pair1 = partial[2] ^ partial[3];
            pair2 = partial[4] ^ partial[5];
            pair3 = partial[6] ^ partial[7];
            multiply = reduce_polynomial((pair0 ^ pair1) ^ (pair2 ^ pair3));
        end
    endfunction

    // Addition chain: 7 phép bình phương tuyến tính + 4 phép nhân.
    // Biến reg cục bộ chỉ chứa kết quả tổ hợp, không phải thanh ghi clock.
    function [7:0] invert(input [7:0] a);
        reg [7:0] power2, power3, power6, power12, power15;
        reg [7:0] power30, power60, power120, power240, power252;
        begin
            power2   = square(a);
            power3   = multiply(power2, a);
            power6   = square(power3);
            power12  = square(power6);
            power15  = multiply(power12, power3);
            power30  = square(power15);
            power60  = square(power30);
            power120 = square(power60);
            power240 = square(power120);
            power252 = multiply(power240, power12);
            invert   = multiply(power252, power2);
        end
    endfunction
    assign inverse = invert(value);
endmodule

// AES S-box: nghịch đảo GF(2^8), sau đó affine của FIPS 197.
module aes_sbox_comb (
    input  wire [7:0] data_in,
    output wire [7:0] data_out
);
    wire [7:0] inv;
    aes_gf256_inverse u_inverse (.value(data_in), .inverse(inv));
    assign data_out = inv ^ {inv[6:0],inv[7]} ^ {inv[5:0],inv[7:6]} ^
                      {inv[4:0],inv[7:5]} ^ {inv[3:0],inv[7:4]} ^ 8'h63;
endmodule

// Inverse S-box: affine nghịch đảo TRƯỚC, rồi nghịch đảo GF(2^8).
module aes_inv_sbox_comb (
    input  wire [7:0] data_in,
    output wire [7:0] data_out
);
    wire [7:0] inverse_affine = {data_in[6:0],data_in[7]} ^
                               {data_in[4:0],data_in[7:5]} ^
                               {data_in[1:0],data_in[7:2]} ^ 8'h05;
    aes_gf256_inverse u_inverse (.value(inverse_affine), .inverse(data_out));
endmodule
