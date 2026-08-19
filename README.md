# Gale-Shapley mentorship matching: a synthetic, reproducible demonstration

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A reproducible Gale-Shapley mentorship-pairing analysis in R, built entirely on synthetic
data. **90.2% of synthetic mentees are paired with a mentor in the top 20% of their own
predicted-compatibility ranking, against 19.8% under random feasible matching — about 4.5x
the benchmark, across 549 matched pairs and 2,000 simulated random matchings per year. One
of the three predefined fairness gates does not pass, which is stated here in the first
paragraph rather than left for a reader to find.**

The pipeline matches synthetic mentees to mentors under two text-similarity scoring
methods (Cosine Similarity and Matching Words), measures each against that random-matching
benchmark, and reports every predefined fairness check with its threshold and outcome,
passing or not. Where the synthetic results depart from the analysis this repository
models, the departure is stated rather than smoothed over.

> **Independent personal work, synthetic data only.** This is a personal project, built
> and published on my own time and equipment. It contains **no employer code, data,
> configuration, or output**; every input under `data/` is generated, and **no real survey
> response, name, identifier, or business label appears anywhere in this repository.** It
> is **not affiliated with, endorsed by, or derived from any employer's proprietary
> implementation**, and nothing here is a statement about any real program or population.
> These results do not establish performance on real employee data. A minimal,
> dependency-free companion implementation of the core statistics lives in
> [gale-shapley-fair-matching-demo](https://github.com/RickPack/gale-shapley-fair-matching-demo).

## Results

| Result | Estimate | Uncertainty or benchmark | Interpretation |
|---|---|---|---|
| Assigned mentor in top 20% of predicted compatibility | **90.2%** (Cosine Similarity)<br>**89.4%** (Matching Words) | 95% CI [87.4, 92.5] and [86.6, 91.9]<br>Random feasible matching: **19.8%** [16.6, 23.1] | About 4.5x the random benchmark for both methods. |
| Assigned mentor is the predicted number one | **27.1%** (Cosine Similarity)<br>**18.2%** (Matching Words) | 95% CI [23.5, 31.1] and [15.1, 21.7]<br>Random feasible matching: **0.51%** [0.0, 1.1] | About 53x and 36x the random benchmark. The two intervals do not overlap, so the methods separate cleanly on this measure. |
| Two methods equivalent within ±5 pp (TOST) | Cosine Similarity − Matching Words = **+1.28 pp** | Pooled 90% CI **[−1.57, +4.14]** pp, margin ±5 pp | **Pass**, pooled. The interval sits inside the margin. 2024 also passes individually; 2023 and 2025 do not. |
| Predefined fairness checks passed at *u* = 1.5 | **2 of 3 binding gates** | Disparate Impact passes (DI 0.987, 90% CI [0.942, 0.998], floor 0.80). Mean percentile gap passes (90% CI [−2.49, +1.60] pp, within ±3 pp). FOSD equivalence is flagged. | The procedure is **not** shown to be fair on these data — the one flagged gate is enough to withhold that claim. The count holds at *u* = 1.3 too, which is what the pipeline's own selector picks. See "Predefined fairness checks". |

The algorithm assigned a top-20% mentor to 90.2% of mentees under Cosine Similarity and
89.4% under Matching Words, and the predicted number-one mentor to 27.1% and 18.2%, under
the stated simulation and benchmark conditions. Of the three binding fairness gates, two
pass (Disparate Impact and the mean percentile gap) and one is flagged (FOSD equivalence)
at its stated threshold.

> That wording is not a hedge. One of the three predefined gates does not pass, and a high
> compatibility rate is not evidence of fairness.

### Sample sizes, simulations, seeds

| Year | Mentees | Eligible mentor pool | Mentors before duplication | Top-20% cutoff rank |
|---|---|---|---|---|
| 2023 | 173 | 184 | 184 | 36 |
| 2024 | 276 | 276 | 221 | 55 |
| 2025 | 100 | 115 | 115 | 23 |
| Pooled | 549 | — | — | — |

- **Populations:** 3 synthetic survey years (2023-2025), plus 3 prior-year match files.
- **Parameter settings:** 12 values of the survey-match weight *u*, from 0.9 to 2.0 in
  steps of 0.1. Headline figures use *u* = 1.5, which is hardcoded in
  `run_all_synthetic.r` for comparability with Pack et al. (2026) rather than selected
  from these data. The pipeline's own selection routine picks *u* = 1.3.
- **Methods:** Cosine Similarity and Matching Words, compared symmetrically. Neither is
  a baseline.
- **Benchmark simulations:** 2,000 random feasible matchings per year, seed 42.
- **Seeds:** matching and tie-breaking seed **88** (`params$seed` in the Rmd); analysis
  and benchmark seed **42**; synthetic vocabulary build seed **726**; word-cloud layout
  seed **726**.

### Definitions and denominators

**Top-20% compatibility rate.** The share of mentees whose assigned mentor ranks in the
best 20% of that mentee's eligible mentor pool. A mentee with pool size *N* counts as a
success when the assigned mentor's rank is at most `floor(0.20 x N)`, the conservative
reading of "top 20%" (36 of 184 rather than 37, for 2023).

**Number-one compatibility rate.** The share of mentees assigned the single
highest-predicted-compatibility mentor, meaning rank exactly 1.

**Eligible mentors, the denominator decision.** The pipeline builds a complete mentee x
mentor grid and ranks every mentor for every mentee, so a mentee's eligible pool is every
mentor row in that grid. When mentees outnumber mentors, the pipeline duplicates willing
mentors until the counts match, and those duplicate rows are ranked like any other. **The
pool used here is the post-duplication pool** (184 / 276 / 115), verified against the grid
size: 173x184 = 31,832, 276x276 = 76,176, 100x115 = 11,500 rows. The choice matters. In
2024 the pre-duplication pool is 221, not 276, which would move the cutoff rank from 55
to 44.

This deliberately models **full pairing**: every mentee is paired and mentors are
duplicated as needed, with no per-mentor cap. Full pairing is the simpler object to reason
about statistically, because it removes the unmatched-mentee stratum: every mentee
contributes to every rate reported here, and no result depends on a capacity rule that
would have to be documented and defended separately. A mentor holding more than two
mentees here is expected behaviour, not a defect.

**A second denominator exists in the pipeline.** The pipeline's own `mentor_percentile`
normalises by `max(assigned rank)` rather than by the pool size. That maximum is smaller
than the pool whenever no mentee is matched to their worst candidate, and it differs by
method: 118 / 266 / 37 under Cosine Similarity and 125 / 274 / 39 under Matching Words,
against pools of 184 / 276 / 115. Both denominators are reported. The `*_pool` columns in
[`artifacts/match_quality_by_year_method_u.csv`](artifacts/match_quality_by_year_method_u.csv)
use the pool, and the `*_repo` columns reproduce the pipeline's definition. The pool
denominator is the larger one, so it is the more permissive of the two.

**Tie rule.** Predicted-compatibility ties are broken before ranking by adding seeded
`U(1e-6, 9e-6)` jitter to every score, so each mentee's ranking is a strict total order
and no rank is shared. The resolution is exactly reproducible for a given seed. Any
residual exact tie falls to `dplyr::row_number()`, which breaks it by row order.

**Benchmark, random feasible matching.** Under a uniformly random assignment of mentees
to distinct mentor slots, each mentee's assigned mentor is a uniformly random member of
that mentee's own ranking, so its rank is Uniform{1..N}. Mentees rank the pool differently
from one another, so these are simulated as independent draws: 2,000 replicates per year,
reported as the mean with a 2.5th-97.5th percentile band. The second benchmark is the
repository's other matching procedure, since the two scoring methods each serve as the
other's comparator.

**Uncertainty.** Clopper-Pearson exact binomial intervals, chosen over Wald because the
number-one rate is small and the 2025 cell has only 100 mentees. Benchmark bands are
simulation percentiles.

![Match quality against a random feasible matching](artifacts/Figure_Match_Quality.png)

### How the results move across the *u* grid

*u* sets the weight on the survey-match subscore relative to the text-similarity
subscore. Pooled rates shift modestly across the 12 values: Cosine Similarity ranges
89.1-90.9% on the Top-20% measure and 23.5-27.7% on number-one, Matching Words 88.3-90.2%
and 15.5-20.0%. See
[`artifacts/match_quality_u_stability.csv`](artifacts/match_quality_u_stability.csv).

Those aggregate ranges understate how much *u* actually does. Individual assignments move
a great deal. Measured against the *u* = 1.5 slice, under Cosine Similarity:

| Compared with *u* = 1.5 | Mentees whose assigned mentor changes | Mentees whose rank changes |
|---|---|---|
| *u* = 0.9 | 241 of 549 | 381 of 549 |
| *u* = 1.0 | 214 of 549 | 359 of 549 |
| *u* = 1.4 | 63 of 549 | 170 of 549 |
| *u* = 1.6 | 86 of 549 | 171 of 549 |
| *u* = 2.0 | 191 of 549 | 325 of 549 |

Matching Words behaves similarly (242 of 549 changing mentor at *u* = 0.9). Nearly half
the cohort is matched to a different person at the ends of the grid while the pooled rate
barely moves, which is worth keeping in mind before reading a stable aggregate as a stable
procedure. Aggregate stability and individual stability are different properties, and only
the first is visible in the summary table.

This behaviour depends on the z-score change described under "Deviations from the
published paper", and on the vocabulary repair described under "Data provenance". An
earlier build of this repository produced a *u* sweep that genuinely was inert, because a
token-encoding defect had collapsed most free-text answers to a single word and flattened
cosine similarity to a standard deviation near 0.003. That defect is fixed. Cosine
similarity now spans 0.042 to 0.761 with a standard deviation near 0.095.

### Method equivalence does not reproduce on synthetic data

The two scoring methods are compared symmetrically. The question the underlying analysis
asks is not whether they differ but whether they are close enough to be treated as
interchangeable: a TOST equivalence test on the Top-20% selection rate, with a ±5
percentage-point margin.

| | Cosine Similarity | Matching Words | Cos − MW | 90% CI | ±5 pp | ±2 pp |
|---|---|---|---|---|---|---|
| 2023 | 82.66% | 82.08% | +0.58 pp | [−4.68, +5.86] | Fail | Fail |
| 2024 | 89.86% | 88.41% | +1.45 pp | [−1.66, +4.65] | **Pass** | Fail |
| 2025 | 76.00% | 74.00% | +2.00 pp | [−7.70, +11.69] | Fail | Fail |
| **Pooled** | **85.06%** | **83.79%** | **+1.28 pp** | **[−1.57, +4.14]** | **Pass** | Fail |

<small>Source: [`artifacts/speed_session_method_tost.csv`](artifacts/speed_session_method_tost.csv). Rates use the pipeline's own percentile denominator, so they sit below the pool-based figures in the Results table.</small>

Equivalence at the ±5 pp margin is established pooled, and in 2024 individually, but not
in 2023 or 2025. The pooled 90% CI, [−1.57, +4.14] pp, sits entirely inside the margin, and
so does 2024's, [−1.66, +4.65] pp. 2023 and 2025 both cover zero on the point estimate but
their intervals are wide enough — [−4.68, +5.86] pp and [−7.70, +11.69] pp — to spill past
±5 pp at one end, so those two years cannot certify equivalence even though nothing in
their point estimates suggests a real difference. At none of the four margins tested does
any year clear the stricter ±2 pp band.

Unlike the fairness-gate section below, this is not one result softened by a wide interval:
it is four separate estimates of the same quantity, agreeing closely in magnitude
(+0.58 to +2.00 pp) but differing in how tightly each year's sample pins that magnitude
down. 2025's cohort of 100 produces the widest interval of the four by a wide margin, which
is exactly the pattern Lo, Datta & Salami describe — a small, stable point estimate that a
small sample cannot certify as small enough.

The methods also separate clearly on the number-one rate (27.1% against 18.2%, with
non-overlapping intervals), which the ±5 pp Top-20% test is not designed to detect.
Overlapping confidence intervals do not establish equivalence, and non-overlapping ones on
a second measure do not establish that the methods are interchangeable on the first.

**How this interval is computed.** The design is paired: the same 549 mentees are scored
under both methods, so the two arms are positively correlated. Lo, Datta & Salami (2025),
Eqs. (5)-(6), give an independent-samples Wald standard error, which assumes two separate
groups and therefore overstates the width here. `build_method_tost_table()` in
`run_all_synthetic.r` uses the paired score interval of Tango (1998) instead, via
`PropCIs::scoreci.mp` on the discordant pairs: 48 mentees selected under Cosine Similarity
only, 41 under Matching Words only, 460 under both. The independent formula would report
roughly [−2.32, +4.88] pp on the same data against the paired [−1.57, +4.14] pp, an SE of
about 0.0219 against 0.0174. Both verdicts are Pass at the pooled level, so the ±5 pp
conclusion is unchanged here; the width is not. `tost_sp_equiv_wald()` is retained in the
script for that comparison and feeds no reported number.

One orientation trap is worth flagging for anyone reading the code: `scoreci.mp(x, y, n)`
estimates `(y - x)/n`, so producing the Cosine − Matching Words difference this README
reports requires passing the discordant counts in the opposite order to the one the
argument names suggest.

A minimal, dependency-free implementation of this same interval, in Python, is in the
[gale-shapley-fair-matching-demo](https://github.com/RickPack/gale-shapley-fair-matching-demo)
repository: `tango_score_ci()` is pinned by a test that reproduces `PropCIs::scoreci.mp`
to four decimals, so it is a smaller surface to read than `PropCIs` itself if the goal is
to check the formula rather than run this pipeline.

### Predefined fairness checks

Protected attribute: mentee grade, dichotomised by the pipeline into **Grades 1-4**
(junior, 387 mentees, n = 774 across both methods) and **Grades 5+** (senior, 162 mentees,
n = 324), pooled over years and methods. Positive outcome: a Top-20% mentor under the
pipeline's percentile definition. Every threshold below is the default already coded in
`run_all_synthetic.r`, and none was chosen for this write-up.

| Check | Role | Threshold | Estimate | Interval | Outcome |
|---|---|---|---|---|---|
| Disparate Impact (four-fifths rule) | Binding gate | DI 90% lower bound ≥ 0.80 | DI = 0.987 | 90% CI [0.942, 0.998] | **Pass** |
| Mean percentile gap, TOST equivalence | Binding gate | 90% CI within ±3 pp | −0.47 pp | 90% CI [−2.49, +1.60] | **Pass** |
| FOSD equivalence, TOST | Binding gate | sup 90% upper ≤ 0.10, inf 90% lower ≥ −0.10 | sup = 0.095, inf = −0.029 | sup 90% U = 0.154, inf 90% L = −0.062 | **Flag** |
| FOSD equivalence, strict | Sensitivity | sup 90% upper ≤ 0.05, inf 90% lower ≥ −0.05 | sup = 0.095, inf = −0.029 | sup 90% U = 0.154, inf 90% L = −0.062 | **Flag** |
| Standardised mean difference | Supportive, not a gate | \|SMD\| ≤ 0.30 | SMD = −0.026 | point estimate | **Pass** |
| Fisher exact, grade group x positive | Supportive, not a gate | reported, not thresholded | p = 0.715 | exact test | Reported |

**Selection rates behind the DI figure:** Grades 1-4, 84.11%; Grades 5+, 85.19%. Mean
percentile 10.63 against 10.16, where lower is better. Full table:
[`artifacts/fairness_checks.csv`](artifacts/fairness_checks.csv).

The gap of −0.47 pp favours senior mentees, in the same direction as the selection-rate
gap, and both are disclosed here rather than set aside. Unlike the DI gate, this one is a
clean pass, not a boundary case: the full 90% interval, [−2.49, +1.60] pp, sits inside the
±3 pp margin rather than merely covering it at the point estimate. The two supportive
measures agree: |SMD| = 0.026 is close to zero, and Fisher's exact test on the
selection-rate difference returns p = 0.715, nowhere near distinguishing the two groups'
rates from chance.

The remaining flag is FOSD equivalence, and it flags for the reason described above: the
observed gap between the two grade groups' full percentile distributions, not just their
means, is small (sup = 0.095, inf = −0.029) but its interval's upper bound, 0.154, crosses
the 0.10 margin. That is a distributional check with a wider interval than the mean-based
one, not evidence of a larger disparity.

What these data establish: the matching procedure clears the four-fifths rule and the
mean-percentile-gap equivalence test for grade-group parity, and does not clear the
stricter, distribution-wide FOSD equivalence test on the same groups.

**This verdict depends on *u*, and *u* = 1.5 is a presentation choice rather than the
pipeline's own recommendation.** `presentation_u` is hardcoded to 1.5 at the top of
`run_all_synthetic.r`. The script also runs a selection routine over the whole grid, and
on these data that routine picks *u* = 1.3
([`artifacts/Proposed_u_decision.csv`](artifacts/Proposed_u_decision.csv)). The fairness
picture at *u* = 1.3 is close to the headline, not materially different from it:

| Gate | *u* = 1.5 | *u* = 1.3 |
|---|---|---|
| Disparate Impact | 0.987, 90% CI [0.942, 0.998] | 0.988, 90% CI [0.946, 0.999] |
| Mean percentile gap | −0.47 pp, 90% CI [−2.49, +1.60], **Pass** | −0.77 pp, 90% CI [−2.58, +1.23], **Pass** |
| FOSD, sup 90% upper | 0.154, **Flag** | 0.146, **Flag** |
| \|SMD\| | 0.026 | 0.044 |

The same two of three binding gates pass at both *u* values, and FOSD flags at both. That
is a more robust result than a single headline value would suggest: the presentation
choice and the pipeline's own selection routine agree on which gates pass here. The *u* =
1.5 figures remain the headline for comparability with Pack et al. (2026), which uses that
value.

Treat the *u* = 1.3 column as a sensitivity check rather than a competing headline.
`Proposed_u_decision.csv` marks that row `passes_all = TRUE` while its own
`FOSD_sup_CI_U` of 0.146 exceeds the 0.10 margin, so the selection routine and the gate
table still disagree about what passing means, even though both now flag the same gate.
See "Known issues" item 2.

## Why some checks fail here

One of the three binding fairness gates flags on these synthetic data, and two of the four
method-equivalence tests (2023 and 2025, individually) fail. That is a property of this
demonstration, not a finding about anything else, and it is worth being explicit about the
mechanism rather than leaving a reader to guess at one.

**FOSD equivalence.** The observed gap between grade groups' full percentile distributions
is small (sup = 0.095, inf = −0.029), well under the 0.10 margin on the point estimate. The
90% interval's upper bound, 0.154, is what crosses the margin. The gate that tests the same
groups' *means* rather than their full distributions — mean percentile gap — passes
cleanly, with its whole interval inside ±3 pp. FOSD is the stricter, wider-interval test of
the two, and it is the one still flagging.

**Method equivalence, per year.** The pooled TOST comparison passes at ±5 pp, and so does
2024 taken alone. 2023 and 2025 do not, even though all three years' point estimates agree
closely (+0.58 to +2.00 pp) — their intervals are simply wider at n = 173 and n = 100 than
at n = 276. This is the same mechanism repeated four times over: a stable point estimate,
a margin it sits inside, and a sample size that determines whether the interval also fits.

None of this points to a defect in the algorithm or the methodology. It follows from
testing modest effects against tight margins on cohorts of 100 to 549 — the situation Lo,
Datta & Salami (2025) describe when a metric sits near its decision boundary, and the
situation the [companion power demonstration](https://github.com/RickPack/gale-shapley-fair-matching-demo#the-verdict-flips-as-the-cohort-shrinks)
isolates by holding everything but the cohort size fixed. The reporting convention is the
one that matters here: the gaps and the flags are stated and not softened, in either
direction.

A separate methods paper (Pack, Lo, Salami & Yao, 2026, in preparation for JSM 2026)
describes the underlying approach. **No result from that paper is reproduced, quoted, or
compared against here**, and nothing in this repository should be read as evidence about
the data behind it.

## Data provenance

All inputs are synthetic. Generation ran once, on a machine holding the restricted source
workbooks, and those workbooks are not in this repository and are not reachable from it.
The three generation scripts are published for auditability — so a reader can check what
was removed and how — not so the generation can be repeated:
[`build_synthetic_inputs.R`](docs/DATA_PROVENANCE.md#build_synthetic_inputsr)
replaces names, IDs, and free text with generated substitutes and discards the mapping;
[`scrub_org_fields.R`](docs/DATA_PROVENANCE.md#scrub_org_fieldsr) randomises the
organisational structure that survived the first pass; and
[`repair_synthetic_vocabulary.R`](docs/DATA_PROVENANCE.md#repair_synthetic_vocabularyr)
fixes a vocabulary defect described below. Full mechanism, script by script, in
[`docs/DATA_PROVENANCE.md`](docs/DATA_PROVENANCE.md).

That defect is worth stating here because it explains the figure below. The generated
vocabulary fell back to `sprintf("term%04d", i)` labels once its 900-item stem pool ran
out, and the analysis scores text after stripping non-letters with
`str_replace_all(toupper(x), "[^A-Z ]", "")`. That strip deleted the digits, so `term0001`,
`term0002` and the rest all collapsed into a single word, `TERM`, 77.6% of all token mass
and 2,748 of 3,647 distinct words. Every document became roughly three-quarters the same
word, cosine similarity between any two sat near 0.99, and the text component stopped
carrying information. `repair_synthetic_vocabulary.R` relabels the offending tokens with
alphabetic-only names, a bijection on the vocabulary that reads no original data and
leaves the document-term matrix unchanged up to a column permutation.

The figure below shows what survives the whole process. The vocabulary is manufactured:
compounds such as `effortapproach` and `contextfield` from a 900-item stem pool, then
letter-only overflow labels (`termaaa`, `termaab`, and so on) once that pool is exhausted.
It carries the rank-frequency structure of the original text without carrying its content.

![Synthetic vocabulary word cloud](artifacts/Figure_WordCloud_Synthetic_Vocab.png)

Counted as they appear, with no stopword list, stemming, or length filter: 71,418 free-text
tokens across 3,508 distinct synthetic words, frequencies 1 to 4,154. The 54 most frequent
are drawn; the complete table is
[`artifacts/wordcloud_token_frequencies.csv`](artifacts/wordcloud_token_frequencies.csv).

**The restricted source workbooks are not in this repository, are not referenced by any
committed path, and are not needed to reproduce anything below.** `.gitignore` excludes
`source_workbooks/` and `GS_SOURCE_ROOT/`; the pipeline reads the committed `data/*.csv`
and never looks anywhere else unless a reader deliberately sets `GS_SOURCE_ROOT` to
something of their own.

## Reproducing every number

Everything in this README regenerates from the committed synthetic CSVs. The intermediate
`.rds` files are not committed. They are bulk outputs of the render step, and rerunning
that step recreates them.

```bash
# 1. Full pipeline: renders 3 years x 12 u values, then writes fairness and
#    summary artifacts. Recreates artifacts/u_*/ from data/*.csv. ~100 minutes.
Rscript run_all_synthetic.r

# 2. Match-quality estimands, intervals, and the random-matching benchmark. ~10 s.
Rscript analyze_match_quality.R

# 3. The predefined fairness checks, with thresholds and pass/fail. ~5 s.
Rscript report_fairness_checks.R

# 4. Figures. ~20 s each.
Rscript make_wordcloud.R
Rscript make_match_quality_figure.R

# 5. Validation checks: 145 assertions across nine groups. ~30 s.
Rscript tests/run_checks.R

# 6. Figure colour-vision and contrast gates.
Rscript tools/check_palette.R
```

Each script takes `--` arguments (input paths, seeds, output folders) and fails with a
named error when an input is missing. Run any of them with no arguments for the documented
defaults.

Caching behaviour, determinism guarantees, the pinned R environment, and how to rebuild
the synthetic CSVs from the original workbooks are documented in
[`docs/REPRODUCE.md`](docs/REPRODUCE.md).

## Figures

Both committed PNGs are generated by script and held to measurable, colour-vision-safe
standards rather than to judgement, because GitHub renders README images on both a light
and a dark page. Palette, sizing, and caption-provenance rules are documented in
[`docs/FIGURES.md`](docs/FIGURES.md); `tools/check_palette.R` enforces the colour gates.

## Statistical power and the boundary problem

Lo, Datta & Salami (2025, §4, *AI and Ethics*) argue that testing for fairness near a
decision threshold requires enough power to distinguish near-compliance from breach, and
that small cohorts routinely fail tests that larger ones pass, not because the algorithm
changed but because the confidence interval widened. Their Fig. 1 shows power collapsing
toward α as the true metric approaches the acceptance boundary, and their Fig. 2 shows power
failing to reach 80% at n ≤ 100.

The FOSD gate and two of the four year-level method-equivalence tests (2023, 2025) fit
that pattern: a point estimate comfortably inside the margin, and an interval too wide at
that sample size to fit inside it as well. Disparate Impact and the mean percentile gap,
which both pass cleanly, rely on simpler estimands — a ratio and a mean difference — that
converge faster than the distribution-wide FOSD test or a per-year split of only 100 to
276 mentees.

Lo, Datta & Salami motivate the framework partly by observing that "if a fairness criterion
is barely met or missed, it is often uncertain if it should be a 'pass' or 'failure,' if the
sample size is not large." The
[companion power demonstration](https://github.com/RickPack/gale-shapley-fair-matching-demo#the-verdict-flips-as-the-cohort-shrinks)
makes the mechanism visible without domain knowledge: holding the algorithm, the scoring
parameters, and the seed constant, n = 100 mentees fail the equivalence test and n = 250
pass it. Only the cohort size changes. That demonstration now uses the same paired score
interval this repository computes, so the two are directly comparable in method, if not
in the specific data behind them.

549 matched pairs is enough to establish the large advantage over random matching, to
measure the senior-mentee gap cleanly, and to pass method equivalence pooled. It is not
enough, at n = 100 to 276 per year, to certify equivalence in every individual year, or to
pass the stricter distribution-wide FOSD test across grade groups. A pass or fail reported
without its sample size is incomplete.

## Repository layout

| Path | What it is |
|---|---|
| `data/*.csv` | Synthetic surveys 2023-2025 and prior-year matches 2022-2024. The only inputs. |
| `build_synthetic_inputs.R` | The generation script, published so the de-identification is auditable. Ran once against restricted inputs held outside this repository; not re-runnable from here. |
| `scrub_org_fields.R` | Randomises group and unit affiliation so no real org structure survives. |
| `repair_synthetic_vocabulary.R` | Relabels digit-bearing overflow tokens the scorer would otherwise collapse. |
| `stable_matching_paper_synthetic.rmd` | De-identified analysis, rendered once per year and *u*. |
| `run_all_synthetic.r` | Renders across the grid, writes fairness and summary artifacts. |
| `analyze_match_quality.R` | Top-20% and number-one estimands, intervals, benchmark. |
| `report_fairness_checks.R` | Predefined fairness checks with thresholds and outcomes. |
| `make_wordcloud.R` | Data-provenance figure. |
| `make_match_quality_figure.R` | Headline figure. |
| `tests/run_checks.R` | 145 assertions across nine groups. |
| `tools/check_palette.R` | Colour-vision and contrast gates for committed figures. |
| `artifacts/` | Committed summary CSVs, the two figures, and pipeline Word tables. |
| `docs/DATA_PROVENANCE.md` | De-identification chain, script by script. |
| `docs/FIGURES.md` | Colour-vision, sizing, and caption-provenance standards for the two figures. |
| `docs/REPRODUCE.md` | Caching, determinism, pinned environment, rebuilding from source workbooks. |

## Deviations from the published paper

The scoring formula used here differs from Pack et al. (2026) in one way.

**Published paper formula:**
```
CS_Pred  = (Cosine_Similarity × 100) + u × overall_survey_match_num
MW_Pred  =  MW_count                 + u × overall_survey_match_num
```

**This repository:**
```
CS_Pred  = z(Cosine_Similarity) + u × z(overall_survey_match_num)
MW_Pred  = z(MW_count)          + u × z(overall_survey_match_num)
```
where `z(·)` denotes standardisation to mean 0, SD 1 across all mentor-mentee pairs for
that year.

**Why the change.** The raw components are on incompatible scales. Measured on these data,
`overall_survey_match_num` carries 6.6 to 8.0 times the standard deviation of
`Cosine_Similarity × 100`, and 11.0 to 12.7 times that of `MW_count`, depending on the year
([`artifacts/score_components.csv`](artifacts/score_components.csv)). The paper's `× 100`
was a practical approximation calibrated to real survey text. Under it, *u* nominally
weights the survey term but the survey term already dominates before *u* is applied.
Z-scoring makes *u* the explicit relative-weight parameter: *u* = 1.5 means the survey
component gets 1.5 times the weight of the text component, as intended.

**Effect on results.** Rankings, Top-20% rates, and the TOST comparison differ from the
paper. The deviation is intentional and confined to this public synthetic demonstration. It
does not reflect a change to the methodology described in the paper.

## Known issues and limitations

1. **Fairness is not fully established.** One of three binding gates (FOSD equivalence)
   flags, and two of the four method-equivalence tests (2023, 2025) fail (see "Why some
   checks fail here" for why these are precision results at the smaller per-year cohorts,
   not demonstrated disparities, and why the FOSD flag alone is still a reason to withhold
   a full fairness claim).
2. **The *u* selection routine and the gate table disagree about what passing means.**
   `Proposed_u_decision.csv` marks the *u* = 1.3 row `passes_all = TRUE` while that same
   row's `FOSD_sup_CI_U` of 0.146 exceeds the 0.10 margin. The selector and the published
   gate table apply different rules, so the selector's recommendation should be read as a
   sensitivity check rather than a competing headline. The pipeline now reports that
   recommendation without acting on it (see below), so nothing published depends on the
   disagreement, but the two rules have not been reconciled.
3. **The Disparate Impact gate is one-sided.** Lo, Datta & Salami test DI against a
   two-sided acceptable range (their §3.3, typically [0.80, 1.20] or [0.80, 1.25]). This
   pipeline gates on the 90% lower bound against a 0.80 floor only, so a DI above the upper
   bound would not be caught. With DI at 0.987 the distinction does not bind here.
4. **Aggregate stability hides individual churn.** Pooled Top-20% rates vary by about two
   percentage points across the *u* grid while up to 241 of 549 mentees are matched to a
   different mentor. Do not read the flat summary as evidence that *u* is unimportant.
5. **`results_mentor_balance.csv` previously mislabelled its pool column.**
   `n_mentor_slots` was computed as `max(assigned rank)` while its own footnote described it
   as the total mentor entries given to Gale-Shapley. It now reads the pool size recorded in
   `matching_pool_<year>.csv` (184 / 276 / 115).
6. **Response filtering is looser than full-survey completion.** A response is retained when
   it has an identity, a mentor/mentee indicator, and at least one of the two
   personality-description fields. The two free-text "anything to add" items are optional.
   Per-year counts are in
   [`artifacts/exclusion_summary_all_years.csv`](artifacts/exclusion_summary_all_years.csv).
7. **Synthetic data breaks confidentiality by design, not fidelity.** Qualitative patterns
   may resemble the original analysis; the numbers will not match it.

## References

- D. Gale & L. S. Shapley (1962). *College Admissions and the Stability of Marriage.*
  American Mathematical Monthly, 69(1), 9-15.
- V. S. Y. Lo, S. Datta & Y. Salami (2025). *Bringing practical statistical science to AI
  and predictive model fairness testing.* AI and Ethics, 5, 2149-2164.
  doi:10.1007/s43681-024-00518-2. Supplies the TOST framework, the (1 − 2α)·100% interval
  convention used for every 90% CI here, and the power argument.
- T. Tango (1998). *Equivalence test and confidence interval for the difference in
  proportions for the paired-sample design.* Statistics in Medicine, 17(8), 891-908.
  Supplies the paired score interval this repository uses for the method-equivalence
  test, via `PropCIs::scoreci.mp`.
- J.-P. Liu, H.-M. Hsueh, E. Hsieh & J. J. Chen (2002). *Tests for equivalence or
  non-inferiority for paired binary data.* Statistics in Medicine, 21(2), 231-245. The same
  problem for paired binary outcomes.
- EEOC Uniform Guidelines on Employee Selection Procedures, the four-fifths rule.

## Licence

See [`LICENSE`](LICENSE).
