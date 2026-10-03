#!/usr/bin/env python3
"""Experimental v1 schema -> shared Idris types, Flux server, Iris client, OpenAPI."""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path
import re

# Idris keywords, generated declarations and imported public API names.
RESERVED = set('''as auto case class codata constructor covering data default do else
export forall hiding if implementation implicit import in infix infixl infixr
interface lambda lazy let module mutual namespace of parameters partial postulate
private proof public record rewrite then total using where with
fromJSON toJSON transport status body code message call routes api preflight
json obj input output value Protocol ProtocolTypes Client RpcError RpcErrorEnvelope
Api String Bool List Int Integer Nat Either Maybe IO AppProg Handler Router
ToJSON FromJSON Cmd HttpRequest HttpResponse HttpError TransportFailure RemoteError
InvalidResponse baseUrl send decodeResponse toString
Principal Authenticator subjectId authenticate rpcAuthenticatedHandler'''.split())
TYPES = {'string': 'String', 'bool': 'Bool'}


def exact(obj, keys, label):
    if not isinstance(obj, dict) or set(obj) != set(keys):
        raise ValueError(f'{label}: expected keys {sorted(keys)}')


def identifier(value, upper=False):
    pattern = r'[A-Z][A-Za-z0-9]*' if upper else r'[a-z][A-Za-z0-9]*'
    if not isinstance(value, str) or not re.fullmatch(pattern, value) or value in RESERVED:
        raise ValueError(f'unsupported or reserved identifier: {value!r}')


def type_refs(kind, models, depth=0):
    if depth > 8:
        raise ValueError('wire type nesting exceeds eight levels')
    if isinstance(kind, str):
        if kind in TYPES:
            return set()
        if kind in models:
            return {kind}
        raise ValueError(f'unknown wire type: {kind}')
    if isinstance(kind, dict) and len(kind) == 1:
        wrapper, inner = next(iter(kind.items()))
        if wrapper in {'list', 'nullable'}:
            if wrapper == 'nullable' and isinstance(inner, dict) and 'nullable' in inner:
                raise ValueError('nested nullable types have an ambiguous wire representation')
            return type_refs(inner, models, depth + 1)
    raise ValueError('wire types must be string, bool, a named model, list, or nullable')


def model_order(models):
    visiting, visited, ordered = set(), set(), []

    def visit(name):
        if name in visiting:
            raise ValueError('recursive wire models are not supported')
        if name in visited:
            return
        visiting.add(name)
        refs = set()
        for kind in models[name].values():
            refs.update(type_refs(kind, models))
        for dependency in sorted(refs):
            visit(dependency)
        visiting.remove(name)
        visited.add(name)
        ordered.append(name)

    for name in sorted(models):
        visit(name)
    return ordered


def idris_type(kind):
    if isinstance(kind, str):
        return TYPES.get(kind, kind)
    wrapper, inner = next(iter(kind.items()))
    return ('List' if wrapper == 'list' else 'Maybe') + ' (' + idris_type(inner) + ')'


def schema_type(kind):
    if isinstance(kind, str):
        if kind in TYPES:
            return {'type': 'boolean' if kind == 'bool' else kind}
        return {'$ref': '#/components/schemas/' + kind}
    if 'list' in kind:
        return {'type': 'array', 'items': schema_type(kind['list'])}
    return {'anyOf': [schema_type(kind['nullable']), {'type': 'null'}]}


