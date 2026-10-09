`timescale 1ns / 1ps

// Stage sinh khóa con: 4 S-box logic, giữ hai bước DFF căn chỉnh round key
module aes_key_expand_round_sync (
    input  wire         clk,
    input  wire         en,
    input  wire [127:0] key_in,
    input  wire [7:0]   rcon_value,
    output wire [127:0] key_out
);
    wire [31:0] rot_in = {key_in[23:16], key_in[15:8], key_in[7:0], key_in[31:24]};
    wire [31:0] sub_out;
    reg  [31:0] sub_out_pipe;
    reg  [127:0] key_delay_1, key_delay_2;

    aes_sbox_pair_sync u_key_sbox_0 (
        .clk(clk), .en(en),
        .data_a(rot_in[31:24]), .data_b(rot_in[23:16]),
        .q_a(sub_out[31:24]),   .q_b(sub_out[23:16])
    );
    aes_sbox_pair_sync u_key_sbox_1 (
        .clk(clk), .en(en),
        .data_a(rot_in[15:8]),  .data_b(rot_in[7:0]),
        .q_a(sub_out[15:8]),    .q_b(sub_out[7:0])
    );

    always @(posedge clk) begin
        if (en) begin
            sub_out_pipe <= sub_out;
            key_delay_1  <= key_in;
            key_delay_2  <= key_delay_1;
        end
    end

    wire [31:0] w0 = key_delay_2[127:96];
    wire [31:0] w1 = key_delay_2[95:64];
    wire [31:0] w2 = key_delay_2[63:32];
    wire [31:0] w3 = key_delay_2[31:0];

    wire [31:0] w4 = w0 ^ sub_out_pipe ^ {rcon_value, 24'b0};
    wire [31:0] w5 = w4 ^ w1;
    wire [31:0] w6 = w5 ^ w2;
    wire [31:0] w7 = w6 ^ w3;
    assign key_out = {w4, w5, w6, w7};
endmodule

// Pipeline Mã hóa AES-128 Unrolled (10 rounds, Latency 20 clock, II = 1)
module aes_128_encrypt_pipeline (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire [127:0] data_in,
    input  wire [127:0] key_in,
    output reg  [127:0] data_out
);
    wire [7:0] rcon [1:10];
    assign rcon[1]  = 8'h01; assign rcon[2]  = 8'h02; assign rcon[3]  = 8'h04;
    assign rcon[4]  = 8'h08; assign rcon[5]  = 8'h10; assign rcon[6]  = 8'h20;
    assign rcon[7]  = 8'h40; assign rcon[8]  = 8'h80; assign rcon[9]  = 8'h1b;
    assign rcon[10] = 8'h36;

    wire [127:0] round_key [0:10];
    assign round_key[0] = key_in;

    genvar k;
    generate
        for (k = 1; k <= 10; k = k + 1) begin : kexpand_loop
            aes_key_expand_round_sync u_kexp (
                .clk        (clk),
                .en         (en),
                .key_in     (round_key[k-1]),
                .rcon_value (rcon[k]),
                .key_out    (round_key[k])
            );
        end
    endgenerate

    wire [127:0] state_chain [0:10];
    wire [127:0] sub_state   [1:10];
    reg  [127:0] sub_state_reg [1:9];
    assign state_chain[0] = data_in ^ key_in;

    genvar i;
    generate
        for (i = 1; i <= 9; i = i + 1) begin : enc_rounds
            wire [127:0] shifted;
            wire [127:0] mixed;

            aes_sub_bytes_sync u_sub (
                .clk       (clk),
                .en        (en),
                .state_in  (state_chain[i-1]),
                .state_out (sub_state[i])
            );

            always @(posedge clk) begin
                if (en) sub_state_reg[i] <= sub_state[i];
            end

            aes_shift_rows u_shift (
                .in  (sub_state_reg[i]),
                .out (shifted)
            );

            aes_mix_columns u_mix (
                .state_in  (shifted),
                .state_out (mixed)
            );

            assign state_chain[i] = mixed ^ round_key[i];
        end
    endgenerate

    wire [127:0] final_shifted;
    aes_sub_bytes_sync u_sub_r10 (
        .clk       (clk),
        .en        (en),
        .state_in  (state_chain[9]),
        .state_out (sub_state[10])
    );
    aes_shift_rows u_shift_r10 (
        .in  (sub_state[10]),
        .out (final_shifted)
    );
    assign state_chain[10] = final_shifted ^ round_key[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_out <= 128'b0;
        else if (en)
            data_out <= state_chain[10];
    end
endmodule

// Pipeline Giải mã AES-128 Unrolled (10 rounds, Latency 20 clock, II = 1)
module aes_128_decrypt_pipeline (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire [127:0] data_in,
    input  wire [127:0] key_in,
    output reg  [127:0] data_out
);
    wire [7:0] rcon [1:10];
    assign rcon[1]  = 8'h01; assign rcon[2]  = 8'h02; assign rcon[3]  = 8'h04;
    assign rcon[4]  = 8'h08; assign rcon[5]  = 8'h10; assign rcon[6]  = 8'h20;
    assign rcon[7]  = 8'h40; assign rcon[8]  = 8'h80; assign rcon[9]  = 8'h1b;
    assign rcon[10] = 8'h36;

    wire [127:0] round_key [0:10];
    assign round_key[0] = key_in;

    genvar k;
    generate
        for (k = 1; k <= 10; k = k + 1) begin : kexpand_dec_loop
            aes_key_expand_round_sync u_kexp (
                .clk        (clk),
                .en         (en),
                .key_in     (round_key[k-1]),
                .rcon_value (rcon[k]),
                .key_out    (round_key[k])
            );
        end
    endgenerate

    wire [127:0] state_chain [0:10];
    wire [127:0] shifted     [1:10];
    wire [127:0] sub_state   [1:10];
    reg  [127:0] sub_state_reg [1:9];
    assign state_chain[0] = data_in ^ round_key[10];

    genvar i;
    generate
        for (i = 1; i <= 9; i = i + 1) begin : dec_rounds
            wire [127:0] addkey;

            aes_inv_shift_rows u_inv_shift (
                .in  (state_chain[i-1]),
                .out (shifted[i])
            );

            aes_inv_sub_bytes_sync u_inv_sub (
                .clk       (clk),
                .en        (en),
                .state_in  (shifted[i]),
                .state_out (sub_state[i])
            );

            always @(posedge clk) begin
                if (en) sub_state_reg[i] <= sub_state[i];
            end

            assign addkey = sub_state_reg[i] ^ round_key[10-i];

            aes_inv_mix_columns u_inv_mix (
                .state_in  (addkey),
                .state_out (state_chain[i])
            );
        end
    endgenerate

    aes_inv_shift_rows u_inv_shift_r10 (
        .in  (state_chain[9]),
        .out (shifted[10])
    );
    aes_inv_sub_bytes_sync u_inv_sub_r10 (
        .clk       (clk),
        .en        (en),
        .state_in  (shifted[10]),
        .state_out (sub_state[10])
    );
    assign state_chain[10] = sub_state[10] ^ key_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_out <= 128'b0;
        else if (en)
            data_out <= state_chain[10];
    end
endmodule

// Lõi tích hợp AES-XTS 128-bit 2 luồng hoàn chỉnh
module aes_xts_128_pipeline (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid_in,        // Phải nối với accepted_in (valid_in && ready_in)
    input  wire [127:0] data_in,
    input  wire [127:0] encrypted_tweak,
    input  wire [255:0] key_in,
    input  wire         en,
    input  wire         first_block,
    input  wire         direction,       // 0: Mã hóa, 1: Giải mã
    output wire [127:0] data_out
);
    wire [127:0] key1 = key_in[255:128];
    reg  [127:0] current_tweak;
    wire [127:0] next_tweak;

    wire [127:0] active_tweak = first_block ? encrypted_tweak : current_tweak;

    gf_mult_alpha u_gf_mult (
        .din (active_tweak),
        .dout(next_tweak)
    );

    // CHÚ Ý QUAN TRỌNG: Chỉ cập nhật Tweak khi một khối thực sự được chấp nhận (valid_in = accepted_in)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_tweak <= 128'b0;
        end else if (en && valid_in) begin
            current_tweak <= next_tweak;
        end
    end

    wire [127:0] PP = data_in ^ active_tweak;
    wire [127:0] CC_enc, CC_dec;

    aes_128_encrypt_pipeline u_aes_data_enc (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .data_in (PP),
        .key_in  (key1),
        .data_out(CC_enc)
    );

    aes_128_decrypt_pipeline u_aes_data_dec (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .data_in (PP),
        .key_in  (key1),
        .data_out(CC_dec)
    );

    wire [127:0] CC = direction ? CC_dec : CC_enc;

    reg [127:0] tweak_delay_line [0:19];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 20; i = i + 1)
                tweak_delay_line[i] <= 128'b0;
        end else if (en) begin
            tweak_delay_line[0] <= active_tweak;
            for (i = 1; i < 20; i = i + 1)
                tweak_delay_line[i] <= tweak_delay_line[i-1];
        end
    end

    assign data_out = CC ^ tweak_delay_line[19];
endmodule
