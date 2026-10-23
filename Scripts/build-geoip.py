#!/usr/bin/env python3
"""Build TorrentFlow's offline country ranges from DB-IP Lite (CC BY 4.0).

Default: download the fixed October 2026 release and create Resources/GeoIP.bin.
If the official download is unavailable, use a pinned, SHA-256-verified mirror.
Use --mirror-only for a reproducible rebuild from that mirror without trying upstream.
--source accepts an already-downloaded .csv or .csv.gz; --output overrides output.
No lookup requests or user IP addresses are sent to DB-IP.
"""
import argparse
import csv
import gzip
import hashlib
import ipaddress
import json
import pathlib
import struct
import tempfile
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_URL = 'https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz'
MIRROR_COMMIT = '0446a112ca157c1cf0edae81e92da5200465505b'
MIRROR_URL = 'https://github.com/sapics/ip-location-db/tree/' + MIRROR_COMMIT + '/dbip-country'
MIRROR_FILES = (
    ('dbip-country-ipv4.csv', '0de8ddf35f4d07c93c59809d226b8e055da54cff377c69b2cfb61c5a674f55c6'),
    ('dbip-country-ipv6.csv', '18cba5a2d6cc65773e58aa779ed3fbf03037c16e5886a37f62b5b9dd687e01a7'),
)

def download(url, destination):
    # curl's total deadline also bounds a server that continuously trickles data.
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                    '--max-time', '20', '--retry', '0', '--output', str(destination), url], check=True)


def download_mirror(directory):
    combined = pathlib.Path(directory) / 'country.csv'
    with combined.open('wb') as out:
        for name, expected in MIRROR_FILES:
            source = pathlib.Path(directory) / name
            url = 'https://raw.githubusercontent.com/sapics/ip-location-db/' + MIRROR_COMMIT + '/dbip-country/' + name
            download(url, source)
            data = source.read_bytes()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError('Pinned DB-IP mirror checksum mismatch: ' + name)
            out.write(data)
            if data and not data.endswith(b'\n'):
                out.write(b'\n')
    return combined


def build(source, output, source_url=SOURCE_URL, release='2026-10'):
    source = pathlib.Path(source)
    with (gzip.open(source, 'rt', encoding='utf-8', newline='') if source.suffix == '.gz' else source.open(encoding='utf-8', newline='')) as stream:
        rows = [[], []]
        for row in csv.reader(stream):
            if not row:
                continue
            if len(row) != 3:
                raise ValueError('Expected DB-IP country CSV fields: first IP,last IP,country')
            start, end = ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1])
            country = row[2].strip().upper()
            if start.version != end.version or int(start) > int(end):
                raise ValueError('Invalid or mixed-family range')
            if len(country) != 2 or not country.isascii() or not country.isalpha():
                raise ValueError('Invalid country code')
            if country == 'ZZ':
                continue
            rows[0 if start.version == 4 else 1].append((int(start), int(end), country))
    compact = []
    for group in rows:
        group.sort()
        merged = []
        for start, end, country in group:
            if merged and start <= merged[-1][1]:
                raise ValueError('Overlapping country ranges')
            if merged and start == merged[-1][1] + 1 and country == merged[-1][2]:
                merged[-1] = (merged[-1][0], end, country)
            else:
                merged.append((start, end, country))
        compact.append(merged)
    output = pathlib.Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + '.tmp')
    with temporary.open('wb') as result:
        result.write(b'TFGEO001' + struct.pack('>QQQ', len(compact[0]), len(compact[1]), 0))
        for width, group in zip((4, 16), compact):
            for start, end, country in group:
                result.write(start.to_bytes(width, 'big') + end.to_bytes(width, 'big') + country.encode('ascii'))
    temporary.replace(output)
    provenance = dict(provider='DB-IP', dataset='IP to Country Lite', release=release, license='CC BY 4.0', source_url=source_url,
                      source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), binary_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                      ipv4_ranges=len(compact[0]), ipv6_ranges=len(compact[1]), bytes=output.stat().st_size)
    output.with_suffix('.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + '\n')
    return provenance

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path)
    parser.add_argument('--mirror-only', action='store_true', help='Use the pinned SHA-256-verified mirror directly')
    parser.add_argument('--source-url', default=SOURCE_URL, help='Provenance URL when building a verified mirror download')
    parser.add_argument('--release', default='2026-10')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'Resources' / 'GeoIP.bin')
    args = parser.parse_args()
    if args.source:
        result = build(args.source, args.output, args.source_url, args.release)
    else:
        with tempfile.TemporaryDirectory(prefix='torrentflow-geoip-') as directory:
            source = pathlib.Path(directory) / 'country.csv.gz'
            provenance_url = args.source_url
            mirror = args.mirror_only
            if not mirror:
                try:
                    download(SOURCE_URL, source)
                except (subprocess.CalledProcessError, OSError) as error:
                    print('Official DB-IP download unavailable; using the pinned mirror.', file=sys.stderr)
                    mirror = True
            if mirror:
                source = download_mirror(directory)
                provenance_url = MIRROR_URL
            result = build(source, args.output, provenance_url, args.release)
            if mirror:
                result['mirror_commit'] = MIRROR_COMMIT
                result['mirror_files'] = [dict(name=name, sha256=digest) for name, digest in MIRROR_FILES]
                args.output.with_suffix('.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
