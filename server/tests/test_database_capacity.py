"""Real cross-process PDO capacity with isolated in-memory SQLite databases."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'src/database-connection.php'
CODE = r'''
require $argv[1];
$config=['dsn'=>'sqlite::memory:','user'=>'','password'=>'','private_session_directory'=>$argv[2]];
$db=null;
try { databaseConnection(); }
catch (PDOException $e) { exit(75); }
echo "connected\n"; fflush(STDOUT);
fgets(STDIN);
releaseDatabaseConnection();
'''


class DatabaseCapacityTests(unittest.TestCase):
    def test_eight_processes_share_capacity_and_recover_after_exit(self):
        with tempfile.TemporaryDirectory(prefix='makelora-capacity-') as private:
            processes = []
            def start():
                process = subprocess.Popen(
                    ['php', '-r', CODE, str(SOURCE), private],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True)
                processes.append(process)
                return process
            try:
                for _ in range(8):
                    self.assertEqual(start().stdout.readline(), 'connected\n')
                self.assertEqual(start().wait(timeout=5), 75)
                # Kernel releases a permit even on an ungraceful worker exit.
                processes[0].kill()
                processes[0].wait(timeout=5)
                self.assertEqual(start().stdout.readline(), 'connected\n')
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                    process.stdin.close()
                    process.stdout.close()
