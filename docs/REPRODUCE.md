# Reproduction details

Supplements the "Reproducing every number" quick-start in the main
[README](../README.md): caching behaviour, determinism guarantees, environment
versions, and how to rebuild the synthetic CSVs from the original workbooks.

## Caching

**Step 1 caches its renders.** `run_all_synthetic.r` skips any *u* whose `.rds` files
already exist under `artifacts/u_*/`, which makes a re-run cheap but also means a change
to the scoring formula will not propagate on its own. **Delete `artifacts/u_*/` before
re-running after any edit to the scoring code** in `stable_matching_paper_synthetic.rmd`.
Skipping that step silently mixes outputs from two different formulas.

## Determinism

`tests/run_checks.R` group G re-runs `analyze_match_quality.R` and
`report_fairness_checks.R` and asserts that the headline table, the seeded benchmark, and
the fairness table are identical across runs. That covers the analysis layer given fixed
`.rds` inputs. It does not re-render the Rmd, so it will not detect a change in the
rendering step; the caching note above is the relevant safeguard there.

## How the synthetic CSVs were generated

**Not repeatable from this repository, by design.** The generation chain is
`build_synthetic_inputs.R`, then `scrub_org_fields.R`, then
`repair_synthetic_vocabulary.R` (see [`DATA_PROVENANCE.md`](DATA_PROVENANCE.md) for what
each script does). It ran once, against restricted inputs held outside this repository,
and its output is what `data/*.csv` contains. The scripts are published so the
de-identification can be read and checked, not so it can be re-run. Nothing in the
analysis path touches anything but the committed CSVs.

## Environment

| Component | Version |
|---|---|
| R | 4.6.1 (2026-06-24 ucrt) |
| Pandoc | required by `rmarkdown::render`; the runner falls back to the RStudio-bundled copy |
| dplyr / tidyr / purrr / tibble | 1.2.1 / 1.3.2 / 1.2.2 / 3.3.1 |
| readr / stringr | 2.2.0 / 1.6.0 |
| ggplot2 / ggpubr / scales | 4.0.3 / 1.0.0 / 1.4.0 |
| ggwordcloud | 0.6.2 |
| flextable / officer | 0.10.0 / 0.7.6 |
| rmarkdown / knitr / kableExtra | 2.31 / 1.51 / 1.4.1 |
| car / janitor / openxlsx / PropCIs | 3.1.5 / 2.2.1 / 4.2.8.1 / 0.3.0 |
| jsonlite | 2.0.0 |

Random number generation uses R's default Mersenne-Twister with
`sample.kind = "Rejection"`, so results reproduce on R 3.6.0 and later. Regenerating
under a different R build can move stored values in the last one or two significant
digits. That is floating-point arithmetic, not the seed drifting, and every figure the
README quotes is rounded far above it.
