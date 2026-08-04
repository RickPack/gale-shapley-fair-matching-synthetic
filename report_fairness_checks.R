#!/usr/bin/env Rscript
## report_fairness_checks.R -- the repository's PREDEFINED fairness checks, reported
## as run, with their own thresholds and their own pass/fail outcomes.
##
## Nothing here is a new fairness definition. Every threshold below is read from the
## defaults already coded in run_all_synthetic.r, and every estimate is read from
## artifacts/u_sweep_fairness_summary_with_fosd.csv. The point of the script is to
## stop the outcomes being summarised loosely: a high compatibility rate is not
## evidence of fairness, and two of these checks do not pass.
##
## Protected attribute: mentee grade, dichotomised by the pipeline into
## "Grades 1-4" (junior) and "Grades 5+" (senior).
## Positive outcome: mentor_percentile <= 20, i.e. a Top-20% mentor under the
## pipeline's own percentile definition.
##
## The checks, as coded:
##
##  1. Disparate Impact / four-fifths rule (BINDING GATE)
##     DI = SR_min / SR_max; passes when the 90% bootstrap lower bound >= 0.80.
##     run_all_synthetic.r: choose_presentation_u(di_floor = 0.80)
##
##  2. Mean percentile-gap equivalence, TOST (BINDING GATE)
##     mean(percentile | Grades 5+) - mean(percentile | Grades 1-4); passes when the
##     whole 90% bootstrap CI lies inside +/- 3 percentage points.
##     run_all_synthetic.r: choose_presentation_u(gap_margin = 3)
##
##  3. First-order stochastic dominance equivalence, TOST (BINDING GATE)
##     Passes when sup(ECDF gap) upper 90% bound <= 0.10 AND inf(ECDF gap) lower 90%
##     bound >= -0.10. A stricter 0.05 margin is reported as a sensitivity.
##     run_all_synthetic.r: fosd_delta = 0.10, fosd_delta_strict = 0.05
##
##  4. Standardised mean difference (SUPPORTIVE, not a gate)
##     |SMD| <= 0.30. smd_as_gate = FALSE in choose_presentation_u, following the
##     Salami & Lo alignment noted in that function.
##
##  5. Fisher exact test on grade group x positive outcome (SUPPORTIVE, not a gate)
##     fisher_alpha = NULL in choose_presentation_u, so it informs but does not gate.
##
## Usage:
##   Rscript report_fairness_checks.R
##   Rscript report_fairness_checks.R --artifacts artifacts --u 1.5 --out artifacts

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(tibble)
})

parse_args <- function(args) {
  get <- function(flag, default) {
    i <- which(args == flag)
    if (length(i) == 0) return(default)
    if (i + 1 > length(args)) stop(sprintf("%s needs a value.", flag))
    args[i + 1]
  }
  list(artifacts = get("--artifacts", "artifacts"),
       out       = get("--out", "artifacts"),
       u         = as.numeric(get("--u", "1.5")))
}
opt <- parse_args(commandArgs(trailingOnly = TRUE))

## Thresholds, mirroring the defaults in run_all_synthetic.r.
DI_FLOOR          <- 0.80
GAP_MARGIN        <- 3
SMD_MAX           <- 0.30
FOSD_DELTA        <- 0.10
FOSD_DELTA_STRICT <- 0.05

sweep_path <- file.path(opt$artifacts, "u_sweep_fairness_summary_with_fosd.csv")
if (!file.exists(sweep_path)) {
  stop(sprintf(paste0("Cannot find %s.\nRun run_all_synthetic.r first -- this script ",
                      "only reformats the pipeline's own fairness output."), sweep_path))
}
sweep <- read_csv(sweep_path, show_col_types = FALSE)

row <- sweep %>% filter(abs(u - opt$u) < 1e-9)
if (nrow(row) != 1) {
  stop(sprintf("Expected exactly one row at u = %.2f in %s; found %d. Available u: %s",
               opt$u, sweep_path, nrow(row), paste(sort(sweep$u), collapse = ", ")))
}

fmt <- function(x, d = 3) if (is.na(x)) "NA" else formatC(x, format = "f", digits = d)

