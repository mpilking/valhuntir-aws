#!/usr/bin/env bash
# Print the cast salt states that failed, from cast's results log. Some failures
# are expected on a headless cloud box (see packer/README.md); review the rest.
python3 - <<'PY'
import yaml
def failed(x):
    if isinstance(x, dict):
        if x.get("result") is False:
            yield x
        for v in x.values():
            yield from failed(v)
    elif isinstance(x, list):
        for v in x:
            yield from failed(v)
results = yaml.safe_load(open("/var/cache/cast/installer/logs/results.yaml"))
states = list(failed(results))
for f in states:
    print("cast failed state:", f.get("__id__"), "|", str(f.get("comment"))[:120])
print("cast failed states:", len(states))
PY
