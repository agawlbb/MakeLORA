"""SQL-free API rejection with a deliberately unavailable local database."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

class DatabaseLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="makelora-db-lifecycle-")
        root = Path(cls.temp.name)
        app = root / "application" / "server"; app.mkdir(parents=True)
        # Test the actual entrypoint/bootstrap with only its unused autoloader stubbed.
        shutil.copytree(ROOT / "src", app / "src")
        (app / "public").mkdir()
        shutil.copyfile(ROOT / "public/api.php", app / "public/api.php")
        (app / "vendor").mkdir()
        (app / "vendor/autoload.php").write_text("<?php\n")
        private = root / "private"; private.mkdir(mode=0o700)
        settings = root / "settings.php"
        settings.write_text("<?php return [\x27environment\x27=>\x27prototype\x27,\x27open_management\x27=>true,\x27dsn\x27=>\x27mysql:host=127.0.0.1;port=1;dbname=makelora_test\x27,\x27user\x27=>\x27fixture\x27,\x27password\x27=>\x27fixture\x27,\x27private_session_directory\x27=>" + json.dumps(str(private)) + "];\n")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        cls.url = f"http://127.0.0.1:{port}/?action="
        env = dict(os.environ, MAKELORA_CONFIG=str(settings))
        cls.process = subprocess.Popen(["php", "-S", f"127.0.0.1:{port}", str(app / "public/api.php")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1): break
            except OSError: time.sleep(0.03)
        else:
            cls.process.terminate(); cls.process.wait(); cls.temp.cleanup()
            raise RuntimeError("PHP fixture failed to start")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate(); cls.process.wait(timeout=5); cls.temp.cleanup()

    def get(self, action, credential=None):
        headers = {"Authorization": "Bearer " + credential} if credential else {}
        try: return urllib.request.urlopen(urllib.request.Request(self.url + action, headers=headers), timeout=5)
        except urllib.error.HTTPError as error: return error

    def test_missing_or_malformed_authentication_never_needs_database(self):
        for credential in [None, "invalid"]:
            with self.get("models", credential) as reply:
                self.assertEqual(reply.status, 401)

    def test_invalid_signed_media_never_needs_database(self):
        with self.get("generation_video_media") as reply:
            self.assertEqual(reply.status, 403)
        with self.get("weights") as reply:
            self.assertEqual(reply.status, 403)

    def test_sql_failure_is_reported_only_when_authentication_needs_sql(self):
        with self.get("models", "a" * 64) as reply:
            self.assertEqual(reply.status, 503)
            body = json.load(reply)
            self.assertIn("temporarily unavailable", body["error"])
            self.assertNotIn("fixture", body["error"])
            self.assertNotIn("127.0.0.1", body["error"])
