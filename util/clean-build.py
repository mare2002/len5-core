#!/usr/bin/env python3
"""Remove build outputs while preserving the configured Spike library cache."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def clean_build(build, keep):
    build, keep = Path(build).resolve(), Path(keep).resolve()
    if build == ROOT or build in ROOT.parents or build == keep:
        raise ValueError('Build directory must be separate from source and Spike cache')
    if not build.exists():
        return
    if not build.is_dir():
        raise ValueError('Build directory is not a directory: ' + str(build))

    def remove(path):
        if path == keep:
            return
        if path.is_symlink():
            path.unlink()
        elif path in keep.parents:
            for child in path.iterdir():
                remove(child)
        elif path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()

    for child in build.iterdir():
        remove(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--keep', type=Path, required=True)
    args = parser.parse_args()
    try:
        clean_build(args.build_dir, args.keep)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
