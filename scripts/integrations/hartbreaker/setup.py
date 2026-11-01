#!/usr/bin/env python3
"""Install the pinned four-hart BlackParrot target into a HartBreaker checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PACKAGE = Path(__file__).resolve().parent


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(checkout: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ['git', '-C', str(checkout), *arguments], text=True, stderr=subprocess.PIPE
    ).strip()


def changed_paths(checkout: Path) -> set[str]:
    tracked = git(checkout, 'diff', '--name-only', 'HEAD').splitlines()
    untracked = git(checkout, 'ls-files', '--others', '--exclude-standard').splitlines()
    return set(tracked + untracked)


def matches_adapted_source(checkout: Path, expected: dict) -> bool:
    return all((checkout / name).is_file() and digest(checkout / name) == wanted
               for name, wanted in expected.items())


def prepare_checkout(checkout: Path, metadata: dict, patch: Path) -> str:
    if Path(git(checkout, 'rev-parse', '--show-toplevel')).resolve() != checkout:
        raise ValueError('--hartbreaker must name the root of its Git checkout')
    revision = git(checkout, 'rev-parse', 'HEAD')
    if revision not in (metadata['upstream_revision'], metadata['adapted_revision']):
        raise ValueError('HartBreaker HEAD differs from the pinned upstream/adapted revision')
    expected = metadata['adapted_files']
    modified = changed_paths(checkout)
    unrelated = modified - expected.keys()
    if unrelated:
        raise ValueError('unrelated HartBreaker changes would make setup ambiguous: '
                         + ', '.join(sorted(unrelated)))
    if matches_adapted_source(checkout, expected):
        return 'already-installed'
    if modified or revision != metadata['upstream_revision']:
        raise ValueError('modified target source differs from the pinned adaptation; preserve it separately')
    git(checkout, 'apply', '--unidiff-zero', '--check', str(patch))
    git(checkout, 'apply', '--unidiff-zero', str(patch))
    if not matches_adapted_source(checkout, expected):
        raise ValueError('applied target does not match the recorded source hashes')
    return 'installed'


def install(checkout: Path, simulators: Path, simulator: Path) -> dict:
    metadata = json.loads((PACKAGE / 'source.json').read_text())
    patch = PACKAGE / 'blackparrot-fourhart.patch'
    if digest(patch) != metadata['patch_sha256']:
        raise ValueError('bundled HartBreaker patch differs from source.json')
    config = json.loads((PACKAGE / 'cfg.json').read_text())
    config['simname'] = str(simulator)
    destination = simulators / metadata['design'] / 'cfg.json'
    if destination.exists() and json.loads(destination.read_text()) != config:
        raise ValueError(f'existing simulator configuration differs; preserve it separately: {destination}')
    result = prepare_checkout(checkout, metadata, patch)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(config, indent=2) + '\n')
    return {'target': metadata['design'], 'source_status': result,
            'hartbreaker': str(checkout), 'upstream_revision': metadata['upstream_revision'],
            'adapted_revision': metadata['adapted_revision'], 'cfg': str(destination),
            'simulator': str(simulator), 'hartids': config['hartids']}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hartbreaker', required=True, type=Path)
    parser.add_argument('--simulators', required=True, type=Path)
    parser.add_argument('--simulator', required=True, type=Path,
                        help='planned or existing BlackParrot Verilator model path')
    args = parser.parse_args()
    try:
        result = install(args.hartbreaker.resolve(strict=True), args.simulators.resolve(),
                         args.simulator.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, f'HartBreaker target setup failed: {error}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
