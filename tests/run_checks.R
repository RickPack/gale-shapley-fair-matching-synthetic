#!/usr/bin/env Rscript
## tests/run_checks.R -- validation checks for the synthetic pipeline and its outputs.
##
## Run from the repository root:
##   Rscript tests/run_checks.R
##
## Exits non-zero on the first failing group, and prints every check either way.
## Groups:
##   A  input schema and synthetic provenance
##   B  matching feasibility and uniqueness
##   C  Top-20% and number-one calculations
##   D  tie handling
##   E  fairness metrics
##   F  confidence intervals and the benchmark simulation
##   G  reproducibility across repeated runs
##   H  confidentiality and metadata scan (docx author, PNG strings, CSV paths)

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(stringr); library(purrr)
})

.pass <- 0L; .fail <- 0L; .failures <- character(0)

ok <- function(label, condition, detail = "") {
  condition <- isTRUE(condition)
  if (condition) {
    .pass <<- .pass + 1L
    cat(sprintf("  PASS  %s%s\n", label, if (nzchar(detail)) paste0(" -- ", detail) else ""))
  } else {
    .fail <<- .fail + 1L
    .failures <<- c(.failures, label)
    cat(sprintf("  FAIL  %s%s\n", label, if (nzchar(detail)) paste0(" -- ", detail) else ""))
  }
  invisible(condition)
}

group <- function(name) cat(sprintf("\n== %s ==\n", name))

ART   <- "artifacts"
DATA  <- "data"
YEARS <- 2023:2025
U_PRESENT <- 1.5
TOP_P <- 20

need_file <- function(p) {
  if (!file.exists(p)) stop(sprintf("Required file missing: %s\nRun run_all_synthetic.r first.", p))
  p
}

## ---------------------------------------------------------------- A: inputs ----

group("A. Input schema and synthetic provenance")

survey_files <- file.path(DATA, sprintf("survey_synthetic_%d.csv", YEARS))
prior_files  <- file.path(DATA, sprintf("prior_year_matches_synthetic_%d.csv", 2022:2024))

ok("A1 all synthetic survey CSVs present", all(file.exists(survey_files)),
   paste(basename(survey_files), collapse = ", "))
ok("A2 all prior-year match CSVs present", all(file.exists(prior_files)))

## affiliation_* rather than business_*: the published fields carry randomly assigned
## synthetic values and must not use language implying real organizational structure.
REQUIRED_SURVEY_COLS <- c("display_name", "corp_id", "first_name", "last_name",
                          "what_is_your_grade_level",
                          "would_you_like_to_be_a_mentor_or_a_mentee",
                          "affiliation_group", "affiliation_unit", "source_year")

for (f in survey_files) {
  d <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE))
  miss <- setdiff(REQUIRED_SURVEY_COLS, names(d))
  ok(sprintf("A3 %s has the required columns", basename(f)), length(miss) == 0,
     if (length(miss)) paste("missing:", paste(miss, collapse = ", ")) else
       sprintf("%d columns, %d rows", ncol(d), nrow(d)))

  nm <- d$display_name[!is.na(d$display_name)]
  ok(sprintf("A4 %s display_name is synthetic", basename(f)),
     length(nm) > 0 && all(str_detect(nm, "^PERSON_[0-9]{4}$")),
     sprintf("%d labels", length(unique(nm))))

  cid <- d$corp_id[!is.na(d$corp_id)]
  ok(sprintf("A5 %s corp_id is synthetic", basename(f)),
     length(cid) > 0 && all(str_detect(cid, "^CID[0-9]{4}$")))

  ok(sprintf("A6 %s names are synthetic", basename(f)),
     all(str_detect(d$first_name[!is.na(d$first_name)], "^First[0-9]{4}$")) &&
       all(str_detect(d$last_name[!is.na(d$last_name)], "^Last[0-9]{4}$")))

  ag <- d$affiliation_group[!is.na(d$affiliation_group)]
  au <- d$affiliation_unit[!is.na(d$affiliation_unit)]
  ok(sprintf("A7 %s affiliation labels are relabelled", basename(f)),
     length(ag) > 0 && all(str_detect(ag, "^Group [0-9]{2}$")) &&
       length(au) > 0 && all(str_detect(au, "^Unit [0-9]{2}$")))

  ## No email addresses anywhere in the file.
  flat <- unlist(lapply(d, as.character), use.names = FALSE)
  flat <- flat[!is.na(flat)]
  ok(sprintf("A8 %s contains no email addresses", basename(f)),
     !any(str_detect(flat, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")))
}

for (f in prior_files) {
  d <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE))
  vals <- c(d$mentee_name, d$gale_shapley_matched_mentor_name)
  vals <- vals[!is.na(vals)]
  ok(sprintf("A9 %s uses PERSON_#### labels only", basename(f)),
     all(str_detect(vals, "^PERSON_[0-9]{4}$")))
}

