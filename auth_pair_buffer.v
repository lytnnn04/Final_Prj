`timescale 1ns / 1ps

// Bộ đệm 2 phần tử bằng DFF: gom 2 khối, hoặc nhả 1 khối có last=1.
// Không bypass input -> output. Hỗ trợ pop batch + push một khối cùng cạnh.
// Ready phản hồi tổ hợp; top phải dùng ready để dừng TOÀN BỘ pipeline AES.
module auth_pair_buffer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [127:0] in_data,
    input  wire         in_last,

    output wire         pair_valid,
    input  wire         pair_ready,
    output wire [127:0] block_first,
    output wire [127:0] block_second,
    output wire         two_blocks,
    output wire         pair_last,
    output wire         empty
);
    reg [127:0] first_data, second_data;
    reg         first_last, second_last;
    reg [1:0]   count;

    assign empty        = (count == 0);
    assign two_blocks   = (count == 2);
    assign block_first  = first_data;
    assign block_second = second_data;
    assign pair_last    = two_blocks ? second_last : first_last;
    assign pair_valid   = rst_n && !clear &&
                          (two_blocks || ((count == 1) && first_last));

    wire take_pair = pair_valid && pair_ready;
    // Không ghép message mới vào batch cũ đã có last.
    wire last_buffered = ((count != 0) && first_last) ||
                         (two_blocks && second_last);
    assign in_ready = rst_n && !clear && !last_buffered &&
                      ((count < 2) || take_pair);
    wire take_input = in_valid && in_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_data  <= 128'b0;
            second_data <= 128'b0;
            first_last  <= 1'b0;
            second_last <= 1'b0;
            count       <= 2'd0;
        end else if (clear) begin
            first_data  <= 128'b0;
            second_data <= 128'b0;
            first_last  <= 1'b0;
            second_last <= 1'b0;
            count       <= 2'd0;
        end else if (take_pair) begin
            // Cả batch cũ đã được lấy. Khối mới (nếu có) trở thành X1.
            first_data  <= take_input ? in_data : 128'b0;
            first_last  <= take_input && in_last;
            second_data <= 128'b0;
            second_last <= 1'b0;
            count       <= take_input ? 2'd1 : 2'd0;
        end else if (take_input) begin
            if (empty) begin
                first_data <= in_data;
                first_last <= in_last;
            end else begin
                second_data <= in_data;
                second_last <= in_last;
            end
            count <= count + 1'b1;
        end
    end
endmodule
