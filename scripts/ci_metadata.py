import argparse
import os
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prefix', default='v')
    parser.add_argument('--manifest', type=Path, default=Path('pubspec.yaml'))
    options = parser.parse_args()
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                      options.manifest.read_text(encoding='utf-8'), re.MULTILINE)
    if not match:
        raise SystemExit('pubspec 版本必须采用 major.minor.patch+build 格式。')
    version = match[1]
    tag = os.environ.get('GITHUB_REF_NAME', '')
    release = (os.environ.get('GITHUB_EVENT_NAME') == 'push'
               and os.environ.get('GITHUB_REF_TYPE') == 'tag'
               and re.fullmatch(re.escape(options.prefix) + r'\d+\.\d+\.\d+', tag) is not None)
    if release and tag != options.prefix + version:
        raise SystemExit('正式版本标签与 pubspec 版本不一致：' + tag + ' / ' + version)
    values = {'release': str(release).lower(), 'version': version,
              'package_version': match[0].split(':', 1)[1].strip()}
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a', encoding='utf-8') as stream:
            stream.write(''.join(name + '=' + value + '\n' for name, value in values.items()))
    print(('正式发布' if release else '测试构建') + '：' + values['package_version'])


if __name__ == '__main__':
    main()