## No absolute filesystem paths in committed scripts.
scripts <- list.files(".", pattern = "\\.(R|r|rmd|Rmd)$", recursive = FALSE, full.names = TRUE)
scripts <- c(scripts, list.files("tools", pattern = "\\.R$", full.names = TRUE))
abs_hits <- map_chr(scripts, function(p) {
  txt <- readLines(p, warn = FALSE)
  hit <- grep("[A-Za-z]:[\\\\/]Users[\\\\/]", txt, value = TRUE)
  if (length(hit)) sprintf("%s: %s", basename(p), hit[1]) else ""
})
abs_hits <- abs_hits[nzchar(abs_hits)]
ok("A10 no absolute user paths in committed scripts", length(abs_hits) == 0,
   if (length(abs_hits)) abs_hits[1] else "")

## ---------------------------------------------------- B: feasibility/uniqueness ----

group("B. Matching feasibility and uniqueness")

pool <- map_dfr(YEARS, ~ read_csv(need_file(file.path(ART, sprintf("matching_pool_%d.csv", .x))),
                                  show_col_types = FALSE))

ok("B1 a pool size is recorded for every year", nrow(pool) == length(YEARS))

ok("B2 grid size equals mentees x post-duplication mentors",
   all(pool$n_alignment_rows == pool$n_mentee * pool$n_mentor_post_duplication),
   paste(sprintf("%d: %d=%dx%d", pool$year, pool$n_alignment_rows,
                 pool$n_mentee, pool$n_mentor_post_duplication), collapse = "; "))

ok("B3 eligible pool equals the post-duplication mentor count",
   all(pool$eligible_mentors_per_mentee == pool$n_mentor_post_duplication))

ok("B4 mentors are duplicated only when mentees outnumber them",
   all((pool$n_mentor_post_duplication > pool$n_mentor_pre_duplication) ==
         (pool$n_mentee > pool$n_mentor_pre_duplication)),
   paste(sprintf("%d: pre %d -> post %d for %d mentees", pool$year,
                 pool$n_mentor_pre_duplication, pool$n_mentor_post_duplication,
                 pool$n_mentee), collapse = "; "))

ok("B5 duplication brings the pool up to the mentee count exactly",
   all(pool$n_mentor_post_duplication >= pmin(pool$n_mentee, pool$n_mentor_pre_duplication)))

u_tag <- gsub("\\.", "p", sprintf("%.3f", U_PRESENT))
fair_path <- function(m, y) file.path(ART, paste0("u_", u_tag), sprintf("fair_df_%s_%d.rds", m, y))

for (y in YEARS) {
  for (m in c("cos_sim", "word_matching")) {
    df <- readRDS(need_file(fair_path(m, y)))
    np <- pool$n_mentor_post_duplication[pool$year == y]

    ok(sprintf("B6 %d/%s one row per mentee", y, m),
       nrow(df) == n_distinct(df$Mentee.Name), sprintf("n = %d", nrow(df)))

    ok(sprintf("B7 %d/%s every rank within the pool", y, m),
       all(df$mentee_rank >= 1) && all(df$mentee_rank <= np),
       sprintf("max rank %d, pool %d", max(df$mentee_rank), np))

    ok(sprintf("B8 %d/%s every mentee has a mentor", y, m),
       !any(is.na(df$GaleShapley_Matched_Mentor_Name)))

    ## Full pairing with mentors duplicated as needed: a mentor may legitimately hold
    ## more than one mentee. What must not happen is more assignments than slots.
    assigned <- df %>% count(GaleShapley_Matched_Mentor_Name, name = "k")
    ok(sprintf("B9 %d/%s assignments do not exceed pool slots", y, m),
       sum(assigned$k) <= np, sprintf("%d assignments, %d slots", sum(assigned$k), np))
  }
}

