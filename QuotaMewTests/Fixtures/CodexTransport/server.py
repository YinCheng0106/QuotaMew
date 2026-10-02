"""Synthetic, manually gated app-server. No credentials, network, or live values."""
import json
import os
import selectors
import sys

control = os.open(sys.argv[1], os.O_RDWR)
events = os.open(sys.argv[2], os.O_RDWR)
selector = selectors.DefaultSelector()
selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
selector.register(control, selectors.EVENT_READ)
buffers = {sys.stdin.fileno(): b"", control: b""}
active = None
initialized = 0

while True:
    for key, _ in selector.select():
        fd = key.fd
        data = os.read(fd, 4096)
        if not data:
            sys.exit(0)
        buffers[fd] += data
        while b"\n" in buffers[fd]:
            line, buffers[fd] = buffers[fd].split(b"\n", 1)
            message = json.loads(line)
            if fd == control:
                action = message["action"]
                if action == "eof":
                    sys.exit(0)
                if action == "oversized":
                    print("x" * 4097, flush=True)
                elif action == "framing":
                    print("not-json", flush=True)
                elif action == "lines":
                    for response in message["lines"]:
                        print(response, flush=True)
                elif action == "error":
                    print(json.dumps({"id": active["id"], "error": {
                        "code": -32601, "message": "synthetic-private-sentinel"}}), flush=True)
                else:
                    result = message.get("result", {"rateLimits": {"primary": {"usedPercent": 25}}})
                    print(json.dumps({"id": active["id"], "result": result}), flush=True)
                active = None
            elif message["method"] == "initialize":
                initialized += 1
                assert message["id"] == 1
                assert active is None
            elif message["method"] == "initialized":
                assert initialized == 1
            else:
                assert "params" not in message
                event = dict(message, pid=os.getpid(), overlap=active is not None, initialized=initialized)
                os.write(events, (json.dumps(event) + "\n").encode())
                active = message
