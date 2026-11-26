"""Export named XCTest attachments into stable App Store source paths."""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-capture", "02-details", "03-history", "04-export", "05-card")
PAYWALL = "paid-01-paywall"
EXPECTED = {f"store-{lang}-{scene}" for lang in LANGUAGES for scene in SCENES} | {PAYWALL}
NAME = re.compile(r"^(store-(?:zh-Hans|zh-Hant|en)-\d{2}-[a-z-]+|paid-01-paywall)(?=[_.]|$)")
PNG = b"\x89PNG\r\n\x1a\n"


def names(folder):
    manifest = folder / "manifest.json"
    sources = {}
    if manifest.is_file():
        for test in json.loads(manifest.read_text(encoding="utf-8")):
            for attachment in test.get("attachments", []):
                original = attachment.get("suggestedHumanReadableName", "")
                exported = attachment.get("exportedFileName", "")
                source = folder / exported
                match = NAME.match(original) or NAME.match(source.name)
                if match and exported and source.resolve().is_relative_to(folder.resolve()):
                    sources[match[1]] = source
    for source in sorted(folder.rglob("*.png")):
        match = NAME.match(source.name)
        if match:
            sources.setdefault(match[1], source)
    return {name: source for name, source in sources.items()
            if source.is_file() and source.suffix.lower() == ".png" and signature(source) == PNG}


def signature(path):
    with path.open("rb") as file:
        return file.read(8)


def export(result, output):
    output.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent) as temp:
        folder = Path(temp)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(folder)], check=True)
        sources = names(folder)
        for name, path in sorted(sources.items()):
            shutil.copy2(path, output / f"{name}.png")
    missing = EXPECTED - sources.keys()
    if missing:
        sys.exit("Missing XCTest screenshots: " + ", ".join(sorted(missing)))
    print(f"Exported {len(sources)} named screenshots to {output}")


if __name__ == "__main__":
    export(*map(Path, sys.argv[1:3]))
