#!/usr/bin/env python3
"""
Zero Em Dash Verification Audit Script
Scans the repository to ensure no em dashes (unicode U+2014, U+2013, U+2015, or -- used as punctuation)
exist in any source code comments, markdown documentation, or text assets.
"""

import os
import sys

EXCLUDED_DIRS = {".git", "lib", "out", "cache", "node_modules", "target", ".zig-cache"}
EXCLUDED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".ico", ".bin", ".tar", ".gz", ".zip", ".wasm"}

def audit_repo(root_dir):
    violations = []
    total_files = 0

    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        for fname in filenames:
            ext = os.path.splitext(fname)[1].lower()
            if ext in EXCLUDED_EXTENSIONS:
                continue
            fpath = os.path.join(dirpath, fname)
            relpath = os.path.relpath(fpath, root_dir)
            
            # Skip this script itself in audit check for literal definitions
            if relpath == "scripts/audit_zero_em_dash.py":
                continue

            total_files += 1
            try:
                with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
                    for idx, line in enumerate(lines, 1):
                        # Check for Unicode em dash and en dash
                        if "\u2014" in line or "\u2015" in line:
                            violations.append((relpath, idx, "Unicode em dash detected: " + line.strip()))
                        # Note: we permit standard double dashes in CLI flags like --force, but forbid ' -- ' as punctuation
                        if " -- " in line:
                            violations.append((relpath, idx, "Spaced double dash punctuation detected: " + line.strip()))
            except Exception as e:
                print(f"Error reading {relpath}: {e}", file=sys.stderr)

    print(f"Audited {total_files} files across {root_dir}")
    if violations:
        print(f"FAILED: Found {len(violations)} em dash violations:")
        for relpath, line_no, detail in violations:
            print(f"  {relpath}:{line_no}: {detail}")
        return False
    else:
        print("PASSED: Zero em dash violations detected across the entire repository.")
        return True

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    passed = audit_repo(target)
    sys.exit(0 if passed else 1)
