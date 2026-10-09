#!/usr/bin/env python3
"""Deterministic GHASH x2 and AES-XTS checks; run from any directory. Requires Icarus + cryptography."""
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(str(p) for p in ROOT.glob('*.v'))
LOCAL = Path('/workspace/.tools/final-prj/root/usr')
IVERILOG = shutil.which('iverilog') or str(LOCAL / 'bin/iverilog')
VVP = shutil.which('vvp') or str(LOCAL / 'bin/vvp')
BASE = [] if shutil.which('iverilog') else ['-B', str(LOCAL / 'lib/x86_64-linux-gnu/ivl')]
R = 0xe1000000000000000000000000000000

def mul(x, y):
    z = 0
    for i in range(128):
        if x & (1 << (127-i)):
            z ^= y
        y = (y >> 1) ^ (R if y & 1 else 0)
    return z

def poly_mul(x, y):
    # Independent ordinary polynomial representation, then reverse GHASH bit order.
    rev = lambda a: int(f'{a:0128b}'[::-1], 2)
    a, b, z = rev(x), rev(y), 0
    for i in range(128):
        if (b >> i) & 1:
            z ^= a << i
    modulus = (1 << 128) | 0x87
    for i in range(254, 127, -1):
        if (z >> i) & 1:
            z ^= modulus << (i-128)
    return rev(z)

def aes(key, data):
    return Cipher(algorithms.AES(key), modes.ECB()).encryptor().update(data)

def lit(x):
    return f"128'h{x:032x}"

def run(name, body):
    run_source(name, '`timescale 1ns/1ps\nmodule tb;\n' + body + '\nendmodule\n')


def run_source(name, source):
    with tempfile.TemporaryDirectory(prefix='final-prj-') as tmp:
        tb, out = Path(tmp)/'tb.sv', Path(tmp)/'sim.vvp'
        tb.write_text(source)
        subprocess.run([IVERILOG, *BASE, '-g2012', '-Wall', '-s', 'tb', '-o', str(out), *SOURCES, str(tb)], cwd=ROOT, check=True)
        result = subprocess.run([VVP, str(out)], cwd=ROOT, text=True, capture_output=True, timeout=90)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        if result.returncode or f'PASS {name}' not in result.stdout:
            raise RuntimeError(f'{name} failed (exit {result.returncode})')

CLOCK = '''reg clk=0; always #5 clk=~clk;
reg rst_n=0;
initial begin #2000000; $fatal(1,"watchdog timeout"); end
'''

def math_checks():
    rng = random.Random(20261009)
    assert mul(0x0388dace60b6a392f328c2b971b2fe78, 0x66e94bd4ef8a2c3b884cfa59ca342b2e) == 0x5e2ec746917062882c85b0685353deb7
    for _ in range(1000):
        y, x1, x2, h = (rng.getrandbits(128) for _ in range(4))
        assert mul(x1, h) == poly_mul(x1, h)
        assert mul(mul(y ^ x1, h) ^ x2, h) == mul(y ^ x1, mul(h, h)) ^ mul(x2, h)
    s = [int(x,16) for x in (ROOT/'aes_sbox.hex').read_text().split()]
    inv = [int(x,16) for x in (ROOT/'aes_inv_sbox.hex').read_text().split()]
    assert len(s) == len(inv) == 256 and all(inv[s[i]] == i for i in range(256))
    print('PASS math: 1000 independent multiplication + GHASH x2 identities; 256 S-box inverses')

def setup_checks():
    key=bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    pt=bytes.fromhex('3243f6a8885a308d313198a2e0370734')
    expected=int.from_bytes(aes(key,pt),'big')
    run('setup', CLOCK + f'''
reg start=0; wire busy,done; wire [127:0] result;
aes_128_setup_iterative dut(clk,rst_n,start,{lit(int.from_bytes(pt,'big'))},{lit(int.from_bytes(key,'big'))},result,busy,done);
initial begin
 repeat(3) @(negedge clk); rst_n=1;
 @(negedge clk); start=1; @(negedge clk); start=0;
 wait(done); #1;
 if(result !== {lit(expected)}) $fatal(1,"AES setup mismatch: %h",result);
 $display("PASS setup: AES known-answer vector"); $finish;
end
''')

