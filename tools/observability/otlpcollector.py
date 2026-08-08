#!/usr/bin/env python3
"""Minimal OTLP/HTTP trace collector.

mxcli's --trace console exporter drops start/end timestamps and parent span ids,
so it cannot give durations or a call tree. --trace-otlp needs somewhere to send
to; this is that somewhere. It accepts POST /v1/traces (protobuf, optionally
gzipped), decodes it, and appends one JSON object per span to a file.
"""
import gzip
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/spans.jsonl"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 4318

lock = threading.Lock()


def attrs_to_dict(attrs):
    out = {}
    for a in attrs:
        v = a.value
        if v.HasField("string_value"):
            out[a.key] = v.string_value
        elif v.HasField("int_value"):
            out[a.key] = v.int_value
        elif v.HasField("bool_value"):
            out[a.key] = v.bool_value
        elif v.HasField("double_value"):
            out[a.key] = v.double_value
        else:
            out[a.key] = str(v)
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # keep stdout for our own output

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)

        rows = []
        if self.path.endswith("/v1/traces"):
            req = trace_service_pb2.ExportTraceServiceRequest()
            req.ParseFromString(body)
            for rs in req.resource_spans:
                service = attrs_to_dict(rs.resource.attributes).get(
                    "service.name", "?"
                )
                for ss in rs.scope_spans:
                    for sp in ss.spans:
                        rows.append(
                            {
                                "service": service,
                                "scope": ss.scope.name,
                                "trace_id": sp.trace_id.hex(),
                                "span_id": sp.span_id.hex(),
                                "parent_id": sp.parent_span_id.hex(),
                                "name": sp.name,
                                "kind": sp.kind,
                                "start": sp.start_time_unix_nano,
                                "end": sp.end_time_unix_nano,
                                "ms": (sp.end_time_unix_nano - sp.start_time_unix_nano)
                                / 1e6,
                                "attrs": attrs_to_dict(sp.attributes),
                                "status": sp.status.code,
                            }
                        )
            if rows:
                with lock, open(OUT, "a") as f:
                    for r in rows:
                        f.write(json.dumps(r) + "\n")

        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    open(OUT, "w").close()
    print(f"OTLP collector on :{PORT} -> {OUT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
