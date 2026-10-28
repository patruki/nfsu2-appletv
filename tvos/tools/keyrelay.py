#!/usr/bin/env python3
"""Steer the game on the Apple TV with this Mac's keyboard (development aid).

    tvos/tools/keyrelay.py <Apple TV IP address>

Open http://localhost:8765 in a browser and keep that tab in front: its key presses and releases
go over UDP to the app (tvos/host/host_remote.c), which feeds them to the game as DirectInput keys.
The Apple TV's address is under Settings > Network.  Needs nothing but Python 3."""
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT_TV = 9777
PORT_WEB = 8765

PAGE = r"""<!doctype html><meta charset=utf-8><title>NFSU2 keys</title>
<style>body{font:16px system-ui;background:#111;color:#eee;margin:40px;max-width:640px}
#s{font-size:28px;margin:20px 0}.on{color:#6f6}.off{color:#f66}kbd{background:#333;padding:2px 8px;border-radius:4px}</style>
<h1>NFSU2 keys</h1><div id=s class=off>click here, then press keys</div>
<p>Keys go to the Apple TV <b>%(tv)s</b>. Arrows steer, <kbd>Enter</kbd> selects, <kbd>Esc</kbd> is back/pause,
<kbd>Space</kbd> handbrake, <kbd>Shift</kbd>/<kbd>Ctrl</kbd> gears and nitrous (the game's own default keys).</p>
<p id=l></p>
<script>
const D={ArrowUp:0xC8,ArrowDown:0xD0,ArrowLeft:0xCB,ArrowRight:0xCD,Enter:0x1C,NumpadEnter:0x9C,Escape:0x01,Space:0x39,
Backspace:0x0E,Tab:0x0F,ShiftLeft:0x2A,ShiftRight:0x36,ControlLeft:0x1D,ControlRight:0x9D,AltLeft:0x38,AltRight:0xB8,
Home:0xC7,End:0xCF,PageUp:0xC9,PageDown:0xD1,Insert:0xD2,Delete:0xD3,Minus:0x0C,Equal:0x0D,Comma:0x33,Period:0x34,
Slash:0x35,Semicolon:0x27,Quote:0x28,BracketLeft:0x1A,BracketRight:0x1B,Backslash:0x2B,Backquote:0x29};
"QWERTYUIOP".split('').forEach((c,i)=>D['Key'+c]=0x10+i);"ASDFGHJKL".split('').forEach((c,i)=>D['Key'+c]=0x1E+i);
"ZXCVBNM".split('').forEach((c,i)=>D['Key'+c]=0x2C+i);
for(let i=1;i<=9;i++)D['Digit'+i]=1+i;D.Digit0=0x0B;
for(let i=1;i<=10;i++)D['F'+i]=0x3A+i;D.F11=0x57;D.F12=0x58;
const held=new Set(),s=document.getElementById('s'),l=document.getElementById('l');
function send(t){fetch('/k?p='+encodeURIComponent(t),{keepalive:true}).catch(()=>{s.textContent='relay not reachable';s.className='off'});}
function show(){s.textContent=held.size?'sending: '+[...held].join(' '):'ready: press keys';s.className='on';}
const CH={Enter:13,NumpadEnter:13,Backspace:8,Tab:9};
const hx=n=>n.toString(16);
addEventListener('keydown',e=>{const d=D[e.code];if(d===undefined)return;e.preventDefault();
 const vk=e.keyCode||0, ch=(e.key.length===1&&!e.ctrlKey&&!e.metaKey)?e.key.codePointAt(0):CH[e.code];
 if(!e.repeat&&!held.has(e.code)){held.add(e.code);send('D '+hx(d)+' '+hx(vk));show();}
 if(ch)send('C '+hx(ch)+' '+hx(d));});          /* typed text, also repeated while the key is held */
addEventListener('keyup',e=>{const d=D[e.code];if(d===undefined)return;e.preventDefault();
 held.delete(e.code);send('U '+hx(d)+' '+hx(e.keyCode||0));show();});
addEventListener('blur',()=>{held.clear();send('R');s.textContent='click here, then press keys';s.className='off';});
</script>"""


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    tv = sys.argv[1]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/k":
                p = parse_qs(u.query).get("p", [""])[0]
                if re.fullmatch(r"[DUC]( [0-9a-f]{1,6}){1,2}|R", p):
                    sock.sendto(p.encode(), (tv, PORT_TV))
                self.send_response(204)
                self.end_headers()
                return
            body = (PAGE % {"tv": tv}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    print("open http://localhost:%d and keep that tab in front (Ctrl+C to stop)" % PORT_WEB)
    HTTPServer(("127.0.0.1", PORT_WEB), H).serve_forever()


if __name__ == "__main__":
    main()
