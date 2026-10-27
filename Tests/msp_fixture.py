#!/usr/bin/env python3
"""Offline interactive MSP peer: rejects wrong IDs, guards, choices and answers."""
import json, sys
session = None
turn = None
requirement = {"approvalId": "approval-fixture", "sourceIndex": 2}
receipts = set()
def emit(**obj):
    print(json.dumps(dict(jsonrpc="2.0", **obj)), flush=True)
def notify(method, **params):
    emit(method=method, params=dict(sessionId=session, **params))
def request(id, method, **params):
    emit(id=id, method=method, params=dict(sessionId=session, **params))
def result(id, **r):
    emit(id=id, result=r)
for line in sys.stdin:
    msg = json.loads(line)
    method, p, rid = msg.get("method"), msg.get("params", {}), msg.get("id")
    if method == "initialize":
        assert p["capabilities"]["userInputDialogs"] is True
        result(rid)
    elif method == "session/read":
        emit(id=rid, error=dict(code=-32020, message="Session not found", data=dict(kind="sessionNotFound")))
    elif method == "session/start":
        session = p["sessionId"]
        result(rid, session=dict(sessionId=session, status="idle"))
    elif method == "turn/start":
        assert p["input"][0]["type"] == "text"
        turn = p["commandId"]
        result(rid, turnId=turn, disposition="started")
        notify("turn/started", turnId=turn)
        notify("item/started", item=dict(itemId="reply", kind="agentMessage", text=""))
        notify("item/delta", itemId="reply", field="text", delta="Waiting for permission.")
        request("show-approval", "approval/request", approvalId="approval-fixture", currentRequirementId=requirement,
                toolName="network", rawArgs="https example.invalid:443", availableChoices=[
                    dict(choiceId="allow-once", label="Allow once", scope="once", decision="approved"),
                    dict(choiceId="deny", label="Deny", scope="once", decision="denied")])
    elif method == "session/setPermissionProfile":
        assert p['sessionId'] == session
        if p['profileId'] == ':unavailable':
            emit(id=rid, error=dict(code=-32030,message='Profile unavailable',data=dict(kind='commandRejected')))
        else:
            assert p['profileId'] == ':ask-me'
            result(rid, status='accepted', applyOutcome='completed', permissionState=dict(profileId=p['profileId'],reviewerAuthority='human',reviewerAttached=False))
    elif method == 'session/setReasoningEffort':
        assert p['sessionId'] == session and p['reasoningEffort'] == 'max'
        result(rid,status='accepted')
    elif method == 'session/setModel':
        assert p['sessionId'] == session and p['model']['modelId'] == 'fixture-model'
        result(rid,status='accepted')
    elif method == "approval/decide":
        assert p["sessionId"] == session and p["approvalId"] == "approval-fixture"
        assert p["choiceId"] == "allow-once" and p["requirementId"] == requirement
        result(rid, terminal=True)
        notify("approval/resolved", approvalId="approval-fixture", decision="approved")
        request("show-question", "userInput/request", userInputId="question-fixture", questions=[
            dict(id="single", header="One", question="Pick one", options=[dict(label="A"), dict(label="B")], selection=dict(mode="single")),
            dict(id="multiple", header="Many", question="Pick two", options=[dict(label="X"), dict(label="Y")], selection=dict(mode="multiple", minSelections=2, maxSelections=2)),
            dict(id="free", header="Text", question="Tell me", options=[], selection=dict(mode="single"))])
    elif method == "userInput/answer":
        assert p["userInputId"] == "question-fixture"
        assert p["answers"] == [dict(questionId="single", selectedLabel="B"), dict(questionId="multiple", selectedLabels=["X", "Y"]), dict(questionId="free", freeText="hello")]
        result(rid)
        notify("userInput/settled", userInputId="question-fixture", outcome="answered")
        notify("item/completed", item=dict(itemId="reply", kind="agentMessage", text="Waiting for permission."))
        notify("turn/foregroundCompleted", blockingAgents=["verify-reminder"])
        assert receipts == {"show-approval", "show-question"}
        notify("turn/completed", turnId=turn, terminal="completed")
    elif method is None and "result" in msg:
        receipts.add(rid)
    elif method == "turn/interrupt":
        result(rid)
        notify("turn/completed", turnId=turn, terminal="cancelled")
