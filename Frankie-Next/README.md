# Frankie Next

Experimental learning/debugging branch. **Original Frankie is not modified by this project.**

## Architecture
- Error Brain: normalized fingerprints for compiler, runtime, CI and tool errors.
- Repair Memory: root causes, attempted fixes, verification commands and outcome/confidence history.
- Teacher Adapter: Qwen-family coding model can propose explanations and repairs; its suggestions are treated as untrusted until verified.
- Repair Controller: retrieve -> rank -> propose -> apply safe repair -> test/build -> record outcome.
- Brain Pack: portable JSONL/SQLite/adapter export so verified knowledge can be imported selectively into Original Frankie.
- Benchmark Gate: compare Frankie Next against its teacher on held-out real project failures before promoting learned knowledge.

## Safety / reliability rules
1. Never overwrite Original Frankie.
2. Never record a repair as successful unless its verification command passes.
3. Preserve failed attempts so they are not blindly repeated.
4. Auto-apply only high-confidence, reversible project/build fixes.
5. Keep model weights, learned memory, credentials and project source in separate stores.
