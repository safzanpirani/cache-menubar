#!/usr/bin/env python3
"""Enable and trust only our registered hooks using Codex's own config API."""
import json
import os
import queue
import shlex
import shutil
import subprocess
import threading


def configure():
    if not shutil.which('codex'):
        raise RuntimeError('Codex is not on PATH; install it and rerun the installer')
    proc = subprocess.Popen(['codex', 'app-server'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    messages = queue.Queue()

    def read():
        for line in proc.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    threading.Thread(target=read, daemon=True).start()
    sequence = 0

    def request(method, params):
        nonlocal sequence
        sequence += 1
        proc.stdin.write(json.dumps({'id': sequence, 'method': method, 'params': params}) + '\n')
        proc.stdin.flush()
        while True:
            message = messages.get(timeout=30)
            if message is None:
                raise RuntimeError('Codex app-server exited')
            if message.get('id') == sequence:
                if 'error' in message:
                    raise RuntimeError(str(message['error']))
                return message['result']

    try:
        init = request('initialize', {'clientInfo': {'name': 'cachewatch_install', 'version': '1'},
                                     'capabilities': {'experimentalApi': True}})
        hook_path = os.path.join(init['codexHome'], 'hooks.json')
        expected = [os.path.expanduser('~/.local/bin/cachewatch-hook'), 'codex']

        def entries():
            result = request('hooks/list', {'cwds': [os.path.expanduser('~')]})
            return [h for group in result['data'] for h in group['hooks']
                    if h.get('sourcePath') == hook_path
                    and shlex.split(h.get('command') or '') == expected]

        hooks = entries()
        if {h['eventName'] for h in hooks} != {'userPromptSubmit', 'stop', 'sessionEnd'}:
            raise RuntimeError('Codex did not load the three cachewatch hooks')
        edits = [{'keyPath': 'features.hooks', 'value': True, 'mergeStrategy': 'replace'}]
        for hook in hooks:
            key = 'hooks.state.' + json.dumps(hook['key'])
            for field, value in [('enabled', True), ('trusted_hash', hook['currentHash'])]:
                edits.append({'keyPath': key + '.' + field, 'value': value, 'mergeStrategy': 'replace'})
        result = request('config/batchWrite', {'edits': edits})
        if result['status'] != 'ok':
            raise RuntimeError('Codex hook settings are overridden by another config layer')
        hooks = entries()
        if not all(h['enabled'] and h['trustStatus'] == 'trusted' for h in hooks):
            raise RuntimeError('Cachewatch hooks are not enabled and trusted')
        print('Codex: all three cachewatch hooks enabled and trusted; reopen existing sessions to load changes')
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == '__main__':
    configure()
