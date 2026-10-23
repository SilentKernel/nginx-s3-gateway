"""Compares two Trivy JSON reports (tests/scan.sh; same file as php-74-base).

    python3 -I scripts/trivy-diff.py <candidate.json> [<published.json>]

Exit 1 when the candidate has a fixable CRITICAL (vulnerability id + package) the published image
has not; 0 otherwise (without a published report: report only).
"""
import json
import sys


def vulns(path):
    d = json.load(open(path))
    return {(v["VulnerabilityID"], v["PkgName"], v.get("Severity", "")): v.get("FixedVersion", "")
            for r in d.get("Results", []) for v in (r.get("Vulnerabilities") or [])}


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cand = vulns(argv[1])
    pub = vulns(argv[2]) if len(argv) == 3 and argv[2] else None
    crit = sorted(k for k in cand if k[2] == "CRITICAL")
    high = sorted(k for k in cand if k[2] == "HIGH")
    print("  info candidate: %d fixable CRITICAL, %d fixable HIGH" % (len(crit), len(high)))
    if pub is None:
        print("  info no published image to compare with: report only")
        return 0
    new = [k for k in crit if k not in pub]
    fixed = [k for k in pub if k not in cand]
    print("  info %d fixable HIGH/CRITICAL of the published image fixed by the candidate" % len(fixed))
    if new:
        print("  FAIL new fixable CRITICAL in the candidate:")
        for vid, pkg, _ in new:
            print("         %s in %s (fixed in %s)" % (vid, pkg, cand[(vid, pkg, "CRITICAL")]))
        return 1
    print("  ok   no fixable CRITICAL the published image does not already have")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
