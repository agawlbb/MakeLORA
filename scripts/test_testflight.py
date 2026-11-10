import os
import unittest
from unittest.mock import patch
import check_testflight as release


class SoleTesterTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {'TESTFLIGHT_TESTER_EMAIL': 'tester@example.invalid', 'VERIFY_EXISTING': 'false'})
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

    def test_empty_group_allows_build_but_not_distribution(self):
        def api(path, body=None):
            self.assertIsNone(body)
            return {'data': [self.group] if path.startswith('apps/') else []}
        with patch.object(release, 'request', side_effect=api):
            self.assertEqual(release.sole_tester_group('app', require_tester=False), self.group)
            with self.assertRaisesRegex(SystemExit, 'Internal tester assignment'):
                release.sole_tester_group('app')

    def test_email_must_match_exactly_in_group(self):
        other = {'id': 'other', 'attributes': {'email': 'not-tester@example.invalid'}}
        with patch.object(release, 'request', side_effect=[{'data': [self.group]}, {'data': [other]}]):
            with self.assertRaisesRegex(SystemExit, 'Remove other testers'):
                release.sole_tester_group('app')

    def test_create_empty_private_internal_group(self):
        def api(path, body=None):
            if path.startswith('apps/'): return {'data': []}
            if path == 'betaGroups':
                self.assertTrue(body['data']['attributes']['isInternalGroup'])
                self.assertFalse(body['data']['attributes']['publicLinkEnabled'])
                return {'data': self.group}
            return {'data': []}
        with patch.object(release, 'request', side_effect=api):
            self.assertEqual(release.sole_tester_group('app', require_tester=False), self.group)

    def test_populated_internal_group_preferred_over_empty_named_group(self):
        populated = {'id': 'populated', 'attributes': {'name': 'Other internal group', 'isInternalGroup': True, 'publicLinkEnabled': False}}
        def api(path, body=None):
            self.assertIsNone(body)
            if path.startswith('apps/'): return {'data': [self.group, populated]}
            return {'data': [self.tester] if '/populated/' in path else []}
        with patch.object(release, 'request', side_effect=api):
            self.assertEqual(release.sole_tester_group('app'), populated)


if __name__ == '__main__':
    unittest.main()
