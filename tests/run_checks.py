#!/usr/bin/env python3
"""Deterministic baseline checks; run from any directory. Requires Icarus + cryptography."""
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
    with tempfile.TemporaryDirectory(prefix='final-prj-') as tmp:
        tb, out = Path(tmp)/'tb.sv', Path(tmp)/'sim.vvp'
        tb.write_text('`timescale 1ns/1ps\nmodule tb;\n' + body + '\nendmodule\n')
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

def ghash_checks():
    rng=random.Random(42)
    body=CLOCK+'''
reg clear=0, invalidate=0, table_start=0, valid=0;
reg [127:0] block_in=0, h=0; wire [127:0] acc;
wire busy,ready,done,table_ready;
integer cycles=0,last_accept=-1;
always @(posedge clk) begin
 cycles <= cycles+1;
 if(valid && ready) begin
  if(last_accept>=0 && cycles-last_accept != 3) $fatal(1,"GHASH II not 3");
  last_accept <= cycles;
 end
end
ghash_core dut(clk,rst_n,clear,invalidate,table_start,valid,block_in,h,acc,busy,ready,done,table_ready);
initial begin
 repeat(3) @(negedge clk); rst_n=1;
'''
    for trial in range(2):
        h=rng.getrandbits(128); y=0
        body+=f'@(negedge clk); h={lit(h)}; table_start=1; last_accept=-1;\n@(negedge clk); table_start=0; wait(table_ready);\n'
        for _ in range(24):
            x=rng.getrandbits(128); y=mul(y ^ x,h)
            body+=f'@(negedge clk); block_in={lit(x)}; valid=1;\n@(posedge clk); while(!ready) @(posedge clk);\n'
            # The next block is driven on the next negedge while GHASH is busy.
        body+=f'@(negedge clk); valid=0; wait(!done); wait(done); #1; if(acc !== {lit(y)}) $fatal(1,"GHASH result mismatch");\n'
        body+='@(negedge clk); clear=1; @(negedge clk); clear=0; #1; if(acc !== 0 || !table_ready) $fatal(1,"clear failed");\n'
    body+='@(negedge clk); invalidate=1; @(negedge clk); invalidate=0; #1; if(table_ready || ready) $fatal(1,"invalidate failed");\n$display("PASS ghash: 48 blocks, 2 keys, II=3, clear and invalidate"); $finish; end\n'
    run('ghash',body)

def top_checks(n, direction, dm):
    key=bytes(range(32)); lba=1; sector=0x0123456789abcdef
    tweak=lba.to_bytes(16,'little')
    pt=bytes((i*29+11)%256 for i in range(16*n))
    enc=Cipher(algorithms.AES(key),modes.XTS(tweak)).encryptor()
    ct=enc.update(pt)+enc.finalize()
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
    name=f'top_n{n}_dir{direction}_dm{dm}'
    body=CLOCK.replace('$fatal(1,"watchdog timeout")', '$display("state=%d key=%b lba=%b setup=%b table=%b sent=%d recv=%d final=%b active=%b valid=%b ready=%b", dut.setup_state,dut.key_loaded,dut.lba_loaded,dut.setup_ready,dut.ghash_table_ready,sent,received,dut.finalize_pending,dut.finalize_active,valid_in,ready_in); $fatal(1,"watchdog timeout")')+f'''
reg [6:0] address=7'h7c; reg read=0,write=0; reg [31:0] writedata=0; wire [31:0] readdata;
reg valid_in=0; reg [127:0] data_in=0; wire ready_in,valid_out; wire [127:0] data_out;
reg ready_out=0; reg [127:0] inputs[0:{n-1}], expected[0:{n-1}];
integer sent=0,received=0,cycle=0; reg streaming=0,holding=0,accepted_last=0; reg [127:0] held;
aes_xts_top_module dut(clk,rst_n,address,read,write,writedata,readdata,valid_in,data_in,ready_in,valid_out,data_out,ready_out);
task csr(input [6:0] addr,input [31:0] value);
begin @(negedge clk); address=addr; writedata=value; write=1; @(negedge clk); write=0; end endtask
always @(negedge clk) begin
 if(streaming) begin
  cycle=cycle+1;
  ready_out=(cycle%7!=0 && cycle%7!=1 && cycle%11!=0);
  if(!valid_in || accepted_last) begin
   valid_in=(sent<{n}) && (cycle%5!=0);
   if(sent<{n}) data_in=inputs[sent];
  end
 end
end
always @(posedge clk) begin
 if(streaming) begin
  if(holding && (!valid_out || data_out !== held)) $fatal(1,"output changed under backpressure");
  holding=valid_out && !ready_out; held=data_out;
  accepted_last=valid_in && ready_in;
  if(accepted_last) sent=sent+1;
  if(valid_out && ready_out) begin
   if(received>={n}) $fatal(1,"extra output");
   if(data_out !== expected[received]) $fatal(1,"XTS output %0d got=%h expected=%h",received,data_out,expected[received]);
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
$display("PASS {name}: {n} XTS blocks + tag + stalls"); $finish;
end
'''
    run(name,body)

if __name__=='__main__':
    math_checks()
    setup_checks()
    ghash_checks()
    for direction in (0,1):
        for dm in (0,1):
            for n in (1,2,3,16):
                top_checks(n,direction,dm)
    print('All 19 check groups passed.')
