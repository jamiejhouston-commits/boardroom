import importlib.util
import io
import json
import threading
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("hermes_acp_client.py")
SPEC = importlib.util.spec_from_file_location("hermes_acp_client", SCRIPT_PATH)
acp = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(acp)


class FakeProcess:
    """Scripted `hermes acp` stand-in: a function maps each incoming JSON-RPC
    request to a list of reply lines (notifications + response)."""

    def __init__(self, responder):
        self.responder = responder
        self._read_r, self._read_w = io.StringIO(), None
        self._out_lines = []
        self._out_available = threading.Event()
        self._lock = threading.Lock()
        self._closed = False
        self.stdin = self
        self.stdout = self

    # stdin interface
    def write(self, data: str) -> int:
        msg = json.loads(data)
        with self._lock:
            for line in self.responder(msg):
                self._out_lines.append(line)
            self._out_available.set()
        return len(data)

    def flush(self) -> None:
        pass

    # stdout interface
    def readline(self) -> str:
        while True:
            with self._lock:
                if self._out_lines:
                    return self._out_lines.pop(0)
                if self._closed:
                    return ""
                self._out_available.clear()
            if not self._out_available.wait(timeout=2):
                return ""

    def poll(self):
        return 1 if self._closed else None

    def kill(self):
        with self._lock:
            self._closed = True
            self._out_available.set()

    terminate = kill


def jline(payload) -> str:
    return json.dumps(payload) + "\n"


def standard_responder(msg):
    method, rid = msg.get("method"), msg.get("id")
    if method == "initialize":
        return [jline({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1}})]
    if method == "session/new":
        return [jline({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "sess-1"}})]
    if method == "session/prompt":
        sid = msg["params"]["sessionId"]
        return [
            jline({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk",
                                             "content": {"type": "text", "text": "Hello "}}}}),
            jline({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk",
                                             "content": {"type": "text", "text": "there."}}}}),
            jline({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}),
        ]
    return []


class AcpClientTests(unittest.TestCase):
    def make_client(self, responder=standard_responder):
        fake = FakeProcess(responder)
        client = acp.AcpClient(spawn=lambda: fake)
        return client, fake

    def test_prompt_streams_chunks_and_completes(self):
        client, _ = self.make_client()
        chunks = list(client.prompt("mobile-key-1", "hi"))
        self.assertEqual(chunks, ["Hello ", "there."])

    def test_session_reused_for_same_key(self):
        session_news = []
        def responder(msg):
            if msg.get("method") == "session/new":
                session_news.append(1)
            return standard_responder(msg)
        client, _ = self.make_client(responder)
        list(client.prompt("key-A", "one"))
        list(client.prompt("key-A", "two"))
        self.assertEqual(len(session_news), 1)

    def test_distinct_keys_get_distinct_sessions(self):
        counter = {"n": 0}
        def responder(msg):
            if msg.get("method") == "session/new":
                counter["n"] += 1
                return [jline({"jsonrpc": "2.0", "id": msg["id"],
                               "result": {"sessionId": f"sess-{counter['n']}"}})]
            return standard_responder(msg)
        client, _ = self.make_client(responder)
        list(client.prompt("key-A", "one"))
        list(client.prompt("key-B", "two"))
        self.assertEqual(counter["n"], 2)

    def test_permission_request_auto_allowed(self):
        granted = {}
        def responder(msg):
            method, rid = msg.get("method"), msg.get("id")
            if method == "session/prompt":
                return [jline({"jsonrpc": "2.0", "id": 999,
                               "method": "session/request_permission",
                               "params": {"options": [
                                   {"optionId": "reject", "kind": "reject_once"},
                                   {"optionId": "allow", "kind": "allow_once"},
                               ]}})]
            if method is None and "result" in msg:   # client's reply to id 999
                granted["outcome"] = msg["result"]["outcome"]
                return [jline({"jsonrpc": "2.0", "id": granted["prompt_id"],
                               "result": {"stopReason": "end_turn"}})]
            return standard_responder(msg)
        def capture(msg):
            if msg.get("method") == "session/prompt":
                granted["prompt_id"] = msg["id"]
            return responder(msg)
        client, _ = self.make_client(capture)
        list(client.prompt("key-A", "do a tool thing"))
        self.assertEqual(granted["outcome"], {"outcome": "selected", "optionId": "allow"})

    def test_dead_process_raises_warm_unavailable(self):
        client, fake = self.make_client()
        list(client.prompt("key-A", "hi"))
        fake.kill()
        with self.assertRaises(acp.WarmUnavailable):
            list(client.prompt("key-A", "again"))