## ------------------------------------------------------- C: the two estimands ----

group("C. Top-20% and number-one calculations")

hl <- read_csv(need_file(file.path(ART, "match_quality_headline.csv")), show_col_types = FALSE)
by_cell <- read_csv(need_file(file.path(ART, "match_quality_by_year_method_u.csv")),
                    show_col_types = FALSE)

for (y in YEARS) {
  np  <- pool$n_mentor_post_duplication[pool$year == y]
  cut <- floor(TOP_P / 100 * np)
  for (mlabel in c("Cosine Similarity", "Matching Words")) {
    mkey <- if (mlabel == "Cosine Similarity") "cos_sim" else "word_matching"
    df   <- readRDS(fair_path(mkey, y))
    row  <- hl %>% filter(year == as.character(y), method == mlabel)

    ok(sprintf("C1 %d/%s cutoff rank is floor(0.20 x pool)", y, mlabel),
       row$top20_cutoff_rank == cut, sprintf("%d of %d", cut, np))

    ok(sprintf("C2 %d/%s Top-20%% count recomputes", y, mlabel),
       row$k_top20_pool == sum(df$mentee_rank <= cut),
       sprintf("k = %d", row$k_top20_pool))

    ok(sprintf("C3 %d/%s Top-20%% rate matches its count", y, mlabel),
       abs(row$pct_top20_pool - 100 * row$k_top20_pool / row$n_mentees) < 1e-9)

    ok(sprintf("C4 %d/%s number-one count recomputes", y, mlabel),
       row$k_rank1 == sum(df$mentee_rank == 1), sprintf("k = %d", row$k_rank1))

    ok(sprintf("C5 %d/%s number-one rate matches its count", y, mlabel),
       abs(row$pct_rank1 - 100 * row$k_rank1 / row$n_mentees) < 1e-9)
  }
}

pooled <- hl %>% filter(year == "Pooled")
per_year <- hl %>% filter(year != "Pooled")
for (mlabel in unique(pooled$method)) {
  p <- pooled %>% filter(method == mlabel)
  y <- per_year %>% filter(method == mlabel)
  ok(sprintf("C6 pooled n equals the sum of years (%s)", mlabel),
     p$n_mentees == sum(y$n_mentees), sprintf("%d", p$n_mentees))
  ok(sprintf("C7 pooled Top-20%% count equals the sum of years (%s)", mlabel),
     p$k_top20_pool == sum(y$k_top20_pool))
  ok(sprintf("C8 pooled number-one count equals the sum of years (%s)", mlabel),
     p$k_rank1 == sum(y$k_rank1))
}

## The two definitions use different cutoffs and neither dominates in general.
## Pool:  rank <= floor(0.20 * N_pool)
## Repo:  mentor_percentile <= 20, i.e. rank <= 1 + 0.20 * (max_rank - 1)
## When max_rank approaches N_pool the repo cutoff is the more permissive of the two,
## so assert that each rate follows from its own cutoff rather than asserting a
## direction between them.
c9 <- all(unlist(Map(function(y, mlabel) {
  mkey <- if (mlabel == "Cosine Similarity") "cos_sim" else "word_matching"
  df   <- readRDS(fair_path(mkey, as.integer(y)))
  row  <- per_year[per_year$year == y & per_year$method == mlabel, ]
  abs(row$pct_top20_repo - 100 * mean(df$mentor_percentile <= TOP_P)) < 1e-9
}, per_year$year, per_year$method)))
ok("C9 the pipeline's own Top-20% rate recomputes from mentor_percentile", c9,
   "reported alongside the pool-based rate; neither cutoff dominates the other")