def multiplier_checks():
    rng = random.Random(128)
    identity = 1 << 127
    ones = (1 << 128) - 1
    vectors = [(0, ones), (ones, 0), (ones, ones), (identity, ones),
               (ones, identity), (identity, identity)]
    # Cover every unreduced monomial degree 0..254, including both folds.
    for degree in range(255):
        i = min(degree, 127)
        j = degree - i
        vectors.append((1 << (127-i), 1 << (127-j)))
    vectors += [(rng.getrandbits(128), rng.getrandbits(128)) for _ in range(512)]
    body = "reg [127:0] a,b; wire [127:0] product;\ngf_mult_128 dut(a,b,product);\ninitial begin\n"
    for i, (a, b) in enumerate(vectors):
        body += f'a={lit(a)}; b={lit(b)}; #1; if(product !== {lit(poly_mul(a,b))}) $fatal(1,"multiply vector {i}");\n'
    body += f'$display("PASS multiplier: {len(vectors)} vectors, all 255 monomial degrees"); $finish; end\n'
    run('multiplier', body)


def ghash_checks():
    rng = random.Random(42)
    body = CLOCK + """
reg clear=0, invalidate=0, key_load=0, valid=0, two=0, last=0;
reg [127:0] first=0, second=0, h=0;
wire [127:0] acc;
wire setup_busy,ready,done,keys_ready,last_done;
ghash_core dut(.clk(clk),.rst_n(rst_n),.clear(clear),.invalidate_key(invalidate),
 .key_load(key_load),.hash_subkey(h),.valid(valid),.ready(ready),
 .block_first(first),.block_second(second),.two_blocks(two),.last(last),
 .accumulator(acc),.keys_ready(keys_ready),.setup_busy(setup_busy),
 .done(done),.last_done(last_done));
initial begin
 repeat(3) @(negedge clk); rst_n=1;
 #1; if(ready || keys_ready) $fatal(1,"ready before key setup");
"""
    keys = [0, 1 << 127, rng.getrandbits(128), rng.getrandbits(128)]
    for h in keys:
        y = 0
        body += f"""
@(negedge clk); h={lit(h)}; key_load=1; valid=1;
#1; if(ready) $fatal(1,"accept during key_load");
@(posedge clk); #1;
if(keys_ready || ready || !setup_busy || done) $fatal(1,"key_load protocol");
@(negedge clk); key_load=0;
#1; if(ready) $fatal(1,"accept during H square");
@(posedge clk); #1;
if(!keys_ready || !ready || setup_busy || done || acc!==0) $fatal(1,"H square protocol");
if(dut.h_squared_reg !== {lit(mul(h,h))}) $fatal(1,"H squared mismatch");
"""
        for i in range(24):
            first, second = rng.getrandbits(128), rng.getrandbits(128)
            two, last = int(i % 3 != 0), int(i == 23)
            y = mul(y ^ first, h)
            if two:
                y = mul(y ^ second, h)
            body += f"""
@(negedge clk); valid=1; first={lit(first)}; second={lit(second)}; two={two}; last={last};
#1; if(!ready) $fatal(1,"cannot accept consecutive batch");
@(posedge clk); #1;
if(!done || last_done!==1'b{last} || acc !== {lit(y)}) $fatal(1,"batch {i} mismatch");
"""
            if i % 5 == 0:
                body += f"""
@(negedge clk); valid=0;
@(posedge clk); #1;
if(done || last_done || acc !== {lit(y)}) $fatal(1,"accumulator changed during gap");
"""
        body += """
@(negedge clk); clear=1; valid=1;
#1; if(ready) $fatal(1,"accept during clear");
@(posedge clk); #1;
if(acc!==0 || !keys_ready || done || last_done) $fatal(1,"clear failed");
@(negedge clk); clear=0; valid=0;
"""
    body += """
// Invalidation during square must cancel setup and clear both hash keys.
@(negedge clk); key_load=1;
@(negedge clk); key_load=0; invalidate=1;
@(posedge clk); #1;
if(keys_ready || ready || setup_busy || dut.h_reg!==0 || dut.h_squared_reg!==0)
 $fatal(1,"invalidate failed");
@(negedge clk); invalidate=0; valid=1;
repeat(3) begin @(posedge clk); #1; if(ready || done || acc!==0) $fatal(1,"accepted invalid key"); end
@(negedge clk); rst_n=0;
#1; if(keys_ready || acc!==0) $fatal(1,"reset failed");
$display("PASS ghash: 96 batches, 4 keys, consecutive batches, singleton, H2, clear/invalidate/reset");
$finish; end
"""
    run('ghash', body)