def validate(schema):
    exact(schema, ['version', 'models', 'endpoints'], 'protocol')
    if type(schema['version']) is not int or schema['version'] != 1:
        raise ValueError('only protocol version 1 is supported')
    models = schema['models']
    if not isinstance(models, dict) or not models:
        raise ValueError('models must be a nonempty object')
    for name, fields in models.items():
        identifier(name, True)
        if name.startswith('Mk'):
            raise ValueError('model name collides with generated declarations')
        if not isinstance(fields, dict) or not fields:
            raise ValueError('models require at least one named field')
        for field, kind in fields.items():
            identifier(field)
            type_refs(kind, models)
    model_order(models)
    endpoints = schema['endpoints']
    if not isinstance(endpoints, list) or not endpoints:
        raise ValueError('endpoints must be a nonempty array')
    names, paths = set(), set()
    for ep in endpoints:
        exact(ep, ['name', 'path', 'request', 'response', 'access'], 'endpoint')
        identifier(ep['name'])
        if not isinstance(ep['path'], str) or not re.fullmatch(r'/rpc/v1/[a-z][a-z0-9]*(?:/[a-z][a-z0-9]*)*', ep['path']):
            raise ValueError('endpoint requires a literal /rpc/v1/ path')
        if ep['name'] in names or ep['path'] in paths:
            raise ValueError('duplicate endpoint name or path')
        names.add(ep['name']); paths.add(ep['path'])
        for key in ['request', 'response']:
            if not isinstance(ep[key], str) or ep[key] not in models:
                raise ValueError(f'unknown {key} model')
        if ep['access'] not in ('public', 'authenticated'):
            raise ValueError('unsupported endpoint access; refusing to expose it')
    return schema


def header(module, digest):
    return [f'-- Generated protocol SHA-256: {digest}. Do not edit.', f'module {module}', '']


def wire_types(schema, digest):
    # This module is shared by both targets. Never import Flux/PG/native runtime
    # here: Iris browser builds must depend only on portable JSON codecs.
    lines = header('ProtocolTypes', digest) + ['import public JSON.Simple', '', '%default covering', '']
    for name in model_order(schema['models']):
        fields = sorted(schema['models'][name].items())
        lines += ['public export', f'record {name} where', f'  constructor Mk{name}']
        lines += [f'  {field} : {idris_type(kind)}' for field, kind in fields]
        pairs = ', '.join(f'("{field}", toJSON v.{field})' for field, _ in fields)
        lines += ['', 'export', f'ToJSON {name} where', f'  toJSON v = JObject [{pairs}]',
                  '', 'export', f'FromJSON {name} where',
                  f'  fromJSON = withObject "{name}" $ \\obj =>',
                  f'    Mk{name} <$> ' + ' <*> '.join(f'field obj "{field}"' for field, _ in fields), '']
    return '\n'.join(lines).rstrip() + '\n'


def server(schema, digest):
    lines = header('Protocol', digest) + [
        'import public ProtocolTypes', 'import public Flux.Platform.Endpoint',
        'import public Flux.Core.Router', '', '%default covering', '',
        'public export', 'record Api where', '  constructor MkApi']
    endpoints = sorted(schema['endpoints'], key=lambda ep: ep['name'])
    protected = any(ep['access'] == 'authenticated' for ep in endpoints)
    for ep in endpoints:
        principal = 'Principal -> ' if ep['access'] == 'authenticated' else ''
        lines += [f"  {ep['name']} : {principal}{ep['request']} -> AppProg {ep['response']}"]
    lines += ['', '-- Applications choose CORS policy; this supplies the preflight status.',
              'preflight : Handler', 'preflight ctx = pure (setStatus 204 ctx)',
              '', 'export',
              'routes : ' + ('Authenticator -> ' if protected else '') + 'Api -> Router Handler',
              'routes ' + ('authenticate ' if protected else '') + 'api = empty']
    for ep in endpoints:
        adapter = 'rpcAuthenticatedHandler authenticate' if ep['access'] == 'authenticated' else 'rpcHandler'
        lines += [f'  |> post "{ep["path"]}" ({adapter} api.{ep["name"]})',
                  f'  |> options_ "{ep["path"]}" preflight']
    return '\n'.join(lines).rstrip() + '\n'


def client(schema, digest):
    lines = header('Client', digest) + [
        'import public ProtocolTypes', 'import public Flux.Platform.Client',
        '', '%default covering', '']
    for ep in sorted(schema['endpoints'], key=lambda ep: ep['name']):
        lines += ['export',
                  f"{ep['name']} : {{msg : Type}} -> Client -> {ep['request']} -> (Either RpcError {ep['response']} -> msg) -> Cmd msg",
                  f"{ep['name']} client input = call client \"{ep['path']}\" input", '']
    return '\n'.join(lines).rstrip() + '\n'


