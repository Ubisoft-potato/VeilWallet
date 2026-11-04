#!/usr/bin/env python3
"""Validate stable i18n keys, native language resources and opaque arguments.

The Swift lexer tracks comments, raw/multiline strings and interpolated expressions
without evaluating them. Interface text belongs in Localizable.strings files.
"""
import argparse
import json
import plistlib
import re
from pathlib import Path

HAN = re.compile(r"[\u3400-\u9fff]")
MARKER = re.compile(r"⟦(\d+)⟧")


def unescape(text, hashes=0):
    prefix = "\\" + "#" * hashes
    pattern = re.escape(prefix) + r"(?:u\{([0-9a-fA-F]+)\}|(.))"
    values = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
    return re.sub(pattern, lambda m: chr(int(m[1], 16)) if m[1] else values.get(m[2], m[0]), text)


class SwiftStrings:
    def __init__(self, source, include_all=False):
        self.source = source
        self.nodes = []
        self.include_all = include_all

    def code(self, start=0, parenthesis=False):
        s, i, depth = self.source, start, 0
        while i < len(s):
            if s.startswith("//", i):
                end = s.find("\n", i); i = len(s) if end < 0 else end; continue
            if s.startswith("/*", i):
                nested = 1; i += 2
                while i < len(s) and nested:
                    if s.startswith("/*", i): nested += 1; i += 2
                    elif s.startswith("*/", i): nested -= 1; i += 2
                    else: i += 1
                continue
            match = re.match(r'(#*)"', s[i:]) if s[i] in '#"' else None
            if match:
                i = self.string(i, len(match[1])); continue
            if parenthesis:
                if s[i] == "(": depth += 1
                elif s[i] == ")":
                    if depth == 0: return i
                    depth -= 1
            i += 1
        if parenthesis: raise ValueError("Unclosed string interpolation")
        return i

    def string(self, start, hashes):
        s = self.source; quote = start + hashes
        count = 3 if s.startswith('"""', quote) else 1
        opening = quote + count; closing = '"' * count + "#" * hashes
        escape = "\\" + "#" * hashes
        i = opening; segment = i; segments = []; arguments = []
        while i < len(s):
            if s.startswith(closing, i):
                segments.append(unescape(s[segment:i], hashes)); end = i + len(closing)
                key = "".join(segments)
                if count == 3:
                    indent = s[s.rfind("\n", opening, i) + 1:i]
                    if indent.strip(): raise ValueError("Invalid multiline closing indentation")
                    if key.startswith("\n"): key = key[1:]
                    key = "\n".join(line[len(indent):] if line.startswith(indent) else line for line in key.split("\n"))
                    if key.endswith("\n"): key = key[:-1]
                if self.include_all or HAN.search(key): self.nodes.append(dict(start=start, end=end, key=key, arguments=arguments, source=s[start:end]))
                return end
            if s.startswith(escape, i):
                next_index = i + len(escape)
                if next_index < len(s) and s[next_index] == "(":
                    segments.append(unescape(s[segment:i], hashes)); segments.append(f"⟦{len(arguments)}⟧")
                    close = self.code(next_index + 1, parenthesis=True)
                    arguments.append(s[next_index + 1:close]); i = close + 1; segment = i; continue
                i = next_index + 1; continue
            i += 1
        raise ValueError("Unclosed Swift string")


def read_strings(path):
    values = {}
    pattern = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$')
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith('/*'): continue
        match = pattern.fullmatch(line)
        if not match: raise ValueError(f'{path.name}: invalid strings entry')
        key, value = map(json.loads, match.groups())
        if key in values: raise ValueError(f'{path.name}: duplicate key')
        values[key] = value
    return values


