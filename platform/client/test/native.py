"""Actual libcurl bridge: ASan/UBSan, peer verification, bounds, argv/files, deadline."""
import http.server
import os
from pathlib import Path
import shlex
import ssl
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[2]

def run(args, **kw):
    return subprocess.run(args,check=True,timeout=kw.pop('timeout',45),**kw)


def main():
    records=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_POST(self):
            records.append((self.path,self.headers.get('Authorization'),self.rfile.read(int(self.headers.get('Content-Length','0')))))
            if self.path=='/slow': time.sleep(35)
            body=b'x'*65537 if self.path=='/large' else b'{}\0suffix' if self.path=='/nul' else b'{}'
            if self.path.startswith('/invalid-utf8-'):
                body=[b'\x80',b'\xc0\xaf',b'\xe0\x80\xaf',b'\xed\xa0\x80',b'\xf4\x90\x80\x80',b'\xe2\x82'][int(self.path.rsplit('-',1)[1])]
            self.send_response(307 if self.path=='/redirect' else 200)
            if self.path=='/redirect': self.send_header('Location',base+'/stolen')
            self.send_header('Content-Length',str(len(body)));self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
    with tempfile.TemporaryDirectory(prefix='flux-native-http-') as directory:
        d=Path(directory); scratch=d/'scratch';scratch.mkdir()
        flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','libcurl'],text=True))
        run([os.environ.get('CC','cc'),'-g','-O1','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
             '-fno-omit-frame-pointer',str(ROOT/'client/test/probe.c'),'-o',str(d/'probe'),*flags,'-pthread'])
        run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=ignored.invalid',
             '-addext','subjectAltName=DNS:localhost','-addext','extendedKeyUsage=serverAuth',
             '-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        plain=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        secure=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(d/'cert.pem',d/'key.pem')
        secure.socket=context.wrap_socket(secure.socket,server_side=True)
        for s in [plain,secure]: threading.Thread(target=s.serve_forever,daemon=True).start()
        base=f'http://127.0.0.1:{plain.server_port}'
        tls=f'https://localhost:{secure.server_port}'
        def probe(url,code=0,status=200,ca=''):
            env=dict(os.environ,TMPDIR=str(scratch),TMP=str(scratch),TEMP=str(scratch),
                     ASAN_OPTIONS='detect_leaks=0:abort_on_error=1',UBSAN_OPTIONS='halt_on_error=1',
                     http_proxy='http://127.0.0.1:1',https_proxy='http://127.0.0.1:1',ALL_PROXY='http://127.0.0.1:1')
            proc=subprocess.Popen([str(d/'probe'),url,str(ca),str(code),str(status)],env=env)
            try:
                deadline=time.monotonic()+40
                while proc.poll() is None:
                    assert time.monotonic()<deadline,'native joined request deadline'
                    argv=subprocess.run(['ps','-axo','args='],stdout=subprocess.PIPE,text=True,check=True).stdout
                    assert 'native-test-token-marker' not in argv and 'native-test-password-marker' not in argv
                    assert list(scratch.iterdir())==[], 'request must not create body/config files'
                    time.sleep(.025)
                assert proc.returncode==0
            finally:
                if proc.poll() is None:proc.kill();proc.wait()
        try:
            probe(base+'/ok')
            assert records[-1]==('/ok','Bearer native-test-token-marker',b'native-test-password-marker')
            probe(base+'/redirect',status=307)
            assert not any(r[0]=='/stolen' for r in records)
            probe(base+'/large',-1,0);probe(base+'/nul',-1,0)
            for i in range(6): probe(base+'/invalid-utf8-'+str(i),-1,0)
            before=len(records)
            for url in ['http://example.com/rpc','file:///etc/passwd',base+'/ok?secret=value',base+'/ok#fragment',base.replace('://','://user:password@')+'/ok']:
                probe(url,-2,0)
            probe(base+'/ok',-2,0,d/'cert.pem')
            assert len(records)==before
            probe(tls+'/ok',-1,0)
            probe(tls.replace('localhost','127.0.0.1')+'/ok',-1,0,d/'cert.pem')
            assert len(records)==before,'untrusted and wrong-host TLS must not send HTTP credentials'
            probe(tls+'/ok',ca=d/'cert.pem')
            assert records[-1][1]=='Bearer native-test-token-marker'
            print('PASS native ASan/UBSan: in-memory credentials, no argv/body files/proxy/redirect leaks, response caps, rejected URL credentials/plaintext, trusted and rejected TLS peers')
            began=time.monotonic();probe(base+'/slow',-3,0)
            assert 28<=time.monotonic()-began<34
            print('PASS real 30-second native request deadline; no abandoned request worker')
        finally:
            for s in [plain,secure]:s.shutdown();s.server_close()

if __name__=='__main__':main()
