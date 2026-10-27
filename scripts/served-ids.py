"""Identifiers of the image a registry serves, for build.sh's post-push check.

    python3 -I scripts/served-ids.py <top digest> <raw manifest json> <platform> [<child raw json>]

Prints every identifier a local Docker engine may use as the image ID of that image:
- the top-level digest (index or manifest): the image ID under the containerd image store;
- for an index, the digest of our platform's manifest;
- the config digest: the image ID under the classic image store.
For an index without <child raw json>, prints "need-child <digest>" (the caller fetches it and calls
again). The caller passes when the tested image ID is among the identifiers printed.

    docker buildx imagetools inspect <ref> --format '{{json .Manifest}}' | python3 -I served-ids.py --digest

Prints the top-level digest from buildx's answer, whatever its version: the JSON of .Manifest, the
human-readable block (old versions print it for any format starting with {{.Manifest), or a bare
digest. Fails on anything else: a guess must never reach the identifiers.
"""
import json
import re
import sys

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def top_digest(text):
    text = text.strip()
    try:
        d = json.loads(text)
        if isinstance(d, dict) and DIGEST.fullmatch(str(d.get("digest", ""))):
            return d["digest"]
    except ValueError:
        pass
    if DIGEST.fullmatch(text):
        return text
    m = re.search(r"^Digest:\s*(sha256:[0-9a-f]{64})\s*$", text, re.M)
    if m:
        return m[1]
    sys.exit("served-ids: no top-level digest in the buildx answer: " + (text.splitlines() or ["(empty)"])[0][:120])


def main(top, raw, platform, child=None):
    if not re.fullmatch(r"sha256:[0-9A-Za-z]+", top):
        sys.exit(f"served-ids: the top digest is not a digest: {top.splitlines()[0][:120] if top else '(empty)'}")
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
    if sys.argv[1:] == ["--digest"]:
        print(top_digest(sys.stdin.read()))
        sys.exit(0)
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
