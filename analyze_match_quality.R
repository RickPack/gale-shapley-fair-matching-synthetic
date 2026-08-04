#!/usr/bin/env Rscript
## analyze_match_quality.R -- match-quality estimands for the synthetic pipeline.
##
## Reads the per-(year, u) artifacts written by stable_matching_paper_synthetic.rmd
## and reports, with uncertainty and a benchmark, how good the assignments are:
##
##   Top-20% compatibility rate  -- share of mentees whose assigned mentor sits in the
##                                  best 20% of that mentee's eligible mentor pool.
##   Number-one compatibility rate -- share of mentees assigned their single
##                                  highest-predicted-compatibility mentor.
##
## DENOMINATOR (stated explicitly; see README "Definitions and denominators").
## The pipeline builds a complete mentee x mentor grid and ranks every mentor for
## every mentee, so a mentee's eligible pool is every mentor row in that grid. When
## mentees outnumber mentors the pipeline duplicates willing mentors until the counts
## match, and those duplicate rows are ranked like any other. The pool used here is
## therefore the POST-DUPLICATION pool, recorded per year in matching_pool_<year>.csv
## and verified against the grid size by the Rmd itself.
##
## This is NOT the same denominator as the pipeline's own `mentor_percentile`, which
## normalises by max(assigned rank) rather than by the pool size. Both are reported:
## `*_pool` columns use the pool, `*_repo` columns reproduce the pipeline's
## definition. The pool denominator is larger, so its threshold is more permissive.
##
## TIE RULE. Predicted-compatibility ties are broken before ranking by adding seeded
## U(1e-6, 9e-6) jitter to every score (Rmd, "Weights" section), so every mentee's
## ranking is a strict total order and no rank is shared. The resolution is exactly
## reproducible for a given seed; run_seed_sensitivity.R quantifies its influence.
##
## BENCHMARK. Random feasible matching. Under a uniformly random assignment of
## mentees to distinct mentor slots, each mentee's assigned mentor is a uniformly
## random member of that mentee's own ranking, so its rank is Uniform{1..N_pool}.
## Mentees rank the pool differently from one another, so these are simulated as
## independent draws. Reported as the mean rate over `--sims` replicates with a 2.5th
## to 97.5th percentile band.
##
## Usage:
##   Rscript analyze_match_quality.R
##   Rscript analyze_match_quality.R --artifacts artifacts --out artifacts \
##                                   --sims 2000 --seed 42 --presentation-u 1.5

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(purrr)
  library(tidyr)
  library(tibble)
})

## ---- arguments ----------------------------------------------------------------

parse_args <- function(args) {
  get <- function(flag, default) {
    i <- which(args == flag)
    if (length(i) == 0) return(default)
    if (i + 1 > length(args)) stop(sprintf("%s needs a value.", flag))
    args[i + 1]
  }
  list(
    artifacts       = get("--artifacts", "artifacts"),
    out             = get("--out", "artifacts"),
    sims            = as.integer(get("--sims", "2000")),
    seed            = as.integer(get("--seed", "42")),
    presentation_u  = as.numeric(get("--presentation-u", "1.5")),
    top_p           = as.numeric(get("--top-p", "20"))
  )
}

opt <- parse_args(commandArgs(trailingOnly = TRUE))

if (!dir.exists(opt$artifacts)) {
  stop(sprintf("Artifacts folder not found: %s\nRun run_all_synthetic.r first.", opt$artifacts))
}
dir.create(opt$out, recursive = TRUE, showWarnings = FALSE)

## ---- helpers ------------------------------------------------------------------

## Clopper-Pearson exact binomial interval, in percent. Exact rather than Wald
## because the number-one rate is small and several per-year cells are under 120.
cp_ci <- function(k, n, conf = 0.95) {
  a <- (1 - conf) / 2
  lo <- ifelse(k == 0, 0, qbeta(a, k, n - k + 1))
  hi <- ifelse(k == n, 1, qbeta(1 - a, k + 1, n - k))
  c(lo = 100 * lo, hi = 100 * hi)
}

## Best 20% of a pool of N. floor() is the conservative reading of "top p%": with
## N = 206 and p = 20 it admits ranks 1..41 rather than 1..42.
top_cutoff <- function(n_pool, p) floor(p / 100 * n_pool)

