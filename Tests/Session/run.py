#!/usr/bin/env python3
"""Standalone real TCP RFB regression suite; no simulator or test target needed."""
import pathlib, socket, struct, subprocess, sys, tempfile, threading, time, zlib
root = pathlib.Path(__file__).resolve().parents[2]
binary = pathlib.Path(tempfile.mkdtemp(prefix='deskpad-session-')) / 'session-tests'
subprocess.run(['swiftc', '-parse-as-library', str(root/'DeskPad/ConnectionStore.swift'), str(root/'DeskPad/VNCSession.swift'), str(root/'DeskPad/RFBInputQueue.swift'), str(root/'DeskPad/RFBZRLEDecoder.swift'), str(root/'Tests/Session/Harness.swift'), '-o', str(binary)], check=True)
def exact(c,n):
    out=b''
    while len(out)<n:
        part=c.recv(n-len(out))
        if not part: raise EOFError()
        out+=part
    return out
errors=[]
def serve_disconnect(listener, mode, marker):
    for attempt in range(2):
        c, _ = listener.accept()
        with c:
            c.settimeout(7)
            c.sendall(b'RFB 003.008\n'); assert exact(c,12)==b'RFB 003.008\n'
            c.sendall(b'\x01\x01'); assert exact(c,1)==b'\x01'
            c.sendall(b'\0'*4); exact(c,1)
            c.sendall(struct.pack('>HH',1,1)+b'\0'*16+struct.pack('>I',0))
            pixel_format=exact(c,20); count=struct.unpack('>H',exact(c,4)[2:])[0]; encodings=struct.unpack('>'+'i'*count,exact(c,count*4)); exact(c,10)
            if mode.startswith('zrle'): assert encodings[0]==16 and 0 in encodings
            if mode in ('rgb565','rgb332'):
                expected_format=bytes([16,16,0,1,0,31,0,63,0,31,11,5,0,0,0,0]) if mode=='rgb565' else bytes([32,8,0,1,0,7,0,7,0,3,5,2,0,0,0,0])
                assert pixel_format==b'\0'*4+expected_format
            rectangle=b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)
            if attempt==0:
                if mode=='remote-payload-close':
                    c.sendall(rectangle+b'\0\0')
                else:
                    c.sendall(rectangle+b'\0\0\xff\0')
                    exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline, 'client did not reach pre-close state'
                    time.sleep(.01)
                if mode=='remote-reset':
                    c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))
                else:
                    c.shutdown(socket.SHUT_WR)
            else:
                c.sendall(rectangle+b'\0\0\xff\0')
                exact(c,10)
                assert exact(c,8)==b'\x04\x01\0\0\0\0\0B', 'stale input reached retry session'
                c.sendall(b'\x03\0\0\0'+struct.pack('>I',8)+b'retry-ok')
                while c.recv(1024): pass

