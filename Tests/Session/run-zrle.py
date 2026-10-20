#!/usr/bin/env python3
"""Independent Python zlib fixtures exercise every ZRLE tile mode and invalid bounds."""
import base64, hashlib, json, pathlib, random, subprocess, sys, tempfile, zlib
root=pathlib.Path(__file__).resolve().parents[2]
work=pathlib.Path(tempfile.mkdtemp(prefix='deskpad-zrle-'))
cases=[]
def b64(value): return base64.b64encode(value).decode()
def rgba(pixels): return b''.join(bytes([p[2],p[1],p[0],255]) for p in pixels)
def add(name,w,h,tiles,pixels=None,reject=False,expired=False,compressed=None,solid=None):
    compressor=zlib.compressobj()
    payload=compressed if compressed is not None else compressor.compress(tiles)+compressor.flush(zlib.Z_SYNC_FLUSH)
    rect=dict(width=w,height=h,compressed=b64(payload))
    if pixels is not None: rect['rgba']=b64(rgba(pixels))
    if solid is not None: rect['solid']=solid
    cases.append(dict(name=name,rectangles=[rect],reject=reject,expired=expired))
red=bytes([0x12,0x34,0x56]); blue=bytes([0x98,0x76,0x54])
add('raw-cpixel',3,2,b'\0'+(red+blue)*3,[red,blue]*3)
add('solid',3,2,b'\1'+red,[red]*6)
for count in (2,3,4,5,16):
    w,h=7,3
    palette=[bytes([i*11,i*7,i*3]) for i in range(count)]
    bits=1 if count==2 else 2 if count<=4 else 4
    packed=bytearray(); pixels=[]
    for y in range(h):
        row=bytearray((w*bits+7)//8)
        for x in range(w):
            index=(x+y)%count
            pixels.append(palette[index])
            row[x*bits//8] |= index << (8-bits-x*bits%8)
        packed.extend(row)
    add(f'packed-{count}-row-padding',w,h,bytes([count])+b''.join(palette)+packed,pixels)
add('plain-rle-extended-run',64,5,b'\x80'+red+b'\xff\x3f'+blue+b'\0',[red]*319+[blue])
for count in (2,127):
    palette=[bytes([i,i+1,i+2]) for i in range(count)]
    add(f'palette-rle-{count}',4,2,bytes([128+count])+b''.join(palette)+bytes([0,0x80+count-1,6]),[palette[0]]+[palette[-1]]*7)
# Four tiles, including one-pixel-wide/bottom edge tiles, in row-major order.
colors=[red,blue,bytes([11,22,33]),bytes([44,55,66])]
pixels=[colors[(y//64)*2+x//64] for y in range(65) for x in range(65)]
add('65x65-edge-tiles',65,65,b''.join(b'\1'+color for color in colors),pixels)
compressor=zlib.compressobj()
rects=[]
for color in (red,blue,red):
    payload=compressor.compress(b'\0'+color*64)+compressor.flush(zlib.Z_SYNC_FLUSH)
    rects.append(dict(width=8,height=8,compressed=b64(payload),rgba=b64(rgba([color]*64))))
cases.append(dict(name='persistent-stream-three-rectangles',rectangles=rects,reject=False,expired=False))
for mode in (17,127,129): add(f'reserved-{mode}',1,1,bytes([mode]),reject=True)
add('packed-index-overrun',1,1,b'\3'+red*3+b'\xc0',reject=True)
add('palette-rle-index-overrun',1,1,b'\x82'+red*2+b'\x02',reject=True)
add('run-overrun',1,1,b'\x80'+red+b'\xff',reject=True)
add('truncated-pixel',1,1,b'\0\x01',reject=True)
add('extra-tile-bytes',1,1,b'\1'+red+b'\0',reject=True)
add('inflate-bomb',1,1,b'\0'*1_000_000,reject=True)
add('invalid-zlib',1,1,b'',compressed=b'invalid',reject=True)
add('empty-compressed',1,1,b'',compressed=b'',reject=True)
add('invalid-dimensions',8192,8192,b'\1'+red,reject=True)
add('expired-decode-budget',1,1,b'\1'+red,reject=True,expired=True)
add('oversized-compressed-for-tiny-tile',1,1,b'',compressed=b'\0'*70_000,reject=True)
add('mid-decode-deadline',4096,4096,(b'\1'+red)*(64*64),reject=True)
cases[-1]['budgetMilliseconds']=1
w,h=6016,3384
add('6K-solid-frame',w,h,(b'\1'+red)*(((w+63)//64)*((h+63)//64)),solid=[red[2],red[1],red[0]])
# An incompressible frame exercises every raw tile and verifies placement via
# an independently assembled RGBA SHA-256, including partial bottom tiles.
rng=random.Random(6143)
encoded=bytearray(); expected=bytearray(w*h*4)
for y in range(0,h,64):
    for x in range(0,w,64):
        tw,th=min(64,w-x),min(64,h-y)
        tile=rng.randbytes(tw*th*3)
        encoded.append(0); encoded.extend(tile)
        for row in range(th):
            src=tile[row*tw*3:(row+1)*tw*3]
            dst=bytearray(tw*4)
            dst[0::4]=src[2::3]; dst[1::4]=src[1::3]; dst[2::4]=src[0::3]; dst[3::4]=bytes([255])*tw
            start=((y+row)*w+x)*4; expected[start:start+tw*4]=dst
compressor=zlib.compressobj()
payload=compressor.compress(encoded)+compressor.flush(zlib.Z_SYNC_FLUSH)
cases.append(dict(name='6K-noisy-raw-tiles',rectangles=[dict(width=w,height=h,compressed=b64(payload),digest=hashlib.sha256(expected).hexdigest())],reject=False,expired=False))
del encoded,expected,payload
fixture=work/'fixtures.json'; fixture.write_text(json.dumps(cases))
binary=work/'zrle-tests'
subprocess.run(['swiftc']+([] if '--debug' in sys.argv else ['-O'])+['-parse-as-library',str(root/'DeskPad/RFBZRLEDecoder.swift'),str(root/'Tests/Session/ZRLEHarness.swift'),'-o',str(binary)],check=True)
subprocess.run([str(binary),str(fixture)],check=True,timeout=60)