def openapi(schema, digest):
    models = {name: {'type': 'object', 'required': sorted(fields),
                     'properties': {field: schema_type(kind)
                                    for field, kind in sorted(fields.items())}}
              for name, fields in sorted(schema['models'].items())}
    def ref(name):
        return {'$ref': '#/components/schemas/' + name}
    paths = {}
    for ep in sorted(schema['endpoints'], key=lambda ep: ep['path']):
        paths[ep['path']] = {'post': {'operationId': ep['name'],
            'security': [{'sessionBearer': []}] if ep['access'] == 'authenticated' else [],
            'requestBody': {'required': True, 'content': {'application/json': {'schema': ref(ep['request'])}}},
            'responses': {'200': {'description': 'Success', 'content': {'application/json': {'schema': ref(ep['response'])}}},
                          'default': {'description': 'RPC error', 'content': {'application/json': {'schema': ref('RpcErrorEnvelope')}}}}}}
    models['RpcErrorEnvelope'] = {'type': 'object', 'required': ['error'], 'properties': {
        'error': {'type': 'object', 'required': ['code', 'message'], 'properties': {
            'code': {'type': 'string'}, 'message': {'type': 'string'}}}}}
    components = {'schemas': models}
    if any(ep['access'] == 'authenticated' for ep in schema['endpoints']):
        components['securitySchemes'] = {'sessionBearer': {'type': 'http', 'scheme': 'bearer'}}
    return {'openapi': '3.1.0', 'info': {'title': 'Flux protocol', 'version': '1'},
            'x-protocol-sha256': digest, 'paths': paths, 'components': components}


def generate(schema, namespace=''):
    if not isinstance(namespace, str) or (namespace and not re.fullmatch(r'[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*', namespace)):
        raise ValueError('invalid generated module namespace')
    validate(schema)
    canonical = json.dumps(schema, sort_keys=True, separators=(',', ':'))
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    output = {'ProtocolTypes.idr': wire_types(schema, digest), 'Protocol.idr': server(schema, digest),
              'Client.idr': client(schema, digest),
              'openapi.json': json.dumps(openapi(schema, digest), sort_keys=True, indent=2) + '\n'}
    if namespace:
        for name in ['ProtocolTypes.idr', 'Protocol.idr', 'Client.idr']:
            output[name] = re.sub(r'^(module|import(?: public)?) (ProtocolTypes|Protocol|Client)$',
                                  lambda match: match[1] + ' ' + namespace + '.' + match[2], output[name], flags=re.M)
    return output


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('schema', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--check', action='store_true', help='fail if generated files differ; never write')
    parser.add_argument('--namespace', default='', help='Idris module namespace, e.g. Generated')
    parser.add_argument('--openapi', type=Path, help='separate OpenAPI output path')
    args = parser.parse_args()
    try:
        if args.schema.stat().st_size > 1024 * 1024:
            raise ValueError('schema exceeds 1 MiB')
        generated = generate(json.loads(args.schema.read_text(), object_pairs_hook=unique_object), args.namespace)
        targets = {name: (args.openapi if name == 'openapi.json' and args.openapi else args.out / name)
                   for name in generated}
        resolved = [path.resolve() for path in targets.values()]
        if args.schema.resolve() in resolved or len(set(resolved)) != len(resolved):
            raise ValueError('generated outputs overlap each other or the schema')
        for name, text in generated.items():
            target = targets[name]
            if args.check:
                if not target.is_file() or target.read_text() != text:
                    raise ValueError(f'generated output is stale: {name}')
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                    temp = Path(output.name)
                    try:
                        output.write(text.encode())
                        output.flush()
                        os.replace(temp, target)
                    finally:
                        temp.unlink(missing_ok=True)
    except (ValueError, OSError, RecursionError) as error:
        parser.exit(1, f'Generation failed: {error}\n')


if __name__ == '__main__':
    main()
