"""Independent synthetic SRTP fixtures: Python cryptography (OpenSSL), RFC 3711/6188.
No Apple code/captures or real session keys are used.
"""
import json, struct, hmac, hashlib, pathlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
master=bytes(range(32)); salt=bytes(range(32,46))
def aes(key,iv,data):
    c=Cipher(algorithms.AES(key),modes.CTR(iv)).encryptor()
    return c.update(data)+c.finalize()
def derive(label,length):
    iv=bytearray(salt+b'\0\0'); iv[7]^=label
    return aes(master,bytes(iv),bytes(length))
key,auth,s=derive(0,32),derive(1,20),derive(2,14)
def packet(seq,roc=0,ssrc=0x12345678, extension=False):
    header=struct.pack('>BBHII',0x90 if extension else 0x80,100,seq,90000,ssrc)
    if extension: header+=bytes.fromhex('bede000101020304')
    payload=b'authenticated media payload\x00\x01'
    index=(roc<<16)|seq
    iv=(int.from_bytes(s,'big')<<16)^(ssrc<<64)^(index<<16)
    encrypted=header+aes(key,iv.to_bytes(16,'big'),payload)
    return (encrypted+hmac.new(auth,encrypted+struct.pack('>I',roc),hashlib.sha1).digest()[:10]).hex()
fixtures={'blob':(master+salt).hex(),'plain':b'authenticated media payload\x00\x01'.hex(), 'packets': [packet(65534),packet(0,1),packet(65535),packet(1,1),packet(100,1),packet(2,1),packet(9,0,123,True)]}
pathlib.Path(__file__).with_name('vectors.json').write_text(json.dumps(fixtures,indent=2)+'\n')
rtcp_key,rtcp_auth,rtcp_salt=derive(3,32),derive(4,20),derive(5,14)
def control(index,encrypted=True):
    header=bytes.fromhex('80c80006')+struct.pack('>I',0x12345678)
    payload=struct.pack('>IIIII',100,0,90000,1,28)
    iv=(int.from_bytes(rtcp_salt,'big')<<16)^(0x12345678<<64)^(index<<16)
    body=header+(aes(rtcp_key,iv.to_bytes(16,'big'),payload) if encrypted else payload)
    body+=struct.pack('>I',index|(0x80000000 if encrypted else 0))
    return (body+hmac.new(rtcp_auth,body,hashlib.sha1).digest()[:10]).hex()
fixtures['rtcp']=[control(10),control(12),control(11,False),control(80),control(13)]
pathlib.Path(__file__).with_name('vectors.json').write_text(json.dumps(fixtures,indent=2)+'\n')
