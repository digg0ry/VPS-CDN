#!/usr/bin/env python3
"""Local-only transport smoke test; never changes deployed node configurations."""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def recv_exact(sock, length):
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("SOCKS connection closed")
        data += chunk
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xray", required=True)
    parser.add_argument("--exports", required=True)
    args = parser.parse_args()
    exports = pathlib.Path(args.exports)
    server = json.loads((exports / "server-inbound.json").read_text())
    client = json.loads((exports / "client-template.json").read_text())
    inbound = server["inbounds"][0]
    user_id = str(uuid.uuid4())
    inbound["port"] = free_port()
    inbound["settings"]["clients"] = [{"id": user_id}]
    # Private routing is relaxed ONLY in this temporary loopback fixture.
    server["routing"] = {"rules": []}
    server["log"] = {"loglevel": "debug"}
    socks_port = free_port()
    client["inbounds"] = [{"listen": "127.0.0.1", "port": socks_port,
                           "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}]
    outbound = client["outbounds"][0]
    outbound["settings"]["vnext"][0].update(address="127.0.0.1", port=inbound["port"])
    outbound["settings"]["vnext"][0]["users"][0]["id"] = user_id
    outbound["streamSettings"]["security"] = "none"
    outbound["streamSettings"].pop("tlsSettings", None)
    outbound["streamSettings"]["xhttpSettings"]["host"] = "localhost"
    client["log"] = {"loglevel": "debug"}
    payload = bytes(range(256)) * 512

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            data = self.rfile.read(int(self.headers["Content-Length"]))
            digest = hashlib.sha256(data).hexdigest().encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(digest)))
            self.end_headers()
            self.wfile.write(digest)

        def log_message(self, *unused):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    # Only this fixture's local HTTP listener may be reached; no external traffic.
    for direct in server["outbounds"]:
        if direct.get("protocol") == "freedom":
            direct["settings"] = {"finalRules": [
                {"action": "allow", "network": "tcp", "ip": ["127.0.0.1"],
                 "port": str(httpd.server_address[1])},
                {"action": "block", "ip": ["0.0.0.0/0", "::/0"]},
            ]}
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    processes = []
    try:
        with tempfile.TemporaryDirectory(prefix="xhttp-smoke-") as tmp:
            with open(pathlib.Path(tmp) / "runtime.log", "w+") as logs:
                for name, config in (("server", server), ("client", client)):
                    path = pathlib.Path(tmp) / (name + ".json")
                    path.write_text(json.dumps(config))
                    check = subprocess.run([args.xray, "run", "-test", "-c", str(path)],
                                           stdout=logs, stderr=logs)
                    if check.returncode:
                        raise RuntimeError(name + " config rejected")
                    processes.append(subprocess.Popen([args.xray, "run", "-c", str(path)],
                                                      stdout=logs, stderr=logs))
                deadline = time.monotonic() + 10
                while True:
                    if any(p.poll() is not None for p in processes):
                        raise RuntimeError("Xray process exited")
                    try:
                        with socket.create_connection(("127.0.0.1", socks_port), timeout=1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise RuntimeError("Xray startup timeout")
                        time.sleep(0.1)

                def request(method):
                    with socket.create_connection(("127.0.0.1", socks_port), timeout=30) as sock:
                        sock.sendall(b"\x05\x01\x00")
                        assert recv_exact(sock, 2) == b"\x05\x00"
                        port = httpd.server_address[1]
                        sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + port.to_bytes(2, "big"))
                        reply = recv_exact(sock, 4)
                        assert reply[0:2] == b"\x05\x00"
                        if reply[3] == 1:
                            recv_exact(sock, 6)
                        elif reply[3] == 4:
                            recv_exact(sock, 18)
                        else:
                            recv_exact(sock, recv_exact(sock, 1)[0] + 2)
                        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                        conn.sock = sock
                        conn.request(method, "/smoke", body=payload if method == "POST" else None)
                        response = conn.getresponse()
                        body = response.read()
                        assert response.status == 200
                        expected = payload if method == "GET" else hashlib.sha256(payload).hexdigest().encode()
                        assert body == expected
                        conn.close()

                try:
                    request("GET")
                    request("POST")
                    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                        list(pool.map(request, ["GET", "POST", "GET", "POST"]))
                except Exception:
                    logs.flush()
                    logs.seek(0)
                    print(logs.read()[-16000:])
                    raise
                print("PASS: Xray config parse, local VLESS/XHTTP GET+header, "
                      "128 KiB download/upload integrity, 4 concurrent requests")
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        httpd.shutdown()
        httpd.server_close()


if __name__ == "__main__":
    main()
