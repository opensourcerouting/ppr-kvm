#!/usr/bin/env python3

import os
import sys
import wget
from pathlib import Path
import hashlib

CacheFiles = [
	["frr_7.2-dev-20190827-00-gf1cc58e74-0_amd64.deb", 
	 "https://files.netdef.org/ppr/frr_7.2-dev-20190827-00-gf1cc58e74-0_amd64.deb", 
	 "a064433785bcddbb1c49a3fd687505aba20ba12a460c36829f972503b3555eb0"
	],
	["frr-sysrepo_7.2-dev-20190827-00-gf1cc58e74-0_amd64.deb", 
	"https://files.netdef.org/ppr/frr-sysrepo_7.2-dev-20190827-00-gf1cc58e74-0_amd64.deb",
	"529ddb351344503659b587d5b18cce53d63774a0221fc7fd7fcb8ab40dfefa57"
	],
	["bbb_sunflower_1080p_30fps_normal.mp4",
	"https://files.netdef.org/ppr/bbb_sunflower_1080p_30fps_normal.mp4",
	],
	["sintel-2048-surround.mp4",
	"https://files.netdef.org/ppr/sintel-2048-surround.mp4",
	],
	["ed_hd.mp4",
	"https://files.netdef.org/ppr/ed_hd.mp4",
	]
]

def sha256sum(filename):
    h  = hashlib.sha256()
    b  = bytearray(128*1024)
    mv = memoryview(b)
    with open(filename, 'rb', buffering=0) as f:
        for n in iter(lambda : f.readinto(mv), 0):
            h.update(mv[:n])
    return h.hexdigest()

CacheDir = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'cache/')

for file in CacheFiles:
	filename = os.path.join(CacheDir, file[0])
	if Path(filename).is_file():
		if len(file) > 2:
			# SHA given - verify sha256
			sha256Hash = sha256sum(filename)
			if sha256Hash == file[2]:
				# SHA matches - no need to download
				continue
			else:
				# No match on SHA - delete file (and re-download in next step)
				os.remove(filename)
		else:
			continue
	print(file[0], "needs to be downloaded")
	fileLoaded = wget.download(file[1], out=filename, bar=wget.bar_thermometer)
	print()
