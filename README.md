# Gale-Shapley mentorship matching: a synthetic, reproducible demonstration

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A reproducible Gale-Shapley mentorship-pairing analysis in R, built entirely on synthetic
data. **90.4% of synthetic mentees are paired with a mentor in the top 20% of their own
predicted-compatibility ranking, against 19.8% under random feasible matching — about 4.6x
the benchmark, across 591 matched pairs and 2,000 simulated random matchings per year. And
two of the three predefined fairness gates do not pass, which is stated here in the first
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
| Assigned mentor in top 20% of predicted compatibility | **90.4%** (Cosine Similarity)<br>**89.2%** (Matching Words) | 95% CI [87.7, 92.6] and [86.4, 91.6]<br>Random feasible matching: **19.8%** [16.6, 23.0] | About 4.6x and 4.5x the random benchmark. |
| Assigned mentor is the predicted number one | **26.4%** (Cosine Similarity)<br>**17.8%** (Matching Words) | 95% CI [22.9, 30.1] and [14.8, 21.1]<br>Random feasible matching: **0.47%** [0.0, 1.0] | About 56x and 37x the random benchmark. The two intervals do not overlap, so the methods separate cleanly on this measure. |
| Two methods equivalent within ±5 pp (TOST) | Cosine Similarity − Matching Words = **+3.21 pp** | Pooled 90% CI **[+0.72, +5.77]** pp, margin ±5 pp | **Fail.** The point estimate sits inside the margin; the interval does not. Every individual year fails too. |
| Predefined fairness checks passed at *u* = 1.5 | **1 of 3 binding gates** | Disparate Impact passes (DI 0.965, 90% CI [0.928, 0.995], floor 0.80). Mean percentile gap and FOSD equivalence are both flagged. | The procedure is **not** shown to be fair on these data. The count is *u*-dependent: 2 of 3 pass at *u* = 0.9, which is what the pipeline's own selector picks. See "Predefined fairness checks". |

The algorithm assigned a top-20% mentor to 90.4% of mentees under Cosine Similarity and
89.2% under Matching Words, and the predicted number-one mentor to 26.4% and 17.8%, under
the stated simulation and benchmark conditions. Of the three binding fairness gates, one
passes (the Disparate Impact four-fifths rule) and two are flagged (mean percentile gap
and FOSD equivalence) at their stated thresholds.

> That wording is not a hedge. Two of the three predefined gates do not pass, and a high
> compatibility rate is not evidence of fairness.

### Sample sizes, simulations, seeds

| Year | Mentees | Eligible mentor pool | Mentors before duplication | Top-20% cutoff rank |
|---|---|---|---|---|
| 2023 | 197 | 206 | 206 | 41 |
| 2024 | 287 | 287 | 233 | 57 |
| 2025 | 107 | 124 | 124 | 24 |
| Pooled | 591 | — | — | — |

- **Populations:** 3 synthetic survey years (2023-2025), plus 3 prior-year match files.
- **Parameter settings:** 12 values of the survey-match weight *u*, from 0.9 to 2.0 in
  steps of 0.1. Headline figures use *u* = 1.5, which is hardcoded in
  `run_all_synthetic.r` for comparability with Pack et al. (2026) rather than selected
  from these data. The pipeline's own selection routine picks *u* = 0.9.
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
reading of "top 20%" (41 of 206 rather than 42, for 2023).

**Number-one compatibility rate.** The share of mentees assigned the single
highest-predicted-compatibility mentor, meaning rank exactly 1.

**Eligible mentors, the denominator decision.** The pipeline builds a complete mentee x
mentor grid and ranks every mentor for every mentee, so a mentee's eligible pool is every
mentor row in that grid. When mentees outnumber mentors, the pipeline duplicates willing
mentors until the counts match, and those duplicate rows are ranked like any other. **The
pool used here is the post-duplication pool** (206 / 287 / 124), verified against the grid
size: 197x206 = 40,582, 287x287 = 82,369, 107x124 = 13,268 rows. The choice matters. In
2024 the pre-duplication pool is 233, not 287, which would move the cutoff rank from 57
to 46.

This deliberately models **full pairing**: every mentee is paired and mentors are
duplicated as needed, with no per-mentor cap. Full pairing is the simpler object to reason
about statistically, because it removes the unmatched-mentee stratum: every mentee
contributes to every rate reported here, and no result depends on a capacity rule that
would have to be documented and defended separately. A mentor holding more than two
mentees here is expected behaviour, not a defect.

