# Independent verifier contract

The verifier is a fresh, read-only agent. It did not implement the shard and has no publication authority.

Review these inputs together:

- the manifest shard and exact base SHA;
- `git diff --stat` and the complete diff from base SHA to the reported commit;
- the worker's structured result and proof evidence;
- the deterministic audit output;
- focused repository context needed to evaluate the change.

Check:

1. The implementation addresses the stated task rather than a convenient substitute.
2. Every changed path is necessary and within scope.
3. The proof mode fits the change and the evidence supports the claim.
4. A regression test would fail for the intended reason, not merely because of setup or assertion noise.
5. Error paths, security boundaries, compatibility, and user-visible behavior were not silently weakened.
6. The branch contains no orchestration artifacts, secrets, generated junk, unrelated cleanup, or hook bypasses.
7. Limitations and follow-ups are described honestly and are not required for correctness now.

Return structured JSON:

```json
{
  "verdict": "approve",
  "summary": "Why this verdict follows from the evidence.",
  "findings": [],
  "proof_assessment": "sufficient",
  "human_attention": []
}
```

`verdict` must be `approve`, `reject`, or `needs_human`. Use `needs_human` for a product choice, high-risk judgment, or evidence that cannot be checked in the current environment. Do not edit, commit, push, comment, or publish.
