#!/usr/bin/env python3
"""Synthetic metadata only. No captured session bytes or keys are persisted."""
import pathlib,plistlib,struct,subprocess,tempfile,zlib
root=pathlib.Path(__file__).resolve().parents[2]
def n(f,v):
 b=bytes([f<<3])
 while v>=128:b+=bytes([(v&127)|128]);v>>=7
 return b+bytes([v])
def blob(f,b):return var((f<<3)|2)+var(len(b))+b
def var(v):
 b=b''
 while v>=128:b+=bytes([(v&127)|128]);v>>=7
 return b+bytes([v])
def stream(video):
 desc=n(1,123456)+n(2,0)
 if video:desc+=blob(3,n(1,123))+n(4,1280)+n(5,720)
 else:desc+=n(4,5632)+n(5,1536)+n(6,1)
 proto=n(1,1)+n(2,1)+blob(5 if video else 3,desc)+blob(12,bytes.fromhex('08042004'))
 return plistlib.dumps({'avcMediaStreamNegotiatorMediaBlob':zlib.compress(proto)},fmt=plistlib.FMT_BINARY)
a,v=stream(False),stream(True)
p=struct.pack('>HHHIHHHI',18+len(a)+len(v),2,2,1,len(a),len(v),0,0)+a+v
fbu=b'\0\0\0\1'+struct.pack('>HHHHi',0,0,0,0,1010)+p
with tempfile.TemporaryDirectory(prefix='hp-answer-') as temp:
 path=pathlib.Path(temp);(path/'fixture').write_bytes(fbu)
 subprocess.run(['swiftc','-parse-as-library',str(root/'DeskPad/AppleHPMediaAnswer.swift'),str(root/'DeskPad/AppleHPControlParser.swift'),str(root/'Tests/HighPerformanceAnswer/Harness.swift'),'-o',str(path/'tests')],check=True)
 subprocess.run([str(path/'tests'),str(path/'fixture')],check=True)
