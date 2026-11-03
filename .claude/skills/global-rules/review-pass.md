<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- Based on The Elements of Agent Style (https://github.com/yzhao062/agent-style), CC BY 4.0. -->

# Review Pass

Two workflows. Every draft gets the self-check before it is returned. A full review runs when the user hands over an existing draft and asks for an audit, a cleanup, or a de-AI pass.

## Self-Check Before Returning a Draft

Run this on the text just written. It is a read, not a rewrite. Six questions, in this order:

1. **Sourcing (RULE-H).** Does every factual claim have a named source, a number, or an observation behind it? Any claim that does not gets cut, softened to an explicit guess, or marked `[UNVERIFIED]`.
2. **Specificity (RULE-03, RULE-08).** Point at the number, file, commit, or mechanism behind each noun phrase. Where nothing can be pointed at, the phrase is filler. Does each verb match the strength of the evidence?
3. **Reader (RULE-01).** Name the reader. Would that reader stop at any term on first pass?
4. **Mechanics (RULE-04, 05, 06, 12, B, D, I).** Filler phrases, clichés, jargon substitutions, sentences over 30 words, dashes used as punctuation, transition openers, contractions against the chosen register. Run `check_style.py` when the draft is a file.
5. **Shape (RULE-A, C, E, 09, 10, 11).** Bullets where prose belongs, repeated sentence openers, paragraph-closing restatements, broken parallelism, long subject-to-verb gaps, key facts buried mid-sentence.
6. **Consistency (RULE-F, G).** One term per entity throughout. Heading case consistent.

Fix what the check finds. Do not report the check to the user unless asked.

## Full Review of an Existing Draft

### 1. Mechanical Audit

Run `python3 check_style.py DRAFT` for RULE-04, 05, 06, 12, B, C, D, G, and I. These are deterministic and come back with line, column, and excerpt. Do not eyeball them; the script counts more reliably than reading does.

### 2. Semantic Audit

Judge the remaining rules by reading, one rule at a time: RULE-01, 02, 03, 07, 08, 09, 10, 11, A, E, F, and H. Use each rule's own directive and BAD to GOOD pairs in `rules.md` as the standard.

RULE-H needs its own pass. List every factual claim in the draft. For each one, record whether the draft names a source, whether that source is checkable, and whether the source actually supports the claim as stated. A citation that exists but does not support the sentence is still a RULE-H violation.

### 3. Report Before Rewriting

Give a scorecard first: one row per rule, a count, and the first two or three violations with line numbers. Then ask whether to produce a revised draft. Do not silently rewrite a document the user asked to have reviewed.

### 4. Revision Invariants

When revising, these hold without exception:

- **No new facts.** No number, citation, link, version, benchmark, or claim that is not already in the source. A claim flagged as unsupported under RULE-H stays flagged; inventing support for it is the worse failure.
- **No new scope.** Fix flagged violations only. Leave untouched any paragraph the audit did not flag.
- **Preserve structure.** Code fences, tables, frontmatter, heading levels, link syntax, list nesting, and inline code spans survive the revision exactly, unless the structure itself is the violation.
- **Preserve meaning.** If a fix changes what the sentence asserts, the fix is wrong. Flag the tension and ask.
- **Write beside, never over.** When the draft is a file the user owns, write the revision to a new path and show a diff.

### 5. Verify

Re-run the mechanical checker on the revision and show the before and after counts. A revision that trades one violation class for another has not worked.

## Scorecard Format

```
RULE-B   dash-as-punctuation      4   L12, L18, L27, L41
RULE-12  sentences over 30 words  3   L7 (38w), L22 (44w), L31 (33w)
RULE-H   unsupported claim        2   L5 "studies suggest", L19 "widely accepted"
RULE-03  abstract category noun   1   L14 "several factors"
...
```

Rules with zero violations collapse into one line at the end rather than taking a row each.
