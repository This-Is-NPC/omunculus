# Run after mix escript.build: python3 scripts/validate_cli.py
import json,os,signal,sqlite3,subprocess,tempfile,time
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
tmp=Path(tempfile.mkdtemp(prefix='omunculus-phase7-e2e-'))
db=tmp/'session.sqlite3'
config=tmp/'omunculus.toml'
config.write_text((repo/'test/fixtures/config/simple.toml').read_text())
env=dict(os.environ,XDG_CACHE_HOME=str(tmp/'cache'))
exe=str(repo/'omunculus')
def cli(*args):
 r=subprocess.run([exe,*args],env=env,text=True,capture_output=True,timeout=90)
 assert r.returncode==0,(args,r.stdout,r.stderr)
 return r.stdout
def events():
 with sqlite3.connect(db) as conn:
  return conn.execute("select sequence,type,payload from events order by sequence").fetchall()
def await_result(n):
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  if any(t=='task.completed' and json.loads(p).get('result')==str(n) for _,t,p in events()): return
  time.sleep(.1)
 raise AssertionError('no completion '+str(n))
follow=None
try:
 cli('send','conte até 3','--provider','fake','--profile','count','--config',str(config),'--session',str(db),'--detach')
 ready=json.loads(Path(str(db)+'.executor-ready').read_text())
 await_result(3)
 assert 'body="3"' in cli('inbox','--session',str(db))
 cursor=events()[-1][0]
 with (tmp/'follow.ndjson').open('w') as out:
  follow=subprocess.Popen([exe,'events','follow','--db',str(db),'--after',str(cursor)],env=env,stdout=out,stderr=subprocess.PIPE)
  payload=json.dumps({'instruction':'conte até 4','execution':{'provider':'fake','profile':'count','cwd':str(tmp),'config_file':str(config)}})
  cli('emit','task.requested','--db',str(db),'--payload',payload)
  await_result(4)
  deadline=time.monotonic()+15
  while time.monotonic()<deadline:
   observed=[json.loads(s) for s in (tmp/'follow.ndjson').read_text().splitlines()]
   if any(e['type']=='task.completed' and e['payload'].get('result')=='4' for e in observed): break
   time.sleep(.1)
  else: raise AssertionError('follow did not observe live completion')
  seq=[e['sequence'] for e in observed]
  assert seq==sorted(set(seq)) and min(seq)>cursor
  assert ready==json.loads(Path(str(db)+'.executor-ready').read_text())
  print(json.dumps({'detach_result':'3','external_emit_result':'4','live_follow_events':len(seq),'ordered_unique':True,'same_executor':True,'artifacts':str(tmp)}))
finally:
 if follow is not None:
  follow.terminate()
  follow.wait(timeout=15)
 path=Path(str(db)+'.executor-ready')
 if path.exists():
  pid=json.loads(path.read_text())['pid']
  cmd=Path('/proc/'+pid+'/cmdline').read_bytes()
  if b'__session-worker' in cmd: os.kill(int(pid),signal.SIGTERM)
