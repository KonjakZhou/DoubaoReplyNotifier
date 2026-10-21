#!/usr/bin/env python3
"""Regression using redacted protocol fields copied from the observed native log."""
import importlib.util,json,sys,time,pathlib
spec=importlib.util.spec_from_file_location('harness',pathlib.Path(__file__).with_name('test-native-rounds.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
fixtures=json.loads((pathlib.Path(__file__).parent/'fixtures/native-new-chat.json').read_text())
s=h.Session()
try:
 for record in fixtures:
  s.append(s.front if '[office-api-logger]' in record else s.native,record)
 state=s.wait(lambda d:s.completed(d)==1)
 assert not state.get('pendingInteractions',{}).get(h.CID)
 time.sleep(1);assert s.completed(s.read())==1
 print('PASS redacted real new-chat protocol replay, exactly one completion')
finally:s.close()