u_tag_of <- function(u) gsub("\\.", "p", sprintf("%.3f", u))
u_of_tag <- function(tag) as.numeric(gsub("p", ".", sub("^u_", "", tag)))

## ---- inputs -------------------------------------------------------------------

pool_files <- list.files(opt$artifacts, pattern = "^matching_pool_[0-9]{4}\\.csv$",
                         full.names = TRUE)
if (length(pool_files) == 0) {
  stop(sprintf(paste0("No matching_pool_<year>.csv in %s.\n",
                      "These record the eligible-mentor pool size and are written by ",
                      "stable_matching_paper_synthetic.rmd. Re-run run_all_synthetic.r."),
               opt$artifacts))
}
pools <- map_dfr(pool_files, ~ read_csv(.x, show_col_types = FALSE))
years <- sort(unique(pools$year))

u_dirs <- list.files(opt$artifacts, pattern = "^u_[0-9]p[0-9]{3}$")
if (length(u_dirs) == 0) stop(sprintf("No u_* subfolders in %s.", opt$artifacts))

methods <- c("Cosine Similarity" = "cos_sim", "Matching Words" = "word_matching")

## ---- per-cell estimands --------------------------------------------------------

cells <- expand_grid(u_dir = u_dirs, year = years, method_label = names(methods)) %>%
  mutate(u = u_of_tag(u_dir), method_key = unname(methods[method_label]))

read_cell <- function(u_dir, year, method_key) {
  f <- file.path(opt$artifacts, u_dir, sprintf("fair_df_%s_%d.rds", method_key, year))
  if (!file.exists(f)) return(NULL)
  readRDS(f)
}

results <- pmap_dfr(
  list(cells$u_dir, cells$year, cells$method_key, cells$method_label, cells$u),
  function(u_dir, year, method_key, method_label, u) {
    df <- read_cell(u_dir, year, method_key)
    if (is.null(df)) return(NULL)

    n_pool <- pools$n_mentor_post_duplication[pools$year == year]
    if (length(n_pool) != 1) stop(sprintf("No pool size recorded for year %d.", year))

    ranks <- df$mentee_rank
    n <- length(ranks)
    if (any(is.na(ranks))) stop(sprintf("NA rank in %s/%d/%s.", u_dir, year, method_key))
    if (max(ranks) > n_pool) {
      stop(sprintf("Rank %d exceeds pool size %d in %s/%d/%s.",
                   max(ranks), n_pool, u_dir, year, method_key))
    }

    cut_pool <- top_cutoff(n_pool, opt$top_p)
    k_top_pool <- sum(ranks <= cut_pool)
    k_top_repo <- sum(df$mentor_percentile <= opt$top_p)
    k_one      <- sum(ranks == 1)

    ci_top_pool <- cp_ci(k_top_pool, n)
    ci_top_repo <- cp_ci(k_top_repo, n)
    ci_one      <- cp_ci(k_one, n)

    tibble(
      year = year, method = method_label, u = u,
      n_mentees = n, n_mentor_pool = n_pool, top20_cutoff_rank = cut_pool,
      k_top20_pool = k_top_pool,
      pct_top20_pool = 100 * k_top_pool / n,
      top20_pool_lo = ci_top_pool[["lo"]], top20_pool_hi = ci_top_pool[["hi"]],
      k_rank1 = k_one,
      pct_rank1 = 100 * k_one / n,
      rank1_lo = ci_one[["lo"]], rank1_hi = ci_one[["hi"]],
      pct_top20_repo = 100 * k_top_repo / n,
      top20_repo_lo = ci_top_repo[["lo"]], top20_repo_hi = ci_top_repo[["hi"]],
      mean_pool_percentile = 100 * mean((ranks - 1) / (n_pool - 1)),
      median_rank = median(ranks)
    )
  }
) %>% arrange(u, year, method)

if (nrow(results) == 0) stop("No fair_df_*.rds artifacts were readable.")

write_csv(results, file.path(opt$out, "match_quality_by_year_method_u.csv"))

## ---- random-feasible-matching benchmark ---------------------------------------

