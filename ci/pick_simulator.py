"""Pick the latest available iPhone, preferring a Pro Max on that runtime when requested."""
import json
import sys


def choose(devices, promax=False):
    candidates = []
    for runtime, items in devices.items():
        if "iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-") if part.isdigit())
        for item in items:
            if item.get("isAvailable") and item.get("name", "").startswith("iPhone"):
                key = (version, promax and "Pro Max" in item["name"])
                candidates.append((key, item))
    return max(candidates, key=lambda pair: pair[0])[1] if candidates else None


if __name__ == "__main__":
    device = choose(json.load(sys.stdin)["devices"], "--promax" in sys.argv)
    if device is None:
        sys.exit("No available iPhone simulator")
    print(device["udid"])
    print(f"Selected {device['name']}", file=sys.stderr)
