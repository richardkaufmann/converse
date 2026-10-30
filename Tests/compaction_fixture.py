#!/usr/bin/env python3
"""Offline compaction peer: catches acknowledgement/completion and queue races."""
import json, sys, time
mode = sys.argv[1]
def emit(value):
    print(json.dumps(value), flush=True)
if 'exec' in sys.argv:
    prompt = sys.stdin.read()
    emit({'type': 'thread.started', 'thread_id': 'compact-thread'})
    emit({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'after compact'}})
    if '--output-last-message' in sys.argv:
        from pathlib import Path
        Path(sys.argv[sys.argv.index('--output-last-message') + 1]).write_text('after compact')
    sys.exit()
if mode.startswith('claude'):
    for line in sys.stdin:
        q = json.loads(line)
        if q.get('type') == 'control_request':
            commands = [] if mode == 'claude-unsupported' else [{'name': 'compact'}]
            emit({'type': 'control_response', 'response': {'request_id': q['request_id'], 'subtype': 'success', 'response': {'commands': commands}}})
        elif q.get('type') == 'user':
            assert q['message']['content'] == '/compact'
            sid = q['session_id']
            if mode != 'claude-no-boundary':
                emit({'type': 'system', 'subtype': 'compact_boundary', 'session_id': sid, 'compact_metadata': {'trigger': 'manual'}})
            emit({'type': 'result', 'subtype': 'success', 'session_id': sid, 'is_error': False})
    sys.exit()
for line in sys.stdin:
    q = json.loads(line)
    rid, method = q.get('id'), q.get('method')
    if rid is None:
        continue
    if method == 'initialize':
        emit({'id': rid, 'result': {}})
    elif method == 'thread/resume':
        assert q['params'] == {'threadId': 'compact-thread', 'excludeTurns': True}
        emit({'id': rid, 'result': {'thread': {'id': 'compact-thread', 'status': {'type': 'active' if mode == 'busy' else 'idle'}}}})
    elif method == 'thread/compact/start':
        assert mode != 'busy'
        if mode == 'rejected':
            emit({'id': rid, 'error': {'code': -32601, 'message': 'unsupported'}})
            continue
        def note(method, **params):
            emit({'method': method, 'params': {'threadId': 'compact-thread', **params}})
        note('turn/started', turn={'id': 'turn-1'})
        note('item/started', turnId='turn-1', item={'type': 'contextCompaction', 'id': 'compact-1'})
        # Events can arrive before the RPC acknowledgement.
        emit({'id': rid, 'result': {}})
        time.sleep(0.15)
        if mode == 'ack-only':
            sys.exit()
        if mode != 'failed':
            note('item/completed', turnId='turn-1', item={'type': 'contextCompaction', 'id': 'compact-1'})
        note('turn/completed', turn={'id': 'turn-1', 'status': 'failed' if mode == 'failed' else 'completed'})
    elif method == 'thread/unsubscribe':
        emit({'id': rid, 'result': {}})
    else:
        raise AssertionError(method)
