#!/usr/bin/env python3
"""Check repository documentation without reading wallet data or following symlinks."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
ABSOLUTE = re.compile(r'(?<![\w:/.[\]\x27{}])(?:~[/\\]|[A-Za-z]:[/\\]|/)[\w.@~-]+(?:[/\\][\w.@~+()-]+)*')
URL = re.compile(r'(?:https?|socks5h?)://[^\s<>`"\)]+')
LINK = re.compile(r'!?\[[^\]]*\]\(([^\s]+?)(?:\s+"[^"]*")?\)')
HAN = re.compile(r'[\u3400-\u9fff]')


def owned(path):
    return not (path.startswith(('Vendor/', 'Configuration/Licenses/', 'Tools/PrivacyProof/node_modules/'))
                or path.endswith(('LICENSE.md', 'LICENSE.txt', 'NOTICE.txt'))
                or path.startswith('Configuration/'))


def inspect_text(name, text, root=ROOT):
    issues = []
    for line_number, line in enumerate(text.splitlines(), 1):
        normalized = line.replace('\\/', '/')
        if ABSOLUTE.search(URL.sub('', normalized)) or 'file://' in normalized:
            issues.append(dict(file=name, line=line_number, rule='absolute filesystem path'))
        if name.endswith('.md') and HAN.search(line):
            issues.append(dict(file=name, line=line_number, rule='non-English primary documentation'))
        if name.endswith('.md'):
            for match in LINK.finditer(line):
                target = match[1].strip('<>')
                if re.match(r'[a-zA-Z][\w+.-]*:', target) or target.startswith('#'): continue
                if target.startswith(('/', '~', '\\')):
                    issues.append(dict(file=name, line=line_number, rule='absolute Markdown link')); continue
                destination = (root/Path(name).parent/unquote(target.split('#', 1)[0])).resolve()
                if not destination.is_relative_to(root.resolve()) or not destination.exists():
                    issues.append(dict(file=name, line=line_number, rule='missing or escaping relative link'))
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    files = sorted({n for n in names if n and (Path(n).suffix.lower() in {'.md','.rst','.adoc','.txt'} or n.startswith('Documentation/') and n.endswith('.json'))})
    issues = []; retained = []; reviewed = 0
    for name in files:
        path = ROOT/name
        if path.is_symlink():
            issues.append(dict(file=name, line=0, rule='documentation symlink')); continue
        if not path.is_file(): continue
        reviewed += 1
        findings = inspect_text(name, path.read_text(errors='replace'))
        if owned(name): issues.extend(findings)
        elif findings: retained.append(dict(file=name, findings=len(findings), reason='upstream/license content preserved'))
    report = dict(filesReviewed=reviewed, ownedIssues=issues, preservedThirdParty=retained,
                  scope='Tracked and non-ignored documentation; repository-relative links; URLs are not filesystem paths')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(bool(issues))


if __name__ == '__main__': main()