def top_checks(n, direction, dm, stalls=True):
    key=bytes(range(32)); lba=1; sector=0x0123456789abcdef
    tweak=lba.to_bytes(16,'little')
    pt=bytes((i*29+11)%256 for i in range(16*n))
    enc=Cipher(algorithms.AES(key),modes.XTS(tweak)).encryptor()
    ct=(enc.update(pt)+enc.finalize()) if n else b''
    incoming,expected=(ct,pt) if direction else (pt,ct)
    auth_key=aes(key[:16],int('5854532d474d41432d41555448000001',16).to_bytes(16,'big')) if dm else key[:16]
    h=int.from_bytes(aes(auth_key,bytes(16)),'big')
    mask=int.from_bytes(aes(auth_key,tweak[:12]+b'\0\0\0\1'),'big')
    blocks=[]
    if dm:
        aad=sector.to_bytes(8,'big')+tweak
        blocks += [int.from_bytes(aad[:16],'big'),int.from_bytes(aad[16:]+bytes(8),'big')]
    blocks += [int.from_bytes(ct[i:i+16],'big') for i in range(0,len(ct),16)]
    blocks += [((192<<64) | n*128) if dm else (n*128)<<64]
    y=0
    for x in blocks: y=mul(y ^ x,h)
    name=f'top_n{n}_dir{direction}_dm{dm}_stalls{int(stalls)}'
    body=CLOCK.replace('$fatal(1,"watchdog timeout")', '$display("state=%d key=%b lba=%b setup=%b hash_keys=%b sent=%d recv=%d final=%b active=%b valid=%b ready=%b", dut.setup_state,dut.key_loaded,dut.lba_loaded,dut.setup_ready,dut.ghash_keys_ready,sent,received,dut.finalize_pending,dut.finalize_active,valid_in,ready_in); $fatal(1,"watchdog timeout")')+f'''
reg [6:0] address=7'h7c; reg read=0,write=0; reg [31:0] writedata=0; wire [31:0] readdata;
reg valid_in=0; reg [127:0] data_in=0; wire ready_in,valid_out; wire [127:0] data_out;
reg ready_out=0; reg [127:0] inputs[0:{max(n,1)-1}], expected[0:{max(n,1)-1}];
integer sent=0,received=0,cycle=0,last_input_cycle=-1,last_output_cycle=-1; reg streaming=0,holding=0,accepted_last=0; reg [127:0] held;
aes_xts_top_module dut(clk,rst_n,address,read,write,writedata,readdata,valid_in,data_in,ready_in,valid_out,data_out,ready_out);
task csr(input [6:0] addr,input [31:0] value);
begin @(negedge clk); address=addr; writedata=value; write=1; @(negedge clk); write=0; end endtask
always @(negedge clk) begin
 if(streaming) begin
  cycle=cycle+1;
  ready_out={'(cycle%7!=0 && cycle%7!=1 && cycle%11!=0 && !(cycle>=25 && cycle<65))' if stalls else '1'};
  if(!valid_in || accepted_last) begin
   valid_in=(sent<{n}) && {'(cycle%5!=0)' if stalls else '1'};
   if(sent<{n}) data_in=inputs[sent];
  end
 end
end
always @(posedge clk) begin
 if(streaming) begin
  if(holding && (!valid_out || data_out !== held)) $fatal(1,"output changed under backpressure");
  holding=valid_out && !ready_out; held=data_out;
  accepted_last=valid_in && ready_in;
  if(accepted_last) begin
   if(!{int(stalls)} && last_input_cycle>=0 && cycle-last_input_cycle!=1)
    $fatal(1,"input throughput below 1 block/clock");
   last_input_cycle=cycle;
   sent=sent+1;
  end
  if(valid_out && ready_out) begin
   if(received>={n}) $fatal(1,"extra output");
   if(data_out !== expected[received]) $fatal(1,"XTS output %0d got=%h expected=%h",received,data_out,expected[received]);
   if(!{int(stalls)} && last_output_cycle>=0 && cycle-last_output_cycle!=1)
    $fatal(1,"output throughput below 1 block/clock");
   last_output_cycle=cycle;
   received=received+1;
  end
 end
end
initial begin
'''
    for i in range(n):
        body+=f'inputs[{i}]={lit(int.from_bytes(incoming[16*i:16*i+16],"big"))}; expected[{i}]={lit(int.from_bytes(expected[16*i:16*i+16],"big"))};\n'
    body+='repeat(3) @(negedge clk); rst_n=1; wait(dut.bist_done); if(dut.bist_error) $fatal(1,"BIST failed");\n'
    if dm: body+="csr(7'h48,32'h10);\n"
    for i in range(8): body+=f"csr(7'h{i*4:02x},32'h{int.from_bytes(key[4*i:4*i+4],'big'):08x});\n"
    for i in range(4): body+=f"csr(7'h{0x20+i*4:02x},32'h{(lba >> (96-32*i))&0xffffffff:08x});\n"
    body+=f"csr(7'h34,32'd{direction}); csr(7'h4c,32'h{sector>>32:08x}); csr(7'h50,32'h{sector&0xffffffff:08x});\n"
    body+='wait(dut.datapath_ready);\n'
    body+=f"csr(7'h48,32'h{(dm<<4)|2:08x});\n"
    if direction:
        for i in range(4):body+=f"csr(7'h{0x38+i*4:02x},32'h{((y^mask)>>(96-32*i))&0xffffffff:08x});\n"
    body+=f'''@(negedge clk); streaming=1;
wait(sent=={n});
csr(7'h48,32'h{(dm<<4)|4:08x});
wait(dut.tag_ready); #1;
if(received!={n}) $fatal(1,"missing outputs");
if(dut.calculated_tag !== {lit(y^mask)}) $fatal(1,"tag mismatch got=%h",dut.calculated_tag);
if(dut.integrity_error) $fatal(1,"unexpected integrity failure");
$display("PASS {name}: {n} XTS blocks + tag; {"stalls" if stalls else "input/output II=1"}"); $finish;
end
'''
    run(name,body)