def split_arguments(source):
    """Split a call tail, treating strings/comments and nested expressions as opaque."""
    i = 0; start = 0; stack = []; parts = []
    lexer = SwiftStrings(source, include_all=True)
    while i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i); i = len(source) if end < 0 else end; continue
        if source.startswith('/*', i):
            level = 1; i += 2
            while i < len(source) and level:
                if source.startswith('/*', i): level += 1; i += 2
                elif source.startswith('*/', i): level -= 1; i += 2
                else: i += 1
            continue
        match = re.match(r'(#*)"', source[i:]) if source[i] in '#"' else None
        if match: i = lexer.string(i, len(match[1])); continue
        if source[i] in '([{': stack.append(source[i])
        elif source[i] in ')]}':
            if stack: stack.pop()
        elif source[i] == ',' and not stack:
            parts.append(source[start:i].strip()); start = i + 1
        i += 1
    parts.append(source[start:].strip())
    return [part for part in parts if part]


def check(root):
    resources = root/'Sources/WalletCore/Resources'
    configuration = json.loads((resources/'i18n.json').read_text())
    languages = [language['id'] for language in configuration['languages']]
    catalogs = {language: read_strings(resources/(language+'.lproj')/'Localizable.strings') for language in languages}
    default = configuration['defaultLanguage']; base = catalogs[default]; issues = []; calls = []
    info = plistlib.loads((root/'Configuration/Info.plist').read_bytes())
    if info['CFBundleDevelopmentRegion'] != default or set(info['CFBundleLocalizations']) != set(languages):
        issues.append('App language metadata does not match i18n configuration')
    package = (root/'Package.swift').read_text()
    if f'defaultLocalization: "{default}"' not in package: issues.append('Missing matching SwiftPM default localization')
    if set(catalogs) != {'en', 'zh-Hans'}: issues.append('Unexpected supported-language configuration')
    for language, values in catalogs.items():
        if set(values) != set(base): issues.append(f'{language}: catalog keys do not match')
        for key, value in values.items():
            indexes = sorted(map(int, MARKER.findall(value)))
            if indexes != list(range(len(indexes))): issues.append(f'{language}: invalid argument indexes')
            if MARKER.findall(value) and sorted(MARKER.findall(value)) != sorted(MARKER.findall(base.get(key,''))):
                issues.append(f'{language}: placeholder mismatch')
            if language == 'en' and key != 'language.simplified_chinese' and HAN.search(value):
                issues.append('Unexpected Han text in English catalog')
    if any(key not in base for key in configuration['aliases'].values()): issues.append('Alias points to missing key')
    if (resources/'localization-en.json').exists(): issues.append('Obsolete phrase-key catalog remains')
    for path in sorted((root/'Sources').rglob('*.swift')):
        source = path.read_text(); lexer = SwiftStrings(source, include_all=True); lexer.code()
        name = path.relative_to(root).as_posix()
        for node in lexer.nodes:
            line = source.count('\n',0,node['start'])+1
            if HAN.search(node['key']): issues.append(f'{name}:{line}: hardcoded translated text')
            before = source[:node['start']]
            if name.startswith('Sources/VeilWallet/') and re.search(r'[A-Za-z]', node['key']):
                if re.search(r'\b(?:Text|Label|Button|TextField|SecureField|ReviewDetail)\(\s*$|(?:eyebrow|title|subtitle):\s*$', before):
                    issues.append(f'{name}:{line}: interface literal must use a resource key')
            if not re.search(r'\bL\(\s*$', before): continue
            if node['arguments']: issues.append(f'{name}:{line}: use a stable message key'); continue
            close = SwiftStrings(source).code(node['end'], parenthesis=True)
            arguments = split_arguments(source[node['end']:close])
            key = node['key']; calls.append(dict(file=name,line=line,key=key,arguments=len(arguments)))
            if key not in base: issues.append(f'{name}:{line}: unknown message key')
            elif len(arguments) != len(MARKER.findall(base[key])): issues.append(f'{name}:{line}: incorrect argument count')
    return dict(languages=languages,keys=len(base),sourceCalls=len(calls),issues=issues),calls


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path, help='Optional sanitized call-site report')
    args = parser.parse_args()
    report,calls = check(args.root)
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(dict(**report,calls=calls),indent=2)+'\n')
    if report['issues']: raise SystemExit('\n'.join(report['issues']))
    print(f"I18n checked: {report['keys']} matching keys in {len(report['languages'])} native catalogs, {report['sourceCalls']} calls; no hardcoded translated text")


if __name__ == '__main__': main()
