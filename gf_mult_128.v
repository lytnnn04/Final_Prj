`timescale 1ns / 1ps

// Nhân GF(2^128) tổ hợp: partial products AND, cây XOR, reduction cố định.
// Polynomial basis / mạng reduction kiểu Mastrovito, KHÔNG có RAM hay clock.
// GHASH bit 127 là hệ số x^0; bit 0 là hệ số x^127 (NIST SP 800-38D).
module gf_mult_128 (
    input  wire [127:0] a,
    input  wire [127:0] b,
    output wire [127:0] product
);
    // Đảo bit để poly[i] đúng nghĩa hệ số x^i. Đây chỉ là nối dây.
    wire [127:0] a_poly, b_poly;
    wire [127:0] reduced;
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 128; bit_index = bit_index + 1) begin : bit_order
            assign a_poly[bit_index] = a[127-bit_index];
            assign b_poly[bit_index] = b[127-bit_index];
            assign product[127-bit_index] = reduced[bit_index];
        end
    endgenerate

    // Tích đa thức chưa reduction có bậc tối đa 254.
    // Cây nhị phân: 128 lá (128..255), 7 tầng XOR, gốc tại node 1.
    // Shift theo genvar là nối dây cố định, không tạo barrel shifter.
    wire [254:0] xor_tree [1:255];
    genvar row, node;
    generate
        for (row = 0; row < 128; row = row + 1) begin : partial_products
            assign xor_tree[128+row] =
                {127'b0, (b_poly & {128{a_poly[row]}})} << row;
        end
        for (node = 1; node < 128; node = node + 1) begin : xor_levels
            assign xor_tree[node] = xor_tree[2*node] ^ xor_tree[2*node+1];
        end
    endgenerate

    // Modulo x^128 + x^7 + x^2 + x + 1:
    // x^128 = x^7 + x^2 + x + 1.
    // Gấp phần bậc cao xuống; tối đa còn 6 bit tràn (bậc 128..133).
    // Gấp lần hai loại hết tràn. Cả hai lần đều là mạng XOR cố định.
    wire [133:0] high_part = {7'b0, xor_tree[1][254:128]};
    wire [133:0] first_fold = (high_part ^ (high_part << 1)) ^
                              ((high_part << 2) ^ (high_part << 7));
    wire [127:0] overflow = {122'b0, first_fold[133:128]};
    wire [127:0] second_fold = (overflow ^ (overflow << 1)) ^
                               ((overflow << 2) ^ (overflow << 7));

    assign reduced = xor_tree[1][127:0] ^ first_fold[127:0] ^ second_fold;
endmodule