**A second denominator exists in the pipeline.** The pipeline's own `mentor_percentile`
normalises by `max(assigned rank)` rather than by the pool size. That maximum is smaller
than the pool whenever no mentee is matched to their worst candidate, and it differs by
method: 148 / 278 / 49 under Cosine Similarity and 136 / 285 / 53 under Matching Words,
against pools of 206 / 287 / 124. Both denominators are reported. The `*_pool` columns in
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
number-one rate is small and the 2025 cell has only 107 mentees. Benchmark bands are
simulation percentiles.

![Match quality against a random feasible matching](artifacts/Figure_Match_Quality.png)

### How the results move across the *u* grid

*u* sets the weight on the survey-match subscore relative to the text-similarity
subscore. Pooled rates shift modestly across the 12 values: Cosine Similarity ranges
89.0-91.2% on the Top-20% measure and 23.4-28.1% on number-one, Matching Words 88.2-90.0%
and 14.9-18.8%. See
[`artifacts/match_quality_u_stability.csv`](artifacts/match_quality_u_stability.csv).

Those aggregate ranges understate how much *u* actually does. Individual assignments move
a great deal. Measured against the *u* = 1.5 slice, under Cosine Similarity:

| Compared with *u* = 1.5 | Mentees whose assigned mentor changes | Mentees whose rank changes |
|---|---|---|
| *u* = 0.9 | 278 of 591 | 408 of 591 |
| *u* = 1.0 | 251 of 591 | 395 of 591 |
| *u* = 1.4 | 66 of 591 | 187 of 591 |
| *u* = 1.6 | 85 of 591 | 180 of 591 |
| *u* = 2.0 | 210 of 591 | 342 of 591 |

Matching Words behaves similarly (277 of 591 changing mentor at *u* = 0.9). Nearly half
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
| 2023 | 84.77% | 82.74% | +2.03 pp | [−2.48, +6.63] | Fail | Fail |
| 2024 | 89.55% | 86.76% | +2.79 pp | [−0.47, +6.19] | Fail | Fail |
| 2025 | 87.85% | 81.31% | +6.54 pp | [−0.53, +13.89] | Fail | Fail |
| **Pooled** | **87.65%** | **84.43%** | **+3.21 pp** | **[+0.72, +5.77]** | **Fail** | Fail |

<small>Source: [`artifacts/speed_session_method_tost.csv`](artifacts/speed_session_method_tost.csv). Rates use the pipeline's own percentile denominator, so they sit below the pool-based figures in the Results table.</small>

Equivalence is not established at either margin. The pooled point estimate of +3.21 pp
lies inside ±5 pp, but the interval reaches +5.77 pp, and a TOST conclusion depends on the
interval rather than the point. This is a precision result. At 591 matched pairs the study
cannot certify a difference this small as small enough, which is the situation Lo, Datta &
Salami describe when a metric sits near its decision boundary.

The pooled interval is the one worth naming: [+0.72, +5.77] pp excludes zero, so across the
three years combined Cosine Similarity selected top-20% mentors at a reliably higher rate
than Matching Words. No individual year does: each single-year interval covers zero, and
the largest single-year gap, 2025's +6.54 pp, carries an interval half again as wide as the
pooled one. Pooling buys the precision that separates the methods; it does not create the
difference.

The methods also separate clearly on the number-one rate (26.4% against 17.8%, with
non-overlapping intervals), which the ±5 pp Top-20% test is not designed to detect.
Overlapping confidence intervals do not establish equivalence, and non-overlapping ones on
a second measure do not establish that the methods are interchangeable on the first.

**How this interval is computed.** The design is paired: the same 591 mentees are scored
under both methods, so the two arms are positively correlated. Lo, Datta & Salami (2025),
Eqs. (5)-(6), give an independent-samples Wald standard error, which assumes two separate
groups and therefore overstates the width here. `build_method_tost_table()` in
`run_all_synthetic.r` uses the paired score interval of Tango (1998) instead, via
`PropCIs::scoreci.mp` on the discordant pairs: 50 mentees selected under Cosine Similarity
only, 31 under Matching Words only, 468 under both. The independent formula would report
[−0.10, +6.53] pp on the same data against the paired [+0.72, +5.77] pp, an SE of 0.0201
against 0.0152. The ±5 pp verdict is Fail either way, so the conclusion is unchanged; the
width is not. `tost_sp_equiv_wald()` is retained in the script for that comparison and
feeds no reported number.

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
(junior, 417 mentees, n = 834 across both methods) and **Grades 5+** (senior, 174 mentees,
n = 348), pooled over years and methods. Positive outcome: a Top-20% mentor under the
pipeline's percentile definition. Every threshold below is the default already coded in
`run_all_synthetic.r`, and none was chosen for this write-up.

