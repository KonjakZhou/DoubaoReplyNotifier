#!/usr/bin/env python3
"""Execute the real compiled Swift notifier, isolated sources/state, notifications off."""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path
binary = Path(sys.argv[1]).resolve()
cid = '90000000000000991'
with tempfile.TemporaryDirectory(prefix='notifier-regression-') as folder:
    base = Path(folder); root = base/'Doubao'; logs = root/'sdk_storage/log'
    system = root/f'Profile 9/.doubao/agent_mode/workspace/.sessions/{cid}/agents/m_regression/system'
    logs.mkdir(parents=True); system.mkdir(parents=True)
    log=logs/'saman_test.log';log.write_text('')
    trajectory=system/'trajectory.jsonl';trajectory.write_text('')
    (system/'assignment.md').write_text('# Main assignment\n')
    state=base/'state.json'
    state.write_text(json.dumps({'version':12,'pendingInteractions':{cid:{'old-unverified':'indexeddb.authorize'}},'activeRunIDs':{cid:'old-stuck'},'activeInterceptors':{cid:{}}}))
    env=dict(os.environ,DOUBAO_NOTIFIER_DATA_ROOT=str(root),DOUBAO_NOTIFIER_LOG_ROOT=str(logs),DOUBAO_NOTIFIER_STATE_FILE=str(state),DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS='1',DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM='1')
    output=open(base/'runtime.log','w')
    process=subprocess.Popen([str(binary)],env=env,stdout=output,stderr=output)
    def data(): return json.loads(state.read_text())
    def count(kind): return sum(f'|{kind}|' in k for k in data().get('processedEvents',{}))
    def append(path, text):
        with path.open('a') as f:f.write(text+'\n')
    def reg(name,seq):append(log,f'[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id={name}:{cid}, priority=0, sequence={seq}, blocker_count=1')
    def end(name):append(log,f'[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id={name}:{cid}, removed_count=1, blocker_count=0')
    def wait_assert(fn,label,timeout=8):
        until=time.monotonic()+timeout
        while time.monotonic()<until:
            if process.poll() is not None:raise RuntimeError('Swift exited '+str(process.returncode))
            try:
                if fn():print('PASS',label,flush=True);return
            except (FileNotFoundError,json.JSONDecodeError):pass
            time.sleep(.1)
        raise AssertionError(label+'; runtime='+ (base/'runtime.log').read_text()[-2400:])
    try:
        wait_assert(lambda: data().get('version')==13,'state migration')
        wait_assert(lambda: not data().get('pendingInteractions',{}).get(cid),'unverified legacy pending no longer blocks')
        assert data().get('quarantinedInteractions',{}).get(cid,{}).get('old-unverified')=='indexeddb.authorize'
        # Exact navigation/shortcut transient, no presentation marker, as captured in reports.
        append(log,f'chat_page_navigate_event conversation_id={cid}')
        append(log,'setShortcutIntercept(COMMAND,W)')
        reg('navigation',1);end('navigation');time.sleep(1.3)
        assert count('reply_completed')==0,'navigation premature completion'
        print('PASS navigation without presentation marker produces zero completions',flush=True)
        # Very fast real run must not be dropped by arbitrary duration threshold.
        reg('real-fast',2);end('real-fast')
        wait_assert(lambda:count('reply_completed')==1,'fast real run emits exactly one completion')
        assert 'old-stuck' not in data().get('terminalRuns',{})
        # Actual supported interaction lifecycle; completion cannot clear legitimate waiting.
        reg('waiting-run',3);time.sleep(.4)
        append(trajectory,json.dumps({'role':'assistant','tool_calls':[{'id':'real-wait','function':{'name':'interaction.ask'}}]}))
        wait_assert(lambda:count('waiting_user')==1,'legitimate waiting is emitted')
        end('waiting-run');time.sleep(1.2)
        assert count('reply_completed')==1,'completed while legitimate waiting'
        assert data()['pendingInteractions'][cid]['real-wait']=='interaction.ask'
        append(trajectory,json.dumps({'role':'tool','tool_call_id':'real-wait','content':'answered'}))
        wait_assert(lambda:count('reply_completed')==2,'resolving wait restores completion')
        # Multiple same-run blockers: one completion, matched lifecycle only.
        reg('parallel-a',4);reg('parallel-b',5);time.sleep(.35);end('parallel-a');time.sleep(.8)
        assert count('reply_completed')==2
        end('parallel-b');wait_assert(lambda:count('reply_completed')==3,'parallel blockers complete once')
        end('parallel-b');time.sleep(.8);assert count('reply_completed')==3
        # Parser source in normal assistant text must not become waiting.
        append(trajectory,json.dumps({'role':'assistant','content':'approve quick_reply schema_payload tool_call ordinary UUID','tool_calls':[{'id':'ordinary','function':{'name':'Grep'}}]}))
        time.sleep(.7);assert count('waiting_user')==1
        print('PASS ordinary text/tools do not become waiting',flush=True)
        # Navigation lacking shortcut marker must wait for positive activity;
        # assistant text is activity evidence only, never completion evidence.
        append(log,f'chat_page_navigate_event conversation_id={cid}')
        reg('ambiguous-nav',6);end('ambiguous-nav');time.sleep(.9)
        assert count('reply_completed')==3
        append(trajectory,json.dumps({'role':'assistant','content':'actual current activity'}))
        wait_assert(lambda:count('reply_completed')==4,'ambiguous navigation requires actual activity')
        # Another conversation must not inherit the prior navigation marker.
        cid2='90000000000000992'
        append(log,f'chat_page_navigate_event conversation_id={cid}')
        append(log,'setShortcutIntercept(COMMAND,W)')
        append(log,f'[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=other:{cid2}, priority=0, sequence=7, blocker_count=1')
        append(log,f'[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=other:{cid2}, removed_count=1, blocker_count=0')
        wait_assert(lambda:count('reply_completed')==5,'navigation does not suppress another conversation')
        process.kill();process.wait(timeout=5)
        process=subprocess.Popen([str(binary)],env=env,stdout=output,stderr=output)
        time.sleep(2.5);assert count('reply_completed')==5
        print('PASS restart does not replay historical events',flush=True)
        print('ALL REAL SWIFT REGRESSIONS PASSED',flush=True)
    finally:
        if process.poll() is None:process.kill();process.wait(timeout=5)
        output.close()
