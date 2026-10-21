"""Write the Sparkle update feed for one Mac release to stdout:
appcast.py DMG PRIVATE_KEY_FILE VERSION BUILD DOWNLOAD_URL
The key file holds the base64 Ed25519 seed (made once, kept outside the repo).
Needs the cryptography package (pip install cryptography)."""
import base64, os, sys
from email.utils import formatdate
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

dmg, key_file, version, build, url = sys.argv[1:6]
key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(key_file).read().strip()))
data = open(dmg, "rb").read()
signature = base64.b64encode(key.sign(data)).decode()

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>YMCA Booker</title>
    <item>
      <title>YMCA Booker {escape(version)} ({escape(build)})</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{escape(url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>""")
