"""Write the Sparkle update feed for one Mac release to stdout:
appcast.py DMG PRIVATE_KEY_FILE VERSION BUILD DOWNLOAD_URL [NOTES.md]
NOTES.md is the version's "What's new": one "- " bullet per line, shown in the update window.
The key file holds the base64 Ed25519 seed (made once, kept outside the repo).
Needs the cryptography package (pip install cryptography)."""
import base64, os, sys
from email.utils import formatdate
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

dmg, key_file, version, build, url = sys.argv[1:6]
notes = ""
if len(sys.argv) > 6 and os.path.exists(sys.argv[6]):
    items = [l[2:].strip() for l in open(sys.argv[6]) if l.startswith("- ")]
    if items:
        notes = ("<h3>What's new in " + escape(version) + "</h3><ul>"
                 + "".join(f"<li>{escape(i)}</li>" for i in items) + "</ul>")
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
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>{f"""
      <description><![CDATA[{notes}]]></description>""" if notes else ""}
      <enclosure url="{escape(url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>""")
