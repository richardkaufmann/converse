#!/usr/bin/env python3
"""Offline CLI peer. No credentials or model requests; validates wire/argv boundaries."""
import json, os, signal, sys, time
kind, args = sys.argv[1], sys.argv[2:]
def emit(value): print(json.dumps(value), flush=True)
models = [{'model': 'fixture-sol', 'displayName': 'Fixture Sol', 'isDefault': True, 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': e} for e in ['low', 'high']]},
          {'model': 'fixture-small', 'displayName': 'Fixture Small', 'isDefault': False, 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}]}]
if args == ['serve']:
    assert kind.startswith('muse')
    session, turn = None, None
    def notify(method, **params): emit({'method': method, 'params': dict(sessionId=session, **params)})
    for line in sys.stdin:
        q = json.loads(line); method, p, rid = q.get('method'), q.get('params', {}), q.get('id')
        if method == 'initialize': emit({'id':rid,'result':{}})
        elif method == 'session/read': emit({'id':rid,'result':{'session':{'sessionId':p['sessionId']}}})
        elif method == 'session/resume':
            session = p['sessionId']; emit({'id':rid,'result':{'session':{'sessionId':session}}})
        elif method == 'session/setModel':
            emit({'id':rid,'error':{'code':-32030,'message':'Saved model no longer available'}})
        elif method == 'turn/start':
            turn = p['commandId']; prompt = p['input'][0]['text']
            if kind != 'muse':
                from pathlib import Path
                marker = Path(os.environ['CONVERSE_DATA_DIR']) / (kind + '.pid')
                if prompt == 'slow': marker.write_text(str(os.getpid()))
                elif marker.exists():
                    try: os.kill(int(marker.read_text()), 0)
                    except ProcessLookupError: pass
                    else: raise AssertionError('Replacement started before previous host exited')
            if kind == 'muse-stuck': signal.signal(signal.SIGTERM, signal.SIG_IGN)
            emit({'id':rid,'result':{'turnId':turn}})
            notify('turn/started', turnId=turn)
            notify('item/started', item={'itemId':'reply','kind':'agentMessage','text':''})
            answer = prompt[len('switchboard-output:'):] if prompt.startswith('switchboard-output:') else 'answer: '+prompt
            notify('item/delta', itemId='reply', field='text', delta='partial' if prompt == 'slow' else answer)
            if prompt != 'slow': notify('turn/completed', turnId=turn, terminal='completed')
        elif method == 'turn/interrupt':
            assert session == p['sessionId'] and turn == p['turnId']
            if kind == 'muse-no-ack': continue
            if kind == 'muse-rejected-interrupt':
                emit({'id':rid,'error':{'code':-32030,'message':'Interrupt unavailable'}})
            else: emit({'id':rid,'result':{}})
            if kind == 'muse': notify('turn/completed', turnId=turn, terminal='cancelled')
        elif method != 'initialized': raise AssertionError(method)
    sys.exit()
if args == ['app-server']:
    assert kind == 'codex'
    for line in sys.stdin:
        q = json.loads(line); method = q.get('method'); rid = q.get('id')
        if rid is None: continue
        if method == 'initialize': result = {}
        elif method == 'model/list': result = {'data': models}
        elif method == 'config/read': result = {'config': {'model': 'fixture-sol', 'model_reasoning_effort': 'low', 'sandbox_mode': 'read-only'}}
        elif method == 'account/read': result = {'account': {'email': os.environ.get('CODEX_HOME', 'default')}}
        elif method == 'thread/read': result = {'thread': {'model': 'fixture-sol', 'reasoningEffort': 'high'}}
        else: raise AssertionError('Status query must not resume or submit: ' + method)
        emit({'id': rid, 'result': result})
    sys.exit()
if args == ['auth', 'status', '--json']:
    assert kind == 'claude'
    emit({'loggedIn': True, 'email': os.environ['CLAUDE_CONFIG_DIR']})
    sys.exit()
if '--no-session-persistence' in args:
    assert kind == 'claude' and '--input-format' in args
    q = json.loads(sys.stdin.readline())
    assert q['request']['subtype'] == 'initialize'
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': q['request_id'], 'response': {
        'models': [{'value': 'default', 'displayName': 'Default', 'resolvedModel': 'fixture-opus', 'supportedEffortLevels': ['low','high']}, {'value': 'sonnet', 'displayName': 'Sonnet', 'resolvedModel': 'fixture-sonnet', 'supportedEffortLevels': ['low','high']}],
        'current_permission_mode': 'manual', 'account': {'email': os.environ.get('CLAUDE_CONFIG_DIR', 'default'), 'tokenSource': 'oauth'}}}})
    # The client closes the probe; no prompt follows.
    assert not sys.stdin.readline()
    sys.exit()
# Claude turns arrive as stream-json user messages on stdin; one process may
# take several turns while a fixture background task is outstanding.
live = kind == 'claude' and '--input-format' in args
assert live or '--' in args
assert not live or '--' not in args
background = None
def finish_background():
    global background
    emit({'type':'system','subtype':'task_notification','task_id':background,'status':'completed','session_id':'fixture-thread'})
    background = None
    emit({'type':'system','subtype':'init','session_id':'fixture-thread'})
    emit({'type':'assistant','message':{'content':[{'type':'text','text':'background finished pid=%d' % os.getpid()}]}})
    emit({'type':'result','session_id':'fixture-thread','result':'background finished pid=%d' % os.getpid()})
