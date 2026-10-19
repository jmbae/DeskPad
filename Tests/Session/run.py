#!/usr/bin/env python3
"""Standalone real TCP RFB regression suite; no simulator or test target needed."""
import pathlib, socket, struct, subprocess, sys, tempfile, threading, time
root = pathlib.Path(__file__).resolve().parents[2]
binary = pathlib.Path(tempfile.mkdtemp(prefix='deskpad-session-')) / 'session-tests'
subprocess.run(['swiftc', '-parse-as-library', str(root/'DeskPad/ConnectionStore.swift'), str(root/'DeskPad/VNCSession.swift'), str(root/'Tests/Session/Harness.swift'), '-o', str(binary)], check=True)
def exact(c,n):
    out=b''
    while len(out)<n:
        part=c.recv(n-len(out))
        if not part: raise EOFError()
        out+=part
    return out
errors=[]
def serve(listener, mode):
    try:
        c,_=listener.accept()
        with c:
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
            elif mode == 'apple':
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
            c.sendall(b'\0'*4); exact(c,1)
            c.sendall(struct.pack('>HH',1,1)+b'\0'*16+struct.pack('>I',0))
            exact(c,20); count=struct.unpack('>H',exact(c,4)[2:])[0]; exact(c,count*4); exact(c,10)
            if mode in ('first-frame','terminal-error'):
                c.sendall(b'\0\0\0\0') # empty update must not count as first frame
                exact(c,10); time.sleep(.55)
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
            elif mode=='first-frame-timeout':
                for _ in range(430):
                    c.sendall(b'\x02')
                    time.sleep(.05)
            elif mode in ('clipboard','apple','vnc33'):
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,1,1,0)+b'\0\0\xff\0')
                exact(c,10)
                if mode=='clipboard':
                    c.sendall(b'\x03\0\0\0'+struct.pack('>I',4)+b'caf\xe9')
                    assert exact(c,8)==b'\x06\0\0\0'+struct.pack('>I',4)
                    assert exact(c,4)==b'caf\xe9'
                    for _ in range(50):
                        assert exact(c,8)==b'\x04\x01\0\0\0\0\0A'
                        assert exact(c,8)==b'\x04\0\0\0\0\0\0A'
            elif mode=='malformed':
                c.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',1,0,1,1,0))
            time.sleep(.35)
        if mode=='reconnect':
            c,_=listener.accept()
            with c: time.sleep(1)
    except (EOFError, BrokenPipeError, ConnectionResetError): pass
    except Exception as error: errors.append(error)
for mode in ['first-frame','reconnect','malformed','clipboard','apple','vnc33','deinit','terminal-error','first-frame-timeout']:
    if '--quick' in sys.argv and mode=='first-frame-timeout': continue
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0)); listener.listen()
        thread=threading.Thread(target=serve,args=(listener,mode),daemon=True); thread.start()
        subprocess.run([str(binary),str(listener.getsockname()[1]),mode],check=True,timeout=30)
        thread.join(timeout=3)
        if errors: raise errors[0]
