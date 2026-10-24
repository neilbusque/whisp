import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('notebook_mcp.py')
spec = importlib.util.spec_from_file_location('whisp_mcp', SCRIPT)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class NotebookMCPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.notebook = module.Notebook(self.temp.name)
    def tearDown(self):
        self.notebook.db.close(); self.temp.cleanup()
    def test_round_trip_and_stale_write_protection(self):
        n = self.notebook.call('save_note', {'title':'Idea','body':"I prefer quiet editors. 'quoted'"})
        memory = self.notebook.call('remember', {'content':'Prefers quiet editors.', 'source_note_id':n['id'], 'evidence':'I prefer quiet editors.'})
        self.assertEqual(memory['source_note_id'], n['id'])
        updated = self.notebook.call('update_note', {'id':n['id'], 'body':'New details', 'expected_updated_at':n['updated_at']})
        with self.assertRaises(ValueError): self.notebook.call('update_note', {'id':n['id'], 'body':'Clobber', 'expected_updated_at':n['updated_at']})
        self.assertEqual(self.notebook.call('get_note', {'id':n['id']})['notes'][0]['body'], updated['body'])
        self.assertEqual(len(self.notebook.call('search_notebook', {'query':'quiet'})['memories']), 1)
        with self.assertRaises(ValueError): self.notebook.call('remember', {'content':'Unsourced inference', 'source_note_id':n['id'], 'evidence':'Never spoken'})
        self.notebook.call('forget_memory', {'id':memory['id'], 'expected_updated_at':memory['updated_at']})
        self.assertEqual(self.notebook.call('list_memories', {}), [])
    def test_profile_backup_and_conflict(self):
        self.notebook.call('update_profile', {'profile':'My profile', 'expected_profile':''})
        with self.assertRaises(ValueError): self.notebook.call('update_profile', {'profile':'Clobber', 'expected_profile':''})
        self.assertEqual(self.notebook.call('get_profile', {})['profile'], 'My profile')
        self.assertEqual(len(list((Path(self.temp.name)/'backups').glob('*.md'))),1)
    def test_stdio_lifecycle_and_mutation(self):
        requests = [dict(jsonrpc='2.0',id=1,method='initialize',params={'protocolVersion':'2025-06-18'}),
                    dict(jsonrpc='2.0',method='notifications/initialized'),
                    dict(jsonrpc='2.0',id=2,method='tools/list'),
                    dict(jsonrpc='2.0',id=3,method='tools/call',params={'name':'save_note','arguments':{'title':'Bridge test','body':'A local test idea.'}})]
        result = subprocess.run([sys.executable, str(SCRIPT), '--profile', self.temp.name], input='\n'.join(map(json.dumps,requests))+'\n', text=True, capture_output=True, timeout=10, check=True)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(output), 3)
        self.assertEqual(output[0]['result']['protocolVersion'],'2025-06-18')
        self.assertEqual(len(output[1]['result']['tools']),10)
        self.assertFalse(output[2]['result']['isError'])
        self.assertEqual(len(self.notebook.call('search_notebook', {'query':'Bridge test'})['notes']), 1)

if __name__ == '__main__': unittest.main()