def lifecycle_checks():
    """Reuse H/H2 across LBAs; refresh on mode/key change; abort in-flight AES."""
    body = CLOCK + """
reg [6:0] address=7'h7c; reg read=0,write=0; reg [31:0] writedata=0;
wire [31:0] readdata;
reg valid_in=0; reg [127:0] data_in=0; wire ready_in,valid_out;
wire [127:0] data_out; reg ready_out=1;
reg [127:0] expected[0:1]; integer received=0, key_loads=0;
reg checking=0;
aes_xts_top_module dut(clk,rst_n,address,read,write,writedata,readdata,
 valid_in,data_in,ready_in,valid_out,data_out,ready_out);
task csr(input [6:0] addr,input [31:0] value);
 begin @(negedge clk); address=addr; writedata=value; write=1;
 @(negedge clk); write=0; end
endtask
task send_block(input [127:0] value);
 begin @(negedge clk); data_in=value; valid_in=1;
 @(posedge clk); while(!ready_in) @(posedge clk);
 @(negedge clk); valid_in=0; end
endtask
always @(posedge clk) begin
 if(rst_n && dut.ghash_key_load_reg) key_loads=key_loads+1;
 if(rst_n && valid_out && ready_out && checking) begin
  if(received>=2 || data_out!==expected[received]) $fatal(1,"lifecycle XTS mismatch");
  received=received+1;
 end
end
initial begin
 repeat(3) @(negedge clk); rst_n=1; wait(dut.bist_done);
 if(dut.bist_error) $fatal(1,"BIST failed");
"""
    key_a, key_b = bytes(range(32)), bytes(range(32,64))
    cases = [(key_a,1,1,True,1), (key_a,2,1,False,1),
             (key_a,3,0,False,2), (key_b,4,1,True,3),
             (key_b,5,1,True,4)]
    for index, (key,lba,dm,reload,loads) in enumerate(cases):
        if index == 4:
            body += """
// Abort a block while it is still inside the twenty-stage AES pipeline.
checking=0;
send_block(128'h1234);
csr(7'h48,32'h18);
#1;
if(dut.key_loaded || dut.ghash_keys_ready || dut.valid_pipeline!==0 || !dut.auth_buffer_empty)
 $fatal(1,"clear-key did not abort in-flight data");
repeat(25) begin @(posedge clk); #1; if(valid_out || ready_in) $fatal(1,"stale data after clear-key"); end
"""
        if reload:
            body += f"csr(7'h48,32'h{(dm<<4)|8:08x});\n"
            for i in range(8):
                body += f"csr(7'h{i*4:02x},32'h{int.from_bytes(key[4*i:4*i+4],'big'):08x});\n"
        else:
            body += f"csr(7'h48,32'h{dm<<4:08x});\n"
        for i in range(4):
            body += f"csr(7'h{0x20+4*i:02x},32'h{(lba>>(96-32*i))&0xffffffff:08x});\n"
        body += f"wait(dut.datapath_ready); #1; if(key_loads!={loads}) $fatal(1,\"H/H2 refresh count got=%0d\",key_loads);\n"
        tweak = lba.to_bytes(16,'little')
        plain = bytes((i+index*17)%256 for i in range(32))
        encryptor = Cipher(algorithms.AES(key),modes.XTS(tweak)).encryptor()
        ciphertext = encryptor.update(plain)+encryptor.finalize()
        auth_key = aes(key[:16],int('5854532d474d41432d41555448000001',16).to_bytes(16,'big')) if dm else key[:16]
        h = int.from_bytes(aes(auth_key,bytes(16)),'big')
        mask = int.from_bytes(aes(auth_key,tweak[:12]+b'\0\0\0\1'),'big')
        aad = bytes(8)+tweak
        blocks = [int.from_bytes(aad[:16],'big'),int.from_bytes(aad[16:]+bytes(8),'big')] if dm else []
        blocks += [int.from_bytes(ciphertext[:16],'big'),int.from_bytes(ciphertext[16:],'big')]
        blocks += [((192<<64)|256) if dm else (256<<64)]
        y=0
        for x in blocks:
            y=mul(y^x,h)
        body += f"""
csr(7'h48,32'h{(dm<<4)|2:08x});
expected[0]={lit(int.from_bytes(ciphertext[:16],'big'))};
expected[1]={lit(int.from_bytes(ciphertext[16:],'big'))};
received=0; checking=1;
send_block({lit(int.from_bytes(plain[:16],'big'))});
send_block({lit(int.from_bytes(plain[16:],'big'))});
csr(7'h48,32'h{(dm<<4)|4:08x});
wait(dut.tag_ready); #1;
if(received!=2 || dut.calculated_tag!=={lit(y^mask)}) $fatal(1,"lifecycle tag/count case {index}");
checking=0;
"""
    body += '$display("PASS lifecycle: 5 messages, LBA reuse, mode/key refresh, in-flight clear-key and recovery"); $finish; end\n'
    run('lifecycle',body)


if __name__=='__main__':
    math_checks()
    setup_checks()
    multiplier_checks()
    ghash_checks()
    run_source('buffer', (ROOT/'tests/tb_auth_pair_buffer.sv').read_text())
    for direction in (0,1):
        for dm in (0,1):
            for n in (0,1,2,3,16):
                top_checks(n,direction,dm)
    for direction in (0,1):
        top_checks(64,direction,1,stalls=False)
    lifecycle_checks()
    print('All 28 check groups passed.')
