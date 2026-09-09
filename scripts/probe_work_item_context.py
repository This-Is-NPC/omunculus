"""Reissue recorded requests with one context intervention; never execute tools."""
import argparse
import copy
import hashlib
import json
import sqlite3
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--db', default='test/sessions.sqlite3')
parser.add_argument('--url', default='http://127.0.0.1:52625/v1/chat/completions')
parser.add_argument('--executor-request', type=int, required=True)
parser.add_argument('--parent-request', type=int, required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--suite', choices=['context', 'parent-role'], default='context')
args = parser.parse_args()
conn = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)


def recorded(sequence):
    event_id, payload = conn.execute(
        "SELECT event_id, payload FROM EVENTS WHERE sequence=? AND type='model.call.requested'",
        (sequence,)).fetchone()
    payload = json.loads(payload)
    return event_id, {'model': payload['model'], 'messages': payload['messages'],
                      'tools': payload['schemas'], 'stream': False}


executor_id, executor = recorded(args.executor_request)
parent_id, parent = recorded(args.parent_request)
conn.close()
scoped = copy.deepcopy(executor)
original = 'Return only a JSON object containing completed (boolean) and comment (nonempty string).'
replacement = ('When ending this Run with a final report, return only a JSON object containing '
               'completed (boolean) and comment (nonempty string). '
               'To delegate work, issue an actual delegate tool call with work_item and comment; '
               'a completion report saying you will delegate does not invoke the tool.')
assert scoped['messages'][0]['content'].count(original) == 1
scoped['messages'][0]['content'] = scoped['messages'][0]['content'].replace(original, replacement)
facts = copy.deepcopy(parent)
facts['messages'][-1]['content'] += (
    '\nRecorded execution facts for the TARGET Run: exposed tools=[delegate]; '
    'tool calls requested=0; delegated children created=0. '
    'The tool schema requires work_item and comment; agent and team are optional routing selectors.\n')
without_notes = copy.deepcopy(parent)
without_notes['messages'] = [m for m in without_notes['messages']
                            if not m.get('content', '').startswith('Recent session comments:\n')]
variants = {'executor_baseline': (executor_id, executor), 'executor_scoped_report': (executor_id, scoped),
            'parent_baseline': (parent_id, parent), 'parent_execution_facts': (parent_id, facts),
            'parent_without_session_notes': (parent_id, without_notes)}
order = ['executor_baseline', 'executor_scoped_report', 'executor_scoped_report',
         'executor_baseline', 'executor_baseline', 'executor_scoped_report',
         'parent_baseline', 'parent_execution_facts', 'parent_without_session_notes',
         'parent_without_session_notes', 'parent_execution_facts', 'parent_baseline']
if args.suite == 'parent-role':
    role = copy.deepcopy(parent)
    lines = role['messages'][0]['content'].splitlines()
    assert sum(line.startswith('Configured agent:') for line in lines) == 1
    role['messages'][0]['content'] = '\n'.join(
        ('Configured agent: In this assessment Run, evaluate the TARGET Work Item against '
         'recorded execution evidence. Distinguish a reported intention from a tool call '
         'and from an observed result. Explain any correction in comment; '
         "delegating the original task is not this assessment Run's objective.")
        if line.startswith('Configured agent:') else line for line in lines) + '\n'
    role_facts = copy.deepcopy(facts)
    role_facts['messages'][0] = copy.deepcopy(role['messages'][0])
    variants['parent_role'] = (parent_id, role)
    variants['parent_role_and_facts'] = (parent_id, role_facts)
    order = ['parent_baseline', 'parent_role', 'parent_role_and_facts',
             'parent_role_and_facts', 'parent_role', 'parent_baseline']

with open(args.output, 'x') as output:
    for index, variant in enumerate(order, 1):
        source_id, body = variants[variant]
        encoded = json.dumps(body, ensure_ascii=False, sort_keys=True).encode()
        print(f'START {index}/{len(order)} {variant}', flush=True)
        row = {'index': index, 'variant': variant, 'source_event_id': source_id,
               'request': body, 'request_sha256': hashlib.sha256(encoded).hexdigest()}
        start = time.monotonic()
        try:
            req = urllib.request.Request(args.url, data=encoded,
                                         headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=120) as response:
                row['http_status'] = response.status
                row['response'] = json.loads(response.read())
        except Exception as error:
            row['transport_error'] = f'{type(error).__name__}: {error}'
        row['elapsed_ms'] = round((time.monotonic() - start) * 1000)
        output.write(json.dumps(row, ensure_ascii=False) + '\n')
        output.flush()
        choice = row.get('response', {}).get('choices', [{}])[0]
        print(json.dumps({'index': index, 'variant': variant,
                          'finish_reason': choice.get('finish_reason'),
                          'message': choice.get('message'),
                          'transport_error': row.get('transport_error')}, ensure_ascii=False), flush=True)