set.seed(opt$seed)
benchmark <- map_dfr(years, function(yr) {
  n_pool <- pools$n_mentor_post_duplication[pools$year == yr]
  n      <- pools$n_mentee[pools$year == yr]
  cut    <- top_cutoff(n_pool, opt$top_p)
  draws  <- matrix(sample.int(n_pool, n * opt$sims, replace = TRUE), nrow = opt$sims)
  top    <- 100 * rowMeans(draws <= cut)
  one    <- 100 * rowMeans(draws == 1)
  tibble(
    year = yr, n_mentees = n, n_mentor_pool = n_pool, sims = opt$sims, seed = opt$seed,
    bench_top20_mean = mean(top),
    bench_top20_lo = unname(quantile(top, 0.025)),
    bench_top20_hi = unname(quantile(top, 0.975)),
    bench_rank1_mean = mean(one),
    bench_rank1_lo = unname(quantile(one, 0.025)),
    bench_rank1_hi = unname(quantile(one, 0.975)),
    bench_top20_expected = 100 * cut / n_pool,
    bench_rank1_expected = 100 / n_pool
  )
})

## Pooled benchmark: all mentees across all three years, same replicate structure.
set.seed(opt$seed)
pooled_bench <- {
  per_year <- map(years, function(yr) {
    n_pool <- pools$n_mentor_post_duplication[pools$year == yr]
    n      <- pools$n_mentee[pools$year == yr]
    cut    <- top_cutoff(n_pool, opt$top_p)
    d      <- matrix(sample.int(n_pool, n * opt$sims, replace = TRUE), nrow = opt$sims)
    list(top = rowSums(d <= cut), one = rowSums(d == 1), n = n)
  })
  n_tot <- sum(map_dbl(per_year, "n"))
  top <- 100 * reduce(map(per_year, "top"), `+`) / n_tot
  one <- 100 * reduce(map(per_year, "one"), `+`) / n_tot
  tibble(
    year = "Pooled", n_mentees = n_tot, n_mentor_pool = NA_integer_,
    sims = opt$sims, seed = opt$seed,
    bench_top20_mean = mean(top),
    bench_top20_lo = unname(quantile(top, 0.025)),
    bench_top20_hi = unname(quantile(top, 0.975)),
    bench_rank1_mean = mean(one),
    bench_rank1_lo = unname(quantile(one, 0.025)),
    bench_rank1_hi = unname(quantile(one, 0.975)),
    bench_top20_expected = NA_real_, bench_rank1_expected = NA_real_
  )
}

benchmark_out <- bind_rows(mutate(benchmark, year = as.character(year)), pooled_bench)
write_csv(benchmark_out, file.path(opt$out, "match_quality_benchmark.csv"))

## ---- headline table at the presentation u --------------------------------------

pu <- opt$presentation_u
headline_years <- results %>% filter(abs(u - pu) < 1e-9)
if (nrow(headline_years) == 0) {
  stop(sprintf("No results at presentation u = %.2f. Available: %s",
               pu, paste(sort(unique(results$u)), collapse = ", ")))
}

pooled <- headline_years %>%
  group_by(method) %>%
  summarise(
    year = "Pooled",
    u = pu,
    n_mentees = sum(n_mentees),
    k_top20_pool = sum(k_top20_pool),
    k_rank1 = sum(k_rank1),
    .groups = "drop"
  ) %>%
  rowwise() %>%
  mutate(
    pct_top20_pool = 100 * k_top20_pool / n_mentees,
    top20_pool_lo = cp_ci(k_top20_pool, n_mentees)[["lo"]],
    top20_pool_hi = cp_ci(k_top20_pool, n_mentees)[["hi"]],
    pct_rank1 = 100 * k_rank1 / n_mentees,
    rank1_lo = cp_ci(k_rank1, n_mentees)[["lo"]],
    rank1_hi = cp_ci(k_rank1, n_mentees)[["hi"]]
  ) %>%
  ungroup()

