#!/usr/bin/env python3
"""Convert an Altera .mif memory file into the text file that spram_sz of bram_kg.vhd reads
with XST: one word per line, in binary, MSB first, DEPTH lines (words the .mif does not give
are 0).

    mif2bin.py in.mif out.txt
"""
import re
import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    width = depth = None
    words = {}
    radix = {'ADDRESS_RADIX': 16, 'DATA_RADIX': 16}
    body = False
    for line in open(src):
        line = line.split('--')[0].strip()
        if not line:
            continue
        if not body:
            m = re.match(r'(WIDTH|DEPTH|ADDRESS_RADIX|DATA_RADIX)\s*=\s*(\w+)\s*;', line)
            if m:
                k, v = m.groups()
                if k == 'WIDTH':
                    width = int(v)
                elif k == 'DEPTH':
                    depth = int(v)
                else:
                    radix[k] = {'HEX': 16, 'DEC': 10, 'BIN': 2, 'UNS': 10}[v]
            elif line.startswith('CONTENT BEGIN'):
                body = True
            continue
        if line.startswith('END'):
            break
        m = re.match(r'(\[\s*(\w+)\s*\.\.\s*(\w+)\s*\]|(\w+))\s*:\s*(\w+)\s*;', line)
        if not m:
            sys.exit('mif2bin: cannot parse: ' + line)
        ar = radix['ADDRESS_RADIX']
        if m.group(4) is not None:
            lo = hi = int(m.group(4), ar)
        else:
            lo, hi = int(m.group(2), ar), int(m.group(3), ar)
        value = int(m.group(5), radix['DATA_RADIX'])
        for a in range(lo, hi + 1):
            words[a] = value
    if width is None or depth is None:
        sys.exit('mif2bin: no WIDTH / DEPTH')
    with open(dst, 'w') as f:
        for a in range(depth):
            f.write(format(words.get(a, 0), '0%db' % width) + '\n')


if __name__ == '__main__':
    main()