| Check | Role | Threshold | Estimate | Interval | Outcome |
|---|---|---|---|---|---|
| Disparate Impact (four-fifths rule) | Binding gate | DI 90% lower bound ≥ 0.80 | DI = 0.965 | 90% CI [0.928, 0.995] | **Pass** |
| Mean percentile gap, TOST equivalence | Binding gate | 90% CI within ±3 pp | −2.00 pp | 90% CI [−3.62, −0.25] | **Flag** |
| FOSD equivalence, TOST | Binding gate | sup 90% upper ≤ 0.10, inf 90% lower ≥ −0.10 | sup = 0.101, inf = −0.003 | sup 90% U = 0.158, inf 90% L = −0.031 | **Flag** |
| FOSD equivalence, strict | Sensitivity | sup 90% upper ≤ 0.05, inf 90% lower ≥ −0.05 | sup = 0.101, inf = −0.003 | sup 90% U = 0.158, inf 90% L = −0.031 | **Flag** |
| Standardised mean difference | Supportive, not a gate | \|SMD\| ≤ 0.30 | SMD = −0.119 | point estimate | **Pass** |
| Fisher exact, grade group x positive | Supportive, not a gate | reported, not thresholded | p = 0.169 | exact test | Reported |

**Selection rates behind the DI figure:** Grades 1-4, 85.13%; Grades 5+, 88.22%. Mean
percentile 10.07 against 8.07, where lower is better. Full table:
[`artifacts/fairness_checks.csv`](artifacts/fairness_checks.csv).

The gap of −2.00 pp favours senior mentees and is disclosed here rather than set aside.
It is worth being precise about what flags it. The point estimate sits comfortably inside
the ±3 pp equivalence margin; only the lower end of its interval, −3.62 pp, crosses. So
the Flag records that the data cannot certify equivalence, not that a large disparity was
found. The two supportive measures point the same way: |SMD| = 0.119 is well under the
0.30 threshold, and Fisher's exact test on the selection-rate difference returns p = 0.169,
which does not distinguish the two groups' rates from chance at conventional levels.

That combination is the honest summary: a small measured advantage to senior mentees,
consistent in direction across the checks, with intervals too wide at this sample size to
declare the procedure equivalent across grade groups. Reporting only the passing gate
would overstate the result, and reporting the Flag as a demonstrated disparity would
overstate it in the other direction.

What these data establish: the matching procedure clears the four-fifths rule for
selection-rate parity across grade groups, and does not clear equivalence testing on the
distribution of match quality across those same groups.

**This verdict depends on *u*, and *u* = 1.5 is a presentation choice rather than the
pipeline's own recommendation.** `presentation_u` is hardcoded to 1.5 at the top of
`run_all_synthetic.r`. The script also runs a selection routine over the whole grid, and
on these data that routine picks *u* = 0.9
([`artifacts/Proposed_u_decision.csv`](artifacts/Proposed_u_decision.csv)). At *u* = 0.9
the fairness picture is materially better:

| Gate | *u* = 1.5 | *u* = 0.9 |
|---|---|---|
| Disparate Impact | 0.965, 90% CI [0.928, 0.995] | 0.9998, 90% CI [0.951, 0.999] |
| Mean percentile gap | −2.00 pp, 90% CI [−3.62, −0.25], **Flag** | +0.19 pp, 90% CI [−1.54, +2.01], **Pass** |
| FOSD, sup 90% upper | 0.158, **Flag** | 0.116, **Flag** |
| \|SMD\| | 0.119 | 0.012 |

Two of the three binding gates pass at *u* = 0.9 against one at *u* = 1.5, and the mean
gap reverses sign, slightly favouring junior mentees. FOSD flags at both. Reporting
"1 of 3 binding gates" without naming the *u* it was measured at would overstate the
result, so the headline table names it. The *u* = 1.5 figures remain the headline for
comparability with Pack et al. (2026), which uses that value.

Treat the *u* = 0.9 column as a sensitivity check rather than a competing headline.
`Proposed_u_decision.csv` marks that row `passes_all = TRUE` while its own
`FOSD_sup_CI_U` of 0.116 exceeds the 0.10 margin, so the selection routine and the gate
table disagree about what passing means. See "Known issues" item 2.

## Why some checks fail here

Two of the three binding gates flag on these synthetic data. That is a property of this
demonstration, not a finding about anything else, and it is worth being explicit about the
mechanism rather than leaving a reader to guess at one.

**Method equivalence.** The pooled 90% CI here is [+0.72, +5.77] pp, missing the ±5 pp
margin by 0.77 pp at the upper end. The point estimate of +3.21 pp is comfortably inside
the margin; the interval is what misses it, so this is a precision result at n = 591 rather
than a large measured difference.

