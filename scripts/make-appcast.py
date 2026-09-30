#!/usr/bin/env python3
"""Write the one-item Sparkle appcast for a macOS build.

    python3 scripts/make-appcast.py \
        --build 75 --short-version 1.0.0 --min-system 14.0 \
        --url https://github.com/.../RemKeys-macOS-75.zip \
        --length 1234567 --signature <base64 EdDSA signature> \
        --notes-file notes.txt --out appcast.xml

Run by deploy-macos.yml after the zip is notarized and signed. One item is
all Sparkle needs: it compares that item's `sparkle:version` with the running
app's CFBundleVersion and offers the update when it's higher. There's no
history to keep: every installed copy only ever needs the newest build.

`notes-file` holds one change per line (the push's commit subjects). They
become the list in Sparkle's update dialog. Everything is escaped here, so a
commit subject containing `<` or `&` can't break the feed.
"""

import argparse
import email.utils
import html
from xml.sax.saxutils import quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--build", required=True, help="CFBundleVersion of the build")
    parser.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--min-system", required=True, help="LSMinimumSystemVersion")
    parser.add_argument("--url", required=True, help="download URL of the zip")
    parser.add_argument("--length", required=True, type=int, help="zip size in bytes")
    parser.add_argument("--signature", required=True, help="sign_update's EdDSA signature")
    parser.add_argument("--notes-file", required=True, help="one change per line")
    parser.add_argument("--out", required=True, help="where to write appcast.xml")
    args = parser.parse_args()

    if not args.build.isdigit():
        parser.error(f"--build must be a plain integer, got {args.build!r}")

    with open(args.notes_file, encoding="utf-8") as f:
        changes = [line.strip() for line in f if line.strip()]
    # html.escape also turns any "]]>" into "]]&gt;", so no subject can close
    # the CDATA section early.
    items = "".join(f"<li>{html.escape(c)}</li>" for c in changes) or "<li>Maintenance build</li>"
    notes = f"<ul>{items}</ul>"

    title = html.escape(f"RemKeys {args.short_version} (build {args.build})")
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>RemKeys for Mac</title>
    <item>
      <title>{title}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.short_version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(args.min_system)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(args.url)} length="{args.length}" type="application/octet-stream" sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
  </channel>
</rss>
"""
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
