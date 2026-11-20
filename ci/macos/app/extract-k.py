#!/usr/bin/env python3
"""Write K.svg: the first letter ("K", paths 1 and 2) of kmonad.svg, unchanged.
Usage: extract-k.py kmonad.svg K.svg"""
import re, sys
src = open(sys.argv[1]).read()
paths = re.findall(r'<path\b.*?/>', src, re.S)[:2]
assert len(paths) == 2, "expected the K paths in kmonad.svg"
fill = re.search(r'<svg\b[^>]*?\bfill="([^"]+)"', src, re.S).group(1)
out = ('<?xml version="1.0" encoding="UTF-8"?>\n'
       '<!-- "K" from kmonad.svg - CC-BY-SA 4.0 - https://github.com/6gk -->\n'
       f'<svg xmlns="http://www.w3.org/2000/svg" fill="{fill}" width="11.32044" height="15.527696" '
       'viewBox="0 0 11.32044 15.527696">\n  ' + '\n  '.join(paths) + '\n</svg>\n')
open(sys.argv[2], 'w').write(out)