class AcpPoolTests(unittest.TestCase):
    def make_pool(self, size=2):
        fakes = []
        def spawn():
            fake = FakeProcess(standard_responder)
            fakes.append(fake)
            return fake
        return acp.AcpPool(size=size, spawn=spawn), fakes

    def test_affinity_is_stable_and_crc32_based(self):
        pool, _ = self.make_pool(size=3)
        import zlib
        for key in ("default:sess-1", "company:ceo-chat", "relay-prewarm-0"):
            expected = pool.clients[zlib.crc32(key.encode("utf-8")) % 3]
            self.assertIs(pool.client_for(key), expected)
            self.assertIs(pool.client_for(key), pool.client_for(key))

    def test_prompt_delegates_to_affine_client_only(self):
        pool, fakes = self.make_pool(size=2)
        self.assertEqual(list(pool.prompt("key-A", "hi")), ["Hello ", "there."])
        # Only the affine client spawned a process; its sibling stayed cold.
        self.assertEqual(len(fakes), 1)
        self.assertEqual(pool.warm_count(), 1)
        self.assertTrue(pool.warm())

    def test_warm_reports_any_and_warm_count_all(self):
        pool, _ = self.make_pool(size=2)
        self.assertFalse(pool.warm())
        self.assertEqual(pool.warm_count(), 0)
        for index, client in enumerate(pool.clients):
            list(client.prompt(f"relay-prewarm-{index}", "OK"))
        self.assertTrue(pool.warm())
        self.assertEqual(pool.warm_count(), 2)

    def test_dead_affine_client_raises_while_pool_still_warm(self):
        pool, fakes = self.make_pool(size=2)
        for index, client in enumerate(pool.clients):
            list(client.prompt(f"relay-prewarm-{index}", "OK"))
        key = "key-A"
        victim = pool.client_for(key)
        fakes[pool.clients.index(victim)].kill()
        self.assertTrue(pool.warm())          # the sibling is still up
        with self.assertRaises(acp.WarmUnavailable):
            list(pool.prompt(key, "again"))   # but this session's client is dead

    def test_pool_size_env_override_and_floor(self):
        import os
        original = os.environ.get("HERMES_WARM_POOL")
        try:
            os.environ["HERMES_WARM_POOL"] = "4"
            self.assertEqual(len(acp.AcpPool(spawn=lambda: FakeProcess(standard_responder)).clients), 4)
            os.environ["HERMES_WARM_POOL"] = "0"
            self.assertEqual(len(acp.AcpPool(spawn=lambda: FakeProcess(standard_responder)).clients), 1)
            os.environ["HERMES_WARM_POOL"] = "junk"
            self.assertEqual(len(acp.AcpPool(spawn=lambda: FakeProcess(standard_responder)).clients), 2)
        finally:
            if original is None:
                os.environ.pop("HERMES_WARM_POOL", None)
            else:
                os.environ["HERMES_WARM_POOL"] = original

    def test_shutdown_stops_every_client(self):
        pool, fakes = self.make_pool(size=2)
        for index, client in enumerate(pool.clients):
            list(client.prompt(f"relay-prewarm-{index}", "OK"))
        pool.shutdown()
        self.assertFalse(pool.warm())
        self.assertTrue(all(fake.poll() is not None for fake in fakes))


if __name__ == "__main__":
    unittest.main()
