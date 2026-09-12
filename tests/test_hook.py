import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / 'hooks/cachewatch-hook'


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, CACHEWATCH_DIR=str(self.root / 'state'),
                        CODEX_HOME=str(self.root / 'codex'), HERDR_PANE_ID='w1:p2')

    def run_hook(self, event, agent='codex', **extra):
        payload = dict(session_id='test-session', hook_event_name=event, cwd='/tmp/project', **extra)
        subprocess.run(['sh', str(HOOK), agent], input=json.dumps(payload), text=True,
                       env=self.env, check=True, capture_output=True)
        path = self.root / 'state' / f'{agent}-test-session.json'
        return json.loads(path.read_text()) if path.exists() else None

    def transcript(self, events):
        path = self.root / 'codex/sessions/2026/09/07/rollout-now-test-session.jsonl'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('\n'.join(json.dumps(e) for e in events))
        return str(path)

    def test_codex_lifecycle_and_latest_usage(self):
        self.transcript([
            {'type': 'turn_context', 'payload': {'model': 'gpt-6-astra'}},
            {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
                'last_token_usage': {'input_tokens': 100, 'cached_input_tokens': 50}}}},
            {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
                'total_token_usage': {'input_tokens': 9999, 'cached_input_tokens': 8888},
                'last_token_usage': {'input_tokens': 200, 'cached_input_tokens': 120}}}},
            {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': None}},
        ])
        active = self.run_hook('UserPromptSubmit', model='gpt-6-astra')
        self.assertTrue(active['active'])
        self.assertEqual(active['pane_id'], 'w1:p2')
        stopped = self.run_hook('Stop')
        self.assertFalse(stopped['active'])
        self.assertEqual(stopped['tokens'], 120)
        self.assertEqual(stopped['model'], 'gpt-6-astra')
        self.assertEqual(stopped['ttl'], 'openai')
        self.assertGreater(stopped['at'], 0)
        self.assertIsNone(self.run_hook('SessionEnd'))

    def test_model_without_transcript(self):
        self.assertEqual(self.run_hook('Stop', model='gpt-6-astra')['model'], 'gpt-6-astra')

    def test_claude_usage_unchanged(self):
        tp = self.transcript([{'message': {'model': 'claude-fable-5', 'usage': {
            'cache_read_input_tokens': 42,
            'cache_creation': {'ephemeral_1h_input_tokens': 100}}}}])
        st = self.run_hook('Stop', agent='claude', transcript_path=tp)
        self.assertEqual((st['tokens'], st['ttl'], st['auth']), (142, '1h', 'subscription'))
        self.assertEqual(st['model'], 'claude-fable-5')

    def test_zero_usage_replaces_previous(self):
        tp = self.transcript([{'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
            'last_token_usage': {'input_tokens': 200, 'cached_input_tokens': 120}}}}])
        self.run_hook('Stop', transcript_path=tp)
        self.transcript([{'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
            'last_token_usage': {'input_tokens': 200, 'cached_input_tokens': 0}}}}])
        self.assertEqual(self.run_hook('Stop', transcript_path=tp)['tokens'], 0)

    def test_cache_creation_total_does_not_double_count_one_hour_bucket(self):
        tp = self.transcript([{'message': {'usage': {
            'cache_read_input_tokens': 42, 'cache_creation_input_tokens': 100,
            'cache_creation': {'ephemeral_1h_input_tokens': 100}}}}])
        state = self.run_hook('Stop', agent='claude', transcript_path=tp)
        self.assertEqual(state['tokens'], 142)

    def test_malformed_tail_events_do_not_hide_valid_usage(self):
        tp = self.transcript([
            {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
                'last_token_usage': {'input_tokens': 200, 'cached_input_tokens': 120}}}},
            {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': 'unavailable'}},
            ['not an event object'],
        ])
        self.assertEqual(self.run_hook('Stop', transcript_path=tp)['tokens'], 120)

    def test_concurrent_hooks_publish_private_valid_records(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=8) as pool:
            states = list(pool.map(lambda _: self.run_hook('UserPromptSubmit', prompt='fixture'), range(24)))
        self.assertTrue(all(state['active'] for state in states))
        path = self.root / 'state/codex-test-session.json'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list((self.root / 'state').glob('.record-*')), [])


if __name__ == '__main__':
    unittest.main()
