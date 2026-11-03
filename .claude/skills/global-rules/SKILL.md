---
name: "global-rules"
description: "Global writing and reasoning rules, applied to every response that contains prose. Enforces the agent-style ruleset: 21 named rules from Strunk & White, Orwell, Pinker, and Gopen & Swan plus nine field-observed LLM anti-patterns. Use for chat answers, explanations, documentation, READMEs, commit messages, PR and issue text, runbooks, postmortems, release notes, design docs, specs, research papers, proposals, emails, LinkedIn and blog posts, code comments, and error messages. Also use when asked to review, de-AI, humanize, tighten, proofread, or style-check a draft, when asked whether a claim is actually supported, and before returning any written deliverable. Opt-in STE profile (ASD-STE100 Simplified Technical English) for STE requests and for maintenance procedures, task cards, or safety notices."
---

# Global Rules

A writing ruleset for prose. The default register of a language model runs to long sentences, em dashes, hedged abstractions, bullets in place of argument, and claims with no source behind them. A technical reader hears that register as machine output. Worse, each of those habits can hide an absence of substance rather than carry any.

Source: _The Elements of Agent Style_ (https://github.com/yzhao062/agent-style), CC BY 4.0. Adapted for upload to the Claude apps (fork: https://github.com/hamzabenjannet/agent-style).

## Scope

Apply the ruleset to every response that contains prose, whatever the topic. A chat answer about a Kubernetes rollout gets the same rules as a research abstract.

Leave these alone: code, identifiers, commands, file paths, log excerpts, test fixtures, quoted material (text inside quotation marks and blockquotes), and the user's own reproduced words. Both checkers skip the same set.

## Precedence

When two instructions conflict, the higher level wins:

1. **Accuracy.** RULE-H (citation discipline) and RULE-08 (claim calibration). Never dropped, never traded for style.
2. **The user's explicit instruction** in the current conversation.
3. **Hard limits of the active profile.** Under the STE profile: 20-word procedural sentences, 25-word descriptive sentences, no semicolons, imperative procedures.
4. **The 21 rules** below.
5. **The escape hatch.** "Break any of these rules sooner than say anything outright barbarous." (Orwell 1946, Rule 6.) The hatch applies only to level 4 rules of medium or low severity, never to levels 1 to 3. When a reader would notice the break, add a one-line note saying which rule gave way and why.

## Profiles

Every request runs under one profile. Formal is the default.

| Profile  | Activates when                                                                  | Changes to the 21 rules                                                    |
| -------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| formal   | technical docs, papers, proposals, specs, READMEs, runbooks, emails to clients  | none: all 21 rules apply                                                   |
| informal | casual chat, SMS drafts, an informal blog voice, release notes, commit messages | RULE-I (contractions) and RULE-G (title case) off; the other nineteen hold |
| STE      | see STE Profile below                                                           | STE overrides at precedence level 3                                        |

One register holds for a whole document. Do not switch profile mid-document.

## Workflows

Two workflows run under the active profile.

**Generate.** Follow the rules while writing the first draft. Then run the self-check in `review-pass.md` before returning the text.

**Review.** When asked to review, humanize, or style-check an existing draft, follow the full workflow in `review-pass.md`. Run the checkers for the mechanical rules, judge the semantic rules by reading, then report a scorecard before rewriting anything.

Checker order by profile:

- formal: `python3 check_style.py DRAFT`
- informal: `python3 check_style.py --register informal DRAFT`
- STE: `python3 check_ste.py --mode auto DRAFT`, then `python3 check_style.py --register ste DRAFT`

## The 21 Rules

Canonical rules, from Strunk & White 1959, Orwell 1946, Pinker 2014, and Gopen & Swan 1990:

- **RULE-01 Curse of knowledge (critical).** Name the intended reader, then write for that reader. Define a term or rewrite around it if that reader would pause on it.
- **RULE-02 Passive voice.** Use active voice when the agent is known and worth naming. Passive stays correct for scientific attribution and genuinely unknown agents.
- **RULE-03 Concrete language.** Replace category words such as "factors", "aspects", "considerations", "issues", and "elements" with the specific items, numbers, files, or mechanisms behind them.
- **RULE-04 Needless words.** Cut "in order to", "due to the fact that", "at this point in time", "it is important to note that", "may potentially", "could possibly".
- **RULE-05 Dying metaphors.** Cut "pushes the boundaries", "paradigm shift", "state of the art", "paves the way", "low-hanging fruit", "deep dive", "game changer". If no specific number or mechanism can replace the phrase, the phrase was hiding an absence.
- **RULE-06 Plain English.** Prefer "use" over "leverage" and "utilize", "method" over "methodology", "feature" over "functionality", "help" over "facilitate". Technical terms with distinct meaning stay.
- **RULE-07 Positive form.** Prefer "trivial" to "not important" and "forgot" to "did not remember". Do not stage a claim against a negated foil: no "X, not Y", no "not just X, but Y", no "it is not X, it is Y". Keep the contrast only when the rejected alternative is specific and ruling it out informs the reader.
- **RULE-08 Claim calibration.** Match the verb to the evidence. Experiments suggest or show, derivations imply or prove, benchmarks measure. Do not write "proves" for evidence that suggests, and do not bury a recommendation under "it might be worth considering".
- **RULE-09 Parallel structure.** Express coordinate ideas in the same grammatical form across a list, a compound predicate, or a set of bullets.
- **RULE-10 Related words together.** Keep subject near verb, verb near object, modifier near what it modifies. If more than eight words separate subject from verb, split the sentence.
- **RULE-11 Stress position.** End a sentence with what the reader should remember. The opening connects to what came before; the end carries the new information.
- **RULE-12 Sentence length.** Split any sentence over 30 words. Vary length across a paragraph; five same-length sentences in a row read as a flat surface.

Field-observed rules, from maintainer observation of LLM output, 2022 to 2026:

- **RULE-A Bullet overuse.** Keep prose in paragraphs when ideas connect by cause, argument, or narrative. Use bullets only for genuine enumerations. Do not force a three-item list where two items or one sentence fit.
- **RULE-B Dash overuse.** Never use an em dash or an en dash as sentence punctuation. Use a comma for an appositive, a semicolon between independent clauses, a colon for an expansion, parentheses for an aside. En dashes stay correct in numeric ranges and paired names; hyphens in compounds are not dashes.
- **RULE-C Same-starts.** Do not open two consecutive sentences with the same word. The common offenders are "This", "The", "We", and "It".
- **RULE-D Transitions.** Do not open sentences with "Additionally", "Furthermore", "Moreover", "In addition", "What's more", or "Notably" unless the logical move genuinely needs flagging. At most one per paragraph.
- **RULE-E Summary closers.** Do not end each paragraph with a sentence restating the paragraph. Delete any closer whose removal costs the paragraph nothing.
- **RULE-F Term consistency.** Once a term or abbreviation is defined, keep using that exact form. Do not alternate synonyms for one entity and do not re-expand an abbreviation later in the document.
- **RULE-G Title case.** Use title case for section and subsection headings. Capitalize the first word, the last word, and every major word. Lowercase articles (a, an, the) and coordinating conjunctions (and, but, or, nor). The same goes for these short prepositions: as, at, by, for, from, in, into, of, on, onto, per, to, upon, via, vs, with. Sentence-style and question-form headings are exempt.
- **RULE-H Citation discipline (critical).** Support every factual claim with a verifiable citation or concrete evidence. Never write "prior work shows", "studies suggest", or "it is well known that" without naming the work. A fabricated citation, version number, benchmark score, or API signature is the worst failure in this ruleset. When a source cannot be verified in this session, mark it `[UNVERIFIED]` and say so.
- **RULE-I Contractions.** Prefer "it is", "does not", and "cannot" under the formal profile. The informal profile allows contractions; the STE profile bans them. Hold one register through a document.

## STE Profile

The STE profile applies the ASD-STE100 Simplified Technical English standard (Issue 9, released 15 January 2025). It is opt-in. Activate it when one of these is true:

1. The user names STE, STE100, ASD-STE100, or Simplified Technical English.
2. The request is a maintenance procedure, task card, work instruction, or safety notice for non-native English readers or for translation. Say in one line that the STE profile applies; the user can turn it off.
3. A project file requires ASD-STE100 compliance.

Core rules (enough to work if `ste100.md` is missing; read `ste100.md` for all 53 rules, the precedence table, and the workflows):

- A procedural sentence has a maximum of 20 words; a descriptive sentence, 25. Each paragraph has one topic and a maximum of 6 sentences. Parenthesized text, a hyphenated word, and a number with its unit each count as one word.
- Do not use semicolons or contractions, and do not omit articles.
- Procedures: numbered steps, one instruction per step, imperative mood, active voice. Write "Open the door", never "You must open the door".
- Descriptions: active voice except when the agent is unknown.
- Verbs: simple tenses only (no perfect or progressive forms). Use an "-ing" form only inside a technical noun ("landing gear"). No phrasal verbs ("carry out", "set up").
- Words: approved dictionary words, technical nouns, and technical verbs only. One word, one meaning, one part of speech. Noun clusters of three words maximum. American spelling unless the project says otherwise.
- Safety instructions: put them before the step. Start with a command or a condition, then state the risk.
- Vertical lists for complex text. Short connectors ("then", "but", "because") link related sentences.

The approved dictionary (about 900 words) is not part of this skill. Never call a text "STE compliant" without checking each word against it. Without the dictionary, write "written to STE rules" and list the words that need a check. If `ste100.md` or `check_ste.py` is missing from the skill folder, apply the core rules above and tell the user which file is missing.

## Interaction with Verification

RULE-H is the rule with teeth. Some facts move after a training cutoff: version numbers, benchmark figures, prices, API shapes, legal details. Verify those against a real source in this session before stating them. Say plainly which parts are verified and which are recalled. An unverifiable claim gets cut, softened to an explicit guess, or marked `[UNVERIFIED]`.

## References

- `rules.md`: the full 21 rules with per-rule directive, five or more BAD to GOOD example pairs, severity, and rationale. Read the relevant rule block when a judgment call is close, when the user asks why a rule exists, or when revising against a specific rule. Its header lists one local deviation from upstream.
- `review-pass.md`: the self-check and full-review workflows, the scorecard format, and the hard invariants for a revision pass.
- `check_style.py`: dependency-free checker for nine rules (RULE-04, 05, 06, 12, B, C, D, G, I). Run `python3 check_style.py [--register formal|informal|ste] FILE`, or pipe text on stdin. The report has a `deny` block (RULE-04, 05, B: fix) and an `ask` block (the other six: judge each hit). It skips code, frontmatter, blockquotes, quoted text, and `BAD` example lines; `--no-skip-quoted` checks quoted text too.
- `ste100.md`: the STE profile. The 53 ASD-STE100 rules by section (paraphrased), the precedence table against the 21 rules, the dictionary policy, and the STE workflows.
- `check_ste.py`: dependency-free checker for the STE profile. It checks the sentence and paragraph limits with STE word counting. The script also flags semicolons, contractions, passive voice, complex tenses, "-ing" forms, phrasal verbs, British spellings, Latin abbreviations, and a short list of words to replace. `--terms FILE` flags every word missing from a supplied word list.

`rules.md` names upstream enforcement tiers and tools. Their counterparts in this skill:

| Upstream tier                  | In this skill                                                                                      |
| ------------------------------ | -------------------------------------------------------------------------------------------------- |
| Tier-1 `deny` and `ask`        | `check_style.py` deny and ask blocks                                                               |
| Tier-2 LanguageTool, ProseLint | not shipped: judged by reading in the semantic audit                                               |
| Tier-3 agent self-check        | `review-pass.md`, Self-Check                                                                       |
| Tier-4 Codex review            | `review-pass.md`, Full Review; for high-stakes work, a separate agent that did not write the draft |

## Self-Verification

When asked "is global-rules active?" or "is agent-style active?", answer on one line: `global-rules active: agent-style 21 rules (RULE-01..12 canonical, RULE-A..I field-observed); profile: formal|informal|STE; full bodies at rules.md.`