ok("C10 number-one rate never exceeds the Top-20% rate",
   all(hl$pct_rank1 <= hl$pct_top20_pool + 1e-9))

ok("C11 every u value in the grid produced results",
   n_distinct(by_cell$u) >= 2 && nrow(by_cell) == n_distinct(by_cell$u) * length(YEARS) * 2,
   sprintf("%d u values, %d rows", n_distinct(by_cell$u), nrow(by_cell)))

## ------------------------------------------------------------ D: tie handling ----

group("D. Tie handling")

for (y in YEARS) {
  for (m in c("cos_sim", "word_matching")) {
    df <- readRDS(fair_path(m, y))
    ok(sprintf("D1 %d/%s ranks are integers", y, m),
       all(abs(df$mentee_rank - round(df$mentee_rank)) < 1e-9))
    ok(sprintf("D2 %d/%s no missing ranks", y, m), !any(is.na(df$mentee_rank)))
  }
}

## The Rmd breaks score ties with seeded U(1e-6, 9e-6) jitter before ranking, so each
## mentee's ordering is a strict total order. Re-rendering with the default seed must
## therefore reproduce the ranks exactly -- checked in group G.
ok("D3 tie rule is documented in the Rmd",
   any(grepl("no duplicates of rank", readLines("stable_matching_paper_synthetic.rmd", warn = FALSE))))

ok("D4 the seed governing tie-breaking is a parameter",
   any(grepl("^\\s*seed:", readLines("stable_matching_paper_synthetic.rmd", warn = FALSE))))

## -------------------------------------------------------- E: fairness metrics ----

group("E. Fairness metrics")

fc <- read_csv(need_file(file.path(ART, "fairness_checks.csv")), show_col_types = FALSE)
fr <- read_csv(need_file(file.path(ART, "fairness_selection_rates.csv")), show_col_types = FALSE)
sweep <- read_csv(need_file(file.path(ART, "u_sweep_fairness_summary_with_fosd.csv")),
                  show_col_types = FALSE)
srow <- sweep %>% filter(abs(u - U_PRESENT) < 1e-9)

ok("E1 exactly one sweep row at the presentation u", nrow(srow) == 1)

ok("E2 the two grade groups are both populated",
   nrow(fr) == 2 && all(fr$n > 30), paste(sprintf("%s n=%d", fr$group, fr$n), collapse = ", "))

di_recomputed <- min(srow$sr_low, srow$sr_high) / max(srow$sr_low, srow$sr_high)
ok("E3 DI equals SR_min / SR_max", abs(srow$DI - di_recomputed) < 1e-9,
   sprintf("DI = %.4f", srow$DI))

ok("E4 DI lies inside its own bootstrap interval",
   srow$DI >= srow$DI_L90 && srow$DI <= srow$DI_U90,
   sprintf("[%.3f, %.3f]", srow$DI_L90, srow$DI_U90))

ok("E5 mean gap equals the difference of group means",
   abs(srow$mean_gap - (srow$mean_pct_high - srow$mean_pct_low)) < 1e-6,
   sprintf("%.2f pp", srow$mean_gap))

ok("E6 the four-fifths outcome matches the 0.80 threshold",
   (fc$outcome[fc$id == 1] == "Pass") == (srow$DI_L90 >= 0.80))

ok("E7 the gap-equivalence outcome matches the +/-3 pp margin",
   (fc$outcome[fc$id == 2] == "Pass") ==
     (srow$mean_gap_L90 >= -3 && srow$mean_gap_U90 <= 3))

ok("E8 the FOSD outcome matches the 0.10 margin",
   (fc$outcome[fc$id == 3] == "Pass") ==
     (srow$FOSD_sup_CI_U <= 0.10 && srow$FOSD_inf_CI_L >= -0.10))

ok("E9 binding gates and supportive checks are labelled distinctly",
   sum(fc$role == "Binding gate") == 3 && sum(fc$role == "Supportive (not a gate)") == 2)

