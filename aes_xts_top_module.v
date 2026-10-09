`timescale 1ns / 1ps

module aes_xts_top_module (
    input  wire        clk,
    input  wire        rst_n,

    // Giao diện điều khiển Avalon-MM Slave CSR
    input  wire [6:0]  address,
    input  wire        read,
    input  wire        write,
    input  wire [31:0] writedata,
    output wire [31:0] readdata,

    // Giao diện dòng dữ liệu vào Avalon-ST Sink
    input  wire        valid_in,
    input  wire [127:0] data_in,
    output wire        ready_in,

    // Giao diện dòng dữ liệu ra Avalon-ST Source
    output wire        valid_out,
    output wire [127:0] data_out,
    input  wire        ready_out
);
    // CSR Register Map
    localparam [6:0] REG_KEY1_0   = 7'h00;
    localparam [6:0] REG_KEY2_0   = 7'h10;
    localparam [6:0] REG_LBA_0    = 7'h20;
    localparam [6:0] REG_LBA_3    = 7'h2c;
    localparam [6:0] REG_STATUS   = 7'h30;
    localparam [6:0] REG_DIR      = 7'h34;
    localparam [6:0] REG_TAG_0    = 7'h38;
    localparam [6:0] REG_TAG_1    = 7'h3c;
    localparam [6:0] REG_TAG_2    = 7'h40;
    localparam [6:0] REG_TAG_3    = 7'h44;
    localparam [6:0] REG_SEC_CTRL = 7'h48;
    localparam [6:0] REG_AAD_SEC0 = 7'h4c;
    localparam [6:0] REG_AAD_SEC1 = 7'h50;

    // SEC_CTRL bit assignments (Đã loại bỏ bit PANIC_MODE)
    localparam integer SEC_RESET_GHASH   = 1;
    localparam integer SEC_FINALIZE_GMAC = 2;
    localparam integer SEC_CLEAR_KEYS    = 3;
    localparam integer SEC_DM_AEAD_MODE  = 4;

    // Trạng thái cấu hình & khóa
    reg [255:0] key_reg;
    reg [127:0] lba_reg;
    reg [63:0]  aad_sector_reg;
    reg         direction;
    reg         key_loaded;
    reg [7:0]   key_word_valid;
    reg         key_write_locked;
    reg         lba_loaded;
    reg         dm_aead_mode_en;
    reg         integrity_error;
    reg         tag_ready;

    reg [127:0] expected_tag;
    reg [3:0]   expected_tag_valid_words;
    reg [127:0] calculated_tag;
    reg [63:0]  auth_bit_count;

    // Quản lý pipeline và kết nối
    reg [19:0]  valid_pipeline;
    wire        core_valid_out = valid_pipeline[19];
    wire        auth_fifo_push_ready;
    wire        auth_fifo_valid;
    wire        auth_fifo_empty;
    wire [127:0] auth_fifo_data;

    wire output_can_commit = direction || auth_fifo_push_ready;
    wire en = !core_valid_out || (ready_out && output_can_commit);

    wire ghash_busy;
    wire ghash_ready;
    wire ghash_done;
    wire ghash_table_ready;
    wire tweak_ready;

    reg  finalize_pending;
    reg  finalize_active;
    reg  [1:0] aad_blocks_pending;

    wire xts_pipeline_busy = |valid_pipeline;
    wire pipeline_busy     = xts_pipeline_busy || !auth_fifo_empty || ghash_busy ||
                             finalize_pending  || finalize_active   || (aad_blocks_pending != 0);

    // Xử lý nạp khóa & Khóa chống ghi đè (Key Write Lock)
    wire key_write_sel = write && (address >= REG_KEY1_0 && address < REG_LBA_0);
    wire key_write_allowed = key_write_sel && !key_write_locked && !pipeline_busy;

    reg [7:0] key_word_bit;
    always @(*) begin
        if (address >= 7'h00 && address <= 7'h1c)
            key_word_bit = 8'b1 << address[4:2];
        else
            key_word_bit = 8'b0;
    end

    wire [7:0] next_key_word_valid = key_word_valid | key_word_bit;
    wire next_key_loaded = &next_key_word_valid;

    wire sec_write = write && (address == REG_SEC_CTRL);
    wire reset_ghash_pulse   = sec_write && writedata[SEC_RESET_GHASH];
    wire finalize_gmac_pulse = sec_write && writedata[SEC_FINALIZE_GMAC];
    wire clear_keys_pulse    = sec_write && writedata[SEC_CLEAR_KEYS];

    // Cập nhật CSR khi ghi
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_reg          <= 256'b0;
            lba_reg          <= 128'b0;
            aad_sector_reg   <= 64'b0;
            direction        <= 1'b0;
            key_loaded       <= 1'b0;
            key_word_valid   <= 8'b0;
            key_write_locked <= 1'b0;
            lba_loaded       <= 1'b0;
        end else if (clear_keys_pulse) begin
            key_reg          <= 256'b0;
            aad_sector_reg   <= 64'b0;
            key_loaded       <= 1'b0;
            key_word_valid   <= 8'b0;
            key_write_locked <= 1'b0;
            lba_loaded       <= 1'b0;
        end else if (write && !pipeline_busy) begin
            if (key_write_allowed) begin
                key_word_valid <= next_key_word_valid;
                key_loaded     <= next_key_loaded;
                if (next_key_loaded)
                    key_write_locked <= 1'b1;

                case (address)
                    7'h00: key_reg[255:224] <= writedata;
                    7'h04: key_reg[223:192] <= writedata;
                    7'h08: key_reg[191:160] <= writedata;
                    7'h0c: key_reg[159:128] <= writedata;
                    7'h10: key_reg[127:96]  <= writedata;
                    7'h14: key_reg[95:64]   <= writedata;
                    7'h18: key_reg[63:32]   <= writedata;
                    7'h1c: key_reg[31:0]    <= writedata;
                    default: ;
                endcase
            end

            case (address)
                REG_LBA_0: begin lba_reg[127:96] <= writedata; lba_loaded <= 1'b0; end
                7'h24:           lba_reg[95:64]  <= writedata;
                7'h28:           lba_reg[63:32]  <= writedata;
                REG_LBA_3: begin lba_reg[31:0]   <= writedata; lba_loaded <= 1'b1; end
                REG_DIR:         direction       <= writedata[0];
                REG_AAD_SEC0:    aad_sector_reg[63:32] <= writedata;
                REG_AAD_SEC1:    aad_sector_reg[31:0]  <= writedata;
                default: ;
            endcase
        end
    end

    // Đọc trạng thái CSR
    wire bist_done, bist_error;
    wire datapath_ready = tweak_ready && ghash_table_ready;
    wire [31:0] status_word = {23'b0, tag_ready, key_write_locked, 1'b0,
                               integrity_error, bist_error, bist_done,
                               pipeline_busy, datapath_ready, key_loaded};

    assign readdata = !read ? 32'b0 :
                      (address == REG_STATUS)   ? status_word :
                      (address == REG_TAG_0)    ? calculated_tag[127:96] :
                      (address == REG_TAG_1)    ? calculated_tag[95:64] :
                      (address == REG_TAG_2)    ? calculated_tag[63:32] :
                      (address == REG_TAG_3)    ? calculated_tag[31:0] :
                      (address == REG_SEC_CTRL) ? {27'b0, dm_aead_mode_en, 4'b0} :
                      32'b0;

    // Handshake luồng dữ liệu vào/ra
    reg first_block_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            first_block_pending <= 1'b1;
        else if (clear_keys_pulse)
            first_block_pending <= 1'b1;
        else if (write && !pipeline_busy && ((address == REG_LBA_3) || (key_write_allowed && next_key_loaded)))
            first_block_pending <= 1'b1;
        else if (valid_in && ready_in)
            first_block_pending <= 1'b0;
    end

    wire accepted_in = valid_in && ready_in;
    wire first_block = first_block_pending && accepted_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_pipeline <= 20'b0;
        else if (en)
            valid_pipeline <= {valid_pipeline[18:0], accepted_in};
    end

    assign valid_out = core_valid_out && output_can_commit;
    assign ready_in  = rst_n && en && key_loaded && lba_loaded && tweak_ready &&
                       ghash_table_ready && (aad_blocks_pending == 0) &&
                       !finalize_pending && !finalize_active &&
                       (!direction || auth_fifo_push_ready) &&
                       (bist_done && !bist_error);

    // Chuyển đổi Endianness cho LBA
    wire [127:0] lba_in_le;
    genvar gk;
    generate
        for (gk = 0; gk < 16; gk = gk + 1) begin : lba_le
            assign lba_in_le[127 - 8*gk : 120 - 8*gk] = lba_reg[8*gk + 7 : 8*gk];
        end
    endgenerate

    // Module Setup Iterative Engine: Quản lý BIST & Sinh khóa dẫn xuất
    localparam [127:0] BIST_PT  = 128'h3243f6a8885a308d313198a2e0370734;
    localparam [127:0] BIST_KEY = 128'h2b7e151628aed2a6abf7158809cf4f3c;
    localparam [127:0] BIST_CT  = 128'h3925841d02dc09fbdc118597196a0b32;
    localparam [127:0] KDF_CONST = 128'h5854532d474d41432d41555448000001;

    reg [3:0]   setup_state;
    reg         setup_pipe_start;
    reg [127:0] setup_pipe_data, setup_pipe_key;
    wire [127:0] setup_pipe_out;
    wire        setup_pipe_busy, setup_pipe_done;
    reg         setup_pending, setup_ready, setup_need_h;
    reg [127:0] derived_auth_key, gmac_hash_subkey, gmac_mask, encrypted_tweak_reg;
    reg         ghash_table_start_reg;
    reg         bist_passed, bist_failed;

    assign bist_done   = bist_passed || bist_failed;
    assign bist_error  = bist_failed;
    assign tweak_ready = setup_ready;

    aes_128_setup_iterative u_setup_engine (
        .clk     (clk),
        .rst_n   (rst_n && !clear_keys_pulse),
        .start   (setup_pipe_start),
        .data_in (setup_pipe_data),
        .key_in  (setup_pipe_key),
        .data_out(setup_pipe_out),
        .busy    (setup_pipe_busy),
        .done    (setup_pipe_done)
    );

    wire setup_key_changed  = key_write_allowed && next_key_loaded;
    wire setup_lba_changed  = write && !pipeline_busy && (address == REG_LBA_3);
    wire setup_mode_changed = sec_write && (writedata[SEC_DM_AEAD_MODE] != dm_aead_mode_en);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            setup_state           <= 4'd0;
            setup_ready           <= 1'b0;
            setup_pending         <= 1'b0;
            setup_need_h          <= 1'b0;
            setup_pipe_start      <= 1'b0;
            bist_passed           <= 1'b0;
            bist_failed           <= 1'b0;
            ghash_table_start_reg <= 1'b0;
        end else if (clear_keys_pulse) begin
            setup_state           <= 4'd2;
            setup_ready           <= 1'b0;
            setup_pending         <= 1'b0;
            setup_need_h          <= 1'b0;
            ghash_table_start_reg <= 1'b0;
        end else begin
            setup_pipe_start      <= 1'b0;
            ghash_table_start_reg <= 1'b0;

            case (setup_state)
                4'd0: begin
                    if (!setup_pipe_busy) begin
                        setup_pipe_data  <= BIST_PT;
                        setup_pipe_key   <= BIST_KEY;
                        setup_pipe_start <= 1'b1;
                        setup_state      <= 4'd1;
                    end
                end
                4'd1: begin
                    if (setup_pipe_done) begin
                        if (setup_pipe_out == BIST_CT) begin
                            bist_passed <= 1'b1;
                            setup_state <= 4'd2;
                        end else begin
                            bist_failed <= 1'b1;
                            setup_state <= 4'd11;
                        end
                    end
                end
                4'd2: begin
                    if (setup_pending && key_loaded && lba_loaded && bist_passed) begin
                        setup_pending <= 1'b0;
                        setup_ready   <= 1'b0;
                        if (setup_need_h && dm_aead_mode_en)
                            setup_state <= 4'd3;
                        else if (setup_need_h)
                            setup_state <= 4'd5;
                        else
                            setup_state <= 4'd7;
                    end
                end
                4'd3: begin
                    if (!setup_pipe_busy) begin
                        setup_pipe_data  <= KDF_CONST;
                        setup_pipe_key   <= key_reg[255:128];
                        setup_pipe_start <= 1'b1;
                        setup_state      <= 4'd4;
                    end
                end
                4'd4: begin
                    if (setup_pipe_done) begin
                        derived_auth_key <= setup_pipe_out;
                        setup_state      <= 4'd5;
                    end
                end
                4'd5: begin
                    if (!setup_pipe_busy) begin
                        setup_pipe_data  <= 128'b0;
                        setup_pipe_key   <= dm_aead_mode_en ? derived_auth_key : key_reg[255:128];
                        setup_pipe_start <= 1'b1;
                        setup_state      <= 4'd6;
                    end
                end
                4'd6: begin
                    if (setup_pipe_done) begin
                        gmac_hash_subkey      <= setup_pipe_out;
                        ghash_table_start_reg <= 1'b1;
                        setup_need_h          <= 1'b0;
                        setup_state           <= 4'd7;
                    end
                end
                4'd7: begin
                    if (!setup_pipe_busy) begin
                        setup_pipe_data  <= {lba_in_le[127:32], 31'b0, 1'b1};
                        setup_pipe_key   <= dm_aead_mode_en ? derived_auth_key : key_reg[255:128];
                        setup_pipe_start <= 1'b1;
                        setup_state      <= 4'd8;
                    end
                end
                4'd8: begin
                    if (setup_pipe_done) begin
                        gmac_mask   <= setup_pipe_out;
                        setup_state <= 4'd9;
                    end
                end
                4'd9: begin
                    if (!setup_pipe_busy) begin
                        setup_pipe_data  <= lba_in_le;
                        setup_pipe_key   <= key_reg[127:0];
                        setup_pipe_start <= 1'b1;
                        setup_state      <= 4'd10;
                    end
                end
                4'd10: begin
                    if (setup_pipe_done) begin
                        encrypted_tweak_reg <= setup_pipe_out;
                        setup_ready         <= !setup_pending;
                        setup_state         <= 4'd2;
                    end
                end
                default: setup_state <= 4'd2;
            endcase

            if (setup_key_changed || setup_lba_changed || setup_mode_changed) begin
                setup_pending <= 1'b1;
                setup_ready   <= 1'b0;
            end
            if (setup_key_changed || setup_mode_changed)
                setup_need_h <= 1'b1;
        end
    end

    // Ghép nối Lõi AES-XTS 128-bit Pipeline
    // Chú ý: .valid_in phải nối với accepted_in (valid_in && ready_in)
    aes_xts_128_pipeline u_aes_xts_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .valid_in        (accepted_in),
        .data_in         (data_in),
        .encrypted_tweak (encrypted_tweak_reg),
        .key_in          (key_reg),
        .en              (en),
        .first_block     (first_block),
        .direction       (direction),
        .data_out        (data_out)
    );

    // Xác thực toàn vẹn & GMAC Handling
    wire [127:0] dm_aad_b0 = {aad_sector_reg, lba_in_le[127:64]};
    wire [127:0] dm_aad_b1 = {lba_in_le[63:0], 64'b0};
    wire aad_push = dm_aead_mode_en && (aad_blocks_pending != 0) && auth_fifo_push_ready;
    wire [127:0] aad_data = (aad_blocks_pending == 2) ? dm_aad_b0 : dm_aad_b1;

    wire stream_push = direction ? accepted_in : (valid_out && ready_out);
    wire [127:0] stream_data = direction ? data_in : data_out;

    wire fifo_push      = aad_push || stream_push;
    wire [127:0] fifo_d = aad_push ? aad_data : stream_data;

    wire [127:0] length_block = dm_aead_mode_en ? {64'd192, auth_bit_count} : {auth_bit_count, 64'b0};
    wire start_finalize = finalize_pending && auth_fifo_empty && (aad_blocks_pending == 0) &&
                          !xts_pipeline_busy && !ghash_busy && ghash_ready;

    wire [127:0] ghash_in = start_finalize ? length_block : auth_fifo_data;
    wire ghash_val        = start_finalize || auth_fifo_valid;
    wire ghash_acc        = ghash_val && ghash_ready;
    wire fifo_pop         = ghash_acc && !start_finalize;

    auth_fifo4 u_fifo (
        .clk(clk), .rst_n(rst_n),
        .clear(reset_ghash_pulse || clear_keys_pulse),
        .push(fifo_push), .push_data(fifo_d), .pop(fifo_pop),
        .push_ready(auth_fifo_push_ready), .valid(auth_fifo_valid),
        .data(auth_fifo_data), .empty(auth_fifo_empty)
    );

    wire [127:0] ghash_acc_out;
    wire [127:0] finalized_tag = ghash_acc_out ^ gmac_mask;
    wire tag_mismatch = ghash_done && finalize_active && direction &&
                        (&expected_tag_valid_words) && (finalized_tag != expected_tag);

    ghash_core u_ghash (
        .clk(clk), .rst_n(rst_n),
        .clear(reset_ghash_pulse || clear_keys_pulse),
        .invalidate_table(clear_keys_pulse),
        .table_start(ghash_table_start_reg),
        .valid(ghash_val), .block_in(ghash_in), .hash_subkey(gmac_hash_subkey),
        .accumulator(ghash_acc_out), .busy(ghash_busy), .ready(ghash_ready),
        .done(ghash_done), .table_ready(ghash_table_ready)
    );

    // Ghi Tag kỳ vọng khi giải mã
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expected_tag             <= 128'b0;
            expected_tag_valid_words <= 4'b0;
        end else if (clear_keys_pulse || reset_ghash_pulse) begin
            expected_tag             <= 128'b0;
            expected_tag_valid_words <= 4'b0;
        end else if (write) begin
            case (address)
                REG_TAG_0: begin expected_tag[127:96] <= writedata; expected_tag_valid_words[0] <= 1'b1; end
                REG_TAG_1: begin expected_tag[95:64]  <= writedata; expected_tag_valid_words[1] <= 1'b1; end
                REG_TAG_2: begin expected_tag[63:32]  <= writedata; expected_tag_valid_words[2] <= 1'b1; end
                REG_TAG_3: begin expected_tag[31:0]   <= writedata; expected_tag_valid_words[3] <= 1'b1; end
                default: ;
            endcase
        end
    end

    // FSM điều phối Finalize & Đếm bit GMAC
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dm_aead_mode_en     <= 1'b0;
            integrity_error     <= 1'b0;
            tag_ready           <= 1'b0;
            auth_bit_count      <= 64'b0;
            calculated_tag      <= 128'b0;
            finalize_pending    <= 1'b0;
            finalize_active     <= 1'b0;
            aad_blocks_pending  <= 2'b0;
        end else begin
            if (sec_write)
                dm_aead_mode_en <= writedata[SEC_DM_AEAD_MODE];

            if (reset_ghash_pulse || clear_keys_pulse) begin
                integrity_error    <= 1'b0;
                auth_bit_count     <= 64'b0;
                calculated_tag     <= 128'b0;
                tag_ready          <= 1'b0;
                finalize_pending   <= 1'b0;
                finalize_active    <= 1'b0;
                aad_blocks_pending <= (reset_ghash_pulse && writedata[SEC_DM_AEAD_MODE]) ? 2'd2 : 2'd0;
            end else begin
                if (aad_push)
                    aad_blocks_pending <= aad_blocks_pending - 1'b1;
                if (stream_push)
                    auth_bit_count <= auth_bit_count + 64'd128;

                if (finalize_gmac_pulse) begin
                    finalize_pending <= 1'b1;
                    tag_ready        <= 1'b0;
                end
                if (start_finalize) begin
                    finalize_pending <= 1'b0;
                    finalize_active  <= 1'b1;
                end
                if (ghash_done && finalize_active) begin
                    calculated_tag  <= finalized_tag;
                    tag_ready       <= 1'b1;
                    finalize_active <= 1'b0;
                end
                if (tag_mismatch)
                    integrity_error <= 1'b1;
            end
        end
    end
endmodule
