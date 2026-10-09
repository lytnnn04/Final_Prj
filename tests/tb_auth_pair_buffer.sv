`timescale 1ns/1ps
module tb;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clear=0;
    reg in_valid=0, in_last=0, pair_ready=0;
    reg [127:0] in_data=0;
    wire in_ready, pair_valid, two_blocks, pair_last, empty;
    wire [127:0] first_data, second_data;
    auth_pair_buffer dut(
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data), .in_last(in_last),
        .pair_valid(pair_valid), .pair_ready(pair_ready),
        .block_first(first_data), .block_second(second_data),
        .two_blocks(two_blocks), .pair_last(pair_last), .empty(empty)
    );

    // Reference queue records only accepted input. No dependence on DUT count.
    reg [127:0] reference_data[0:2047];
    reg reference_last[0:2047];
    integer head=0, tail=0, accepted=0, consumed=0, simultaneous=0;
    integer stalled=0, singletons=0, final_pairs=0;
    reg input_taken=0, output_held=0;
    reg [127:0] held_first, held_second;
    reg held_two, held_last;
    always @(posedge clk) begin
        input_taken = 0;
        if (!rst_n || clear) begin
            head=0; tail=0; output_held=0;
        end else begin
            if(output_held && (!pair_valid || first_data!==held_first ||
                second_data!==held_second || two_blocks!==held_two || pair_last!==held_last))
                $fatal(1,"batch changed during backpressure");
            output_held=pair_valid && !pair_ready;
            held_first=first_data; held_second=second_data;
            held_two=two_blocks; held_last=pair_last;
            if(output_held) stalled=stalled+1;
            if(empty !== (head==tail)) $fatal(1,"empty mismatch");
            if(pair_valid && pair_ready) begin
                if(head>=tail || first_data!==reference_data[head]) $fatal(1,"first block mismatch");
                if(two_blocks) begin
                    if(head+1>=tail || reference_last[head] || second_data!==reference_data[head+1])
                        $fatal(1,"second block/order mismatch");
                    if(pair_last!==reference_last[head+1]) $fatal(1,"pair last mismatch");
                    if(pair_last) final_pairs=final_pairs+1;
                    head=head+2; consumed=consumed+2;
                end else begin
                    if(!reference_last[head] || !pair_last) $fatal(1,"invalid singleton");
                    head=head+1; consumed=consumed+1; singletons=singletons+1;
                end
            end
            if(in_valid && in_ready) begin
                reference_data[tail]=in_data; reference_last[tail]=in_last;
                tail=tail+1; accepted=accepted+1; input_taken=1;
                if(pair_valid && pair_ready) simultaneous=simultaneous+1;
            end
            if(tail-head>2) $fatal(1,"overflow");
        end
    end

    // Deterministic pseudo-random traffic, with messages of length 1..9.
    reg [31:0] rng=32'h89abcdef;
    integer cycle, sequence_id=0, remaining=1;
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        for(cycle=0;cycle<1500;cycle=cycle+1) begin
            @(negedge clk);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            pair_ready=rng[2] && !(cycle>=100 && cycle<140);
            if(!in_valid || input_taken) begin
                if(input_taken) begin
                    sequence_id=sequence_id+1;
                    remaining=(remaining==1) ? (sequence_id%9+1) : remaining-1;
                end
                in_valid=rng[0]; in_data=sequence_id; in_last=(remaining==1);
            end
        end
        // Drain whatever source beat is still pending, then flush an odd tail.
        @(negedge clk); pair_ready=1;
        while(in_valid && !input_taken) @(negedge clk);
        in_valid=0;
        @(negedge clk);
        if(tail-head==1 && !reference_last[head]) begin
            in_data=128'hfeed; in_last=1; in_valid=1;
            @(negedge clk); in_valid=0;
        end
        repeat(3) @(negedge clk);
        if(!empty || accepted!=consumed) $fatal(1,"drain mismatch");
        if(!simultaneous || !stalled || !singletons || !final_pairs) $fatal(1,"missing coverage");

        // Clear while full and stalled, then asynchronous reset with one pending.
        in_valid=1; in_last=0; in_data=128'h11; pair_ready=0;
        @(negedge clk); in_data=128'h22;
        @(negedge clk); in_valid=0;
        #1; if(in_ready || !pair_valid) $fatal(1,"expected full buffer");
        clear=1;
        #1; if(in_ready || pair_valid) $fatal(1,"handshake during clear");
        @(negedge clk); clear=0;
        #1; if(!empty) $fatal(1,"clear failed");
        in_valid=1; in_data=128'h33;
        @(negedge clk); in_valid=0; rst_n=0;
        #1; if(!empty || pair_valid || in_ready) $fatal(1,"reset failed");
        $display("PASS buffer: accepted=%0d simultaneous=%0d stalled=%0d singles=%0d final_pairs=%0d, clear/reset",accepted,simultaneous,stalled,singletons,final_pairs);
        $finish;
    end
    initial begin #100000; $fatal(1,"buffer watchdog"); end
endmodule
