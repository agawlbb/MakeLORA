import os
import unittest
from unittest.mock import patch
import check_testflight as release


class SoleTesterTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {'TESTFLIGHT_TESTER_EMAIL': 'tester@example.invalid'})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.group = {'id': 'group', 'attributes': {'name': 'Internal Testing', 'isInternalGroup': True, 'publicLinkEnabled': False}}
        self.tester = {'id': 'tester', 'attributes': {'email': 'tester@example.invalid'}}

    def test_existing_private_group(self):
        def api(path, body=None):
            self.assertIsNone(body)
            return {'data': [self.group] if '/betaGroups?' in path else [self.tester]}
        with patch.object(release, 'request', side_effect=api):
            self.assertEqual(release.sole_tester_group('app')['id'], 'group')

    def test_other_tester_stops_before_assignment(self):
        with patch.object(release, 'request', side_effect=[{'data': [self.group]}, {'data': [{'id': 'other', 'attributes': {'email': 'other@example.invalid'}}]}]) as request:
            with self.assertRaisesRegex(SystemExit, 'Remove other testers'):
                release.sole_tester_group('app')
            self.assertTrue(all(call.args[1:] == () for call in request.call_args_list))

    def test_public_link_stops_before_assignment(self):
        self.group['attributes']['publicLinkEnabled'] = True
        with patch.object(release, 'request', return_value={'data': [self.group]}) as request:
            with self.assertRaisesRegex(SystemExit, 'Disable public'):
                release.sole_tester_group('app')
            self.assertEqual(request.call_count, 1)

    def test_create_group_and_add_only_requested_existing_tester(self):
        assigned = False
        def api(path, body=None):
            nonlocal assigned
            if path == 'apps/app/betaGroups?limit=200': return {'data': []}
            if path == 'betaGroups':
                self.assertTrue(body['data']['attributes']['isInternalGroup'])
                self.assertFalse(body['data']['attributes']['publicLinkEnabled'])
                return {'data': self.group}
            if path == 'betaGroups/group/betaTesters?limit=200': return {'data': [self.tester] if assigned else []}
            if path.startswith('betaTesters?'): return {'data': [self.tester]}
            if path == 'betaGroups/group/relationships/betaTesters':
                self.assertEqual(body, {'data': [{'type': 'betaTesters', 'id': 'tester'}]})
                assigned = True
                return {}
            self.fail('Unexpected API operation: ' + path)
        with patch.object(release, 'request', side_effect=api):
            self.assertEqual(release.sole_tester_group('app')['id'], 'group')
            self.assertTrue(assigned)

    def test_email_filter_must_match_exact_address(self):
        other = {'id': 'other', 'attributes': {'email': 'not-tester@example.invalid'}}
        self.assertEqual(release.select_tester([other, self.tester], 'tester@example.invalid'), self.tester)
        self.assertIsNone(release.select_tester([other], 'tester@example.invalid'))

    def test_duplicate_email_prefers_existing_internal_tester(self):
        external = {'id': 'a-external', 'attributes': {'email': 'tester@example.invalid'}}
        with patch.object(release, 'all_items', side_effect=[[], [self.group]]):
            self.assertEqual(release.select_tester([external, self.tester], 'tester@example.invalid'), self.tester)

    def test_duplicate_internal_records_select_only_one_identity(self):
        second = {'id': 'z-second', 'attributes': {'email': 'TESTER@example.invalid'}}
        with patch.object(release, 'all_items', return_value=[self.group]):
            self.assertEqual(release.select_tester([second, self.tester], 'tester@example.invalid'), self.tester)


if __name__ == '__main__':
    unittest.main()