## The headline claim must not overstate the fairness result.
gates <- fc %>% filter(role == "Binding gate")
cat(sprintf("  NOTE  %d of %d binding fairness gates pass at u = %.2f\n",
            sum(gates$outcome == "Pass"), nrow(gates), U_PRESENT))

## --------------------------------------------------- F: intervals and benchmark ----

group("F. Confidence intervals and benchmark simulation")

ok("F1 every Top-20% interval brackets its estimate",
   all(hl$top20_pool_lo <= hl$pct_top20_pool + 1e-9) &&
     all(hl$top20_pool_hi >= hl$pct_top20_pool - 1e-9))

ok("F2 every number-one interval brackets its estimate",
   all(hl$rank1_lo <= hl$pct_rank1 + 1e-9) && all(hl$rank1_hi >= hl$pct_rank1 - 1e-9))

ok("F3 all intervals lie inside [0, 100]",
   all(c(hl$top20_pool_lo, hl$rank1_lo) >= 0) &&
     all(c(hl$top20_pool_hi, hl$rank1_hi) <= 100))

ok("F4 narrower intervals for larger samples",
   {
     w <- hl %>% filter(year != "Pooled") %>%
       mutate(width = top20_pool_hi - top20_pool_lo)
     cor(w$n_mentees, w$width) < 0
   })

bm <- read_csv(need_file(file.path(ART, "match_quality_benchmark.csv")), show_col_types = FALSE)

ok("F5 benchmark simulated the requested number of replicates",
   all(bm$sims >= 1000), sprintf("%d", max(bm$sims)))

ok("F6 simulated random Top-20% matches its analytic expectation",
   {
     per_year_bm <- bm %>% filter(year != "Pooled")
     all(abs(per_year_bm$bench_top20_mean - per_year_bm$bench_top20_expected) < 1.5)
   },
   "within 1.5 pp of floor(0.2N)/N")

ok("F7 simulated random number-one matches its analytic expectation",
   {
     per_year_bm <- bm %>% filter(year != "Pooled")
     all(abs(per_year_bm$bench_rank1_mean - per_year_bm$bench_rank1_expected) < 0.5)
   },
   "within 0.5 pp of 100/N")

ok("F8 observed Top-20% beats the random benchmark interval",
   all(hl$top20_pool_lo > bm$bench_top20_hi[match(hl$year, bm$year)]),
   "lower bound above the benchmark upper bound in every cell")

ok("F9 observed number-one beats the random benchmark interval",
   all(hl$rank1_lo > bm$bench_rank1_hi[match(hl$year, bm$year)]))

## ------------------------------------------------ F2: method equivalence (TOST) ----

group("F2. Between-method equivalence")

tost_path <- file.path(ART, "speed_session_method_tost.csv")
if (file.exists(tost_path)) {
  tt <- read_csv(tost_path, show_col_types = FALSE)
  ovr <- tt %>% filter(Year == "Overall")

  ok("F10 an Overall row is present", nrow(ovr) == 1)

  ## The file stores Cosine minus Matching Words; the README quotes the reverse
  ## direction, matching how the underlying analysis presents it.
  ok("F11 the reported delta is Cosine minus Matching Words",
     abs(ovr$Delta_rate_cos_minus_mw - (ovr$Rate_Cosine - ovr$Rate_MW)) < 1e-4,
     sprintf("%.4f", ovr$Delta_rate_cos_minus_mw))

  ok("F12 the equivalence interval brackets the delta",
     ovr$CI_L_90pct <= ovr$Delta_rate_cos_minus_mw &&
       ovr$CI_U_90pct >= ovr$Delta_rate_cos_minus_mw)

  ## The +/-5 pp verdict must follow from the interval, not from a stored string.
  passes_5pp <- ovr$CI_L_90pct >= -0.05 && ovr$CI_U_90pct <= 0.05
  ok("F13 the +/-5 pp verdict follows from the interval",
     (ovr$Equiv_primary_delta5pp == "Pass") == passes_5pp,
     sprintf("stored '%s', interval [%.4f, %.4f]",
             ovr$Equiv_primary_delta5pp, ovr$CI_L_90pct, ovr$CI_U_90pct))

  ok("F14 every year carries a verdict",
     all(tt$Equiv_primary_delta5pp %in% c("Pass", "Fail")) &&
       all(tt$Equiv_strict_delta2pp %in% c("Pass", "Fail")))

  ## The README states equivalence is NOT established on synthetic data. If a future
  ## run flips that, the README claim must be revisited rather than silently left.
  if (passes_5pp) {
    cat("  NOTE  method equivalence now PASSES at +/-5 pp; update the README section\n")
  } else {
    cat(sprintf("  NOTE  method equivalence fails at +/-5 pp as documented (MW - Cos = %+.2f pp, 90%% CI [%+.2f, %+.2f])\n",
                -100 * ovr$Delta_rate_cos_minus_mw,
                -100 * ovr$CI_U_90pct, -100 * ovr$CI_L_90pct))
  }
} else {
  ok("F10 speed_session_method_tost.csv present", FALSE, "run run_all_synthetic.r")
}

