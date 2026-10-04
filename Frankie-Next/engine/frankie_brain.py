#!/usr/bin/env python3
"""Frankie Next repair-memory engine. Standard-library only."""
from __future__ import annotations
import argparse, hashlib, json, re, sqlite3, subprocess, time
from pathlib import Path

SCHEMA_VERSION=1

def normalize(text:str)->str:
    text=re.sub(r"(/[^\s:]+)+", "<PATH>", text)
    text=re.sub(r"\b0x[0-9a-fA-F]+\b", "<HEX>", text)
    text=re.sub(r"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+Z-]+\b", "<TIME>", text)
    return re.sub(r"\s+"," ",text).strip()

def fingerprint(error:str, toolchain:str="", platform:str="")->str:
    raw="|".join((normalize(error),toolchain.strip(),platform.strip()))
    return hashlib.sha256(raw.encode()).hexdigest()

class Brain:
    def __init__(self,path):
        self.path=Path(path); self.path.parent.mkdir(parents=True,exist_ok=True)
        self.db=sqlite3.connect(self.path)
        self.db.execute("""CREATE TABLE IF NOT EXISTS repairs(
          fingerprint TEXT, error TEXT, toolchain TEXT, platform TEXT,
          fix TEXT, verify_cmd TEXT, outcome TEXT, confidence REAL,
          teacher TEXT, created REAL, PRIMARY KEY(fingerprint,fix))""")
        self.db.commit()
    def recall(self,fp):
        return self.db.execute("""SELECT fix,verify_cmd,outcome,confidence,teacher
          FROM repairs WHERE fingerprint=? ORDER BY
          CASE outcome WHEN 'verified' THEN 0 ELSE 1 END, confidence DESC""",(fp,)).fetchall()
    def record(self,fp,error,toolchain,platform,fix,verify_cmd,outcome,confidence,teacher):
        self.db.execute("""INSERT OR REPLACE INTO repairs VALUES(?,?,?,?,?,?,?,?,?,?)""",
          (fp,normalize(error),toolchain,platform,fix,verify_cmd,outcome,float(confidence),teacher,time.time()))
        self.db.commit()
    def export_jsonl(self,out):
        rows=self.db.execute("SELECT * FROM repairs ORDER BY created").fetchall()
        cols=[d[0] for d in self.db.execute("SELECT * FROM repairs LIMIT 0").description]
        Path(out).write_text("\n".join(json.dumps(dict(zip(cols,r)),sort_keys=True) for r in rows)+("\n" if rows else ""))
    def import_jsonl(self,src):
        for line in Path(src).read_text().splitlines():
            if not line.strip(): continue
            x=json.loads(line)
            old=self.db.execute("SELECT confidence,outcome FROM repairs WHERE fingerprint=? AND fix=?",(x["fingerprint"],x["fix"])).fetchone()
            if old and old[1]=="verified" and (x.get("outcome")!="verified" or old[0]>=float(x.get("confidence",0))): continue
            self.record(x["fingerprint"],x["error"],x.get("toolchain",""),x.get("platform",""),x["fix"],x.get("verify_cmd",""),x.get("outcome","failed"),x.get("confidence",0),x.get("teacher"))
    def verify_and_record(self,error,toolchain,platform,fix,verify_cmd,teacher="manual"):
        fp=fingerprint(error,toolchain,platform)
        p=subprocess.run(verify_cmd,shell=True,text=True,capture_output=True) if verify_cmd else None
        ok=bool(p and p.returncode==0)
        self.record(fp,error,toolchain,platform,fix,verify_cmd,"verified" if ok else "failed",0.90 if ok else 0.10,teacher)
        return ok, (p.stdout+p.stderr if p else "No verification command")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--db",default="brain/frankie-next.sqlite3")
    sub=ap.add_subparsers(dest="cmd",required=True)
    f=sub.add_parser("fingerprint"); f.add_argument("error"); f.add_argument("--toolchain",default=""); f.add_argument("--platform",default="")
    r=sub.add_parser("recall"); r.add_argument("error"); r.add_argument("--toolchain",default=""); r.add_argument("--platform",default="")
    v=sub.add_parser("verify"); v.add_argument("error"); v.add_argument("--fix",required=True); v.add_argument("--verify-cmd",required=True); v.add_argument("--toolchain",default=""); v.add_argument("--platform",default=""); v.add_argument("--teacher",default="manual")
    e=sub.add_parser("export"); e.add_argument("output")
    i=sub.add_parser("import"); i.add_argument("input")
    a=ap.parse_args(); b=Brain(a.db)
    if a.cmd=="fingerprint": print(fingerprint(a.error,a.toolchain,a.platform))
    elif a.cmd=="recall": print(json.dumps(b.recall(fingerprint(a.error,a.toolchain,a.platform)),indent=2))
    elif a.cmd=="verify":
        ok,out=b.verify_and_record(a.error,a.toolchain,a.platform,a.fix,a.verify_cmd,a.teacher); print(out); raise SystemExit(0 if ok else 1)
    elif a.cmd=="export": b.export_jsonl(a.output)
    elif a.cmd=="import": b.import_jsonl(a.input)

if __name__=="__main__": main()
