`timescale 1ns / 1ps

// Dual-port M20K S-Box (Mã hóa)
module aes_sbox_m20k_dp (
    input  wire       clk,
    input  wire       en,
    input  wire [7:0] addr_a,
    input  wire [7:0] addr_b,
    output reg  [7:0] q_a,
    output reg  [7:0] q_b
);
    (* ramstyle = "M20K", ram_init_file = "aes_sbox.hex" *)
    reg [7:0] rom [0:255];
    initial $readmemh("aes_sbox.hex", rom);

    always @(posedge clk) begin
        if (en) begin
            q_a <= rom[addr_a];
            q_b <= rom[addr_b];
        end
    end
endmodule

// Dual-port M20K Inverse S-Box (Giải mã)
module aes_inv_sbox_m20k_dp (
    input  wire       clk,
    input  wire       en,
    input  wire [7:0] addr_a,
    input  wire [7:0] addr_b,
    output reg  [7:0] q_a,
    output reg  [7:0] q_b
);
    (* ramstyle = "M20K", ram_init_file = "aes_inv_sbox.hex" *)
    reg [7:0] rom [0:255];
    initial $readmemh("aes_inv_sbox.hex", rom);

    always @(posedge clk) begin
        if (en) begin
            q_a <= rom[addr_a];
            q_b <= rom[addr_b];
        end
    end
endmodule

// Biến đổi 16 byte SubBytes song song qua 8 khối M20K dual-port
module aes_sub_bytes_sync (
    input  wire         clk,
    input  wire         en,
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    genvar sb;
    generate
        for (sb = 0; sb < 8; sb = sb + 1) begin : sbox_bank
            aes_sbox_m20k_dp u_rom (
                .clk    (clk),
                .en     (en),
                .addr_a (state_in[127 - 16*sb -: 8]),
                .addr_b (state_in[119 - 16*sb -: 8]),
                .q_a    (state_out[127 - 16*sb -: 8]),
                .q_b    (state_out[119 - 16*sb -: 8])
            );
        end
    endgenerate
endmodule

// Biến đổi 16 byte InvSubBytes song song qua 8 khối M20K dual-port
module aes_inv_sub_bytes_sync (
    input  wire         clk,
    input  wire         en,
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    genvar isb;
    generate
        for (isb = 0; isb < 8; isb = isb + 1) begin : inv_sbox_bank
            aes_inv_sbox_m20k_dp u_rom (
                .clk    (clk),
                .en     (en),
                .addr_a (state_in[127 - 16*isb -: 8]),
                .addr_b (state_in[119 - 16*isb -: 8]),
                .q_a    (state_out[127 - 16*isb -: 8]),
                .q_b    (state_out[119 - 16*isb -: 8])
            );
        end
    endgenerate
endmodule