def prompts():
    if not live:
        yield args[args.index('--')+1]; return
    for line in iter(sys.stdin.readline, ''):
        q = json.loads(line)
        assert q['type'] == 'user' and q['message']['role'] == 'user' and q['parent_tool_use_id'] is None
        yield q['message']['content']
    if background: finish_background()
def turn(prompt):
  global background
  if prompt.startswith(('identity-check', 'identity-wait')):
      assert kind == 'claude'
      from pathlib import Path
      flag = '--resume' if '--resume' in args else '--session-id'
      transcript = args[args.index(flag)+1]
      emit({'type':'system', 'session_id':transcript})
      if prompt.startswith('identity-wait'): time.sleep(2)
      path = prompt.split('read-only session identity sidecar ', 1)[1].split('; time zone ', 1)[0]
      identity = json.loads(Path(path).read_text())
      emit({'type':'result', 'session_id':transcript, 'result':json.dumps({'prompt':prompt, 'identity':identity})})
      sys.exit()

  assert '--model' in args and args[args.index('--model')+1] == ('fixture-sol' if kind == 'codex' else 'sonnet')
  if prompt in ['urgent', 'queued', 'fail']:
      resume = 'resume' if kind == 'codex' else '--resume'
      assert resume in args and args[args.index(resume)+1] == 'fixture-thread'
  if kind == 'codex':
      assert 'model_reasoning_effort="high"' in args and 'sandbox_mode="read-only"' in args
      assert os.environ['CODEX_HOME'].endswith('fixture-codex-account') and 'OPENAI_API_KEY' not in os.environ
      emit({'type':'thread.started','thread_id':'fixture-thread'})
  else:
      assert '--effort' in args and args[args.index('--effort')+1] == 'high' and os.environ['CLAUDE_CODE_EFFORT_LEVEL'] == 'high'
      assert '--permission-mode' in args and args[args.index('--permission-mode')+1] == 'manual'
      assert os.environ['CLAUDE_CONFIG_DIR'].endswith('fixture-claude-account') and 'ANTHROPIC_API_KEY' not in os.environ
      emit({'type':'system','session_id':'fixture-thread','model':'fixture-sonnet'})
  # Isolated retained context for account-rebinding tests; never a credential.
  from pathlib import Path
  store = Path(os.environ['CLAUDE_CONFIG_DIR' if kind == 'claude' else 'CODEX_HOME'])
  context = store / ('projects/fixture/fixture-thread.jsonl' if kind == 'claude' else 'sessions/fixture/rollout-fixture-thread.jsonl')
  context.parent.mkdir(parents=True, exist_ok=True)
  context.write_text('{"context":"fixture-thread"}\n')
  if prompt == 'slow':
      signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
      if kind == 'codex': emit({'type':'item.completed','item':{'type':'agent_message','text':'partial'}})
      else: emit({'type':'assistant','message':{'content':[{'type':'text','text':'partial'}]}})
      time.sleep(20)
  if prompt == 'login-required':
      if kind == 'codex': emit({'type':'turn.failed','error':{'message':'Not logged in. Please run /login'}})
      else: emit({'type':'result','session_id':'fixture-thread','is_error':True,'result':'Not logged in. Please run /login'})
      sys.exit(1)
  if prompt == 'fail': sys.exit(1)
  if prompt in ['bg-start', 'bg-exit']:
      assert live
      background = 't1'
      emit({'type':'system','subtype':'task_started','task_id':background,'description':'Fixture subagent','session_id':'fixture-thread'})
      emit({'type':'assistant','message':{'content':[{'type':'text','text':'started pid=%d' % os.getpid()}]}})
      emit({'type':'result','session_id':'fixture-thread','result':'started pid=%d' % os.getpid()})
      # A CLI time limit ends the process without a completion notice.
      if prompt == 'bg-exit': time.sleep(0.3); sys.exit(0)
      return
  if prompt == 'bg-ping':
      emit({'type':'result','session_id':'fixture-thread','result':'answer: bg-ping pid=%d' % os.getpid()})
      if background: time.sleep(0.3); finish_background()
      return
  answer = prompt[len('switchboard-output:'):] if prompt.startswith('switchboard-output:') else 'answer: '+prompt
  if kind == 'codex' and prompt.startswith('switchboard-progress:'):
      emit({'type':'item.completed','item':{'type':'agent_message','text':'I will inspect this before sending.'}})
      answer = prompt[len('switchboard-progress:'):]
  if kind == 'codex' and prompt.startswith('switchboard-file-only:'):
      answer = prompt[len('switchboard-file-only:'):]
  if kind == 'codex' and prompt.startswith('switchboard-commentary-only:'):
      emit({'type':'item.completed','item':{'type':'agent_message','text':prompt[len('switchboard-commentary-only:'):]}})
      answer = 'Finished without sending.'
  if prompt == 'working-directory': answer = os.getcwd()
  if kind == 'codex':
      if '--output-last-message' in args and not prompt.startswith('switchboard-missing-final:'):
          Path(args[args.index('--output-last-message')+1]).write_text(answer)
      if not prompt.startswith('switchboard-file-only:'):
          emit({'type':'item.completed','item':{'type':'agent_message','text':answer}})
      emit({'type':'turn.completed','usage':{'input_tokens':2,'output_tokens':3}})
  else: emit({'type':'result','session_id':'fixture-thread','result':answer})
for prompt in prompts(): turn(prompt)