checks <- tribble(
  ~id, ~check, ~role, ~threshold, ~estimate, ~interval, ~pass,

  1L, "Disparate Impact (four-fifths rule)", "Binding gate",
  sprintf("DI 90%% lower bound >= %.2f", DI_FLOOR),
  sprintf("DI = %s", fmt(row$DI)),
  sprintf("90%% CI [%s, %s]", fmt(row$DI_L90), fmt(row$DI_U90)),
  row$DI_L90 >= DI_FLOOR,

  2L, "Mean percentile gap, TOST equivalence", "Binding gate",
  sprintf("90%% CI within +/-%g pp", GAP_MARGIN),
  sprintf("gap = %s pp", fmt(row$mean_gap, 2)),
  sprintf("90%% CI [%s, %s]", fmt(row$mean_gap_L90, 2), fmt(row$mean_gap_U90, 2)),
  (row$mean_gap_L90 >= -GAP_MARGIN) && (row$mean_gap_U90 <= GAP_MARGIN),

  3L, "FOSD equivalence, TOST (margin 0.10)", "Binding gate",
  sprintf("sup 90%% upper <= %.2f and inf 90%% lower >= -%.2f", FOSD_DELTA, FOSD_DELTA),
  sprintf("sup = %s, inf = %s", fmt(row$FOSD_obs_sup), fmt(row$FOSD_obs_inf)),
  sprintf("sup 90%% U = %s; inf 90%% L = %s", fmt(row$FOSD_sup_CI_U), fmt(row$FOSD_inf_CI_L)),
  (row$FOSD_sup_CI_U <= FOSD_DELTA) && (row$FOSD_inf_CI_L >= -FOSD_DELTA),

  4L, "FOSD equivalence, strict sensitivity (0.05)", "Sensitivity",
  sprintf("sup 90%% upper <= %.2f and inf 90%% lower >= -%.2f",
          FOSD_DELTA_STRICT, FOSD_DELTA_STRICT),
  sprintf("sup = %s, inf = %s", fmt(row$FOSD_obs_sup), fmt(row$FOSD_obs_inf)),
  sprintf("sup 90%% U = %s; inf 90%% L = %s", fmt(row$FOSD_sup_CI_U), fmt(row$FOSD_inf_CI_L)),
  (row$FOSD_sup_CI_U <= FOSD_DELTA_STRICT) && (row$FOSD_inf_CI_L >= -FOSD_DELTA_STRICT),

  5L, "Standardised mean difference", "Supportive (not a gate)",
  sprintf("|SMD| <= %.2f", SMD_MAX),
  sprintf("SMD = %s", fmt(row$SMD)),
  "point estimate only",
  abs(row$SMD) <= SMD_MAX,

  6L, "Fisher exact test, grade group x positive", "Supportive (not a gate)",
  "reported, not thresholded",
  sprintf("p = %s", format(row$fisher_p, digits = 3, scientific = TRUE)),
  "exact test",
  NA
)

checks <- checks %>%
  mutate(
    u = opt$u,
    outcome = case_when(is.na(pass) ~ "Reported", pass ~ "Pass", TRUE ~ "Flag")
  ) %>%
  select(u, id, check, role, threshold, estimate, interval, outcome)

write_csv(checks, file.path(opt$out, "fairness_checks.csv"))

## Selection rates behind the DI figure, so the direction of the gap is explicit.
rates <- tibble(
  u = opt$u,
  group = c("Grades 1-4", "Grades 5+"),
  n = c(row$n_low, row$n_high),
  selection_rate_pct = 100 * c(row$sr_low, row$sr_high),
  mean_percentile = c(row$mean_pct_low, row$mean_pct_high)
)
write_csv(rates, file.path(opt$out, "fairness_selection_rates.csv"))

## ---- console summary ------------------------------------------------------------

gates <- checks %>% filter(role == "Binding gate")
n_pass <- sum(gates$outcome == "Pass")
n_gate <- nrow(gates)

cat(sprintf("\n=== Predefined fairness checks at u = %.2f ===\n", opt$u))
print(as.data.frame(checks %>% select(check, role, threshold, estimate, interval, outcome)),
      row.names = FALSE)

cat("\n=== Selection rates behind DI ===\n")
print(as.data.frame(rates %>% mutate(across(where(is.numeric), ~ round(.x, 2)))),
      row.names = FALSE)

cat(sprintf("\nBinding gates passed: %d of %d.\n", n_pass, n_gate))
direction <- if (row$mean_gap < 0) "Grades 5+ (senior)" else "Grades 1-4 (junior)"
cat(sprintf("Mean percentile gap %.2f pp favours %s (lower percentile is better).\n",
            row$mean_gap, direction))
if (n_pass < n_gate) {
  cat("Not all predefined gates pass. Any summary of this run must say so.\n")
}

cat("\nWrote:\n  ", file.path(opt$out, "fairness_checks.csv"),
    "\n  ", file.path(opt$out, "fairness_selection_rates.csv"), "\n")
