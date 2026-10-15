"""Static regression for built-in macOS service lifecycle; real restart is tested separately."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ServiceTests(unittest.TestCase):
    def test_shell_syntax(self):
        for name in ['scripts/manage-service.sh', 'install.sh', 'uninstall.sh']:
            subprocess.run(['/bin/bash', '-n', str(ROOT/name)], check=True)
    def test_no_extra_runtime_dependency(self):
        service = (ROOT/'scripts/manage-service.sh').read_text()
        install = (ROOT/'install.sh').read_text()
        self.assertNotIn('python', service.lower())
        self.assertIn('scripts/manage-service.sh', install)
        self.assertNotIn('manage-service.py', install)
    def test_exit_and_version_guards(self):
        service = (ROOT/'scripts/manage-service.sh').read_text()
        self.assertIn('-insert KeepAlive -bool false', service)
        self.assertIn('-insert RunAtLoad -bool true', service)
        self.assertIn('runtime-health.json', service)
        self.assertIn('"$PIDS" == "$HEALTH_PID"', service)
        self.assertIn('-extract build raw', service)
        self.assertIn('${VERSION}', service)
        self.assertNotRegex(service, r'\$VERSION[^A-Za-z0-9_\s\"}]')
    def test_failure_propagated_and_uninstall_bootout(self):
        install = (ROOT/'install.sh').read_text()
        uninstall = (ROOT/'uninstall.sh').read_text()
        self.assertIn('if ! /bin/bash "$ROOT/scripts/manage-service.sh"', install)
        self.assertIn('DOUBAO_NOTIFIER_SKIP_LAUNCH', install)
        self.assertIn('launchctl bootout', uninstall)
        self.assertIn('com.local.doubao-reply-notifier.agent.plist', uninstall)

if __name__ == '__main__': unittest.main()
