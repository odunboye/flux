"""Explicit mobile API origin and CSP policy. No insecure development exceptions."""
import html
from html.parser import HTMLParser
import ipaddress
import re
from urllib.parse import urlsplit


def api_origin(value):
    if not isinstance(value, str) or not value or value.strip() != value:
        raise ValueError('apiOrigin must be a canonical HTTPS origin')
    try:
        parsed = urlsplit(value)
        host = parsed.hostname
        port = parsed.port
        if parsed.scheme != 'https' or not host or parsed.username is not None or parsed.password is not None or parsed.path or parsed.query or parsed.fragment:
            raise ValueError()
        try:
            address = ipaddress.ip_address(host)
            authority = '[' + address.compressed + ']' if address.version == 6 else str(address)
        except ValueError:
            if host.split('.')[-1].isdigit() or re.fullmatch(r'0x[0-9a-f]+', host) or len(host) > 253 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in host.split('.')):
                raise ValueError()
            authority = host
        if port is not None and port != 443:
            if not 0 < port <= 65535:
                raise ValueError()
            authority += ':' + str(port)
        if value != 'https://' + authority:
            raise ValueError()
    except (TypeError, ValueError):
        raise ValueError('apiOrigin must be a canonical HTTPS origin without credentials, path, query or fragment') from None
    return value


class Policies(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.policies = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'meta' and (values.get('http-equiv') or '').lower() == 'content-security-policy':
            if len(values) != len(attrs) or 'content' not in values:
                raise ValueError('Ambiguous CSP meta element')
            self.policies.append((self.get_starttag_text(), values['content']))


def bind_csp(source, origin):
    api_origin(origin)
    parser = Policies()
    parser.feed(source)
    if len(parser.policies) != 1:
        raise ValueError('Format-2 mobile HTML requires exactly one CSP meta element')
    raw, policy = parser.policies[0]
    directives = {}
    for piece in policy.split(';'):
        words = piece.split()
        if not words:
            continue
        key = words[0].lower()
        if key in directives:
            raise ValueError('Duplicate CSP directive: ' + key)
        directives[key] = words[1:]
    for key, expected in [('default-src', ["'self'"]), ('script-src', ["'self'"]),
                          ('object-src', ["'none'"]), ('base-uri', ["'none'"]), ('form-action', ["'none'"])]:
        if directives.get(key) != expected:
            raise ValueError('Mobile CSP requires ' + key + ' ' + ' '.join(expected))
    if any(key in directives for key in ['script-src-elem', 'script-src-attr']):
        raise ValueError('Separate script CSP overrides are not supported')
    directives['connect-src'] = [origin]
    result = '; '.join(' '.join([key] + values) for key, values in directives.items())
    return source.replace(raw, '<meta http-equiv="Content-Security-Policy" content="' + html.escape(result, quote=True) + '">', 1)
