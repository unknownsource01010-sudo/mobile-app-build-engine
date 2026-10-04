# Teacher interface

Frankie Next may consult Qwen or a future coding model, but teacher output is **a proposal, not learned truth**.

Teacher response contract:
```json
{"root_cause":"...","fix":"...","verification":["..."],"confidence":0.0}
```

Promotion rule: a proposed repair enters verified memory only after its verification command(s) pass. Failed proposals are retained with low confidence to prevent repetitive retries.

No model weights are bundled here. Configure/download a compatible model separately so Frankie memory remains portable across teachers.
