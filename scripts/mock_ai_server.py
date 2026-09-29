#!/usr/bin/env python3
"""Local mock of the Anthropic Messages streaming API for Tandem end-to-end tests.

Streams a Markdown answer that describes the request (image count, prompt) and
records each request body to /tmp/tandem-qa/last_request.json for inspection.
Usage: python3 scripts/mock_ai_server.py [port]
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
os.makedirs("/tmp/tandem-qa", exist_ok=True)


def sse(handler, event, payload):
    handler.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())
    handler.wfile.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + fmt % args + "\n")

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            body = json.dumps({"data": [{"id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z"}], "has_more": False}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        request = json.loads(raw)
        images = 0
        prompt = ""
        for message in request.get("messages", []):
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if block.get("type") == "image":
                        images += 1
                    if block.get("type") == "text" and message["role"] == "user":
                        prompt = block.get("text", "")
        summary = {
            "path": self.path,
            "model": request.get("model"),
            "headers": {k: v for k, v in self.headers.items() if k.lower() in ("anthropic-version", "anthropic-beta", "x-api-key")},
            "keys": sorted(request.keys()),
            "thinking": request.get("thinking"),
            "output_config": request.get("output_config"),
            "fallbacks": request.get("fallbacks"),
            "cache_control": request.get("cache_control"),
            "message_count": len(request.get("messages", [])),
            "image_count": images,
            "last_prompt": prompt,
            "image_bytes": [len(b["source"]["data"]) for m in request.get("messages", []) if isinstance(m.get("content"), list) for b in m["content"] if b.get("type") == "image"],
        }
        with open("/tmp/tandem-qa/last_request.json", "w") as f:
            json.dump(summary, f, indent=2)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        sse(self, "message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "model": request.get("model"), "content": [], "usage": {"input_tokens": 1200 + images * 1600, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
        sse(self, "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}})
        for piece in ["Looking at the screenshot", ", the test pattern shows five color bars", " and a millisecond clock."]:
            sse(self, "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": piece}})
            time.sleep(0.05)
        sse(self, "content_block_stop", {"type": "content_block_stop", "index": 0})
        sse(self, "content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})
        answer = (
            f"## What I see\n\nYou sent **{images} screenshot{'s' if images != 1 else ''}** with the prompt:\n\n> {prompt or '(no text)'}\n\n"
            "- A **Tandem test pattern** with five color bars\n- A live `HH:mm:ss.SSS` clock\n- A moving white marker\n\n"
            "```swift\nlet latency = displayTime - captureTime\n```\n\n| Check | Result |\n|---|---|\n| Image received | ✅ |\n| Streaming | ✅ |\n"
        )
        words = answer.split(" ")
        for index, word in enumerate(words):
            sse(self, "content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": word + (" " if index < len(words) - 1 else "")}})
            time.sleep(0.015)
        sse(self, "content_block_stop", {"type": "content_block_stop", "index": 1})
        sse(self, "message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_details": None}, "usage": {"output_tokens": len(words)}})
        sse(self, "message_stop", {"type": "message_stop"})


if __name__ == "__main__":
    print(f"Mock Anthropic API on http://127.0.0.1:{PORT}/v1/")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
