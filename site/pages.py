"""Writes public/privacy/ and public/support/ from PRIVACY.md and SUPPORT.md at the repo
root, so the policy has one source. Run after editing either:
    uv run --no-project --with markdown python site/pages.py
"""
import pathlib
import re

import markdown

root = pathlib.Path(__file__).resolve().parent.parent
public = root / "site" / "public"
links = {
    "PRIVACY.md": "../privacy/",
    "SUPPORT.md": "../support/",
    "README.md": "https://github.com/lprsrts/fringe#readme",
}

page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fringe · {slug}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="https://fringe.lprsrts.com/{slug}/">
<meta name="theme-color" content="#0b0d0f">
<link rel="icon" href="../assets/favicon.png" type="image/png">
<link rel="stylesheet" href="../styles.css">
</head>
<body>
<main>

<p class="top"><a href="../"><b>fringe</b></a> &nbsp;·&nbsp; {slug}</p>

{body}

<p class="sig">— alper (<a href="https://github.com/lprsrts">@lprsrts</a>)</p>

</main>
</body>
</html>
"""

for slug, source, description in [
    ("privacy", "PRIVACY.md", "fringe collects no data. nothing you do in it leaves your mac."),
    ("support", "SUPPORT.md", "how to get help with fringe, report a bug or ask a question."),
]:
    text = (root / source).read_text()
    for target, url in links.items():
        text = re.sub(rf"\]\({re.escape(target)}(#[^)]*)?\)",
                      lambda m, url=url: f"]({url if url.startswith('http') and not m.group(1) else url.split('#')[0] + (m.group(1) or '')})", text)
    body = markdown.markdown(text, extensions=["fenced_code"])
    (public / slug).mkdir(parents=True, exist_ok=True)
    (public / slug / "index.html").write_text(page.format(slug=slug, description=description, body=body))
    print(public / slug / "index.html")
