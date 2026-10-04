# Frankie Brain Pack v1

Portable knowledge only. It intentionally does not contain the base model.

Folders:
- memory/verified.jsonl — verified error/fix records
- memory/failed.jsonl — failed attempts
- adapters/ — optional LoRA/adapters created later
- manifests/ — hashes, schema/model compatibility and provenance
- benchmarks/ — teacher-vs-Frankie evaluation results

Import policy: merge by fingerprint; never downgrade a higher-confidence verified record; require compatibility checks before importing adapters.
