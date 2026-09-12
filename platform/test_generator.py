import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from generate import generate, unique_object

ROOT = Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / 'example/schema.json').read_text())


class GeneratorTests(unittest.TestCase):
    def test_deterministic(self):
        self.assertEqual(generate(SCHEMA), generate(json.loads(json.dumps(SCHEMA, sort_keys=True))))

    def test_single_field_record_is_object(self):
        files = generate(SCHEMA)
        self.assertIn('withObject "CreateTodoRequest"', files['ProtocolTypes.idr'])
        self.assertIn('toJSON v = JObject [("title", toJSON v.title)]', files['ProtocolTypes.idr'])

    def test_flux_ui_client_has_no_server_dependencies(self):
        files = generate(SCHEMA)
        self.assertEqual(set(files), {'Protocol.idr', 'ProtocolTypes.idr', 'Client.idr', 'openapi.json'})
        self.assertIn('Either RpcError TodoResponse -> msg) -> Cmd msg', files['Client.idr'])
        self.assertNotIn('Flux.Core', files['Client.idr'])
        self.assertNotIn('Flux.Platform.Endpoint', files['Client.idr'])
        self.assertNotIn('Flux.', files['ProtocolTypes.idr'])
        self.assertNotIn('Idris2_pg', files['ProtocolTypes.idr'])
        self.assertIn('options_ "/rpc/v1/todos/create" preflight', files['Protocol.idr'])

    def test_openapi_matches_routes(self):
        spec = json.loads(generate(SCHEMA)['openapi.json'])
        ep = spec['paths']['/rpc/v1/todos/create']['post']
        self.assertEqual(ep['security'], [])
        self.assertEqual(ep['operationId'], 'createTodo')
        self.assertEqual(spec['components']['schemas']['TodoResponse']['properties']['id'], {'type': 'string'})

    def test_unsupported_types_rejected(self):
        for kind in ['Integer', 'number', 'optional', 'password', {}, None]:
            schema = copy.deepcopy(SCHEMA)
            schema['models']['CreateTodoRequest']['title'] = kind
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                generate(schema)

    def test_named_lists_and_nullable_types(self):
        schema = copy.deepcopy(SCHEMA)
        schema['models']['AContainer'] = {
            'items': {'list': {'nullable': 'TodoResponse'}},
            'nextId': {'nullable': 'string'},
        }
        files = generate(schema)
        source = files['ProtocolTypes.idr']
        self.assertLess(source.index('record TodoResponse'), source.index('record AContainer'))
        self.assertIn('items : List (Maybe (TodoResponse))', source)
        self.assertIn('nextId : Maybe (String)', source)
        specs = json.loads(files['openapi.json'])['components']['schemas']
        self.assertEqual(specs['AContainer']['required'], ['items', 'nextId'])
        self.assertEqual(specs['AContainer']['properties']['items']['items']['anyOf'],
                         [{'$ref': '#/components/schemas/TodoResponse'}, {'type': 'null'}])

    def test_recursive_models_rejected(self):
        for fields in [{'self': 'Recursive'}, {'children': {'list': 'Recursive'}}]:
            schema = copy.deepcopy(SCHEMA)
            schema['models']['Recursive'] = fields
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, 'recursive'):
                generate(schema)
        schema['models']['Recursive'] = {'other': 'Other'}
        schema['models']['Other'] = {'back': {'nullable': 'Recursive'}}
        with self.assertRaisesRegex(ValueError, 'recursive'):
            generate(schema)

    def test_invalid_composite_types(self):
        for kind in [{'list': 'Missing'}, {'optional': 'string'},
                     {'list': 'string', 'nullable': 'bool'}, {'nullable': {'nullable': 'string'}}]:
            schema = copy.deepcopy(SCHEMA)
            schema['models']['CreateTodoRequest']['title'] = kind
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                generate(schema)

    def test_type_depth_bounded(self):
        schema = copy.deepcopy(SCHEMA)
        kind = 'string'
        for _ in range(10):
            kind = {'list': kind}
        schema['models']['CreateTodoRequest']['title'] = kind
        with self.assertRaisesRegex(ValueError, 'nesting'):
            generate(schema)

    def test_full_crud_schema(self):
        schema = json.loads((ROOT / 'crud/schema.json').read_text())
        files = generate(schema)
        for name in ['createTodo', 'getTodo', 'listTodos', 'updateTodo', 'toggleTodo', 'deleteTodo']:
            self.assertIn(f'{name} : {{msg : Type}} -> Client ->', files['Client.idr'])
        self.assertEqual(len(json.loads(files['openapi.json'])['paths']), 6)

    def test_authentication_fails_closed(self):
        schema = copy.deepcopy(SCHEMA)
        schema['endpoints'][0]['access'] = 'authenticated'
        with self.assertRaisesRegex(ValueError, 'refusing to expose'):
            generate(schema)

    def test_duplicate_endpoints(self):
        schema = copy.deepcopy(SCHEMA)
        schema['endpoints'].append(copy.deepcopy(schema['endpoints'][0]))
        with self.assertRaises(ValueError):
            generate(schema)

    def test_unsafe_names_and_paths(self):
        for value in ['../bad', "bad'", 'x\nmain', 'class', 'toString', 'transport']:
            schema = copy.deepcopy(SCHEMA)
            schema['endpoints'][0]['name'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                generate(schema)
        for path in ['https://evil.example/', '/rpc/v1/:id', '/rpc/v2/create', '/rpc/v1/create?x=1']:
            schema = copy.deepcopy(SCHEMA)
            schema['endpoints'][0]['path'] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                generate(schema)

    def test_reserved_model(self):
        for name in ['String', 'RpcErrorEnvelope', 'Api', 'MkTodo']:
            schema = copy.deepcopy(SCHEMA)
            schema['models'][name] = {'title': 'string'}
            with self.subTest(name=name), self.assertRaises(ValueError):
                generate(schema)

    def test_unknown_model(self):
        schema = copy.deepcopy(SCHEMA)
        schema['endpoints'][0]['response'] = 'Missing'
        with self.assertRaises(ValueError):
            generate(schema)

    def test_unknown_keys_and_versions(self):
        schema = copy.deepcopy(SCHEMA)
        schema['extra'] = True
        with self.assertRaises(ValueError):
            generate(schema)
        for version in [True, '1', 0, 2]:
            schema = copy.deepcopy(SCHEMA)
            schema['version'] = version
            with self.subTest(version=version), self.assertRaises(ValueError):
                generate(schema)

    def test_duplicate_json_keys(self):
        with self.assertRaises(ValueError):
            json.loads('{"version":1,"version":2}', object_pairs_hook=unique_object)

    def test_cli_check_and_rejection_preserve_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / 'generated'
            cmd = [sys.executable, str(ROOT / 'generate.py'), str(ROOT / 'example/schema.json'), '--out', str(out)]
            subprocess.run(cmd, check=True, capture_output=True)
            subprocess.run(cmd + ['--check'], check=True, capture_output=True)
            (out / 'Client.idr').write_text('sentinel')
            self.assertNotEqual(subprocess.run(cmd + ['--check'], capture_output=True).returncode, 0)
            invalid = Path(temporary) / 'bad.json'
            invalid.write_text('{"version":2}')
            cmd[2] = str(invalid)
            self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
            self.assertEqual((out / 'Client.idr').read_text(), 'sentinel')


if __name__ == '__main__':
    unittest.main()
