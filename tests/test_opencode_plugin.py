import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1] / 'hooks/cachewatch-opencode.js'
NODE = shutil.which('node') or shutil.which('bun')

DRIVER = r'''
import plugin from %(plugin)s;

const hooks = await plugin.server({ directory: "/tmp/project" });
const events = JSON.parse(process.argv[2] ?? process.env.CW_EVENTS);
for (const step of events) {
  if (step.hook === "chat.message") await hooks["chat.message"]({ sessionID: step.sessionID }, { parts: step.parts });
  else await hooks.event({ event: { type: step.type, properties: step.properties } });
}
'''


@unittest.skipIf(NODE is None, 'needs node or bun')
class OpencodePluginTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.driver = self.root / 'driver.mjs'
        self.driver.write_text(DRIVER % {'plugin': json.dumps(PLUGIN.as_uri())})

    def run_events(self, events, session='ses_abc', **env):
        subprocess.run([NODE, str(self.driver), json.dumps(events)], check=True, capture_output=True,
                       env=dict(os.environ, CACHEWATCH_DIR=str(self.state), HERDR_PANE_ID='w1:p2', **env))
        path = self.state / f'opencode-{session}.json'
        return json.loads(path.read_text()) if path.exists() else None

    def assistant(self, provider='anthropic', model='claude-sonnet-5', read=1000, write=200):
        return {'type': 'message.updated', 'properties': {'sessionID': 'ses_abc', 'info': {
            'sessionID': 'ses_abc', 'role': 'assistant', 'model': {'providerID': provider, 'modelID': model},
            'tokens': {'input': 10, 'output': 20, 'cache': {'read': read, 'write': write}}}}}

    def test_turn_lifecycle(self):
        record = self.run_events([
            {'hook': 'chat.message', 'sessionID': 'ses_abc', 'parts': [{'type': 'text', 'text': 'fix  the\nbuild'}]},
            self.assistant(),
            {'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}},
        ])
        self.assertEqual(record['agent'], 'opencode')
        self.assertEqual(record['session_id'], 'ses_abc')
        self.assertEqual(record['cwd'], '/tmp/project')
        self.assertEqual(record['title'], 'project')
        self.assertEqual(record['pane_id'], 'w1:p2')
        self.assertEqual(record['last_prompt'], 'fix the build')
        self.assertEqual(record['model'], 'claude-sonnet-5')
        self.assertEqual(record['ttl'], '5m')
        self.assertEqual(record['tokens'], 1200)
        self.assertFalse(record['active'])
        self.assertIn('at', record)

    def test_prompt_marks_session_active(self):
        record = self.run_events([
            {'hook': 'chat.message', 'sessionID': 'ses_abc', 'parts': [{'type': 'text', 'text': 'hello'}]},
        ])
        self.assertTrue(record['active'])
        self.assertNotIn('at', record)

    def test_latest_turn_wins_and_non_anthropic_uses_openai_ttl(self):
        record = self.run_events([
            self.assistant(read=5000, write=0),
            {'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}},
            self.assistant(provider='openai', model='gpt-6', read=40, write=60),
            {'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}},
        ])
        self.assertEqual(record['ttl'], 'openai')
        self.assertEqual(record['model'], 'gpt-6')
        self.assertEqual(record['tokens'], 100)

    def test_versioned_event_names_are_accepted(self):
        record = self.run_events([
            dict(self.assistant(), type='message.updated.1'),
            {'type': 'session.idle.1', 'properties': {'sessionID': 'ses_abc'}},
        ])
        self.assertEqual(record['tokens'], 1200)

    def test_idle_without_a_turn_writes_nothing(self):
        self.assertIsNone(self.run_events([{'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}}]))

    def test_session_deleted_removes_the_record(self):
        self.assertIsNone(self.run_events([
            self.assistant(),
            {'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}},
            {'type': 'session.deleted', 'properties': {'sessionID': 'ses_abc'}},
        ]))

    def test_ttl_override(self):
        record = self.run_events([
            self.assistant(),
            {'type': 'session.idle', 'properties': {'sessionID': 'ses_abc'}},
        ], CACHEWATCH_OPENCODE_TTL='1h')
        self.assertEqual(record['ttl'], '1h')

    def test_unsafe_session_id_is_ignored(self):
        self.run_events([
            {'hook': 'chat.message', 'sessionID': '../escape', 'parts': []},
        ], session='../escape')
        self.assertFalse((self.root / 'escape.json').exists())
        self.assertFalse(any(self.state.glob('*.json')) if self.state.exists() else False)


if __name__ == '__main__':
    unittest.main()
