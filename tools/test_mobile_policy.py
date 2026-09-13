import unittest
import mobile_policy

POLICY = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'"
HTML = '<meta http-equiv="Content-Security-Policy" content="' + POLICY + '"><script src="app.js"></script>'


class PolicyTests(unittest.TestCase):
    def test_canonical_https_only(self):
        for origin in ['https://api.example.com', 'https://localhost:8443', 'https://127.0.0.1:9443', 'https://[::1]:9443']:
            self.assertEqual(mobile_policy.api_origin(origin), origin)
        for origin in ['', None, 'http://localhost:8080', 'https://user:pass@example.com',
                       'https://api.example.com/', 'https://API.example.com', 'https://example.com:443',
                       'https://example.com?x=1', 'https://example.com#fragment', 'https://example.com:0',
                       'https://example.com\n', 'https://127.1', 'https://2130706433', 'https://0x7f000001',
                       'https://example..com', 'https://example.com.evil/path']:
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                mobile_policy.api_origin(origin)

    def test_explicit_connect_policy_only(self):
        result = mobile_policy.bind_csp(HTML, 'https://api.example.com')
        parsed = mobile_policy.Policies(); parsed.feed(result)
        self.assertIn('connect-src https://api.example.com', parsed.policies[0][1])
        self.assertIn("script-src 'self'", parsed.policies[0][1])
        self.assertNotIn("connect-src 'self'", parsed.policies[0][1])

    def test_ambiguous_or_unsafe_policy_rejected(self):
        for source in ['<main>No policy</main>', HTML + HTML,
                       HTML.replace("script-src 'self'", "script-src *"),
                       HTML.replace("script-src 'self'", "script-src 'self'; script-src-elem *"),
                       HTML.replace("connect-src 'self'", "connect-src 'self'; connect-src *")]:
            with self.assertRaises(ValueError):
                mobile_policy.bind_csp(source, 'https://api.example.com')


if __name__ == '__main__':
    unittest.main()
