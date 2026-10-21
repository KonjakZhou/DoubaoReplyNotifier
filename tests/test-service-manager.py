"""Static regression for built-in macOS service lifecycle and installer paths."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ServiceTests(unittest.TestCase):
    def test_shell_syntax(self):
        for name in ['scripts/manage-service.sh', 'install.sh', 'uninstall.sh', 'Install.command']:
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

    def test_failure_propagated_and_uninstall_bootout(self):
        install = (ROOT/'install.sh').read_text()
        uninstall = (ROOT/'uninstall.sh').read_text()
        self.assertIn('if ! /bin/bash "$ROOT/scripts/manage-service.sh"', install)
        self.assertIn('DOUBAO_NOTIFIER_SKIP_LAUNCH', install)
        self.assertIn('"$LAUNCHCTL" bootout', uninstall)
        # uninstall derives plist path from $AGENT_LABEL
        self.assertIn('$AGENT_LABEL.plist', uninstall)
        self.assertIn('AGENT_LABEL="com.local.doubao-reply-notifier.agent"', uninstall)

    # --- New in 4.7.3: /Applications default, env override, migration --------
    def test_default_target_is_applications(self):
        install = (ROOT/'install.sh').read_text()
        self.assertIn('DOUBAO_NOTIFIER_APPS_DIR:-/Applications', install)
        # The hardcoded legacy ~/Applications path must appear only as LEGACY_APP
        # (the migration source), not as the default APP assignment.
        self.assertIn('LEGACY_APP="$HOME/Applications/$APP_NAME"', install)
        # The actual install target must derive from APPS_DIR, not hardcoded ~.
        import re
        self.assertRegex(install, r'(?m)^APP="\$APPS_DIR/\$APP_NAME"$')

    def test_launchagent_programarguments_uses_final_bin_path(self):
        service = (ROOT/'scripts/manage-service.sh').read_text()
        self.assertIn('-insert ProgramArguments.0 -string "$BIN"', service)
        self.assertIn('BIN="$APP/Contents/MacOS/DoubaoReplyNotifier"', service)

    def test_process_matching_is_exact_path_not_substring(self):
        install = (ROOT/'install.sh').read_text()
        service = (ROOT/'scripts/manage-service.sh').read_text()
        uninstall = (ROOT/'uninstall.sh').read_text()
        for text in (install, service, uninstall):
            # Must not actually invoke pgrep (substring match can kill unrelated shells).
            # Strip comments before checking.
            code = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
            self.assertNotIn('pgrep', code)
            # Must use exact command comparison via ps + awk.
            self.assertIn('ps -axo pid=,command=', text)

    def test_rollback_on_failure(self):
        install = (ROOT/'install.sh').read_text()
        self.assertIn('ROLLBACK_NEEDED=1', install)
        self.assertIn('mv "$OLD_APP_BACKUP" "$APP"', install)
        # State directory must not be removed by installer.
        self.assertNotIn('rm -rf "$STATE_DIR"', install)

    def test_uninstall_covers_both_locations(self):
        uninstall = (ROOT/'uninstall.sh').read_text()
        self.assertIn('DOUBAO_NOTIFIER_APPS_DIR:-/Applications', uninstall)
        self.assertIn('"$HOME/Applications/$APP_NAME"', uninstall)
        self.assertIn('Application Support/DoubaoReplyNotifier', uninstall)

    def test_launchservices_dedup(self):
        install = (ROOT/'install.sh').read_text()
        self.assertIn('lsregister', install)
        self.assertIn('mdfind', install)
        self.assertIn('kMDItemCFBundleIdentifier', install)

    # --- Rollback coverage after swap/plist overwrite --------------------------
    def test_rollback_covers_fresh_install_and_plist_restore(self):
        install = (ROOT/'install.sh').read_text()
        # Partial new target must be torn down on failure even with no prior target.
        self.assertIn('SWAP_COMMITTED=1', install)
        self.assertIn('PLIST_OVERWRITTEN=1', install)
        # Fresh-target rollback armed BEFORE the copy (partial-cp teardown).
        self.assertIn('TARGET_CREATION_ARMED=1', install)
        self.assertIn('TARGET_CREATION_ARMED=0', install)
        self.assertIn('elif [[ "$SWAP_COMMITTED" == "1" || "$TARGET_CREATION_ARMED" == "1" ]]', install)
        # Plist rollback: restore previous plist when a backup exists, else remove
        # the orphaned plist so launchd never retries a broken binary at login.
        self.assertIn('OLD_PLIST_BACKUP', install)
        self.assertIn('/bin/rm -f "$LEGACY_PLIST"', install)
        # Success path must disarm all rollback flags.
        self.assertIn('SWAP_COMMITTED=0', install)
        self.assertIn('PLIST_OVERWRITTEN=0', install)

    def test_existing_target_identity_gate_and_service_teardown(self):
        install = (ROOT/'install.sh').read_text()
        # Existing target: symlink refused, foreign bundle refused, never touched.
        self.assertIn('if [[ -L "$APP" ]]; then', install)
        self.assertIn('非本产品的 App', install)
        # On failure after service start: stop new service/processes by exact
        # target path BEFORE file rollback; honest stopped-state disclosure.
        self.assertIn('NEW_SERVICE_STARTED=1', install)
        self.assertIn('NEW_SERVICE_STARTED=0', install)
        self.assertIn('"$LAUNCHCTL" bootout "$svc"', install)
        self.assertIn('服务为停止态', install)

    # --- 4.7.4: after file rollback, immediately recover the old service; ----
    # bootstrap failure is disclosed honestly and never upgraded to "running".
    def test_old_service_recovered_after_rollback(self):
        install = (ROOT/'install.sh').read_text()
        self.assertRegex(install, r'VERSION="4\.7\.[0-9]+"')
        self.assertRegex(install, r'BUILD="[0-9]+"')
        # launchctl path overridable for isolation, defaults to production path.
        self.assertIn('LAUNCHCTL="${DOUBAO_LAUNCHCTL:-/bin/launchctl}"', install)
        # cleanup calls recovery only when a rollback actually happened.
        self.assertIn('recover_old_service || true', install)
        # Recovery bootstraps the restored plist in the gui domain.
        self.assertIn('"$LAUNCHCTL" bootstrap "$domain" "$LEGACY_PLIST"', install)
        # Managed vs plain application-job: direct relaunch = equivalent running.
        self.assertIn('started="direct"', install)
        self.assertIn('started="managed"', install)
        self.assertIn('等效运行态', install)
        # Identity gate before relaunching the restored bundle.
        self.assertIn('recover_bundle_identity_ok', install)
        # Recovery requires the app's OWN health: live PID == health PID, ready,
        # version/build match restored bundle, and freshly written (no stale ready).
        self.assertIn('"$pid" == "$hpid"', install)
        self.assertIn('"$hready" == "true"', install)
        self.assertIn('"$hver" == "$old_ver"', install)
        self.assertIn('"$hbuild" == "$old_build"', install)
        self.assertIn('"$mtime" -ge "$baseline"', install)
        # Failure/unready path: honest warning, function returns 1.
        self.assertIn('未能恢复就绪', install)
        # Success claim requires observing the exact-path process first.
        self.assertIn('旧版受管服务已恢复运行', install)
        # Recovery must never write/fake health itself.
        self.assertNotIn('runtime-health.json" >', install.split('recover_old_service()')[1].split('recover_bundle_identity_ok')[0])

    # --- manage-service launchctl overridable so isolation never hits real ---
    # gui domain; product detection (exact path / health PID / version) untouched.
    def test_manage_service_launchctl_override(self):
        svc = (ROOT/'scripts/manage-service.sh').read_text()
        self.assertIn('LAUNCHCTL="${DOUBAO_LAUNCHCTL:-/bin/launchctl}"', svc)
        self.assertIn('"$LAUNCHCTL" bootout "$SERVICE"', svc)
        self.assertIn('"$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"', svc)
        # Detection logic unchanged: exact exec path, health PID match, version.
        self.assertIn('"$PIDS" == "$HEALTH_PID"', svc)
        self.assertIn('CFBundleIdentifier', svc)

    # --- 4.7.4 acceptance gates: unique instance + loaded in launchd domain --
    def test_ready_requires_loaded_and_unique_instance(self):
        svc = (ROOT/'scripts/manage-service.sh').read_text()
        # Uniqueness: exactly one exact-path instance before declaring ready.
        self.assertIn('INSTANCE_COUNT="$(exact_pids | /usr/bin/wc -l', svc)
        self.assertIn('拒绝重复启动', svc)
        # Loaded acceptance: print the service in the gui domain must succeed.
        self.assertIn('"$LAUNCHCTL" print "$SERVICE"', svc)
        self.assertIn('未在 launchd 域加载', svc)

    # --- build script must never delete an existing external bundle ----------
    def test_build_refuses_existing_output(self):
        b = (ROOT/'scripts/build-universal.sh').read_text()
        self.assertIn('拒绝覆盖', b)
        self.assertNotIn('/bin/rm -rf "$OUT_DIR/Doubao Reply Notifier.app"', b)

    # --- Identity-verified legacy cleanup -------------------------------------
    def test_legacy_cleanup_requires_bundle_identity(self):
        install = (ROOT/'install.sh').read_text()
        uninstall = (ROOT/'uninstall.sh').read_text()
        # Installer proves the legacy bundle identity before any touch.
        self.assertIn('legacy_identity_ok()', install)
        self.assertIn('CFBundleIdentifier', install)
        self.assertIn('BUNDLE_ID', install)
        # The legacy rm -rf must sit inside the identity check, not bare.
        self.assertIn('if legacy_identity_ok; then', install)
        # Uninstaller gates every bundle deletion on the same identity check.
        self.assertIn('CFBundleIdentifier raw "$t/Contents/Info.plist"', uninstall)

if __name__ == '__main__':
    unittest.main()