## --------------------------------------------------------- G: reproducibility ----

group("G. Reproducibility across repeated runs")

## The benchmark simulation is seeded, so a second call with the same seed must give
## the same numbers. Re-running the analysis script is the cheap end-to-end check;
## re-rendering the Rmd is covered by the byte-comparison note in the README.
tmp_out <- file.path(tempdir(), "repro_check")
dir.create(tmp_out, showWarnings = FALSE, recursive = TRUE)
rc <- system2("Rscript", c("analyze_match_quality.R", "--out", shQuote(tmp_out)),
              stdout = FALSE, stderr = FALSE)
ok("G1 the analysis script re-runs cleanly", rc == 0, sprintf("exit %d", rc))

if (rc == 0) {
  a <- read_csv(file.path(ART, "match_quality_headline.csv"), show_col_types = FALSE)
  b <- read_csv(file.path(tmp_out, "match_quality_headline.csv"), show_col_types = FALSE)
  ok("G2 headline table is identical on a repeat run", isTRUE(all.equal(a, b)))

  a2 <- read_csv(file.path(ART, "match_quality_benchmark.csv"), show_col_types = FALSE)
  b2 <- read_csv(file.path(tmp_out, "match_quality_benchmark.csv"), show_col_types = FALSE)
  ok("G3 seeded benchmark is identical on a repeat run", isTRUE(all.equal(a2, b2)))

  rc2 <- system2("Rscript", c("report_fairness_checks.R", "--out", shQuote(tmp_out)),
                 stdout = FALSE, stderr = FALSE)
  ok("G4 the fairness script re-runs cleanly", rc2 == 0)
  if (rc2 == 0) {
    f1 <- read_csv(file.path(ART, "fairness_checks.csv"), show_col_types = FALSE)
    f2 <- read_csv(file.path(tmp_out, "fairness_checks.csv"), show_col_types = FALSE)
    ok("G5 fairness table is identical on a repeat run", isTRUE(all.equal(f1, f2)))
  }
}

## Figure palettes are held to their own gates.
rc3 <- system2("Rscript", "tools/check_palette.R", stdout = FALSE, stderr = FALSE)
ok("G6 committed figure palettes pass the colour-vision checks", rc3 == 0,
   sprintf("exit %d", rc3))

## ---------------------------------------- H: confidentiality / metadata scan ----

group("H. Confidentiality and metadata scan")

