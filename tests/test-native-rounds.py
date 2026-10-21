#!/usr/bin/env python3
"""Isolated runtime regression; never writes user state or posts system notifications."""
import json, os, pathlib, subprocess, tempfile, time, sys
BIN = str(pathlib.Path(sys.argv[1]).resolve())
ROOT = pathlib.Path(__file__).resolve().parents[1]
CID='90000000000000061'; LOCAL='local_2111801313218126'; PRODUCT='com.work.pc.doubao'
S1='667083b6-3110-4585-99f3-59efdf57a971'; S2='9556e4b9-7c8c-4c8f-ae30-c49b8fe4d1bd'
I='2b4b05d8-419a-49ec-a358-1b29d7050670'
class Session:
 def __init__(self, seed=None):
  self.tmp=tempfile.TemporaryDirectory(prefix='native-round-regression-'); self.p=pathlib.Path(self.tmp.name)
  self.root=self.p/'DoubaoWork'; self.logs=self.root/'sdk_storage/log'; self.logs.mkdir(parents=True)
  self.native=self.logs/'saman_test.log';self.front=self.logs/'saman_frontend_test.log'
  self.native.touch();self.front.touch();self.state=self.p/'state.json'
  system=self.root/'Default/.doubaowork/agent_mode/workspace/.sessions'/CID/'agents/m_test/system'
  system.mkdir(parents=True);(system/'assignment.md').write_text('# Assignment\n- Role: main\n')
  self.traj=system/'trajectory.jsonl';self.traj.touch()
  if seed:self.state.write_text(json.dumps(seed))
  env=os.environ.copy();env.update(DOUBAO_NOTIFIER_DATA_ROOT=str(self.root),DOUBAO_NOTIFIER_WORKSPACE_DIR='.doubaowork',DOUBAO_NOTIFIER_LOG_ROOT=str(self.logs),DOUBAO_NOTIFIER_STATE_FILE=str(self.state),DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS='1',DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM='1')
  self.out=open(self.p/'runtime.log','w');self.proc=subprocess.Popen([BIN],env=env,stdout=self.out,stderr=self.out)
  self.wait(lambda s:s.get('version')==14 and len(s.get('runtimeLogOffsets',{}))==2)
  time.sleep(.3)
 def read(self):
  try:return json.loads(self.state.read_text())
  except (FileNotFoundError,json.JSONDecodeError):return {}
 def wait(self,cond,timeout=8):
  end=time.monotonic()+timeout
  while time.monotonic()<end:
   assert self.proc.poll() is None, 'test process exited'
   s=self.read()
   if cond(s):return s
   time.sleep(.08)
  self.out.flush();raise AssertionError(self.read(),(self.p/'runtime.log').read_text()[-4000:])
 def append(self,p,text):
  with p.open('a') as f:f.write(text+'\n')
 def record(self,event,session=S1,ts=1792573965913,local=LOCAL,cid=CID):
  m={'conversation_id':cid,'local_conversation_id':local,'chat_session_id':session,'query_send_timestamp':ts,'page_role':'mainagent','mode_type':'work_task'}
  if event.endswith('end'):m.update(lifecycle_state='session: SyncMessageReceivingStage, message:MessageEnd',agent_error='0',cancel_source='')
  obj={'version':1,'type':'event','eventName':event,'meta':m}
  self.append(self.front,'[50849:67625542:1021/171248.059402:INFO:FRONTEND(0)] [neotix] [office-api-logger] "[webview][unknown][flow-web][logifier-report]: '+json.dumps(obj,separators=(',',':'))+'", source:  (0)')
 def block(self,cid=CID,end=False):
  text=(f'Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:{cid}, removed_count=1, blocker_count=0' if end else f'Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:{cid}, priority=0, sequence=8, blocker_count=1')
  self.append(self.native,'[50849:67625542:1021/171247.387305:INFO:exit_intercept_service.cc(61)] [exit_intercept] '+text)
 def completed(self,s):return sum(k.startswith(CID+'|reply_completed|') for k in s.get('processedEvents',{}))
 def close(self):
  self.proc.terminate()
  try:self.proc.wait(timeout=3)
  except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait()
  self.out.close();self.tmp.cleanup()

def test_local_late_mapping():
 s=Session()
 try:
  s.block(LOCAL);s.block(LOCAL,True);time.sleep(.5)
  assert s.completed(s.read())==0
  s.record('on_message_receiving_start');time.sleep(.4)
  s.record('on_message_session_end')
  s.wait(lambda d:s.completed(d)==1)
  s.record('on_message_session_end');time.sleep(.8)
  assert s.completed(s.read())==1
 finally:s.close()

def test_round_waits():
 s=Session({'version':13,'pendingInteractions':{CID:{I:'interaction.request_action'}}})
 try:
  d=s.wait(lambda d:I in d.get('quarantinedInteractions',{}).get(CID,{}))
  assert not d.get('pendingInteractions',{}).get(CID)
  s.record('on_message_receiving_start');time.sleep(.5)
  # Native received carries explicit sandbox mapping, so it stays current-run pending.
  s.append(s.native,f'[lid={{"conversation_id":"{CID}","sandbox_id":"sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}] mapping')
  new='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  s.append(s.native,'[agent-task] "{"event":"toolcall","data":{"name":"interaction.ask","sandbox_id":"sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","status":"received","tcid":"'+new+'"}}"')
  s.wait(lambda d:new in d.get('pendingInteractions',{}).get(CID,{}))
  s.record('on_message_session_end');time.sleep(.9)
  assert s.completed(s.read())==0,'unanswered current wait must block even after end'
  # Explicit new user query, not a duplicate start/resume, isolates the older wait.
  s.record('on_message_receiving_start',S2,1792574383002);time.sleep(.5)
  s.wait(lambda d:new in d.get('quarantinedInteractions',{}).get(CID,{}))
  s.record('on_message_session_end',S2,1792574383002)
  s.wait(lambda d:s.completed(d)==1)
  # Late end for old session cannot complete the new session again.
  s.record('on_message_session_end');time.sleep(.8);assert s.completed(s.read())==1
 finally:s.close()

def test_page_sync():
 s=Session()
 try:
  s.append(s.native,f'[chat_page_load] chat_page_navigate_event url: chrome://doubaowork-chat/chat/{CID}, last_committed_url: doubaowork://doubaowork-chat/chat/{LOCAL},')
  s.append(s.native,'[saman_chat_shellapi] setShortcutIntercept')
  s.block();s.block(end=True);time.sleep(1);assert s.completed(s.read())==0
  s.block(LOCAL);s.record('on_message_receiving_start');time.sleep(.5)
  s.block(LOCAL,True);s.record('on_message_session_end');s.wait(lambda d:s.completed(d)==1)
 finally:s.close()

if __name__ == '__main__':
 for test in [test_local_late_mapping,test_round_waits,test_page_sync]:
  test();print('PASS',test.__name__,flush=True)
