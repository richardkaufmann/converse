#!/usr/bin/env python3
"""Offline CLI peer. No credentials or model requests; validates wire/argv boundaries."""
import json, os, signal, sys, time
kind, args = sys.argv[1], sys.argv[2:]
def emit(value): print(json.dumps(value), flush=True)
models = [{'model': 'fixture-sol', 'displayName': 'Fixture Sol', 'isDefault': True, 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': e} for e in ['low', 'high']]},
          {'model': 'fixture-small', 'displayName': 'Fixture Small', 'isDefault': False, 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}]}]
if args == ['serve']:
    assert kind == 'muse'
    session, turn = None, None
    def notify(method, **params): emit({'method': method, 'params': dict(sessionId=session, **params)})
    for line in sys.stdin:
        q = json.loads(line); method, p, rid = q.get('method'), q.get('params', {}), q.get('id')
        if method == 'initialize': emit({'id':rid,'result':{}})
        elif method == 'session/read': emit({'id':rid,'result':{'session':{'sessionId':p['sessionId']}}})
        elif method == 'session/resume':
            session = p['sessionId']; emit({'id':rid,'result':{'session':{'sessionId':session}}})
        elif method == 'turn/start':
            turn = p['commandId']; prompt = p['input'][0]['text']
            emit({'id':rid,'result':{'turnId':turn}})
            notify('turn/started', turnId=turn)
            notify('item/started', item={'itemId':'reply','kind':'agentMessage','text':''})
            notify('item/delta', itemId='reply', field='text', delta='partial' if prompt == 'slow' else 'answer: '+prompt)
            if prompt != 'slow': notify('turn/completed', turnId=turn, terminal='completed')
        elif method == 'turn/interrupt':
            assert session == p['sessionId'] and turn == p['turnId']
            emit({'id':rid,'result':{}}); notify('turn/completed', turnId=turn, terminal='cancelled')
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
if '--input-format' in args:
    assert kind == 'claude' and '--no-session-persistence' in args
    q = json.loads(sys.stdin.readline())
    assert q['request']['subtype'] == 'initialize'
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': q['request_id'], 'response': {
        'models': [{'value': 'default', 'displayName': 'Default', 'resolvedModel': 'fixture-opus', 'supportedEffortLevels': ['low','high']}, {'value': 'sonnet', 'displayName': 'Sonnet', 'resolvedModel': 'fixture-sonnet', 'supportedEffortLevels': ['low','high']}],
        'current_permission_mode': 'manual', 'account': {'email': os.environ.get('CLAUDE_CONFIG_DIR', 'default'), 'tokenSource': 'oauth'}}}})
    # The client closes the probe; no prompt follows.
    assert not sys.stdin.readline()
    sys.exit()
assert '--' in args
prompt = args[args.index('--')+1]
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
if prompt == 'slow':
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    if kind == 'codex': emit({'type':'item.completed','item':{'type':'agent_message','text':'partial'}})
    else: emit({'type':'assistant','message':{'content':[{'type':'text','text':'partial'}]}})
    time.sleep(20)
if prompt == 'fail': sys.exit(1)
if kind == 'codex':
    emit({'type':'item.completed','item':{'type':'agent_message','text':'answer: '+prompt}})
    emit({'type':'turn.completed','usage':{'input_tokens':2,'output_tokens':3}})
else: emit({'type':'result','session_id':'fixture-thread','result':'answer: '+prompt})
