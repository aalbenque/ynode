#!/usr/bin/env python3

import sys
from hpack import Decoder

f=open('/dev/stdin', 'rb')
data = memoryview(f.read())
d = Decoder()
decoded_headers=d.decode(data)
for hdr in decoded_headers:
	print(f"{hdr[0]} {hdr[1]}")

exit()