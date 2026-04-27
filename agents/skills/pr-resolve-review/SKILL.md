---
name: pr-resolve-review
description: >
  Fetch and systematically address all review comments on the current
  PR. Every comment gets both a code fix (or explanation) and a reply
  in the thread. Use when a reviewer leaves comments, when CI passes
  but review is blocking, or when the user says "resolve the review".
---

# Resolve Review Comments

Fetch review comments on the current PR, address each one with both a
code change (or reasoned decline) and a thread reply, then request
re-review.

**Every comment must be addressed with both:**
1. A code change (or an inline comment / explanation if no code change
   is the right answer).
2. A reply on the review thread stating what was done.

## Usage

```
/pr-resolve-review [options] [pr-number]
```

**Options:**
- `--new` — Only show unresolved or post-last-push comments.
- (default) — Show every comment.

**Arguments:**
- `[pr-number]` — Optional. Detected from the current branch by default.

---

## Workflow

### 1. Detect the PR

```bash
PR=${PR:-$(gh pr view --json number --jq '.number')}
```

If no PR is associated with the current branch, prompt for the number.

### 2. Ensure the checkout matches the PR branch

```bash
gh pr view "$PR" --json headRefName --jq '.headRefName'
git branch --show-current
```

If they differ, check out the PR branch before editing
(`gh pr checkout "$PR"`).

### 3. Fetch PR + reviews + comments

```bash
gh pr view "$PR" --json title,state,baseRefName,reviewDecision
gh api "repos/Digimuoto/cortex/pulls/$PR/reviews"  --jq '.[] | {user: .user.login, state, submitted_at}'
gh api "repos/Digimuoto/cortex/pulls/$PR/comments" --jq '.[] | {id, path, line, user: .user.login, body, in_reply_to_id, created_at}'
```

