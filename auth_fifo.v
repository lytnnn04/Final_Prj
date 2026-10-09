`timescale 1ns / 1ps

// Hàng đợi 4 phần tử đồng bộ ghép nối giữa AES (II=1) và GHASH (II=3)
module auth_fifo4 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    input  wire         push,
    input  wire [127:0] push_data,
    input  wire         pop,
    output wire         push_ready,
    output wire         valid,
    output wire [127:0] data,
    output wire         empty
);
    reg [127:0] mem [0:3];
    reg [2:0] count;

    assign valid      = (count != 3'd0);
    assign empty      = (count == 3'd0);
    assign data       = mem[0];
    assign push_ready = (count < 3'd4) || pop;

    integer idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 3'd0;
            for (idx = 0; idx < 4; idx = idx + 1)
                mem[idx] <= 128'b0;
        end else if (clear) begin
            count <= 3'd0;
        end else begin
            case ({push && push_ready, pop && valid})
                2'b10: begin
                    mem[count] <= push_data;
                    count <= count + 1'b1;
                end
                2'b01: begin
                    mem[0] <= mem[1];
                    mem[1] <= mem[2];
                    mem[2] <= mem[3];
                    count <= count - 1'b1;
                end
                2'b11: begin
                    case (count)
                        3'd1: mem[0] <= push_data;
                        3'd2: begin mem[0] <= mem[1]; mem[1] <= push_data; end
                        3'd3: begin mem[0] <= mem[1]; mem[1] <= mem[2]; mem[2] <= push_data; end
                        default: begin
                            mem[0] <= mem[1]; mem[1] <= mem[2];
                            mem[2] <= mem[3]; mem[3] <= push_data;
                        end
                    endcase
                end
                default: ;
            endcase
        end
    end
endmodule