def serve(listener, mode, marker):
    stage = 'setup'
    try:
        if mode in ('remote-close','remote-reset','remote-payload-close'):
            serve_disconnect(listener,mode,marker)
            return
        c,_=listener.accept()
        with c:
            c.settimeout(7)
            if mode=='deinit':
                assert c.recv(1)==b''
                return
            c.sendall(b'RFB 003.005\n' if mode=='vnc33' else b'RFB 003.008\n')
            assert exact(c,12)==(b'RFB 003.003\n' if mode=='vnc33' else b'RFB 003.008\n')
            if mode=='vnc33':
                challenge=bytes(range(16))
                c.sendall(struct.pack('>I',2)+challenge)
                key=bytes(int(f'{byte:08b}'[::-1],2) for byte in b'secret\0\0')
                expected=subprocess.run(['/usr/bin/openssl','enc','-des-ecb','-nopad','-K',key.hex()],input=challenge,capture_output=True,check=True).stdout
                assert exact(c,16)==expected
            elif mode in ('apple','apple-failure'):
                c.sendall(b'\x01\x1e'); assert exact(c,1)==b'\x1e'
                # RFC 2409 1024-bit MODP group, deterministic server exponent.
                prime=int('FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF',16)
                c.sendall(struct.pack('>HH',2,128)+prime.to_bytes(128,'big')+pow(2,7,prime).to_bytes(128,'big'))
                response=exact(c,256)
                shared=pow(int.from_bytes(response[128:],'big'),7,prime).to_bytes(128,'big')
                import hashlib
                credentials=subprocess.run(['/usr/bin/openssl','enc','-d','-aes-128-ecb','-nopad','-K',hashlib.md5(shared).hexdigest()],input=response[:128],capture_output=True,check=True).stdout
                assert credentials[:6]==b'alice\0' and credentials[64:71]==b'secret\0'
            else:
                c.sendall(b'\x01\x01'); exact(c,1)
            if mode=='apple-failure':
                c.sendall(struct.pack('>I',1))
                assert c.recv(1)==b'' # Apple sends no following reason length or body.
                return
            c.sendall(b'\0'*4); exact(c,1)
            dimensions=(1024,1024) if mode=='slow-raw' else (1,1)
            c.sendall(struct.pack('>HH',*dimensions)+b'\0'*16+struct.pack('>I',0))
            pixel_format=exact(c,20); count=struct.unpack('>H',exact(c,4)[2:])[0]; encodings=struct.unpack('>'+'i'*count,exact(c,count*4)); exact(c,10)
            if mode.startswith('zrle'): assert encodings[0]==16 and 0 in encodings
            if mode in ('rgb565','rgb332'):
                expected_format=bytes([16,16,0,1,0,31,0,63,0,31,11,5,0,0,0,0]) if mode=='rgb565' else bytes([32,8,0,1,0,7,0,7,0,3,5,2,0,0,0,0])
                assert pixel_format==b'\0'*4+expected_format
            stage = 'activity'
            if mode in ('rgb565','rgb332'):
                value=bytes([0x65,0x8c]) if mode=='rgb565' else bytes([0x91,0,0])
                compressor=zlib.compressobj()
                payload=compressor.compress(b'\x01'+value)+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                # A server may still select Raw after ZRLE; its byte count must
                # follow the same negotiated format rather than RGBA storage.
                value=b'\xff'*(pixel_format[4]//8)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+value)
                exact(c,10)
            elif mode=='zrle':
                compressor=zlib.compressobj()
                payload=compressor.compress(b'\x01\x12\x34\x56')+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                payload=compressor.compress(b'\x01\x98\x76\x54')+compressor.flush(zlib.Z_SYNC_FLUSH)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,16)+struct.pack('>I',len(payload))+payload)
                exact(c,10)
            elif mode in ('zrle-bounds','zrle-length','zrle-bomb','zrle-palette','zrle-timeout'):
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1 if mode=='zrle-bounds' else 0,0,1,1,16))
                if mode=='zrle-length': c.sendall(struct.pack('>I',100_000_000))
                elif mode=='zrle-timeout':
                    c.settimeout(25)
                    c.sendall(struct.pack('>I',64)+b'\x78')
                elif mode!='zrle-bounds':
                    compressor=zlib.compressobj()
                    data=b'\0'*1_000_000 if mode=='zrle-bomb' else b'\x82'+b'\0'*6+b'\x02'
                    payload=compressor.compress(data)+compressor.flush(zlib.Z_SYNC_FLUSH)
                    c.sendall(struct.pack('>I',len(payload))+payload)
            elif mode=='slow-raw':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1024,1024,0))
                # A valid payload may take longer than the small-message deadline.
                time.sleep(21)
                c.sendall(b'\0\0\xff\0'*(1024*1024))
                exact(c,10)
            elif mode in ('first-frame','terminal-error'):
                c.sendall(b'\0\0\0\0') # empty update must not count as first frame
                exact(c,10)
                deadline=time.monotonic()+5
                while not marker.exists():
                    assert time.monotonic()<deadline, f'{mode}: no client readiness signal'
                    time.sleep(.01)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
            elif mode=='resize-release':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                assert exact(c,8)==b'\x04\x01\0\0\0\0\xff\xe3'
                assert exact(c,6)==b'\x05\x01\0\0\0\0'
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,2,2,-223))
                assert exact(c,10)==b'\x03\0\0\0\0\0\0\x02\0\x02'
                assert exact(c,8)==b'\x04\0\0\0\0\0\xff\xe3'
                assert exact(c,6)==b'\x05\0\0\0\0\0'
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,2,2,0)+b'\0\0\xff\0'*4)
                exact(c,10)
            elif mode=='resize-timeout':
                for _ in range(220):
                    c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,-223))
                    assert exact(c,10)==b'\x03\0\0\0\0\0\0\x01\0\x01'
                    time.sleep(.1)
            elif mode=='first-frame-timeout':
                for _ in range(430):
                    # None of these messages contains a pixel or earns more time.
                    c.sendall(b'\x02'+b'\0\0\0\0')
                    exact(c,10)
                    c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,0,0,0))
                    exact(c,10)
                    time.sleep(.05)
            elif mode in ('clipboard','apple','apple-failure','vnc33'):
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                if mode=='clipboard':
                    c.sendall(b'\x03\0\0\0'+struct.pack('>I',4)+b'caf\xe9')
                    assert exact(c,8)==b'\x06\0\0\0'+struct.pack('>I',4)
                    assert exact(c,4)==b'caf\xe9'
                    for _ in range(50):
                        assert exact(c,8)==b'\x04\x01\0\0\0\0\0A'
                        assert exact(c,8)==b'\x04\0\0\0\0\0\0A'
                    c.sendall(b'\x03\0\0\0'+struct.pack('>I',14)+b'input-complete')
            elif mode=='malformed':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1,0,1,1,0))
            if mode not in ('first-frame-timeout','resize-timeout'):
                while c.recv(1024): pass
        if mode=='reconnect':
            c,_=listener.accept()
            with c:
                c.settimeout(7)
                assert c.recv(1)==b''
    except (EOFError, BrokenPipeError, ConnectionResetError) as error:
        if stage != 'activity' or mode not in ('terminal-error','first-frame-timeout','resize-timeout'):
            errors.append(AssertionError(f'{mode}: unexpected disconnect before all protocol assertions completed: {error}'))
    except Exception as error: errors.append(error)
for mode in ['rgb565','rgb332','zrle','zrle-bounds','zrle-length','zrle-bomb','zrle-palette','zrle-timeout','remote-close','remote-reset','remote-payload-close','slow-raw','first-frame','reconnect','malformed','clipboard','apple','apple-failure','vnc33','deinit','terminal-error','resize-release','first-frame-timeout','resize-timeout']:
    selected = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--case=')), None)
    if selected and mode != selected: continue
    if '--resize-only' in sys.argv and mode!='resize-timeout': continue
    if '--quick' in sys.argv and mode in ('zrle-timeout','slow-raw','first-frame-timeout','resize-timeout'): continue
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0)); listener.listen(); listener.settimeout(3)
        marker=binary.parent / f'{mode}-ready'
        thread=threading.Thread(target=serve,args=(listener,mode,marker),daemon=True); thread.start()
        subprocess.run([str(binary),str(listener.getsockname()[1]),mode,str(marker)],check=True,timeout=30)
        thread.join(timeout=3)
        assert not thread.is_alive(), f"{mode}: fake server did not finish protocol assertions"
        if errors: raise errors[0]
