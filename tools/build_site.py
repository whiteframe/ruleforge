import html, json, os, shutil, urllib.parse
from common import ROOT

metrics = json.load(open(ROOT / "results/metrics.json"))
pages = os.environ.get("PAGES_URL", "https://YOUR-USER.github.io/ruleforge").rstrip("/")
navigator = ("https://mitre-attack.github.io/attack-navigator/#layerURL="
             + urllib.parse.quote(f"{pages}/coverage_layer.json", safe=""))
rows = "".join(
    f"<tr><td>{html.escape(r['id'])}</td><td>{html.escape(r['title'])}</td>"
    f"<td>{r['recall']}</td><td>{r['fp_per_24h']}</td><td>{len(r['missed_runs'])}</td></tr>"
    for r in metrics["rules"])
page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>RuleForge results</title>
<style>body{{font-family:system-ui;margin:2rem auto;max-width:960px;padding:0 1rem}}
table{{border-collapse:collapse;width:100%}}th,td{{border-bottom:1px solid #ddd;padding:.4rem;text-align:left}}</style>
</head><body><h1>RuleForge nightly results</h1>
<p>Generated {metrics['generated']} · <a href="{navigator}">Open coverage in ATT&amp;CK Navigator</a></p>
<table><tr><th>Rule</th><th>Title</th><th>Recall</th><th>FP per 24 h</th><th>Missed runs</th></tr>
{rows}</table></body></html>"""

site = ROOT / "site"
site.mkdir(exist_ok=True)
(site / "index.html").write_text(page)
layer = ROOT / "results/coverage_layer.json"
if layer.exists():
    shutil.copy(layer, site / "coverage_layer.json")
print(f"Wrote {site / 'index.html'}")
