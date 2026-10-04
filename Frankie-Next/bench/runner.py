#!/usr/bin/env python3
import json, subprocess, sys, time
from pathlib import Path

def run_case(case):
    start=time.time()
    p=subprocess.run(case["command"],shell=True,text=True,capture_output=True,timeout=case.get("timeout",120))
    return {"name":case["name"],"passed":p.returncode==case.get("expected_exit",0),"seconds":round(time.time()-start,3),"output":(p.stdout+p.stderr)[-4000:]}

cases=json.loads(Path(sys.argv[1]).read_text())
results=[run_case(c) for c in cases]
print(json.dumps({"passed":sum(x["passed"] for x in results),"total":len(results),"results":results},indent=2))
raise SystemExit(0 if all(x["passed"] for x in results) else 1)
