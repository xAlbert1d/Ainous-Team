---
last_updated: null
---

# Authority Decision Log

Chronological record of all authority decisions. Each entry records who asked, what they wanted, and what was decided.

Format for each decision (CRITICAL — enforcement script parses these fields):

```
## AUTH-<NNN>
- **role:** <requesting role name>
- **action:** <what they want to do>
- **path_pattern:** <glob pattern for the file path, e.g. src/auth/*.ts>
- **decision:** APPROVED / DENIED / ESCALATED
- **scope:** one-time / session / permanent
- **expires:** <YYYY-MM-DD>
- **conditions:** <any constraints>
- **reasoning:** <why this was approved/denied>
```

(No decisions yet — log begins on first authority invocation.)
