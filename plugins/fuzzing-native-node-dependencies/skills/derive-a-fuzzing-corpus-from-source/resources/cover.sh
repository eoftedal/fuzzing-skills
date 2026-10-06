#!/bin/bash
# How few seeds actually carry the coverage?  Greedy minimal cover over a maps directory.
#
#   MAPS="maps_final [maps_final_mode2 ...]" [KEEP=./corpus-min CORPUS=./corpus-final] ./cover.sh
#
# MAPS may name several directories (the per-mode maps of a swept corpus, or sweep.sh's
# maps_<base>_union): a seed's edge set is the union of its maps across them, so the cover
# is not biased towards the default mode.
#
# A very small cover means the reachable surface is nearly exhausted and further seed work is
# waste -- use it as a stop signal, not as a reason to ship only the cover (a fuzzer mutates
# what you give it, and duplicate seeds cost little).
set -uo pipefail
for kv in "$@"; do export "$kv"; done
: "${MAPS:?set MAPS}"
python3 - "${KEEP:-}" "${CORPUS:-}" $MAPS <<'PY'
import os, shutil, sys
keep, corpus, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
sets = {}
for maps in dirs:
    for m in sorted(os.listdir(maps)):
        p = os.path.join(maps, m)
        if not os.path.isfile(p) or m.startswith('.'):
            continue
        sets.setdefault(m, set()).update(l.split(':', 1)[0] for l in open(p) if ':' in l)
if not sets:
    sys.exit(f'no maps in {" ".join(dirs)}')
universe = set().union(*sets.values())
chosen, covered = [], set()
while covered != universe:
    name, edges = max(sets.items(), key=lambda kv: (len(kv[1] - covered), -len(kv[0])))
    gain = len(edges - covered)
    if gain == 0:
        break
    chosen.append((name, gain)); covered |= edges
print(f'universe        {len(universe)} edges over {len(sets)} seeds' + (f' ({len(dirs)} map dirs)' if len(dirs) > 1 else ''))
print(f'greedy cover    {len(chosen)} seeds reach all of them')
print(f'redundant       {len(sets) - len(chosen)} seeds add nothing beyond the cover')
for n, g in chosen[:25]:
    print(f'  +{g:<5} {n}')
if len(chosen) > 25:
    print(f'  ... and {len(chosen) - 25} more')
if keep and corpus:
    os.makedirs(keep, exist_ok=True)
    n = 0
    for name, _ in chosen:
        src = os.path.join(corpus, name)
        if os.path.exists(src):
            shutil.copy(src, keep); n += 1
    print(f'copied {n} cover seeds -> {keep}')
PY
