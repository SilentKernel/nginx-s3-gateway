"""Identifiers of the image a registry serves, for build.sh's post-push check.

    python3 -I scripts/served-ids.py <top digest> <raw manifest json> <platform> [<child raw json>]

Prints every identifier a local Docker engine may use as the image ID of that image:
- the top-level digest (index or manifest): the image ID under the containerd image store;
- for an index, the digest of our platform's manifest;
- the config digest: the image ID under the classic image store.
For an index without <child raw json>, prints "need-child <digest>" (the caller fetches it and calls
again). The caller passes when the tested image ID is among the identifiers printed.
"""
import json
import sys


def main(top, raw, platform, child=None):
    manifest = json.loads(raw)
    ids = [top]
    if "manifests" in manifest:
        os_, arch = platform.split("/")[:2]
        entries = [e for e in manifest["manifests"]
                   if e.get("platform", {}).get("os") == os_ and e.get("platform", {}).get("architecture") == arch]
        if not entries:
            sys.exit(f"no {platform} manifest in the index")
        if child is None:
            print("need-child", entries[0]["digest"])
            return 0
        ids.append(entries[0]["digest"])
        manifest = json.loads(child)
    config = manifest.get("config", {}).get("digest")
    if config:
        ids.append(config)
    print("\n".join(ids))
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
