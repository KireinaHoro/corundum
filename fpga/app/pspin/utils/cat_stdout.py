#!/usr/bin/env python3
from argparse import ArgumentParser
from itertools import product

NUM_CLUSTERS = 2
NUM_CORES = 8

parser = ArgumentParser(description='Parse and display PsPIN logs by core.')
parser.add_argument('--dev', type=str, help='device file to read from', default='/dev/pspin1')
parser.add_argument('--cluster', type=int, help='cluster id to read from', default=0)
parser.add_argument('--core', type=int, help='core id to read from', default=0)
parser.add_argument('--dump-files', type=bool, help='dump all cores output', default=False)
parser.add_argument('--prefix', type=str, help='file name prefix for output', default='pspin-stdout-')

args = parser.parse_args()

files = [[None] * NUM_CORES for _ in range(NUM_CLUSTERS)]
if args.dump_files:
    for cl, co in product(range(NUM_CLUSTERS), range(NUM_CORES)):
        files[cl][co] = open(f'{args.prefix}{cl}.{co}.log', 'ab+')

print(f'Printing stdout for core {args.cluster}.{args.core}')
print(f'Dump files: {"yes" if args.dump_files else "no"}')

try:
    with open(args.dev, 'rb') as f:
        while word := f.read(4):
            char, core, cluster, _ = word
            if cluster == args.cluster and core == args.core:
                print(chr(char), end='')
            if args.dump_files:
                files[cluster][core].write(char.to_bytes(1, 'little'))
except KeyboardInterrupt:
    print('Exit signal received, quitting...')

if args.dump_files:
    for cl, co in product(range(NUM_CLUSTERS), range(NUM_CORES)):
        files[cl][co].close()