headline <- bind_rows(
  headline_years %>%
    mutate(year = as.character(year)) %>%
    select(year, method, u, n_mentees, n_mentor_pool, top20_cutoff_rank,
           k_top20_pool, pct_top20_pool, top20_pool_lo, top20_pool_hi,
           k_rank1, pct_rank1, rank1_lo, rank1_hi, pct_top20_repo, mean_pool_percentile),
  pooled %>%
    select(year, method, u, n_mentees, k_top20_pool, pct_top20_pool,
           top20_pool_lo, top20_pool_hi, k_rank1, pct_rank1, rank1_lo, rank1_hi)
) %>%
  left_join(benchmark_out %>% select(year, bench_top20_mean, bench_top20_lo,
                                     bench_top20_hi, bench_rank1_mean,
                                     bench_rank1_lo, bench_rank1_hi),
            by = "year")

write_csv(headline, file.path(opt$out, "match_quality_headline.csv"))

## ---- why u does or does not matter ------------------------------------------------

## Collect the score-component spreads the Rmd records, if present. These explain how
## much leverage u has: a mentee's ranking comes from Cosine_Similarity * 100 +
## u * overall_survey_match_num, so if the survey-match term dwarfs the text term the
## score is very nearly u times a fixed quantity, u is a positive rescaling, and the
## ordering cannot change. Older artifact folders predate this file; its absence is
## not an error.
sc_files <- list.files(opt$artifacts, pattern = "^score_components_[0-9]{4}\\.csv$",
                       recursive = TRUE, full.names = TRUE)
if (length(sc_files) > 0) {
  score_components <- map_dfr(sc_files, ~ read_csv(.x, show_col_types = FALSE)) %>%
    distinct() %>%
    arrange(year, u, component)
  write_csv(score_components, file.path(opt$out, "score_components.csv"))

  dominance <- score_components %>%
    select(year, u, component, scaled_sd) %>%
    pivot_wider(names_from = component, values_from = scaled_sd) %>%
    mutate(
      cos_vs_survey = overall_survey_match_num / Cosine_Similarity,
      mw_vs_survey  = overall_survey_match_num / MW_count
    )
  write_csv(dominance, file.path(opt$out, "score_component_dominance.csv"))

  cat("\n=== Score-component spread (SD scaled into score units) ===\n")
  dominance %>%
    mutate(across(where(is.numeric), ~ round(.x, 3))) %>%
    as.data.frame() %>%
    print(row.names = FALSE)
  cat("Survey-match term outweighs the cosine term by the ratio in cos_vs_survey.\n")
}

## ---- stability across the u grid ------------------------------------------------

u_stability <- results %>%
  group_by(method, u) %>%
  summarise(
    n_mentees = sum(n_mentees),
    pct_top20_pool = 100 * sum(k_top20_pool) / sum(n_mentees),
    pct_rank1 = 100 * sum(k_rank1) / sum(n_mentees),
    .groups = "drop"
  ) %>%
  arrange(method, u)
write_csv(u_stability, file.path(opt$out, "match_quality_u_stability.csv"))

## ---- console summary -------------------------------------------------------------

cat("\n=== Match quality at u =", pu, "(pool denominator) ===\n")
headline %>%
  mutate(across(where(is.numeric), ~ round(.x, 2))) %>%
  select(year, method, n_mentees, pct_top20_pool, top20_pool_lo, top20_pool_hi,
         bench_top20_mean, pct_rank1, rank1_lo, rank1_hi, bench_rank1_mean) %>%
  as.data.frame() %>%
  print(row.names = FALSE)

cat("\n=== Range across the u grid (pooled across years) ===\n")
u_stability %>%
  group_by(method) %>%
  summarise(
    top20_min = round(min(pct_top20_pool), 1), top20_max = round(max(pct_top20_pool), 1),
    rank1_min = round(min(pct_rank1), 1), rank1_max = round(max(pct_rank1), 1),
    n_u = n(), .groups = "drop"
  ) %>%
  as.data.frame() %>%
  print(row.names = FALSE)

cat("\nWrote:\n",
    file.path(opt$out, "match_quality_by_year_method_u.csv"), "\n",
    file.path(opt$out, "match_quality_headline.csv"), "\n",
    file.path(opt$out, "match_quality_benchmark.csv"), "\n",
    file.path(opt$out, "match_quality_u_stability.csv"), "\n")