**Mean percentile gap.** The −2.00 pp advantage to senior mentees (90% CI [−3.62, −0.25],
|SMD| = 0.119) flags for the same reason: the point estimate sits inside the ±3 pp margin
and only the lower interval bound crosses it. |SMD| = 0.119 is well under the 0.30
supportive threshold, and Fisher's exact test returns p = 0.169.

Neither result points to a defect in the algorithm or the methodology. Both follow from
testing modest effects against tight margins on a cohort of 591 — the situation Lo, Datta
& Salami (2025) describe when a metric sits near its decision boundary, and the situation
the [companion power demonstration](https://github.com/RickPack/gale-shapley-fair-matching-demo#the-verdict-flips-as-the-cohort-shrinks)
isolates by holding everything but the cohort size fixed. The reporting convention is the
one that matters here: the gaps are stated and not softened.

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

Counted as they appear, with no stopword list, stemming, or length filter: 77,009 free-text
tokens across 3,647 distinct synthetic words, frequencies 1 to 4,483. The 53 most frequent
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

Both flagged gates here fit that pattern. The mean percentile gap and the method-equivalence
test each produced a point estimate inside its margin and an interval that crossed it.
Disparate Impact, which passes, relies on a ratio of proportions that converges faster than
a distributional equivalence test.

Lo, Datta & Salami motivate the framework partly by observing that "if a fairness criterion
is barely met or missed, it is often uncertain if it should be a 'pass' or 'failure,' if the
sample size is not large." The
[companion power demonstration](https://github.com/RickPack/gale-shapley-fair-matching-demo#the-verdict-flips-as-the-cohort-shrinks)
makes the mechanism visible without domain knowledge: holding the algorithm, the scoring
parameters, and the seed constant, n = 100 mentees fail the equivalence test and n = 250
pass it. Only the cohort size changes. That demonstration uses Tango's paired score interval
rather than the independent-samples formula this repository currently computes, so the two
are not directly comparable in width.

591 matched pairs is enough to establish the large advantage over random matching and enough
to measure the senior-mentee gap. It is not enough to certify method equivalence or
distributional equivalence across grade groups at these margins. A pass or fail reported
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
`overall_survey_match_num` carries 6.7 to 8.4 times the standard deviation of
`Cosine_Similarity × 100`, and 10.9 to 13.0 times that of `MW_count`, depending on the year
([`artifacts/score_components.csv`](artifacts/score_components.csv)). The paper's `× 100`
was a practical approximation calibrated to real survey text. Under it, *u* nominally
weights the survey term but the survey term already dominates before *u* is applied.
Z-scoring makes *u* the explicit relative-weight parameter: *u* = 1.5 means the survey
component gets 1.5 times the weight of the text component, as intended.

**Effect on results.** Rankings, Top-20% rates, and the TOST comparison differ from the
paper. The deviation is intentional and confined to this public synthetic demonstration. It
does not reflect a change to the methodology described in the paper.

## Known issues and limitations

1. **Fairness is not established.** Two of three binding gates flag, with a 2.00 pp
   advantage to senior mentees on mean percentile (see "Predefined fairness checks" for
   why that is a precision result, not a demonstrated disparity, and why it is still a
   reason to withhold a fairness claim).
2. **The *u* selection routine and the gate table disagree about what passing means.**
   `Proposed_u_decision.csv` marks the *u* = 0.9 row `passes_all = TRUE` while that same
   row's `FOSD_sup_CI_U` of 0.116 exceeds the 0.10 margin. The selector and the published
   gate table apply different rules, so the selector's recommendation should be read as a
   sensitivity check rather than a competing headline. The pipeline now reports that
   recommendation without acting on it (see below), so nothing published depends on the
   disagreement, but the two rules have not been reconciled.
3. **The Disparate Impact gate is one-sided.** Lo, Datta & Salami test DI against a
   two-sided acceptable range (their §3.3, typically [0.80, 1.20] or [0.80, 1.25]). This
   pipeline gates on the 90% lower bound against a 0.80 floor only, so a DI above the upper
   bound would not be caught. With DI at 0.965 the distinction does not bind here.
4. **Aggregate stability hides individual churn.** Pooled Top-20% rates vary by about two
   percentage points across the *u* grid while up to 278 of 591 mentees are matched to a
   different mentor. Do not read the flat summary as evidence that *u* is unimportant.
5. **`results_mentor_balance.csv` previously mislabelled its pool column.**
   `n_mentor_slots` was computed as `max(assigned rank)` while its own footnote described it
   as the total mentor entries given to Gale-Shapley. It now reads the pool size recorded in
   `matching_pool_<year>.csv` (206 / 287 / 124).
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
