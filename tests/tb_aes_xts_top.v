`timescale 1ns / 1ps

// Testbench người dùng, cập nhật cho GHASH x2 + auth_pair_buffer.
// RTL S-box là logic tổ hợp; mô phỏng không cần nạp tệp HEX.
module tb_aes_xts_top();
    localparam integer TIMEOUT_CYCLES = 2000;
    localparam integer XTS_BLOCKS = 96;

    reg clk;
    reg rst_n;

    reg [6:0]  address;
    reg        read;
    reg        write;
    reg [31:0] writedata;
    wire [31:0] readdata;

    reg         valid_in;
    reg [127:0] data_in;
    wire        ready_in;

    wire         valid_out;
    wire [127:0] data_out;
    reg          ready_out;

    reg          is_dec_phase;
    reg          check_xts_outputs;
    reg [127:0]  captured_ctx [0:95];
    reg [31:0]   status_read_val;
    integer      pass_count;
    integer      fail_count;
    integer      total_output_count = 0;
    integer      stall_cycle = 0;
    integer      stalled_output_cycles = 0;
    reg          stall_outputs = 0;
    reg          output_held = 0;
    reg [127:0]  held_output;

    // Watchdog chung: mọi wait đều phải kết thúc hoặc báo lỗi, không treo simulator.
    initial begin
        #2000000;
        $fatal(1, "Global timeout: testbench did not finish");
    end

    // ready_out chỉ đổi ở cạnh xuống, tránh race với handshake của DUT.
    // Stall liên tiếp 40 nhịp và stall ngắn tuần hoàn trong hai pha XTS.
    always @(negedge clk) begin
        if (!rst_n || !stall_outputs) begin
            stall_cycle = 0;
            ready_out = 1'b1;
        end else begin
            stall_cycle = stall_cycle + 1;
            ready_out = (stall_cycle % 7 != 0) &&
                        !(stall_cycle >= 25 && stall_cycle < 65);
        end
    end

    // Output phải giữ nguyên valid/data khi bên nhận chưa ready.
    always @(posedge clk) begin
        if (!rst_n) begin
            output_held = 0;
            total_output_count = 0;
        end else begin
            if (output_held && (valid_out !== 1'b1 || data_out !== held_output))
                $fatal(1, "Output changed while stalled");
            output_held = (valid_out === 1'b1 && ready_out === 1'b0);
            held_output = data_out;
            if (output_held) stalled_output_cycles = stalled_output_cycles + 1;
            if (valid_out && ready_out) total_output_count = total_output_count + 1;
        end
    end

    aes_xts_top_module u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .address(address),
        .read(read),
        .write(write),
        .writedata(writedata),
        .readdata(readdata),
        .valid_in(valid_in),
        .data_in(data_in),
        .ready_in(ready_in),
        .valid_out(valid_out),
        .data_out(data_out),
        .ready_out(ready_out)
    );

    // Xung Clock 100MHz (Chu kỳ 10ns)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Dữ liệu Plaintext và Ciphertext cho 3 Vectors chuẩn IEEE 1619
    // Mỗi Vector gồm 512 bytes = 16 dòng 256-bit = 32 khối 128-bit
    reg [255:0] ptx_vector [0:47];
    reg [255:0] ctx_vector [0:47];

    initial begin
        // Vector 4 (IEEE 1619 - LBA = 0)
        ptx_vector[0]  = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
        ptx_vector[1]  = 256'h202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f;
        ptx_vector[2]  = 256'h404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f;
        ptx_vector[3]  = 256'h606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f;
        ptx_vector[4]  = 256'h808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f;
        ptx_vector[5]  = 256'ha0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf;
        ptx_vector[6]  = 256'hc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf;
        ptx_vector[7]  = 256'he0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff;
        ptx_vector[8]  = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
        ptx_vector[9]  = 256'h202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f;
        ptx_vector[10] = 256'h404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f;
        ptx_vector[11] = 256'h606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f;
        ptx_vector[12] = 256'h808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f;
        ptx_vector[13] = 256'ha0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf;
        ptx_vector[14] = 256'hc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf;
        ptx_vector[15] = 256'he0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff;

        ctx_vector[0]  = 256'h27a7479befa1d476489f308cd4cfa6e2a96e4bbe3208ff25287dd3819616e89c;
        ctx_vector[1]  = 256'hc78cf7f5e543445f8333d8fa7f56000005279fa5d8b5e4ad40e736ddb4d35412;
        ctx_vector[2]  = 256'h328063fd2aab53e5ea1e0a9f332500a5df9487d07a5c92cc512c8866c7e860ce;
        ctx_vector[3]  = 256'h93fdf166a24912b422976146ae20ce846bb7dc9ba94a767aaef20c0d61ad0265;
        ctx_vector[4]  = 256'h5ea92dc4c4e41a8952c651d33174be51a10c421110e6d81588ede82103a252d8;
        ctx_vector[5]  = 256'ha750e8768defffed9122810aaeb99f9172af82b604dc4b8e51bcb08235a6f434;
        ctx_vector[6]  = 256'h1332e4ca60482a4ba1a03b3e65008fc5da76b70bf1690db4eae29c5f1badd03c;
        ctx_vector[7]  = 256'h5ccf2a55d705ddcd86d449511ceb7ec30bf12b1fa35b913f9f747a8afd1b130e;
        ctx_vector[8]  = 256'h94bff94effd01a91735ca1726acd0b197c4e5b03393697e126826fb6bbde8ecc;
        ctx_vector[9]  = 256'h1e08298516e2c9ed03ff3c1b7860f6de76d4cecd94c8119855ef5297ca67e9f3;
        ctx_vector[10] = 256'he7ff72b1e99785ca0a7e7720c5b36dc6d72cac9574c8cbbc2f801e23e56fd344;
        ctx_vector[11] = 256'hb07f22154beba0f08ce8891e643ed995c94d9a69c9f1b5f499027a78572aeebd;
        ctx_vector[12] = 256'h74d20cc39881c213ee770b1010e4bea718846977ae119f7a023ab58cca0ad752;
        ctx_vector[13] = 256'hafe656bb3c17256a9f6e9bf19fdd5a38fc82bbe872c5539edb609ef4f79c203e;
        ctx_vector[14] = 256'hbb140f2e583cb2ad15b4aa5b655016a8449277dbd477ef2c8d6c017db738b18d;
        ctx_vector[15] = 256'heb4a427d1923ce3ff262735779a418f20a282df920147beabe421ee5319d0568;

        // Vector 5 (IEEE 1619 - LBA = 1)
        ptx_vector[16] = 256'h27a7479befa1d476489f308cd4cfa6e2a96e4bbe3208ff25287dd3819616e89c;
        ptx_vector[17] = 256'hc78cf7f5e543445f8333d8fa7f56000005279fa5d8b5e4ad40e736ddb4d35412;
        ptx_vector[18] = 256'h328063fd2aab53e5ea1e0a9f332500a5df9487d07a5c92cc512c8866c7e860ce;
        ptx_vector[19] = 256'h93fdf166a24912b422976146ae20ce846bb7dc9ba94a767aaef20c0d61ad0265;
        ptx_vector[20] = 256'h5ea92dc4c4e41a8952c651d33174be51a10c421110e6d81588ede82103a252d8;
        ptx_vector[21] = 256'ha750e8768defffed9122810aaeb99f9172af82b604dc4b8e51bcb08235a6f434;
        ptx_vector[22] = 256'h1332e4ca60482a4ba1a03b3e65008fc5da76b70bf1690db4eae29c5f1badd03c;
        ptx_vector[23] = 256'h5ccf2a55d705ddcd86d449511ceb7ec30bf12b1fa35b913f9f747a8afd1b130e;
        ptx_vector[24] = 256'h94bff94effd01a91735ca1726acd0b197c4e5b03393697e126826fb6bbde8ecc;
        ptx_vector[25] = 256'h1e08298516e2c9ed03ff3c1b7860f6de76d4cecd94c8119855ef5297ca67e9f3;
        ptx_vector[26] = 256'he7ff72b1e99785ca0a7e7720c5b36dc6d72cac9574c8cbbc2f801e23e56fd344;
        ptx_vector[27] = 256'hb07f22154beba0f08ce8891e643ed995c94d9a69c9f1b5f499027a78572aeebd;
        ptx_vector[28] = 256'h74d20cc39881c213ee770b1010e4bea718846977ae119f7a023ab58cca0ad752;
        ptx_vector[29] = 256'hafe656bb3c17256a9f6e9bf19fdd5a38fc82bbe872c5539edb609ef4f79c203e;
        ptx_vector[30] = 256'hbb140f2e583cb2ad15b4aa5b655016a8449277dbd477ef2c8d6c017db738b18d;
        ptx_vector[31] = 256'heb4a427d1923ce3ff262735779a418f20a282df920147beabe421ee5319d0568;

        ctx_vector[16] = 256'h264d3ca8512194fec312c8c9891f279fefdd608d0c027b60483a3fa811d65ee5;
        ctx_vector[17] = 256'h9d52d9e40ec5672d81532b38b6b089ce951f0f9c35590b8b978d175213f329bb;
        ctx_vector[18] = 256'h1c2fd30f2f7f30492a61a532a79f51d36f5e31a7c9a12c286082ff7d2394d18f;
        ctx_vector[19] = 256'h783e1a8e72c722caaaa52d8f065657d2631fd25bfd8e5baad6e527d763517501;
        ctx_vector[20] = 256'hc68c5edc3cdd55435c532d7125c8614deed9adaa3acade5888b87bef641c4c99;
        ctx_vector[21] = 256'h4c8091b5bcd387f3963fb5bc37aa922fbfe3df4e5b915e6eb514717bdd2a7407;
        ctx_vector[22] = 256'h9a5073f5c4bfd46adf7d282e7a393a52579d11a028da4d9cd9c77124f9648ee3;
        ctx_vector[23] = 256'h83b1ac763930e7162a8d37f350b2f74b8472cf09902063c6b32e8c2d9290cefb;
        ctx_vector[24] = 256'hd7346d1c779a0df50edcde4531da07b099c638e83a755944df2aef1aa31752fd;
        ctx_vector[25] = 256'h323dcb710fb4bfbb9d22b925bc3577e1b8949e729a90bbafeacf7f7879e7b114;
        ctx_vector[26] = 256'h7e28ba0bae940db795a61b15ecf4df8db07b824bb062802cc98a9545bb2aaeed;
        ctx_vector[27] = 256'h77cb3fc6db15dcd7d80d7d5bc406c4970a3478ada8899b329198eb61c193fb62;
        ctx_vector[28] = 256'h75aa8ca340344a75a862aebe92eee1ce032fd950b47d7704a3876923b4ad6284;
        ctx_vector[29] = 256'h4bf4a09c4dbe8b4397184b7471360c9564880aedddb9baa4af2e75394b08cd32;
        ctx_vector[30] = 256'hff479c57a07d3eab5d54de5f9738b8d27f27a9f0ab11799d7b7ffefb2704c95c;
        ctx_vector[31] = 256'h6ad12c39f1e867a4b7b1d7818a4b753dfd2a89ccb45e001a03a867b187f225dd;

        // Vector 7 (IEEE 1619 - LBA = fd)
        ptx_vector[32] = 256'h8e41b78c390b5af9d758bb214a67e9f6bf7727b09ac6124084c37611398fa45d;
        ptx_vector[33] = 256'haad94868600ed391fb1acd4857a95b466e62ef9f4b377244d1c152e7b30d731a;
        ptx_vector[34] = 256'had30c716d214b707aed99eb5b5e580b3e887cf7497465651d4b60e6042051da3;
        ptx_vector[35] = 256'h693c3b78c14489543be8b6ad0ba629565bba202313ba7b0d0c94a3252b676f46;
        ptx_vector[36] = 256'hcc02ce0f8a7d34c0ed229129673c1f61aed579d08a9203a25aac3a77e9db6026;
        ptx_vector[37] = 256'h7996db38df637356d9dcd1632e369939f2a29d89345c66e05066f1a3677aef18;
        ptx_vector[38] = 256'hdea4113faeb629e46721a66d0a7e785d3e29af2594eb67dfa982affe0aac058f;
        ptx_vector[39] = 256'h6e15864269b135418261fc3afb089472cf68c45dd7f231c6249ba0255e1e0338;
        ptx_vector[40] = 256'h33fc4d00a3fe02132d7bc3873614b8aee34273581ea0325c81f0270affa13641;
        ptx_vector[41] = 256'hd052d36f0757d484014354d02d6883ca15c24d8c3956b1bd027bcf41f151fd80;
        ptx_vector[42] = 256'h23c5340e5606f37e90fdb87c86fb4fa634b3718a30bace06a66eaf8f63c4aa3b;
        ptx_vector[43] = 256'h637826a87fe8cfa44282e92cb1615af3a28e53bc74c7cba1a0977be9065d0c1a;
        ptx_vector[44] = 256'h5dec6c54ae38d37f37aa35283e048e5530a85c4e7a29d7b92ec0c3169cdf2a80;
        ptx_vector[45] = 256'h5c7604bce60049b9fb7b8eaac10f51ae23794ceba68bb58112e293b9b692ca72;
        ptx_vector[46] = 256'h1b37c662f8574ed4dba6f88e170881c82cddc1034a0ca7e284bf0962b6b26292;
        ptx_vector[47] = 256'hd836fa9f73c1ac770eef0f2d3a1eaf61d3e03555fd424eedd67e18a18094f888;

        ctx_vector[32] = 256'hd55f684f81f4426e9fde92a5ff02df2ac896af63962888a97910c1379e20b0a3;
        ctx_vector[33] = 256'hb1db613fb7fe2e07004329ea5c22bfd33e3dbe4cf58cc608c2c26c19a2e2fe22;
        ctx_vector[34] = 256'hf98732c2b5cb844cc6c0702d91e1d50fc4382a7eba5635cd602432a2306ac4ce;
        ctx_vector[35] = 256'h82f8d70c8d9bc15f918fe71e74c622d5cf71178bf6e0b9cc9f2b41dd8dbe441c;
        ctx_vector[36] = 256'h41cd0c73a6dc47a348f6702f9d0e9b1b1431e948e299b9ec2272ab2c5f0c7be8;
        ctx_vector[37] = 256'h6affa5dec87a0bee81d3d50007edaa2bcfccb35605155ff36ed8edd4a40dcd4b;
        ctx_vector[38] = 256'h243acd11b2b987bdbfaf91a7cac27e9c5aea525ee53de7b2d3332c8644402b82;
        ctx_vector[39] = 256'h3e94a7db26276d2d23aa07180f76b4fd29b9c0823099c9d62c519880aee7e969;
        ctx_vector[40] = 256'h7617c1497d47bf3e571950311421b6b734d38b0db91eb85331b91ea9f61530f5;
        ctx_vector[41] = 256'h4512a5a52a4bad589eb69781d537f23297bb459bdad2948a29e1550bf4787e0b;
        ctx_vector[42] = 256'he95bb173cf5fab17dab7a13a052a63453d97ccec1a321954886b7a1299faaeec;
        ctx_vector[43] = 256'hae35c6eaaca753b041b5e5f093bf83397fd21dd6b3012066fcc058cc32c3b09d;
        ctx_vector[44] = 256'h7562dee29509b5839392c9ff05f51f3166aaac4ac5f238038a3045e6f72e48ef;
        ctx_vector[45] = 256'h0fe8bc675e82c318a268e43970271bf119b81bf6a982746554f84e72b9f00280;
        ctx_vector[46] = 256'ha320a08142923c23c883423ff949827f29bbacdc1ccdb04938ce6098c95ba6b3;
        ctx_vector[47] = 256'h2528f4ef78eed778b2e122ddfd1cbdd11d1c0a6783e011fc536d63d053260637;
    end

    integer row;
    reg [6:0] block_out_idx = 7'b0;

    initial begin
        rst_n = 0;
        address = 7'h7c;
        read = 0;
        write = 0;
        writedata = 32'b0;
        valid_in = 0;
        data_in = 128'b0;
        ready_out = 1;
        is_dec_phase = 0;
        check_xts_outputs = 0;
        pass_count = 0;
        fail_count = 0;

        repeat(5) @(negedge clk);
        rst_n = 1;

        $display("=========================================================================");
        $display("=== STAGE 0: BIST POWER-ON KAT TEST ===");
        $display("=========================================================================");
        repeat(100) @(posedge clk);
        read_avalon_fast(7'h30, status_read_val);

        if (status_read_val[3] !== 1'b1 || status_read_val[4] !== 1'b0) begin
            $display("[FATAL ERROR] BIST Failed! status = 0x%08h", status_read_val);
            fail_count = fail_count + 1;
            $fatal(1, "Automatic check failed: BIST power-on KAT mismatch!");
        end else begin
            $display("[PASS BIST] Hardware BIST Passed successfully! status = 0x%08h", status_read_val);
            pass_count = pass_count + 1;
        end

        #20;
        $display("=========================================================================");
        $display("=== STAGE 1: ENCRYPTION OF VECTORS 4, 5, 7 ===");
        $display("=========================================================================");
        check_xts_outputs = 1;
        stall_outputs = 1;
        write_avalon_fast(7'h00, 32'h27182818); write_avalon_fast(7'h04, 32'h28459045);
        write_avalon_fast(7'h08, 32'h23536028); write_avalon_fast(7'h0c, 32'h74713526);

        write_avalon_fast(7'h10, 32'h31415926); write_avalon_fast(7'h14, 32'h53589793);
        write_avalon_fast(7'h18, 32'h23846264); write_avalon_fast(7'h1c, 32'h33832795);
        write_avalon_fast(7'h34, 32'h00000000); // ENCRYPTION

        // Vector 4 (LBA = 0)
        $display("\n>>> STREAMING VECTOR 4 (LBA = 0, Blocks 0..31) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h00000000);
        wait_ready_in;

        for (row = 0; row < 16; row = row + 1) begin
            send_stream_block(ptx_vector[row][255:128]);
            send_stream_block(ptx_vector[row][127:0]);
        end
        wait_output_count(32);
        wait_pipeline_idle;

        // Vector 5 (LBA = 1)
        $display("\n>>> STREAMING VECTOR 5 (LBA = 1, Blocks 32..63) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h00000001);
        wait_ready_in;

        for (row = 16; row < 32; row = row + 1) begin
            send_stream_block(ptx_vector[row][255:128]);
            send_stream_block(ptx_vector[row][127:0]);
        end
        wait_output_count(64);
        wait_pipeline_idle;

        // Vector 7 (LBA = fd)
        $display("\n>>> STREAMING VECTOR 7 (LBA = fd, Blocks 64..95) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h000000fd);
        wait_ready_in;

        for (row = 32; row < 48; row = row + 1) begin
            send_stream_block(ptx_vector[row][255:128]);
            send_stream_block(ptx_vector[row][127:0]);
        end
        wait_output_count(96);
        wait_pipeline_idle;

        $display("=========================================================================");
        $display("=== STAGE 2: DECRYPTION OF VECTORS 4, 5, 7 ===");
        $display("=========================================================================");
        @(negedge clk);
        is_dec_phase = 1;
        block_out_idx = 0;
        write_avalon_fast(7'h34, 32'h00000001); // DECRYPTION

        // Decrypt Vector 4
        $display("\n>>> DECRYPTING VECTOR 4 (LBA = 0, Blocks 0..31) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h00000000);
        wait_ready_in;

        for (row = 0; row < 16; row = row + 1) begin
            send_stream_block(captured_ctx[row*2]);
            send_stream_block(captured_ctx[row*2 + 1]);
        end
        wait_output_count(32);
        wait_pipeline_idle;

        // Decrypt Vector 5
        $display("\n>>> DECRYPTING VECTOR 5 (LBA = 1, Blocks 32..63) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h00000001);
        wait_ready_in;

        for (row = 16; row < 32; row = row + 1) begin
            send_stream_block(captured_ctx[row*2]);
            send_stream_block(captured_ctx[row*2 + 1]);
        end
        wait_output_count(64);
        wait_pipeline_idle;

        // Decrypt Vector 7
        $display("\n>>> DECRYPTING VECTOR 7 (LBA = fd, Blocks 64..95) <<<");
        write_avalon_fast(7'h20, 32'h00000000); write_avalon_fast(7'h24, 32'h00000000);
        write_avalon_fast(7'h28, 32'h00000000); write_avalon_fast(7'h2c, 32'h000000fd);
        wait_ready_in;

        for (row = 32; row < 48; row = row + 1) begin
            send_stream_block(captured_ctx[row*2]);
            send_stream_block(captured_ctx[row*2 + 1]);
        end
        wait_output_count(96);
        wait_pipeline_idle;
        @(negedge clk);
        check_xts_outputs = 0;
        stall_outputs = 0;
        wait_pipeline_idle;

        $display("=========================================================================");
        $display("=== STAGE 3: GMAC & DM-CRYPT AEAD REGRESSION ===");
        $display("=========================================================================");
        run_gmac_vector(
            "CAVS GMAC AAD=0 Count=0",
            128'h11754cd72aec309bf52f7687212e8957,
            96'h3c819d9a9bed087615030b65,
            2'd0,
            384'b0,
            128'h250327c674aaf477aef2675748cf6971
        );

        // Tag mở rộng được tính độc lập bằng cryptography AESGCM:
        // encrypt(iv, plaintext rỗng, AAD = 1/2/3 khối). Không lấy tag từ DUT.
        run_gmac_vector(
            "GHASH x2 GMAC AAD=128 bits",
            128'h11754cd72aec309bf52f7687212e8957,
            96'h3c819d9a9bed087615030b65,
            2'd1,
            384'h00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000102030405060708090a0b0c0d0e0f10,
            128'h86a4d94eb2b6e65b84c6b9b7cb04d7ec
        );
        run_gmac_vector(
            "GHASH x2 GMAC AAD=256 bits",
            128'h11754cd72aec309bf52f7687212e8957,
            96'h3c819d9a9bed087615030b65,
            2'd2,
            384'h00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000102030405060708090a0b0c0d0e0f10,
            128'hf6464ecc071d49d17ffef8858d2ac842
        );
        run_gmac_vector(
            "GHASH x2 GMAC AAD=384 bits",
            128'h11754cd72aec309bf52f7687212e8957,
            96'h3c819d9a9bed087615030b65,
            2'd3,
            384'h00112233445566778899aabbccddeeffffeeddccbbaa998877665544332211000102030405060708090a0b0c0d0e0f10,
            128'hbdc335f80aed168e569cf5c2658f5df1
        );

        test_key_write_lock;
        run_dm_crypt_aead_vector;
        run_integrity_check_case(1'b0); // Valid tag case
        run_integrity_check_case(1'b1); // Mismatch case (asserts INTEGRITY_ERROR flag, no DMA lock)

        $display("\n=========================================================================");
        if (stalled_output_cycles == 0)
            $fatal(1, "Backpressure checks never exercised");
        $display("Stalled output cycles checked: %0d", stalled_output_cycles);
        $display("REGRESSION SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("[ALL TESTS PASSED: XTS vectors, GMAC/DM tags, integrity and backpressure]");
            $display("=========================================================================");
        end else begin
            $display("[REGRESSION FAILED]");
            $display("=========================================================================");
            $fatal(1, "Automatic grading failed: Total failures = %0d", fail_count);
        end
        $finish;
    end

    wire [5:0] current_row  = block_out_idx[6:1];
    wire       half_select  = block_out_idx[0];
    wire [127:0] expected_ctx_block = (!half_select) ? ctx_vector[current_row][255:128] : ctx_vector[current_row][127:0];
    wire [127:0] expected_ptx_block = (!half_select) ? ptx_vector[current_row][255:128] : ptx_vector[current_row][127:0];

    // CHẤM ĐIỂM TỰ ĐỘNG VÀ DUMP TỪNG KHỐI
    always @(posedge clk) begin
        if (check_xts_outputs && valid_out && ready_out) begin
            if (block_out_idx >= XTS_BLOCKS)
                $fatal(1, "Unexpected extra XTS output block");
            if (!is_dec_phase) begin
                captured_ctx[block_out_idx] <= data_out;
                if (data_out === expected_ctx_block) begin
                    $display("[ENC PASS] Block %2d (Row %2d, H%0d) | Out: %032h (Matches IEEE standard)",
                             block_out_idx, current_row, half_select, data_out);
                    pass_count = pass_count + 1;
                end else begin
                    $display("\n=========================================================================");
                    $display("[FATAL FAIL ENC] Block %2d (Row %2d, H%0d) MISMATCH!",
                             block_out_idx, current_row, half_select);
                    $display("   >> Actual   Out : %032h", data_out);
                    $display("   >> Expected Ctx : %032h", expected_ctx_block);
                    $display("=========================================================================\n");
                    fail_count = fail_count + 1;
                    $fatal(1, "Automatic check failed: Block %0d encryption mismatch!", block_out_idx);
                end
            end else begin
                if (data_out === expected_ptx_block) begin
                    $display("[DEC PASS] Block %2d (Row %2d, H%0d) | Out: %032h (Recovered original plaintext)",
                             block_out_idx, current_row, half_select, data_out);
                    pass_count = pass_count + 1;
                end else begin
                    $display("\n=========================================================================");
                    $display("[FATAL FAIL DEC] Block %2d (Row %2d, H%0d) MISMATCH!",
                             block_out_idx, current_row, half_select);
                    $display("   >> Actual   Out : %032h", data_out);
                    $display("   >> Expected Ptx : %032h", expected_ptx_block);
                    $display("=========================================================================\n");
                    fail_count = fail_count + 1;
                    $fatal(1, "Automatic check failed: Block %0d decryption mismatch!", block_out_idx);
                end
            end
            block_out_idx <= block_out_idx + 1'b1;
        end
    end

    task wait_ready_in;
        integer cycles;
        begin
            cycles = 0;
            while (ready_in !== 1'b1 && cycles < TIMEOUT_CYCLES) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (ready_in !== 1'b1)
                $fatal(1, "Datapath ready timeout (H/H2, tweak or BIST)");
        end
    endtask

    task wait_output_count(input integer target);
        integer cycles;
        begin
            cycles = 0;
            while (block_out_idx < target && cycles < TIMEOUT_CYCLES) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (block_out_idx !== target)
                $fatal(1, "Output count mismatch: got %0d, expected %0d", block_out_idx, target);
        end
    endtask

    task write_avalon_fast(input [6:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            address   = addr;
            writedata = data;
            write     = 1'b1;
            @(negedge clk);
            write     = 1'b0;
            address   = 7'b0;
            writedata = 32'b0;
        end
    endtask

    task send_stream_block(input [127:0] b_data);
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            @(negedge clk);
            valid_in = 1'b1;
            data_in  = b_data;
            @(posedge clk);
            while (ready_in !== 1'b1 && timeout_cycles < TIMEOUT_CYCLES) begin
                timeout_cycles = timeout_cycles + 1;
                @(posedge clk);
            end
            if (ready_in !== 1'b1)
                $fatal(1, "Input handshake timeout");
            @(negedge clk);
            valid_in = 1'b0;
            data_in = 128'b0;
        end
    endtask

    task read_avalon_fast(input [6:0] addr, output [31:0] read_val);
        begin
            @(negedge clk);
            address = addr;
            read = 1'b1;
            @(posedge clk);
            #1 read_val = readdata;
            @(negedge clk);
            read = 1'b0;
            address = 7'h7c;
        end
    endtask

    task write_key_pair(input [127:0] key1, input [127:0] key2);
        begin
            write_avalon_fast(7'h00, key1[127:96]);
            write_avalon_fast(7'h04, key1[95:64]);
            write_avalon_fast(7'h08, key1[63:32]);
            write_avalon_fast(7'h0c, key1[31:0]);
            write_avalon_fast(7'h10, key2[127:96]);
            write_avalon_fast(7'h14, key2[95:64]);
            write_avalon_fast(7'h18, key2[63:32]);
            write_avalon_fast(7'h1c, key2[31:0]);
        end
    endtask

    task write_iv96(input [95:0] iv);
        begin
            write_avalon_fast(7'h20, 32'b0);
            write_avalon_fast(7'h24, {iv[7:0], iv[15:8], iv[23:16], iv[31:24]});
            write_avalon_fast(7'h28, {iv[39:32], iv[47:40], iv[55:48], iv[63:56]});
            write_avalon_fast(7'h2c, {iv[71:64], iv[79:72], iv[87:80], iv[95:88]});
        end
    endtask

    task write_expected_tag(input [127:0] tag);
        begin
            write_avalon_fast(7'h38, tag[127:96]);
            write_avalon_fast(7'h3c, tag[95:64]);
            write_avalon_fast(7'h40, tag[63:32]);
            write_avalon_fast(7'h44, tag[31:0]);
        end
    endtask

    task read_calculated_tag(output [127:0] tag);
        reg [31:0] w0, w1, w2, w3;
        begin
            wait_tag_ready;
            read_avalon_fast(7'h38, w0);
            read_avalon_fast(7'h3c, w1);
            read_avalon_fast(7'h40, w2);
            read_avalon_fast(7'h44, w3);
            tag = {w0, w1, w2, w3};
        end
    endtask

    task wait_tag_ready;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while (u_dut.tag_ready !== 1'b1 && timeout_cycles < TIMEOUT_CYCLES) begin
                @(negedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (u_dut.tag_ready !== 1'b1) begin
                $display("[FATAL ERROR] Timeout waiting for tag_ready!");
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed: GMAC tag_ready timeout!");
            end
        end
    endtask

    // Chỉ dùng sau finalize, hoặc sau luồng XTS có số khối chẵn đã drain.
    // Một khối lẻ trong auth_pair_buffer vẫn giữ pipeline_busy = 1.
    task wait_pipeline_idle;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while (u_dut.pipeline_busy !== 1'b0 && timeout_cycles < TIMEOUT_CYCLES) begin
                @(negedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (u_dut.pipeline_busy !== 1'b0) begin
                $display("[FATAL ERROR] Timeout waiting for pipeline idle!");
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed: Pipeline busy timeout!");
            end
        end
    endtask

    task check_128(input [8*48-1:0] name, input [127:0] got, input [127:0] expected);
        begin
            if (got === expected) begin
                $display("[PASS] %0s | %032h (Match)", name, got);
                pass_count = pass_count + 1;
            end else begin
                $display("\n=========================================================================");
                $display("[FATAL FAIL] %0s MISMATCH!", name);
                $display("   >> Actual  : %032h", got);
                $display("   >> Expected: %032h", expected);
                $display("=========================================================================\n");
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed on %0s", name);
            end
        end
    endtask

    task run_gmac_vector(input [8*48-1:0] name, input [127:0] key, input [95:0] iv,
                         input [1:0] block_count, input [383:0] aad_blocks, input [127:0] expected);
        reg [127:0] tag;
        integer outputs_before;
        begin
            outputs_before = total_output_count;
            write_avalon_fast(7'h48, 32'h00000008); // clear
            write_key_pair(key, key);
            write_avalon_fast(7'h34, 32'h00000001); // decrypt
            write_iv96(iv);
            wait_ready_in;
            repeat (14) @(posedge clk);
            write_avalon_fast(7'h48, 32'h00000002); // reset ghash

            if (block_count > 0) send_stream_block(aad_blocks[383:256]);
            if (block_count > 1) send_stream_block(aad_blocks[255:128]);
            if (block_count > 2) send_stream_block(aad_blocks[127:0]);

            // GHASH x2 có thể đang giữ một khối lẻ: finalize TRƯỚC khi đợi idle.
            // Top tự drain AES rồi enqueue length block để hoàn tất cặp cuối.
            write_avalon_fast(7'h48, 32'h00000004); // finalize
            read_calculated_tag(tag);
            wait_pipeline_idle;
            if (total_output_count - outputs_before != block_count)
                $fatal(1, "GMAC output count mismatch");
            check_128(name, tag, expected);
        end
    endtask

    task test_key_write_lock;
        reg [31:0] status;
        begin
            read_avalon_fast(7'h30, status);
            if (status[7] === 1'b1) begin
                $display("[PASS] Key write lock successfully asserted (anti-tamper lock active)");
                pass_count = pass_count + 1;
            end else begin
                $display("[FATAL ERROR] Key write lock was NOT asserted!");
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed: Key write lock inactive!");
            end

            write_avalon_fast(7'h48, 32'h00000008); // explicit clear
            read_avalon_fast(7'h30, status);
            if (status[7] === 1'b0 && status[0] === 1'b0) begin
                $display("[PASS] Explicit clear deasserted key_loaded and key_write_locked");
                pass_count = pass_count + 1;
            end else begin
                $display("[FATAL ERROR] Explicit key clear failed! status = 0x%08h", status);
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed: Key clear command failed!");
            end
        end
    endtask

    task run_dm_crypt_aead_vector;
        reg [127:0] tag;
        integer outputs_before;
        begin
            outputs_before = total_output_count;
            write_avalon_fast(7'h48, 32'h00000018); // clear + native AEAD
            write_key_pair(
                128'h27182818284590452353602874713526,
                128'h31415926535897932384626433832795);
            write_avalon_fast(7'h34, 32'h00000001); // decrypt

            write_avalon_fast(7'h20, 32'h0f0e0d0c);
            write_avalon_fast(7'h24, 32'h0b0a0908);
            write_avalon_fast(7'h28, 32'h07060504);
            write_avalon_fast(7'h2c, 32'h03020100);
            write_avalon_fast(7'h4c, 32'h05000000);
            write_avalon_fast(7'h50, 32'h00000000);

            wait_ready_in;
            write_avalon_fast(7'h48, 32'h00000012); // reset GHASH + AEAD
            wait_ready_in;
            send_stream_block(128'h00112233445566778899aabbccddeeff);
            // GHASH x2 có thể đang giữ một khối lẻ: finalize TRƯỚC khi đợi idle.
            // Top tự drain AES rồi enqueue length block để hoàn tất cặp cuối.
            write_avalon_fast(7'h48, 32'h00000014); // finalize
            read_calculated_tag(tag);
            wait_pipeline_idle;
            if (total_output_count - outputs_before != 1)
                $fatal(1, "DM output count mismatch");
            check_128("dm-crypt Native AEAD (AAD + Ciphertext GMAC)", tag, 128'hf41bde8267254697194188b06d938b99);
        end
    endtask

    task run_integrity_check_case(input fail_case);
        reg [127:0] key;
        reg [95:0] iv;
        reg [127:0] aad;
        reg [127:0] tag_to_write;
        reg [127:0] expected_correct_tag, calculated_tag;
        reg [31:0] status;
        begin
            if (fail_case) begin
                key = 128'hd1f6af919cde85661208bdce0c27cb22;
                iv = 96'h898c6929b435017bf031c3c5;
                aad = 128'h7c5faa40e636bbc91107e68010c92b9f;
                expected_correct_tag = 128'he45489b426e98c4a289c3f8bbe0d5b28;
                tag_to_write = 128'hae45f11777540a2caeb128be8092468a; // Mismatched tag
            end else begin
                key = 128'h2370e320d4344208e0ff5683f243b213;
                iv = 96'h04dbb82f044d30831c441228;
                aad = 128'hd43a8e5089eea0d026c03a85178b27da;
                expected_correct_tag = 128'h2a049c049d25aa95969b451d93c31c6e;
                tag_to_write = expected_correct_tag; // Valid tag
            end

            write_avalon_fast(7'h48, 32'h00000008); // clear
            write_key_pair(key, key);
            write_avalon_fast(7'h34, 32'h00000001);
            write_iv96(iv);
            wait_ready_in;
            repeat (14) @(posedge clk);
            write_avalon_fast(7'h48, 32'h00000002);
            write_expected_tag(tag_to_write);
            send_stream_block(aad);
            // GHASH x2 có thể đang giữ một khối lẻ: finalize TRƯỚC khi đợi idle.
            // Top tự drain AES rồi enqueue length block để hoàn tất cặp cuối.
            write_avalon_fast(7'h48, 32'h00000004);
            read_calculated_tag(calculated_tag);
            check_128("Integrity case calculated tag", calculated_tag, expected_correct_tag);
            wait_pipeline_idle;
            read_avalon_fast(7'h30, status);

            if (!fail_case && status[5] === 1'b0) begin
                $display("[PASS] Valid tag accepted, integrity_error = 0");
                pass_count = pass_count + 1;
            end else if (fail_case && status[5] === 1'b1 && ready_in === 1'b1) begin
                $display("[PASS] Mismatched tag correctly asserted INTEGRITY_ERROR flag while DMA remained active (no panic lock)");
                pass_count = pass_count + 1;
            end else begin
                $display("[FATAL ERROR] Integrity check failed! status = 0x%08h, ready_in = %b", status, ready_in);
                fail_count = fail_count + 1;
                $fatal(1, "Automatic check failed: Integrity check handling error!");
            end
        end
    endtask

endmodule