Extract for each comment:
- `id` (needed to reply)
- `path` and `line`
- `user.login`
- `body`
- `in_reply_to_id` (if it's a reply)
- `created_at`

### 4. Filter to unresolved (if `--new`)

A comment counts as "already addressed" if:
- It has a reply containing `Fixed`, `Done`, `Addressed`, or `Declined`
- It was created before the last push to the PR branch

Use the last push timestamp:

```bash
gh api "repos/Digimuoto/cortex/pulls/$PR/commits" --jq '[.[].commit.committer.date] | max'
```

### 5. Categorize each comment

| Pattern | Intent | Default action |
|---|---|---|
| "should", "must", "change", "fix", "remove" | Required change | Apply the code change |
| "?", "why", "how", "can you explain" | Question | Reply with an answer; maybe link the relevant ADR |
| "consider", "could", "might", "what about" | Suggestion | Decide, then reply; implement if reasonable |
| "nit:", "style:", "minor:" | Nitpick | Fix if trivial; otherwise reply acknowledging |
| "LGTM", "ship it", "looks good" | Approval | No action needed |

### 6. Display a structured summary before editing

```markdown
## PR #<n> — Review Comments

### Required changes
1. `src/Cortex/Pulse/Executor.hs:142` — @reviewer
   > Wildcard match on PulseOutcome — ADR 0014 requires exhaustive patterns.

2. `src-platform/Platform/Observability/Emit.hs:88` — @reviewer
   > Missing redaction on the JWT token field.

### Questions
3. `src/Cortex/Graph/Core.hs:30` — @reviewer
   > Why was overlay separated from connect?

### Suggestions
4. `src/Cortex/Wire/V1/Compiler.hs:410` — @reviewer
   > Consider caching the resolved contract lookup.

### Already addressed (skipped with --new)
- 3 comments resolved in the previous round
```

Then write a TodoWrite list mirroring the required/questions/suggestions.

### 7. Address each comment

#### Code change

1. Read the file at the cited line.
2. Understand the suggested change — re-read neighboring code if the
   request is unclear.
3. Make the fix. Stay within the scope of the comment; don't scope-creep.
4. Commit with:

```
fix(review): <short description>

Addresses <file>:<line>.
```

#### Reply to the thread

After pushing the fix, reply to the inline comment. Use JSON input
whenever the reply contains backticks, markdown, or multiple lines:

```bash
reply_body="Fixed in \`$(git rev-parse --short HEAD)\`. <short reason>."
jq -n --arg body "$reply_body" '{body: $body}' \
  | gh api "repos/Digimuoto/cortex/pulls/$PR/comments/<comment-id>/replies" \
      --method POST --input -
```

#### Question

Formulate the answer, post the reply. Link the authoritative source
when one exists — ADRs, architecture chapters, or other docs:

```bash
reply_body=$'Short answer: <n>.\n\nSee [ADR 0016](docs/ADRs/0016-canonical-cortex-epistemological-archetypes.md) for the full reasoning.'
jq -n --arg body "$reply_body" '{body: $body}' \
  | gh api "repos/Digimuoto/cortex/pulls/$PR/comments/<comment-id>/replies" \
      --method POST --input -
```

#### Suggestion — implement or decline

If you implement: reply with "Implemented in `<sha>`. <one-line note>."

If you decline: reply explaining the trade-off in one short paragraph.
Be respectful — reviewers are investing attention, even in suggestions
you don't adopt.

### 8. Check CI after your changes

```bash
gh pr checks "$PR"
```

If CI went red, run `/ci-fix` before requesting re-review.

Run the local quality gate if you touched substrate code:

```bash
just fmt
just check
just test-match "<affected area>"
```

### 9. Post a re-review summary

One summary comment on the PR (not on individual threads):

```bash
body=$(cat <<'EOF'
## Review Comments Addressed

### Fixed
- [x] `Pulse/Executor.hs:142` — exhaustive match on PulseOutcome
- [x] `Platform/Observability/Emit.hs:88` — JWT redaction

### Responded
- [x] `Graph/Core.hs:30` — explained overlay vs. connect separation

### Declined (with explanation)
- [ ] `Wire/V1/Compiler.hs:410` — caching adds complexity not warranted at
      current lookup volumes

Ready for re-review @<reviewer>.
EOF
)

jq -n --arg body "$body" '{body: $body}' \
  | gh api "repos/Digimuoto/cortex/issues/$PR/comments" \
      --method POST --input -
```

Keep the summary concise. List actions, not raw logs. If a command
output matters, include only the relevant few lines in a fenced block.
If you accidentally post a malformed comment, edit it in place with
`PATCH /issues/comments/<id>`.

## Reply templates

**Acknowledging a fix**

```
Fixed in `abc1234`. Switched to an exhaustive match on the four
PulseOutcome variants per ADR 0014.
```

**Explaining a decision**

```
Good catch. We chose X here because:
1. <reason>
2. <reason>

The alternative would <trade-off>. Happy to revisit if <condition>.
```

**Declining a suggestion**

```
Considered this and decided against it:
- <reason>

I'll revisit if <trigger>. Thanks for flagging it.
```

**Asking for clarification**

```
Could you expand on what you mean by <X>? Want to make sure I address
the underlying concern, not just the surface comment.
```

## Principles

1. **Reply to every comment.** Silence is disrespect.
2. **Address, don't just acknowledge.** Fix the code, answer the
   question, or explicitly decline — then reply.
3. **Be brief.** Multi-paragraph apologies waste the reviewer's time.
4. **One commit per logical change.** Makes the re-review traceable.
5. **Never mark "resolved" on behalf of the reviewer.** Leave that to
   them.
6. **Use JSON input for `gh api` comment bodies.** Shell escaping in
   markdown-heavy replies goes wrong often enough to be a rule.

## Tools

| Operation | Tool |
|---|---|
| Get PR meta | `gh pr view --json …` |
| Get reviews | `gh api repos/.../pulls/<n>/reviews` |
| Get inline comments | `gh api repos/.../pulls/<n>/comments` |
| Reply to inline comment | `gh api repos/.../pulls/<n>/comments/<id>/replies` |
| Post PR-level summary | `gh api repos/.../issues/<n>/comments` |
| Edit a posted summary | `gh api repos/.../issues/comments/<id> -X PATCH` |
| Track progress | `TodoWrite` |