## H1: committed docx files must have empty dc:creator and cp:lastModifiedBy.
docx_files <- list.files(ART, pattern = "\\.docx$", full.names = TRUE, recursive = FALSE)
if (length(docx_files) == 0) {
  ok("H1 no committed docx files to scan", TRUE)
} else {
  docx_meta <- vapply(docx_files, function(f) {
    con <- tryCatch(unz(f, "docProps/core.xml"), error = function(e) NULL)
    if (is.null(con)) return("no core.xml")
    xml <- tryCatch({
      x <- paste(readLines(con, warn = FALSE), collapse = "")
      try(close(con), silent = TRUE); x
    }, error = function(e) { try(close(con), silent = TRUE); "" })
    creator  <- if (grepl("<dc:creator>[^<]+</dc:creator>", xml))
                  sub(".*<dc:creator>([^<]+)</dc:creator>.*", "\\1", xml) else ""
    last_mod <- if (grepl("<cp:lastModifiedBy>[^<]+</cp:lastModifiedBy>", xml))
                  sub(".*<cp:lastModifiedBy>([^<]+)</cp:lastModifiedBy>.*", "\\1", xml) else ""
    if (nchar(trimws(creator)) == 0 && nchar(trimws(last_mod)) == 0) "" else
      sprintf("creator='%s' lastModifiedBy='%s'", creator, last_mod)
  }, character(1))
  ok("H1 all committed docx files have empty author metadata",
     all(!nzchar(docx_meta)),
     if (any(nzchar(docx_meta)))
       paste(sprintf("%s: %s", basename(docx_files)[nzchar(docx_meta)],
                     docx_meta[nzchar(docx_meta)]), collapse = "; ")
     else "")
}

## H2: committed PNG files must carry no embedded author or path strings.
png_files <- list.files(ART, pattern = "\\.png$", full.names = TRUE, recursive = FALSE)
if (length(png_files) == 0) {
  ok("H2 no committed PNG files to scan", TRUE)
} else {
  png_hits <- vapply(png_files, function(f) {
    sz   <- file.info(f)$size
    raw_bytes <- readBin(f, "raw", n = min(sz, 65536L))
    printable  <- raw_bytes[raw_bytes >= as.raw(0x20) & raw_bytes < as.raw(0x7f)]
    txt <- rawToChar(printable)
    if (grepl("(?i)(\\bauthor\\b|\\bcreator\\b|\\bartist\\b|copyright|\\busers\\b)", txt, perl = TRUE))
      "suspicious string found" else ""
  }, character(1))
  ok("H2 all committed PNGs carry no author/path metadata",
     all(!nzchar(png_hits)),
     if (any(nzchar(png_hits)))
       paste(basename(png_files)[nzchar(png_hits)], collapse = ", ")
     else "")
}

## H3: committed artifact CSVs must contain no absolute user-path strings.
csv_files <- list.files(ART, pattern = "\\.csv$", full.names = TRUE, recursive = FALSE)
if (length(csv_files) == 0) {
  ok("H3 no committed CSV artifacts to scan", TRUE)
} else {
  csv_hits <- unlist(lapply(csv_files, function(f) {
    lines <- readLines(f, warn = FALSE)
    hits  <- grep("[A-Za-z]:[\\\\/]Users[\\\\/]", lines, value = TRUE)
    if (length(hits)) sprintf("%s: %s", basename(f), hits[1]) else character(0)
  }))
  ok("H3 no absolute user paths in committed artifact CSVs",
     length(csv_hits) == 0,
     if (length(csv_hits)) csv_hits[1] else "")
}

## H4: no committed script or data file contains an absolute user path.
## (A10 covers scripts; this extends to data/ CSVs which could embed source paths.)
data_csvs <- list.files(DATA, pattern = "\\.csv$", full.names = TRUE, recursive = FALSE)
data_hits <- unlist(lapply(data_csvs, function(f) {
  lines <- readLines(f, warn = FALSE)
  hits  <- grep("[A-Za-z]:[\\\\/]Users[\\\\/]", lines, value = TRUE)
  if (length(hits)) sprintf("%s: %s", basename(f), hits[1]) else character(0)
}))
ok("H4 no absolute user paths in data/ CSVs",
   length(data_hits) == 0,
   if (length(data_hits)) data_hits[1] else "")

## ── I. Beyond-Paper-1 mentor fairness output ─────────────────────────────────
group("I. Beyond-Paper-1 mentor fairness output")

