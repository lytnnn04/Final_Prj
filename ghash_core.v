`timescale 1ns / 1ps

// GHASH x2: nhân hai khối trong CÙNG một chu kỳ, chốt Y tại cạnh clock.
// Cặp: Y' = (Y XOR block_first)*H^2 XOR block_second*H.
// Lẻ:  Y' = (Y XOR block_first)*H. Không đệm thêm khối zero.
module ghash_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,          // Xóa Y, giữ H/H^2 cho message tiếp.
    input  wire         invalidate_key, // Xóa cả H/H^2 và readiness.
    input  wire         key_load,       // Chốt H; chu kỳ sau tự tính H^2.
    input  wire [127:0] hash_subkey,

    input  wire         valid,
    output wire         ready,
    input  wire [127:0] block_first,
    input  wire [127:0] block_second,
    input  wire         two_blocks,
    input  wire         last,           // Batch này chứa length block cuối.

    output reg  [127:0] accumulator,
    output reg          keys_ready,
    output wire         setup_busy,
    output reg          done,          // Mỗi batch đã commit.
    output reg          last_done      // Chỉ batch cuối đã commit.
);
    reg [127:0] h_reg;
    reg [127:0] h_squared_reg;
    reg         square_pending;

    assign setup_busy = square_pending;
    assign ready = rst_n && keys_ready && !square_pending &&
                   !key_load && !invalidate_key && !clear;
    wire accept = valid && ready;

    // Dùng lại multiplier 1 trong setup, KHÔNG cần multiplier thứ ba.
    wire [127:0] mult1_a = square_pending ? h_reg : (accumulator ^ block_first);
    wire [127:0] mult1_b = square_pending ? h_reg :
                          (two_blocks ? h_squared_reg : h_reg);
    wire [127:0] mult1_product;
    wire [127:0] mult2_product;

    gf_mult_128 u_mult_first (
        .a(mult1_a), .b(mult1_b), .product(mult1_product)
    );
    gf_mult_128 u_mult_second (
        .a(two_blocks ? block_second : 128'b0),
        .b(h_reg), .product(mult2_product)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_reg          <= 128'b0;
            h_squared_reg  <= 128'b0;
            square_pending <= 1'b0;
            keys_ready     <= 1'b0;
            accumulator    <= 128'b0;
            done           <= 1'b0;
            last_done      <= 1'b0;
        end else begin
            done      <= 1'b0;
            last_done <= 1'b0;
            if (invalidate_key) begin
                h_reg          <= 128'b0;
                h_squared_reg  <= 128'b0;
                square_pending <= 1'b0;
                keys_ready     <= 1'b0;
                accumulator    <= 128'b0;
            end else if (key_load) begin
                h_reg          <= hash_subkey;
                h_squared_reg  <= 128'b0;
                square_pending <= 1'b1;
                keys_ready     <= 1'b0;
                accumulator    <= 128'b0;
            end else if (square_pending) begin
                // H đã ổn định trọn một chu kỳ sau key_load.
                h_squared_reg  <= mult1_product;
                square_pending <= 1'b0;
                keys_ready     <= 1'b1;
                accumulator    <= 128'b0;
            end else if (clear) begin
                accumulator <= 128'b0;
            end else if (accept) begin
                accumulator <= mult1_product ^ mult2_product;
                done        <= 1'b1;
                last_done   <= last;
            end
        end
    end
endmodule
