"""Render docs/SPEC.md to docs/SPEC.pdf.

Usage: python tools/spec_pdf.py

Needs the `markdown` package (pip install markdown) and Chrome or Edge, which prints the page headlessly.
The PDF is only a convenience copy; docs/SPEC.md is the source.
"""
import os, sys, shutil, pathlib, subprocess, tempfile
import markdown

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "SPEC.md"
OUT = ROOT / "docs" / "SPEC.pdf"
BROWSERS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "google-chrome", "chromium", "chromium-browser", "microsoft-edge",
]
CSS = """
@page { size: Letter; margin: 18mm 16mm; }
body { font: 10.5pt/1.45 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; color: #1a1a1a; }
h1 { font-size: 20pt; margin: 0 0 4pt; }
h2 { font-size: 14pt; margin: 18pt 0 6pt; border-bottom: 1px solid #ccc; padding-bottom: 2pt; }
table { border-collapse: collapse; width: 100%; font-size: 8.5pt; margin: 6pt 0 10pt; }
th, td { border: 1px solid #bbb; padding: 3pt 5pt; vertical-align: top; text-align: left; }
th { background: #eee; }
tr { break-inside: avoid; }
code { font: 8.5pt Consolas, "DejaVu Sans Mono", monospace; background: #f3f3f3; padding: 0 2px; }
pre { background: #f3f3f3; padding: 6pt; font-size: 8.5pt; white-space: pre-wrap; }
pre code { padding: 0; }
a { color: #1a1a1a; }
"""

def find_browser():
    for b in BROWSERS:
        path = b if os.path.isabs(b) else shutil.which(b)
        if path and os.path.exists(path):
            return path
    sys.exit("Chrome or Edge not found")

def main():
    body = markdown.markdown(SRC.read_text(encoding="utf-8"), extensions=["tables", "fenced_code"])
    html = f'<!doctype html><html><head><meta charset="utf-8"><title>ΔV Co-op Mod Spec</title><style>{CSS}</style></head><body>{body}</body></html>'
    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "spec.html"
        page.write_text(html, encoding="utf-8")
        subprocess.run([find_browser(), "--headless", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={tmp}/profile", f"--print-to-pdf={OUT}", page.as_uri()],
                       check=True, capture_output=True)
    print(f"wrote {OUT}")

if __name__ == "__main__":
    main()