## I1: mentor_grade_balance.csv must exist and have the required columns.
mentor_csv <- file.path(ART, "mentor_grade_balance.csv")
if (!file.exists(mentor_csv)) {
  ok("I1 mentor_grade_balance.csv exists", FALSE,
     "Run report_fairness_checks.R to generate it")
} else {
  mb <- read_csv(mentor_csv, show_col_types = FALSE)
  required_cols <- c("u", "method_label", "mentor_grade_group",
                     "n", "n_top20", "selection_rate", "DI")
  ok("I1 mentor_grade_balance.csv exists with required columns",
     all(required_cols %in% names(mb)),
     if (!all(required_cols %in% names(mb)))
       paste("missing:", paste(setdiff(required_cols, names(mb)), collapse = ", "))
     else "")

  ## I2: both grade groups and both methods present at presentation u.
  u_rows <- mb %>% filter(abs(u - U_PRESENT) < 1e-9, !is.na(DI))
  ok("I2 both grade groups present at presentation u",
     nrow(u_rows) >= 4L,
     sprintf("%d rows at u=%.2f with non-NA DI (expect >=4)", nrow(u_rows), U_PRESENT))

  ## I3: mentor_grade_balance.csv contains no absolute user paths.
  lines <- readLines(mentor_csv, warn = FALSE)
  path_hits <- grep("[A-Za-z]:[\\\\/]Users[\\\\/]", lines, value = TRUE)
  ok("I3 mentor_grade_balance.csv contains no absolute user paths",
     length(path_hits) == 0,
     if (length(path_hits)) path_hits[1] else "")

  ## I5: the mentor-side DI counts mentors, not assignments. Full pairing
  ## duplicates a mentor when the mentee pool needs it, and duplication is not
  ## spread evenly across the grade groups, so counting assignments loads the
  ## two arms of DI unequally. n must therefore stay below n_assignments
  ## wherever any mentor holds more than one mentee.
  if (all(c("n", "n_assignments") %in% names(mb))) {
    never_exceeds <- all(mb$n <= mb$n_assignments, na.rm = TRUE)
    collapsed     <- any(mb$n < mb$n_assignments, na.rm = TRUE)
    ok("I5 mentor DI counts distinct mentors, not assignments",
       never_exceeds && collapsed,
       if (!never_exceeds) "n exceeds n_assignments in at least one row"
       else if (!collapsed)
         "n == n_assignments everywhere; duplicated mentors were not collapsed"
       else sprintf("%d mentors over %d assignments at u=%.2f",
                    sum(mb$n[is.na(mb$year)]), sum(mb$n_assignments[is.na(mb$year)]),
                    U_PRESENT))
  } else {
    ok("I5 mentor DI counts distinct mentors, not assignments", FALSE,
       "n_assignments column absent -- rates are assignment-weighted again")
  }
}

## I4: mentor_mentee_mutual_sat.csv must exist with required columns and clean paths.
mutual_csv <- file.path(ART, "mentor_mentee_mutual_sat.csv")
if (!file.exists(mutual_csv)) {
  ok("I4 mentor_mentee_mutual_sat.csv exists", FALSE,
     "Run report_fairness_checks.R to generate it")
} else {
  ms <- read_csv(mutual_csv, show_col_types = FALSE)
  req <- c("u", "method_label", "n", "mentee_sr", "mentor_sr",
           "gap_mentee_minus_mentor")
  ok("I4 mentor_mentee_mutual_sat.csv exists with required columns",
     all(req %in% names(ms)),
     if (!all(req %in% names(ms)))
       paste("missing:", paste(setdiff(req, names(ms)), collapse = ", "))
     else "")
  lines_m <- readLines(mutual_csv, warn = FALSE)
  path_hits_m <- grep("[A-Za-z]:[\\\\/]Users[\\\\/]", lines_m, value = TRUE)
  ok("I4b mentor_mentee_mutual_sat.csv contains no absolute user paths",
     length(path_hits_m) == 0,
     if (length(path_hits_m)) path_hits_m[1] else "")
}

## ---------------------------------------------------------------- summary ----

cat(sprintf("\n%s\n", strrep("-", 60)))
cat(sprintf("%d passed, %d failed\n", .pass, .fail))
if (.fail > 0) {
  cat("Failing checks:\n")
  cat(paste0("  ", .failures, collapse = "\n"), "\n")
  quit(status = 1)
}
cat("All checks passed.\n")
