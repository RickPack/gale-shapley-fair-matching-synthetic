# If these lines needed, run once per R Studio instance.

# pacman::pac_load("extrafont")
# extrafont::font_import()       # slow, first-time only
# extrafont::loadfonts(device = "win")
# extrafont::loadfonts(device = "pdf")

# -----------------------------
# 0) Parameters & dependencies
# -----------------------------
runrmd         <- TRUE
xeps_fosd      <- 0
# FOSD equivalence margins (TOST). A u passes FOSD equivalence iff
#   FOSD_sup_CI_U <=  fosd_delta  AND  FOSD_inf_CI_L >= -fosd_delta
# using the 90% bootstrap CI (per Lo, Datta & Salami 2025).
fosd_delta        <- 0.10  # primary margin: TOST margin on ECDF gap, analogous to four-fifths rule on selection rates
fosd_delta_strict <- 0.05  # sensitivity margin (stricter)
years          <- 2023:2025
u_grid_all     <- seq(0.9, 2.0, 0.1)
presentation_u <- 1.5         # <-- figures/tables use this u
thr_top_p      <- 20          # "Top-20%" threshold (benefit): lower percentile = better
thr_pos_pct    <- thr_top_p   # positive outcome: mentor_percentile <= thr_pos_pct
B_boot         <- 5000        # bootstrap reps for DI CI
set.seed(42)

args_all <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", args_all[grep("^--file=", args_all)])
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(file_arg[1])) else normalizePath(".")
indir  <- normalizePath(script_dir, winslash = "/", mustWork = TRUE)
setwd(indir)
if (!file.exists("build_synthetic_inputs.R")) {
  stop("Missing build_synthetic_inputs.R in the current folder.")
}
## Synthetic input CSVs are committed to this repository, so the confidential source
## workbooks are not needed to reproduce the analysis. Rebuild them only when
## GS_SOURCE_ROOT is set explicitly; otherwise require the committed CSVs and fail
## clearly if any are missing.
required_inputs <- c(
  file.path("data", sprintf("survey_synthetic_%d.csv", 2023:2025)),
  file.path("data", sprintf("prior_year_matches_synthetic_%d.csv", 2022:2024))
)
if (nzchar(Sys.getenv("GS_SOURCE_ROOT", unset = ""))) {
  message("GS_SOURCE_ROOT is set; rebuilding synthetic inputs from source workbooks.")
  source("build_synthetic_inputs.R", local = TRUE)
} else {
  missing_inputs <- required_inputs[!file.exists(required_inputs)]
  if (length(missing_inputs) > 0) {
    stop(sprintf(
      paste0("Missing synthetic input file(s): %s\n",
             "Either restore them from the repository, or set GS_SOURCE_ROOT to the folder ",
             "holding the original workbooks to regenerate them with build_synthetic_inputs.R."),
      paste(missing_inputs, collapse = ", ")
    ))
  }
  message("Using committed synthetic inputs in data/ (GS_SOURCE_ROOT not set).")
}
outdir <- file.path(indir, 'Output')
dir.create(outdir, showWarnings = FALSE)
dir.create("artifacts", showWarnings = FALSE)

u_is_done <- function(u, out_dir = "artifacts", require_key_files = TRUE, years = NULL) {
  u_tag <- gsub("\\.", "p", sprintf("%.3f", u))  # e.g., 0.175 -> "0p175"
  u_dir <- file.path(out_dir, paste0("u_", u_tag))
  if (!dir.exists(u_dir)) return(FALSE)
  if (!require_key_files) return(TRUE)
  if (is.null(years)) return(dir.exists(u_dir))
  needed <- c(
    file.path(u_dir, sprintf("fair_df_cos_sim_%s.rds",       years)),
    file.path(u_dir, sprintf("fair_df_word_matching_%s.rds", years))
  )
  all(file.exists(needed))
}

u_grid_todo <- u_grid_all[ !vapply(u_grid_all, u_is_done,
                                   logical(1),
                                   out_dir = "artifacts",
                                   require_key_files = TRUE,   # <- set to FALSE if folder-existence is enough
                                   years = years) ]

# Use separate grids for rendering vs analysis:
# - u_grid_render: only missing u values that need rendering now.
# - u_grid: full analysis grid when rendering is enabled (after todo render, all should exist),
#           otherwise only already-complete u values.
u_grid_render <- if (runrmd) u_grid_todo else numeric(0)
u_grid <- if (runrmd) u_grid_all else setdiff(u_grid_all, u_grid_todo)

suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(purrr); library(stringr); library(tibble)
  library(rmarkdown); library(readr)
  library(ggplot2); library(ggpubr); library(scales)
  library(flextable); library(officer)
  library(car)      # for Levene/BF (center=median)
  library(jsonlite)
})

## Pandoc is required by rmarkdown::render. Prefer whatever the environment already
## provides; otherwise try the usual RStudio-bundled locations. No absolute path is
## assumed to exist -- each candidate is tested, and a clear error names the fix.
if (!rmarkdown::pandoc_available()) {
  candidates <- c(
    Sys.getenv("RSTUDIO_PANDOC", unset = NA_character_),
    file.path(Sys.getenv("PROGRAMFILES", unset = ""),
              "RStudio/resources/app/bin/quarto/bin/tools"),
    file.path(Sys.getenv("PROGRAMFILES", unset = ""),
              "RStudio/bin/quarto/bin/tools"),
    "/usr/lib/rstudio/resources/app/bin/quarto/bin/tools",
    "/Applications/RStudio.app/Contents/Resources/app/bin/quarto/bin/tools"
  )
  candidates <- candidates[!is.na(candidates) & nzchar(candidates)]
  hit <- NULL
  for (d in candidates) {
    if (any(file.exists(file.path(d, c("pandoc", "pandoc.exe"))))) { hit <- d; break }
  }
  if (!is.null(hit)) {
    Sys.setenv(RSTUDIO_PANDOC = hit)
  } else {
    stop(paste0("Pandoc was not found. Install Pandoc, or set RSTUDIO_PANDOC to the ",
                "folder containing the pandoc executable, then re-run."))
  }
}

role_pal <- c("Mentor"="#0072B2","Mentee"="#D55E00")

# --------------------------------------------
# 1) Render Rmd across years and u (if needed)
# --------------------------------------------
if (runrmd) {
  rmd_input <- "stable_matching_paper_synthetic.rmd"
  walk(u_grid_render, function(u) {
    u_tag <- gsub("\\.", "p", sprintf("%.3f", u))   # e.g., 0.175 -> "0p175", 0.150 -> "0p150"
    art_dir <- file.path("artifacts", paste0("u_", u_tag))
    dir.create(art_dir, showWarnings = FALSE, recursive = TRUE)
    walk(years, ~ rmarkdown::render(
      input = rmd_input,
      params = list(year = .x, u = u, artifacts_dir = "artifacts", heavy = FALSE),
      envir = new.env(),
      output_dir = outdir,
      output_file = sprintf("stable_matching_%d_u%s.html", .x, u_tag)
    ))
  })
}

# -----------------------------------------------
# 2) Helpers (artifact loading, transforms, plots)
# -----------------------------------------------

# autofit flextables
ft_default <- function(x, max_width = 0) {
  ft <- flextable::flextable(x)
  ft <- flextable::autofit(ft)
  ft <- flextable::set_table_properties(ft, layout = "autofit", width = 1)  # 100% page width
  if (max_width > 0) {
    ft <- flextable::fit_to_width(ft, max_width = max_width)  # inches; set if you want a hard cap
  }
  ft
}

# Keep wide tables within the printable page width in Word.
compact_ft <- function(ft_obj, max_width = 6.5, font_size = 8) {
  ft_obj %>%
    flextable::autofit() %>%
    flextable::fontsize(size = font_size, part = "all") %>%
    flextable::padding(padding = 1.5, part = "all") %>%
    flextable::set_table_properties(layout = "autofit", width = 1) %>%
    flextable::fit_to_width(max_width = max_width)
}

# Standard Word section settings: Letter paper + normal 1-inch margins.
std_docx_section <- function() {
  officer::prop_section(
    page_size = officer::page_size(orient = "portrait", width = 8.5, height = 11),
    page_margins = officer::page_mar(
      top = 1, bottom = 1, left = 1, right = 1,
      header = 0.5, footer = 0.5, gutter = 0
    ),
    type = "continuous"
  )
}

save_docx_std <- function(..., path) {
  args <- list(...)
  args$path <- path
  args$pr_section <- std_docx_section()

  tryCatch({
    do.call(flextable::save_as_docx, args)
  }, error = function(e) {
    alt_path <- sub("\\.docx$", "_new.docx", path, ignore.case = TRUE)
    args$path <- alt_path
    do.call(flextable::save_as_docx, args)
    message(sprintf(
      "Could not write %s (likely open/locked). Wrote %s instead. Details: %s",
      path, alt_path, conditionMessage(e)
    ))
  })
}
# convenience re-exports
ft <- function(x, max_width = 0) ft_default(x, max_width = max_width)

# Format u to folder tag (two supported styles)
mk_u_tag <- function(u, style = c("p3", "nodot2")) {
  style <- match.arg(style)
  switch(
    style,
    p3     = gsub("\\.", "p", sprintf("%.3f", u)),  # 0.175 -> "0p175"
    nodot2 = gsub("\\.", "", sprintf("%.2f", u))    # 0.17  -> "017"
  )
}

# Parse u back from a folder tag (handles both styles)
parse_u_tag <- function(tag_or_path) {
  tag <- sub("^u_", "", basename(tag_or_path))
  if (grepl("p", tag, fixed = TRUE)) {
    # "0p175" -> 0.175
    suppressWarnings(as.numeric(sub("p", ".", tag, fixed = TRUE)))
  } else if (grepl("^\\d+$", tag)) {
    # "017" -> 0.17  (old two-decimal style)
    suppressWarnings(as.numeric(tag) / 100)
  } else {
    NA_real_
  }
}

# Discover all u_* folders under artifacts/ and return (u_dir, u) pairs
discover_u_dirs <- function(base = "artifacts") {
  dirs   <- list.dirs(base, recursive = FALSE, full.names = TRUE)
  u_dirs <- dirs[grepl("(/|\\\\)u_[0-9p]+$", dirs)]
  tibble::tibble(
    u_dir = u_dirs,
    u     = purrr::map_dbl(u_dirs, parse_u_tag)
  ) %>%
    dplyr::filter(!is.na(u)) %>%
    dplyr::arrange(u)
}

# Small guard for clearer errors when an artifact file is missing
.check_artifact <- function(path) {
  if (!file.exists(path)) {
    stop(
      sprintf("Missing artifact: %s\nRender the Rmd for this u/year first.", 
              normalizePath(path, winslash = "/")),
      call. = FALSE
    )
  }
}

# --- helpers: bootstrap mean-gap with 95% + 90% ----
boot_mean_gap <- function(x_low, x_high, B = 2000, seed = 42) {
  set.seed(seed)
  n1 <- length(x_low); n2 <- length(x_high)
  vals <- replicate(B, {
    m1 <- mean(sample(x_low,  n1, replace = TRUE))
    m2 <- mean(sample(x_high, n2, replace = TRUE))
    m2 - m1
  })
  list(
    ci95 = stats::quantile(vals, c(0.025, 0.975)),
    ci90 = stats::quantile(vals, c(0.05,  0.95))
  )
}

smd_pooled <- function(x_low, x_high) {
  m1 <- mean(x_low); m2 <- mean(x_high)
  s1 <- stats::var(x_low); s2 <- stats::var(x_high)
  n1 <- length(x_low); n2 <- length(x_high)
  sp <- sqrt(((n1-1)*s1 + (n2-1)*s2) / (n1+n2-2))
  if (!is.finite(sp) || sp == 0) return(NA_real_)
  (m2 - m1) / sp
}

load_fair_for_u <- function(u = NULL, years, out_dir = "artifacts", adir = NULL) {
  # Resolve the artifact directory:
  if (is.null(adir)) {
    if (is.null(u)) stop("Provide either `u` or `adir` to load_fair_for_u().")
    candidates <- c(
      file.path(out_dir, paste0("u_", mk_u_tag(u, "p3"))),     # new style
      file.path(out_dir, paste0("u_", mk_u_tag(u, "nodot2")))  # old style
    )
    adir <- candidates[dir.exists(candidates)][1]
    if (is.na(adir)) stop(sprintf("No artifact directory found for u=%.6f", u))
  }
  
  # Read per-year artifacts with clear errors if missing
  fair_cos <- purrr::map_dfr(years, ~{
    f <- file.path(adir, sprintf("fair_df_cos_sim_%s.rds", .x))
    .check_artifact(f)
    readRDS(f) %>% dplyr::mutate(method = "Cosine Similarity", year = .x)
  })
  fair_word <- purrr::map_dfr(years, ~{
    f <- file.path(adir, sprintf("fair_df_word_matching_%s.rds", .x))
    .check_artifact(f)
    readRDS(f) %>% dplyr::mutate(method = "Matching Words", year = .x)
  })
  fair <- dplyr::bind_rows(fair_cos, fair_word)
  
  # Ensure mentor_percentile exists or derive from ranks (as in your original)
  if (!"mentor_percentile" %in% names(fair)) {
    if ("GS_mentee_rank_of_mentor" %in% names(fair)) {
      rank_to_percentile <- function(rank_vec) {
        mr <- suppressWarnings(max(rank_vec, na.rm = TRUE))
        if (!is.finite(mr) || mr <= 1) return(rep(0, length(rank_vec)))
        100 * ((rank_vec - 1) / (mr - 1))
      }
      fair <- fair %>% dplyr::mutate(mentor_percentile = rank_to_percentile(GS_mentee_rank_of_mentor))
    } else {
      stop("Neither mentor_percentile nor GS_mentee_rank_of_mentor present in fair_df_*.")
    }
  }
  
  # Grade buckets and stratum (your original logic)
  fair %>%
    dplyr::mutate(
      grade_num = suppressWarnings(as.numeric(stringr::str_extract(as.character(grade_mentee), "\\d+"))),
      grade_group = dplyr::case_when(
        !is.na(grade_num) & grade_num <= 4 ~ "Grades 1–4",
        !is.na(grade_num) & grade_num >= 5 ~ "Grades 5+",
        TRUE ~ NA_character_
      ),
      grade_stratum = if ("grade_stratum" %in% names(.)) grade_stratum else grade_group
    ) %>%
    dplyr::filter(!is.na(grade_group), !is.na(method), !is.na(mentor_percentile))
}

# Load per-u density frames saved by the Rmd (for Figures 2 & 3)
load_density_for_u <- function(u, years, out_dir="artifacts") {
  u_tag <- gsub("\\.", "p", sprintf("%.3f", u))   # e.g., 0.175 -> "0p175", 0.150 -> "0p150"
  adir  <- file.path(out_dir, paste0("u_", u_tag))
  cos_den  <- map_dfr(years, ~ { f <- file.path(adir, sprintf("density_plot_cos_sim_%s.rds", .x))
  df <- readRDS(f); if (!"year" %in% names(df)) df$year <- .x; df })
  word_den <- map_dfr(years, ~ { f <- file.path(adir, sprintf("density_plot_word_matching_%s.rds", .x))
  df <- readRDS(f); if (!"year" %in% names(df)) df$year <- .x; df })
  list(cos=cos_den, word=word_den)
}

# ---------
# 3) Stats
# ---------
cp_ci_percent <- function(k, n, conf.level=0.95) {
  if (is.na(n) || n == 0) return(c(NA_real_, NA_real_))
  100 * binom.test(k, n, conf.level = conf.level)$conf.int
}

# ------------------------------------------------------------
# Bootstrap FOSD: ECDF gap CI + dominance probability
# Lower = better -> if MW dominates COS, F_MW >= F_COS across t
# Inputs are expected to be POOLED across all years before calling.
# CI: BCa (preferred) via boot::boot.ci, falling back to percentile if BCa fails.
# 90% CI per Lo, Datta & Salami (2025) TOST: (1-2*alpha)*100% at alpha=0.05.
# ------------------------------------------------------------
run_fosd_bootstrap <- function(x_cos = NULL, x_mw = NULL,
                               x_low = NULL, x_high = NULL,
                               B = 10000, seed = 42,
                               grid = seq(0, 100, by = 0.5),
                               method = c("percentile", "bca")) {
  method <- match.arg(method)  # method arg kept for API compat; always uses simple percentile loop
  # Allow either (x_low, x_high) for grade groups OR (x_cos, x_mw) for methods
  if (!is.null(x_low) && !is.null(x_high)) {
    xA <- x_low   # Grades 1–4
    xB <- x_high  # Grades 5+
  } else if (!is.null(x_cos) && !is.null(x_mw)) {
    xA <- x_cos   # Cosine
    xB <- x_mw    # Matching Words
  } else {
    stop("run_fosd_bootstrap: provide either (x_cos, x_mw) or (x_low, x_high).")
  }

  set.seed(seed)
  xA <- xA[!is.na(xA)]
  xB <- xB[!is.na(xB)]
  if (length(xA) < 5 || length(xB) < 5) {
    return(list(
      obs_sup = NA_real_, obs_inf = NA_real_,
      sup_CI = c(NA_real_, NA_real_), inf_CI = c(NA_real_, NA_real_),
      mw_dominance_prob = NA_real_, cos_dominance_prob = NA_real_
    ))
  }

  FA <- ecdf(xA); FB <- ecdf(xB)
  gap_obs <- FB(grid) - FA(grid)
  obs_sup <- max(gap_obs); obs_inf <- min(gap_obs)

  # 90% CI: (1-2*alpha)*100% for TOST at alpha=0.05; Lo, Datta & Salami (2025)
  nA <- length(xA); nB <- length(xB)
  sup_vals <- numeric(B); inf_vals <- numeric(B)
  dom_mw  <- logical(B); dom_cos <- logical(B)
  for (b in seq_len(B)) {
    xbA   <- sample(xA, nA, replace = TRUE)
    xbB   <- sample(xB, nB, replace = TRUE)
    gap_b <- ecdf(xbB)(grid) - ecdf(xbA)(grid)
    sup_vals[b] <- max(gap_b)
    inf_vals[b] <- min(gap_b)
    # gap = FB - FA. inf(gap) >= 0 means FB >= FA everywhere, so B carries more
    # mass at low values: B is stochastically smaller and (lower = better) better.
    dom_mw[b]   <- inf_vals[b] >= 0   # B (second) stochastically smaller/better
    dom_cos[b]  <- sup_vals[b] <= 0   # A (first) stochastically smaller/better
  }

  list(
    obs_sup = obs_sup,
    obs_inf = obs_inf,
    sup_CI  = as.numeric(stats::quantile(sup_vals, c(0.05, 0.95), na.rm = TRUE)),
    inf_CI  = as.numeric(stats::quantile(inf_vals, c(0.05, 0.95), na.rm = TRUE)),
    mw_dominance_prob  = mean(dom_mw,  na.rm = TRUE),
    cos_dominance_prob = mean(dom_cos, na.rm = TRUE)
  )
}

run_combined_diagnostics <- function(u, years, out_dir="artifacts", bf_per_year = FALSE) {
  fair <- load_fair_for_u(u, years, out_dir)
  
  # Cumulative Gains at top 20%
  cg_cos <- cumgain_top(filter(fair, method=="Cosine Similarity"), p = 20)
  cg_mw  <- cumgain_top(filter(fair, method=="Matching Words"),   p = 20)
  
  # Brown–Forsythe BETWEEN methods
  bf <- run_bf_between_methods(fair, per_year = bf_per_year)
  
  # --- KS + Bootstrap FOSD ---
  x_cos <- fair %>% filter(method=="Cosine Similarity") %>% pull(mentor_percentile)
  x_mw  <- fair %>% filter(method=="Matching Words")   %>% pull(mentor_percentile)
  
  # KS with tiny jitter to suppress ties warning (KS is descriptive only)
  ks_diag <- .ks_one_sided_diag(x_cos, x_mw)
  
  # Bootstrap FOSD (primary inference)
  fosd <- run_fosd_bootstrap(x_cos, x_mw, B = 10000, seed = 42, grid = seq(0, 100, by = 0.5))
  
  # Write a compact CSV for Word macro / audit trail
  u_tag <- gsub("\\.", "p", sprintf("%.3f", u))   # e.g., 0.175 -> "0p175", 0.150 -> "0p150"
  fosd_df <- tibble::tibble(
    u = u,
    obs_sup = fosd$obs_sup,  sup_L = fosd$sup_CI[1], sup_U = fosd$sup_CI[2],
    obs_inf = fosd$obs_inf,  inf_L = fosd$inf_CI[1], inf_U = fosd$inf_CI[2],
    mw_dominance_prob  = fosd$mw_dominance_prob,
    cos_dominance_prob = fosd$cos_dominance_prob,
    KS_D_cos_greater = ks_diag$D_cos_greater,
    KS_p_cos_greater = ks_diag$p_cos_greater,
    KS_D_mw_less     = ks_diag$D_mw_less,
    KS_p_mw_less     = ks_diag$p_mw_less
  )
  readr::write_csv(fosd_df, file.path(out_dir, sprintf("fosd_summary_u%s.csv", u_tag)))
  
  # ECDF Figure
  plot_df <- bind_rows(
    data.frame(value = x_cos, method = "Cosine Similarity"),
    data.frame(value = x_mw,  method = "Matching Words")
  )
  p_ecdf <- ggplot(plot_df, aes(x=value, color=method)) +
    stat_ecdf(linewidth = 1.1) +
    labs(
      title = "ECDF Comparison for FOSD",
      subtitle = sprintf(
        "u = %.2f | KS D_cos>mw = %.3f (p=%.3g) | D_mw<cos = %.3f (p=%.3g)",
        u,
        ks_diag$D_cos_greater, ks_diag$p_cos_greater,
        ks_diag$D_mw_less,     ks_diag$p_mw_less
      )
    ) +
    scale_color_brewer(palette="Set1") +
    theme_minimal(base_size=10) +
    theme(legend.position="bottom")
  u_tag <- gsub("\\.", "p", sprintf("%.3f", u))   # e.g., 0.175 -> "0p175", 0.150 -> "0p150"
  ggsave(file.path(out_dir, sprintf("ECDF_FOSD_u%s.png", u_tag)),
         p_ecdf, width=7, height=4.5, dpi=300, bg="white")
  
  # Combined table (if bf_per_year = FALSE, show overall BF; else summarize)
  if (!bf_per_year) {
    tab <- tibble::tibble(
      u = u,
      Cosine_cumgain_top20 = cg_cos,
      MW_cumgain_top20     = cg_mw,
      BF_F_between         = bf[["F value"]][1],
      BF_p_between         = bf[["Pr(>F)"]][1],
      
      # KS diagnostics (one-sided)
      KS_D_cos_greater = ks_diag$D_cos_greater,
      KS_p_cos_greater = ks_diag$p_cos_greater,
      KS_D_mw_less     = ks_diag$D_mw_less,
      KS_p_mw_less     = ks_diag$p_mw_less,
      
      # Bootstrap FOSD (primary inference)
      FOSD_obs_sup         = fosd$obs_sup,
      FOSD_sup_CI_L        = fosd$sup_CI[1],
      FOSD_sup_CI_U        = fosd$sup_CI[2],
      FOSD_obs_inf         = fosd$obs_inf,
      FOSD_inf_CI_L        = fosd$inf_CI[1],
      FOSD_inf_CI_U        = fosd$inf_CI[2],
      MW_Dominance_Prob    = fosd$mw_dominance_prob,
      COS_Dominance_Prob   = fosd$cos_dominance_prob
    )
  } else {
    tab <- bf %>% mutate(u = u) %>% relocate(u)
  }
  
  ft <- flextable(tab) %>% autofit() %>%
    align(align="center", part="all") %>% bold(part="header") %>% theme_booktabs() %>%
    add_header_lines("Combined Diagnostics: Cumulative Gains + Brown–Forsythe + KS FOSD") %>%
    add_footer_lines("KS test: one-sided tests for first-order stochastic dominance; lower percentiles are better.")
  
  save_docx_std("Diagnostics" = ft,
                path = file.path(out_dir, sprintf("Diagnostics_Combined_u%s.docx", u_tag)))
  
  tab
}

# ---- Distributional fairness across grade groups on mentor_percentile ----
build_distributional_fairness <- function(fair2, B_gap = 2000, seed = 42) {
  # mentor_percentile lower = better
  x_low  <- fair2 %>% dplyr::filter(grade_group == "Grades 1–4") %>% dplyr::pull(mentor_percentile)
  x_high <- fair2 %>% dplyr::filter(grade_group == "Grades 5+")   %>% dplyr::pull(mentor_percentile)
  
  # Mean gap & CIs (you already have boot_mean_gap)
  set.seed(seed)
  gap     <- mean(x_high, na.rm = TRUE) - mean(x_low, na.rm = TRUE)
  gap_cis <- boot_mean_gap(x_low, x_high, B = B_gap, seed = seed)
  gap_L95 <- gap_cis$ci95[1]; gap_U95 <- gap_cis$ci95[2]
  gap_L90 <- gap_cis$ci90[1]; gap_U90 <- gap_cis$ci90[2]
  
  # SMD (you already have smd_pooled)
  smd <- smd_pooled(x_low, x_high)
  
  # Bootstrap FOSD between groups (you already have run_fosd_bootstrap)
  # Here ECDF gap = F_high - F_low on a grid, so:
  #  - obs_sup > 0 means Grades 5+ worse somewhere (ECDF_high > ECDF_low)
  #  - obs_inf < 0 means Grades 5+ better somewhere
  fosd <- run_fosd_bootstrap(x_low = x_low, x_high = x_high, B = 10000, seed = seed, grid = seq(0, 100, by = 0.5))
  
  tibble::tibble(
    mean_gap = gap,
    mean_gap_L = gap_L95, mean_gap_U = gap_U95,
    mean_gap_L90 = gap_L90, mean_gap_U90 = gap_U90,
    SMD = smd,
    FOSD_obs_sup = fosd$obs_sup,
    FOSD_sup_CI_L = fosd$sup_CI[1], FOSD_sup_CI_U = fosd$sup_CI[2],
    FOSD_obs_inf = fosd$obs_inf,
    FOSD_inf_CI_L = fosd$inf_CI[1], FOSD_inf_CI_U = fosd$inf_CI[2],
    MW_dominance_prob = fosd$mw_dominance_prob,  # here "mw" means "x_high dominates"? Keep names generic if confusing
    COS_dominance_prob = fosd$cos_dominance_prob # rename if desired to "high/low" to avoid confusion
  )
}

build_fairness_summaries <- function(fair, thr_pos_pct = 20, B = 5000, seed = 42) {
  # Positive outcome = mentor_percentile <= thr_pos_pct (top p%)
  fair2 <- fair %>% dplyr::mutate(positive = as.integer(mentor_percentile <= thr_pos_pct))
  
  # DI with bootstrap CI
  counts <- fair2 %>%
    dplyr::group_by(grade_group) %>%
    dplyr::summarise(n = dplyr::n(), pos = sum(positive), sr = pos / n, .groups = "drop") %>%
    dplyr::arrange(desc(sr))
  
  stopifnot(nrow(counts) == 2L)  # expect exactly two grade groups
  
  sr_max <- counts$sr[1]; sr_min <- counts$sr[2]
  grp_max <- as.character(counts$grade_group[1]); grp_min <- as.character(counts$grade_group[2])
  
  DI <- ifelse(sr_max == 0, NA_real_, sr_min / sr_max)
  
  set.seed(seed)
  boot_DI <- replicate(B, {
    p1 <- sr_max; p2 <- sr_min; n1 <- counts$n[1]; n2 <- counts$n[2]
    bx1 <- rbinom(1, n1, p1); p1b <- bx1 / n1
    bx2 <- rbinom(1, n2, p2); p2b <- bx2 / n2
    if (p1b == 0 && p2b == 0) return(NA_real_)
    pmin <- min(p1b, p2b); pmax <- max(p1b, p2b)
    if (pmax == 0) NA_real_ else pmin / pmax
  })
  boot_DI <- boot_DI[!is.na(boot_DI)]
  DI_ci <- if (length(boot_DI) > 20) stats::quantile(boot_DI, c(0.025, 0.975)) else c(NA_real_, NA_real_)
  
  di_tab <- tibble::tibble(
    `SR max grp` = grp_max, `SR max` = scales::percent(sr_max, accuracy = 0.01),
    `SR min grp` = grp_min, `SR min` = scales::percent(sr_min, accuracy = 0.01),
    `DI` = ifelse(is.na(DI), NA_character_, sprintf("%.3f", DI)),
    `DI 95% CI` = if (any(is.na(DI_ci))) NA_character_ else sprintf("[%.3f, %.3f]", DI_ci[1], DI_ci[2]),
    `80% rule` = ifelse(is.na(DI), NA_character_, ifelse(DI >= 0.80, "Pass", "Flag"))
  )
  
  # Distributional fairness (mean gap, SMD, FOSD between grade groups)
  dist_tab <- build_distributional_fairness(fair, B_gap = 2000, seed = seed)
  
  # Return only what callers actually use
  list(
    fair = fair,
    di_table = di_tab,
    dist_table = dist_tab
  )
}


# ---- DI table footnotes (categorical fairness; not TOST) ----
.di_foot <- c(
  "Notes:",
  "1. DI = SR_min / SR_max, where 'positive' = mentor_percentile ≤ Top-p threshold.",
  "2. '80% rule' indicates whether DI ≥ 0.80 (UGESP reference).",
  "3. DI 95% CI computed via bootstrap on the two selection rates. DI is reported for estimation and governance; TOST is not applicable to DI."
)

# ---- Distributional Fairness footnotes (TOST explicit) ----
.dist_foot <- c(
  "Notes:",
  "1. mean_gap = mean(mentor_percentile in Grades 5+) − mean(mentor_percentile in Grades 1–4). Positive = higher (worse) percentiles for Grades 5+.",
  "2. mean_gap_L90 / mean_gap_U90 = 90% bootstrap CI for mean_gap used for TOST equivalence. Equivalence is concluded when the entire 90% CI lies within the prespecified margin (e.g., ±3).",
  "3. mean_gap_L / mean_gap_U = 95% bootstrap CI for mean_gap used for estimation (more conservative; not used for TOST).",
  "4. SMD = standardized mean difference (pooled SD). |SMD| ≤ 0.20–0.30 is generally considered small.",
  "5. FOSD_obs_sup / FOSD_obs_inf are the observed extrema of the ECDF gap D(t) = F_{5+}(t) − F_{1–4}(t) over mentor percentiles (lower = better).",
  "6. FOSD_sup_CI_L/U and FOSD_inf_CI_L/U = 90% bootstrap CIs for the ECDF gap, reported as distributional dominance diagnostics rather than deployment gates.",
  "7. If sup_CI_U ≤ 0, Grades 5+ are never worse across the distribution (weak stochastic dominance). If inf_CI_L ≥ 0, Grades 5+ are never better. In this study, grade-group FOSD is diagnostic only."
)

save_fairness_tables <- function(di_tab, dist_tab) {
  # ---- DI table ----
  ft_di <- flextable::flextable(di_tab) %>%
    flextable::theme_booktabs() %>% flextable::autofit() %>%
    flextable::align(align = "center", part = "all") %>% flextable::bold(part = "header") %>%
    flextable::add_header_lines(values = "Disparate Impact (DI) – Grades 1–4 vs Grades 5+") %>%
    flextable::add_footer_lines(values = c(
      "Notes:",
      "1. DI = SR_min / SR_max, using positive outcome = mentor_percentile ≤ threshold (Top-p).",
      "2. '80% rule' shows whether DI ≥ 0.80 (UGESP).",
      "3. 95% CI via bootstrap on the two selection rates."
    ))
  
  save_docx_std(`Table: Disparate Impact (DI)` = ft_di,
                path = file.path("artifacts", "DI_summary.docx"))
  
  # ---- Distributional Fairness table ----
  foot_dist <- c(
    "Notes:",
    "1. mean_gap = mean(mentor_percentile in Grades 5+) − mean(mentor_percentile in Grades 1–4). Positive = higher (worse) percentiles for Grades 5+.",
    "2. mean_gap_L/U and mean_gap_L90/U90 = 95% and 90% bootstrap CIs for mean_gap (equivalence often judged at 90%).",
    "3. SMD = standardized mean difference (pooled SD). |SMD| ≤ 0.20–0.30 is typically small.",
    "4. FOSD_obs_sup/inf = observed sup/inf of ECDF_high − ECDF_low over the percentile grid.",
    "5. FOSD_sup/inf_CI_L/U = 90% bootstrap CIs for the ECDF gap, reported as distributional diagnostics. If sup_CI_U ≤ 0, Grades 5+ never worse; if inf_CI_L ≥ 0, Grades 5+ never better (interpret with context)."
  )

  dist_fmt <- dist_tab %>%
    dplyr::mutate(dplyr::across(where(is.numeric), ~ round(.x, 3)))

  dist_core <- dist_fmt %>%
    dplyr::select(
      mean_gap,
      SMD,
      FOSD_obs_sup,
      FOSD_sup_CI_L,
      FOSD_sup_CI_U,
      FOSD_obs_inf,
      FOSD_inf_CI_L,
      FOSD_inf_CI_U
    )

  dist_ci <- dist_fmt %>%
    dplyr::select(
      mean_gap_L,
      mean_gap_U,
      mean_gap_L90,
      mean_gap_U90,
      MW_dominance_prob,
      COS_dominance_prob
    )

  ft_dist_core <- flextable::flextable(dist_core) %>%
    flextable::theme_booktabs() %>%
    flextable::set_header_labels(
      mean_gap = "mean_gap",
      SMD = "SMD",
      FOSD_obs_sup = "sup_obs",
      FOSD_sup_CI_L = "sup_CI_L",
      FOSD_sup_CI_U = "sup_CI_U",
      FOSD_obs_inf = "inf_obs",
      FOSD_inf_CI_L = "inf_CI_L",
      FOSD_inf_CI_U = "inf_CI_U"
    ) %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::bold(part = "header") %>%
    compact_ft(max_width = 6.5, font_size = 8) %>%
    flextable::add_header_lines(values = "Distributional Fairness (ECDF-Gap Dominance Diagnostics)")

  ft_dist_ci <- flextable::flextable(dist_ci) %>%
    flextable::theme_booktabs() %>%
    flextable::set_header_labels(
      mean_gap_L = "gap_L95",
      mean_gap_U = "gap_U95",
      mean_gap_L90 = "gap_L90",
      mean_gap_U90 = "gap_U90",
      MW_dominance_prob = "high_dom_prob",
      COS_dominance_prob = "low_dom_prob"
    ) %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::bold(part = "header") %>%
    compact_ft(max_width = 6.5, font_size = 8) %>%
    flextable::add_header_lines(values = "Distributional Fairness (Gap CIs and Dominance Probabilities)") %>%
    flextable::add_footer_lines(values = foot_dist)

  save_docx_std(
    `Table: Distributional Fairness (Core)` = ft_dist_core,
    `Table: Distributional Fairness (CIs)` = ft_dist_ci,
    path = file.path("artifacts", "Distributional_Fairness.docx")
  )
}

# -----------------------------
# 4) Figures for presentation_u
# -----------------------------
fair_u <- load_fair_for_u(presentation_u, years)

# ---- Figure 1: Cumulative Gains (5% buckets) ----
df_5 <- fair_u %>%
  group_by(year, method) %>%
  reframe(
    percentile = seq(0, 100, by = 5),
    cum_rate = sapply(percentile, function(p) mean(mentor_percentile <= p, na.rm = TRUE))
  )

p_fig1 <- ggplot(df_5, aes(x = percentile, y = cum_rate, color = method, group = method)) +
  geom_abline(slope = 1/100, intercept = 0, linetype = "dashed", color = "grey50") + # random baseline
  geom_step(linewidth = 1.1, direction = "hv") +
  geom_point(size = 1.8) +
  facet_wrap(~ year, nrow = 1) +
  scale_x_continuous(breaks = seq(0, 100, 10)) +
  scale_y_continuous(labels = percent_format(accuracy = 1), limits = c(0, 1)) +
  scale_color_brewer(palette = "Set1", name = "Method") +
  labs(title = "Cumulative Gain Curves by Year and Method",
       subtitle = "Curves above the dashed baseline indicate lift vs. random selection",
       x = "Percentile threshold (Top p% of predicted compatibility; lower = better)",
       y = "Cumulative share of mentees within threshold") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")
p_fig1
ggsave(file.path("artifacts", "Figure_1_Cumulative_Gains.png"),
       p_fig1, width = 6.5, height = 4.5, units = "in", dpi = 300, bg = "white")

# ---- Figures 2 & 3: Density plots by Role (Cosine/Word) ----
den <- load_density_for_u(presentation_u, years)
cos_density_graph <- ggpubr::ggdensity(
  data = den$cos, x = "Rank", rug = TRUE, color = "Role", fill = "Role"
) +
  facet_wrap(~ year, nrow = 1, scales = "free_y") +
  scale_color_manual(values = role_pal, name = "Role") +
  scale_fill_manual(values = role_pal, name = "Role") +
  labs(title = "Density of Gale–Shapley Mentee Rank of Mentor (Cosine Similarity)",
       subtitle = "Faceted by year",
       x = "Rank of assigned mentor (1 = most compatible)",
       y = "Density") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom", strip.text = element_text(face = "bold"))
ggsave(file.path("artifacts", "Figure_2_Density_Cos_Sim.png"),
       cos_density_graph, width = 7, height = 3.5, units = "in", dpi = 400, bg = "white")

word_density_graph <- ggpubr::ggdensity(
  data = den$word, x = "Rank", rug = TRUE, color = "Role", fill = "Role"
) +
  facet_wrap(~ year, nrow = 1, scales = "free_y") +
  scale_color_manual(values = role_pal, name = "Role") +
  scale_fill_manual(values = role_pal, name = "Role") +
  labs(title = "Density of Gale–Shapley Mentee Rank of Mentor (Matching Words)",
       subtitle = "Faceted by year",
       x = "Rank of assigned mentor (1 = most compatible)",
       y = "Density") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom", strip.text = element_text(face = "bold"))
ggsave(file.path("artifacts", "Figure_3_Density_Word_Matching.png"),
       word_density_graph, width = 7, height = 3.5, units = "in", dpi = 400, bg = "white")

# -----------------------------
# 5) Find u where Matching Words stochastically dominates Cosine Similarity across all years
# -----------------------------
dominance_u <- NULL
for (u_loop in sort(u_grid_all)) {
  fair_u_loop <- load_fair_for_u(u_loop, years)
  df_5 <- fair_u_loop %>%
    group_by(year, method) %>%
    reframe(
      percentile = seq(0, 100, by = 5),
      cum_rate = sapply(percentile, function(pv) mean(mentor_percentile <= pv, na.rm = TRUE))
    )
  
  # Check dominance at 25, 50, 75 percentiles
  check_df <- df_5 %>%
    filter(percentile %in% c(25, 50, 75)) %>%
    select(year, percentile, method, cum_rate) %>%
    pivot_wider(names_from = method, values_from = cum_rate)
  
  dominance <- check_df %>%
    group_by(year) %>%
    summarise(dominates = all(`Matching Words` > `Cosine Similarity`))
  
  if (all(dominance$dominates)) {
    dominance_u <- u_loop
    break
  }
}

if (!is.null(dominance_u)) {
  cat("Stochastic dominance achieved at u =", dominance_u, "\n")
} else {
  cat("No u found where dominance holds for all years.\n")
}
# Restore fair_u to presentation_u (loop above may have changed it via fair_u_loop).
# fair_u is still the correct presentation_u object from Section 4.

# ---- Figure 4: Percentile distribution by Year & Method ----
p_fig4 <- ggplot(fair_u, aes(x = mentor_percentile, fill = method, color = method)) +
  geom_density(alpha = 0.35) +
  facet_wrap(~ year, nrow = 1, scales = "free_y") +
  scale_fill_brewer(palette = "Set1", name = "Method") +
  scale_color_brewer(palette = "Set1", name = "Method") +
  labs(title = "Percentile Distribution by Year and Method",
       x = "Mentor percentile (0 = best, 100 = worst)",
       y = "Density") +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom", strip.text = element_text(face = "bold"))
ggsave(file.path("artifacts", "Figure_4_Percentiles_Density_By_Year.png"),
       p_fig4, width = 6.5, height = 4.5, units = "in", dpi = 300, bg = "white")

# ---- Figure 6: Selection rates by Grade Group (overall) ----
fig6_df <- fair_u %>%
  mutate(positive = as.integer(mentor_percentile <= thr_pos_pct)) %>%
  group_by(grade_group) %>%
  summarise(selection_rate = mean(positive), .groups="drop")
p_fig6 <- ggplot(fig6_df, aes(x = grade_group, y = selection_rate, fill = grade_group)) +
  geom_col(width = 0.6) +
  scale_y_continuous(labels = percent_format(accuracy = 0.1), limits = c(0, 1)) +
  scale_fill_brewer(palette = "Pastel1", guide = "none") +
  labs(title = "Selection Rates by Grade Group",
       subtitle = sprintf("Positive = mentor_percentile ≤ %d (Top-%s%%)", thr_pos_pct, thr_top_p),
       x = NULL, y = "Selection rate") +
  theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank())
ggsave(file.path("artifacts", "Figure_6_Selection_Rates_By_Grade_Group.png"),
       p_fig6, width = 6.5, height = 4.5, units = "in", dpi = 300, bg = "white")

# -----------------------------
# 5) Fairness summaries (presentation_u)
# -----------------------------
fair_summ <- build_fairness_summaries(
  fair_u,
  thr_pos_pct = thr_pos_pct,
  B = B_boot,
  seed = 42
)

save_fairness_tables(fair_summ$di_table, fair_summ$dist_table)

# -----------------------------
# 6) Fairness u-sweep (no TOST)
# -----------------------------
# --- helpers: bootstrap CIs for DI and ΔSR with 95% + 90% ----
boot_DI_and_diff <- function(n1, p1, n2, p2, B = 5000, seed = 42) {
  set.seed(seed)
  
  # Bootstrap DI
  di_vals <- replicate(B, {
    bx1 <- rbinom(1, n1, p1); p1b <- bx1 / n1
    bx2 <- rbinom(1, n2, p2); p2b <- bx2 / n2
    if (p1b == 0 && p2b == 0) return(NA_real_)
    pmin <- min(p1b, p2b); pmax <- max(p1b, p2b)
    if (pmax == 0) NA_real_ else pmin / pmax
  })
  di_vals <- di_vals[!is.na(di_vals)]
  di_ci95 <- if (length(di_vals) > 20) stats::quantile(di_vals, c(0.025, 0.975)) else c(NA_real_, NA_real_)
  di_ci90 <- if (length(di_vals) > 20) stats::quantile(di_vals, c(0.05, 0.95))  else c(NA_real_, NA_real_)
  
  # Bootstrap SR difference (Grades 1–4 minus 5+)
  diff_vals <- replicate(B, {
    bx1 <- rbinom(1, n1, p1); p1b <- bx1 / n1
    bx2 <- rbinom(1, n2, p2); p2b <- bx2 / n2
    p1b - p2b
  })
  diff_ci95 <- stats::quantile(diff_vals, c(0.025, 0.975))
  diff_ci90 <- stats::quantile(diff_vals, c(0.05,  0.95))
  
  list(
    di_ci95   = di_ci95,
    di_ci90   = di_ci90,
    diff_ci95 = diff_ci95,
    diff_ci90 = diff_ci90
  )
}

# Discover all available u_* folders under artifacts/
u_index <- discover_u_dirs("artifacts")  # returns columns: u_dir, u

# ---- Build u_sweep without Selection-Rate differences, with FOSD sup_CI_U ----
u_sweep <- purrr::map_dfr(u_grid, function(u) {
  fair <- load_fair_for_u(u, years)                                # you already have this
  fair2 <- fair %>% dplyr::mutate(positive = as.integer(mentor_percentile <= thr_pos_pct))
  
  # Group stats for DI
  grp <- fair2 %>%
    dplyr::group_by(grade_group) %>%
    dplyr::summarise(n = dplyr::n(), pos = sum(positive), sr = pos/n, mean_pct = mean(mentor_percentile), .groups = "drop") %>%
    dplyr::mutate(order = dplyr::if_else(grade_group == "Grades 1–4", 1L, 2L)) %>%
    dplyr::arrange(order)
  
  # Fisher exact (optional diagnostic, not gating)
  tab <- matrix(c(grp$pos[1], grp$n[1] - grp$pos[1], grp$pos[2], grp$n[2] - grp$pos[2]), nrow = 2, byrow = TRUE)
  fisher_p <- stats::fisher.test(tab)$p.value
  
  # DI point and bootstrap CIs (reuse your helper)
  di_vals <- boot_DI_and_diff(grp$n[1], grp$sr[1], grp$n[2], grp$sr[2], B = B_boot)  # returns di_ci95/di_ci90, diff components ignored
  DI <- if (grp$sr[2] == 0 && grp$sr[1] == 0) NA_real_ else min(grp$sr)/max(grp$sr)
  di_L95 <- di_vals$di_ci95[1]; di_U95 <- di_vals$di_ci95[2]
  di_L90 <- di_vals$di_ci90[1]; di_U90 <- di_vals$di_ci90[2]
  
  # Distributional fairness (gap, CIs, SMD)
  x_low  <- fair2 %>% dplyr::filter(grade_group == "Grades 1–4") %>% dplyr::pull(mentor_percentile)
  x_high <- fair2 %>% dplyr::filter(grade_group == "Grades 5+")   %>% dplyr::pull(mentor_percentile)
  gap     <- mean(x_high, na.rm = TRUE) - mean(x_low, na.rm = TRUE)
  gap_cis <- boot_mean_gap(x_low, x_high, B = 2000)
  gap_L95 <- gap_cis$ci95[1]; gap_U95 <- gap_cis$ci95[2]
  gap_L90 <- gap_cis$ci90[1]; gap_U90 <- gap_cis$ci90[2]
  smd     <- smd_pooled(x_low, x_high)
  
  # FOSD between groups (ECDF gap)
  fosd <- run_fosd_bootstrap(x_low, x_high, B = 10000, seed = 42, grid = seq(0, 100, by = 0.5))
  
  tibble::tibble(
    u = u,
    n_low = grp$n[1],  sr_low  = grp$sr[1],
    n_high = grp$n[2], sr_high = grp$sr[2],
    fisher_p = fisher_p,
    # DI
    DI = DI, DI_L = di_L95, DI_U = di_U95, DI_L90 = di_L90, DI_U90 = di_U90,
    # Distributional fairness
    mean_pct_low = grp$mean_pct[1], mean_pct_high = grp$mean_pct[2],
    mean_gap = gap, mean_gap_L = gap_L95, mean_gap_U = gap_U95,
    mean_gap_L90 = gap_L90, mean_gap_U90 = gap_U90,
    SMD = smd,
    FOSD_obs_sup = fosd$obs_sup, FOSD_sup_CI_L = fosd$sup_CI[1], FOSD_sup_CI_U = fosd$sup_CI[2],
    FOSD_obs_inf = fosd$obs_inf, FOSD_inf_CI_L = fosd$inf_CI[1], FOSD_inf_CI_U = fosd$inf_CI[2],
    MW_dominance_prob = fosd$mw_dominance_prob, COS_dominance_prob = fosd$cos_dominance_prob
  )
})

readr::write_csv(u_sweep, file.path("artifacts","u_sweep_fairness_summary.csv"))

# ============================================================
# Table A (rank distribution per year, combined DOCX)
# + presentation_u recommendation report
# ============================================================

# ------------------------------------------------------------
# Function: Build Table A for a single year's fairness frame
# ------------------------------------------------------------
build_table_A_for_year <- function(fair_year_df, year) {
  fair_year_df %>%
    mutate(
      rank_bin = case_when(
        GS_mentee_rank_of_mentor == 1 ~ "Rank 1",
        GS_mentee_rank_of_mentor %in% 2:3 ~ "Rank 2–3",
        GS_mentee_rank_of_mentor %in% 4:5 ~ "Rank 4–5",
        TRUE ~ "Other"
      ),
      top20 = mentor_percentile <= 20
    ) %>%
    group_by(method) %>%
    summarise(
      pct_rank1   = mean(rank_bin == "Rank 1"),
      pct_23      = mean(rank_bin == "Rank 2–3"),
      pct_45      = mean(rank_bin == "Rank 4–5"),
      pct_top20   = mean(top20),
      mean_pct    = mean(mentor_percentile),
      median_pct  = median(mentor_percentile),
      .groups="drop"
    ) %>%
    mutate(Year = as.character(year)) %>%
    relocate(Year, .before = method)
}

# ------------------------------------------------------------
# Build combined Table A for all years
# ------------------------------------------------------------
build_table_A_combined <- function(years, presentation_u) {
  fair_u <- load_fair_for_u(presentation_u, years)
  
  tables <- map_df(years, function(y) {
    fair_y <- fair_u %>% filter(year == y)
    build_table_A_for_year(fair_y, y)
  })
  
  # Save CSV for transparency
  write_csv(tables, "artifacts/Table_A_rank_distribution.csv")
  
  # Create a combined DOCX
  ft <- flextable(tables) %>%
    theme_booktabs() %>%
    autofit() %>%
    bold(part = "header") %>%
    align(align = "center", part = "all") %>%
    add_header_lines(values = "Table A: Rank Distribution Summaries by Year and Method") %>%
    add_footer_lines(values = "Rank bins based on GS stable matching output; top-20% defined as mentor_percentile ≤ 20.")
  
  save_docx_std("Table A" = ft,
                path = "artifacts/Table_A_rank_distribution.docx")
}

# ------------------------------------------------------------
# Recommend presentation_u value
# ------------------------------------------------------------
recommend_presentation_u <- function(u_sweep) {
  stopifnot(is.data.frame(u_sweep))
  if (!("u" %in% names(u_sweep))) {
    stop(
      paste0(
        "u_sweep must contain a 'u' column. This usually means the sweep was built from an empty u_grid. ",
        "Rebuild u_sweep after setting analysis u_grid to non-empty values."
      ),
      call. = FALSE
    )
  }
  
  # Normalize / reconstruct key fields if they are missing
  us <- u_sweep %>%
    dplyr::mutate(
      # DI point estimate: min(sr)/max(sr) if DI is missing (uses sr_low/sr_high you already keep)
      DI = dplyr::coalesce(.data[["DI"]],
                           if (all(c("sr_low","sr_high") %in% names(.))) {
                             pmin(sr_low, sr_high) / pmax(sr_low, sr_high)
                           } else NA_real_),
      # Choose DI interval for ribbon width (prefer 95% if present, else 90% if present)
      DI_L = dplyr::coalesce(.data[["DI_L"]], .data[["DI_L90"]]),
      DI_U = dplyr::coalesce(.data[["DI_U"]], .data[["DI_U90"]]),
      # Gap CI (prefer 90% for equivalence; fallback to 95%)
      mean_gap_L90 = dplyr::coalesce(.data[["mean_gap_L90"]], .data[["mean_gap_L"]]),
      mean_gap_U90 = dplyr::coalesce(.data[["mean_gap_U90"]], .data[["mean_gap_U"]])
    )
  
  # Score each u (lower total is better)
  scored <- us %>%
    dplyr::mutate(
      score_DI  = ifelse(is.na(DI), Inf, abs(1 - DI)),
      score_gap = abs(mean_gap),
      score_smd = abs(SMD),
      score_var = ifelse(is.na(DI_L) | is.na(DI_U), Inf, abs(DI_U - DI_L)),
      total_score = score_DI + score_gap + 0.5 * score_smd + 0.1 * score_var
    ) %>%
    dplyr::arrange(total_score)
  
  best_u <- scored %>% dplyr::slice(1)
  
  # Persist artifacts
  readr::write_csv(scored, "artifacts/presentation_u_recommendation.csv")
  
  # SR-free narrative
  narrative <- paste0(
    "Recommended value of presentation_u: ", best_u$u, "\n\n",
    "Rationale:\n",
    "- Minimizes absolute deviation of DI from 1 (categorical fairness).\n",
    "- Minimizes mean-percentile gap between grade groups (equivalence logic).\n",
    "- Minimizes standardized mean difference (effect size).\n",
    "- Achieves tighter bootstrap confidence intervals.\n\n",
    "This ranking-based recommendation follows the practical statistical science principles ",
    "emphasized by Salami and colleagues: empirical robustness, uncertainty quantification, ",
    "and transparent, audit-ready thresholds."
  )
  
  ft <- flextable::flextable(data.frame(Recommendation = narrative)) %>%
    flextable::autofit() %>%
    flextable::theme_booktabs() %>%
    flextable::align(align = "left", part = "all") %>%
    flextable::add_header_lines(values = "Recommended presentation_u (Statistical Summary)")
  
  save_docx_std("u Recommendation" = ft,
                path = "artifacts/presentation_u_recommendation.docx")
  
  best_u
}

# ------------------------------------------------------------
# Run both procedures
# ------------------------------------------------------------
# 1. Combined Table A
build_table_A_combined(years, presentation_u)

# 2. Use existing u_sweep from your pipeline
best_u <- recommend_presentation_u(u_sweep)

# Plots: DI vs u, SR diff vs u, mean-gap vs u
p_di <- ggplot(u_sweep, aes(x=u, y=DI)) +
  geom_ribbon(aes(ymin=DI_L, ymax=DI_U), fill="#A7C7E7", alpha=0.35) +
  geom_line(color="#1F77B4", linewidth=1) + geom_point(color="#1F77B4", size=2) +
  geom_hline(yintercept = 0.80, linetype="dashed", color="firebrick") +
  scale_y_continuous("Disparate Impact (SR_min / SR_max)", limits=c(0,1.5)) +
  scale_x_continuous("Weight u") +
  labs(title = "Disparate Impact (bootstrap 95% CI) vs u",
       subtitle = "Dashed line at 0.80 (UGESP four-fifths rule)") +
  theme_minimal(base_size=10)
ggsave(file.path("artifacts","Figure_u_sweep_DI_bootstrap.png"), p_di,
       width=7, height=4.2, dpi=300, bg="white")

p_gap <- ggplot(u_sweep, aes(x=u, y=mean_gap)) +
  geom_ribbon(aes(ymin=mean_gap_L, ymax=mean_gap_U), fill="#F7C9C9", alpha=0.35) +
  geom_hline(yintercept = 0, linetype="dashed", color="grey40") +
  geom_line(color="#D62728", linewidth=1) + geom_point(color="#D62728", size=2) +
  scale_y_continuous("Mean Percentile Gap (Grades 5+ minus 1–4)") +
  scale_x_continuous("Weight u") +
  labs(title="Mean mentor-percentile gap (bootstrap 95% CI) vs u",
       subtitle="Lower is better (0 = equal). Negative gap means higher grades receive better (lower) percentiles.") +
  theme_minimal(base_size=10)
ggsave(file.path("artifacts","Figure_u_sweep_MeanPercentileGap_bootstrap.png"), p_gap,
       width=7, height=4.2, dpi=300, bg="white")

# ------------------------------------------------------------
# 7) Proposed-u selection based on your rules  (FIXED VERSION)
# ------------------------------------------------------------

# Thresholds — use existing if present; otherwise default to your paper’s rules
di_floor   <- if (exists("di_floor"  , inherits = TRUE)) get("di_floor"  , inherits = TRUE) else 0.80
gap_margin <- if (exists("gap_margin", inherits = TRUE)) get("gap_margin", inherits = TRUE) else 3.0
smd_max    <- if (exists("smd_max"   , inherits = TRUE)) get("smd_max"   , inherits = TRUE) else 0.20

# FOSD equivalence margin (TOST): prefer fosd_delta if set; back-compat fall-back to fosd_eps/eps_fosd if defined; else 0.10
fosd_delta <- if (exists("fosd_delta", inherits = TRUE)) {
  get("fosd_delta", inherits = TRUE)
} else if (exists("fosd_eps", inherits = TRUE)) {
  get("fosd_eps", inherits = TRUE)
} else if (exists("eps_fosd", inherits = TRUE)) {
  get("eps_fosd", inherits = TRUE)
} else 0.10
# Maintain `fosd_eps` as a back-compat alias used by older code paths in this script.
fosd_eps <- fosd_delta

# Select the correct column names (strings) present in u_sweep
stopifnot(exists("u_sweep"))
diL     <- if ("DI_L90"        %in% names(u_sweep)) "DI_L90"        else "DI_L"
mgL_col <- if ("mean_gap_L90"  %in% names(u_sweep)) "mean_gap_L90"  else "mean_gap_L"
mgU_col <- if ("mean_gap_U90"  %in% names(u_sweep)) "mean_gap_U90"  else "mean_gap_U"
has_inf_L <- "FOSD_inf_CI_L" %in% names(u_sweep)

proposed_u_tbl <- u_sweep %>%
  mutate(
    pass_DI   = !is.na(.data[[diL]])      & (.data[[diL]]     >= di_floor),
    pass_gap  = !is.na(.data[[mgL_col]])  & !is.na(.data[[mgU_col]]) &
      (.data[[mgL_col]] >= -gap_margin) & (.data[[mgU_col]] <= gap_margin),
    pass_SMD  = !is.na(SMD)               & (abs(SMD) <= smd_max),
    # Grade-group ECDF-gap dominance diagnostics are retained for reporting only.
    # They are not used as the operational gate for proposed_u selection.
    pass_FOSD = !is.na(FOSD_sup_CI_U)     & (FOSD_sup_CI_U <=  fosd_delta) &
                (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta) else TRUE),
    fosd_pass_delta10 = !is.na(FOSD_sup_CI_U) & (FOSD_sup_CI_U <=  fosd_delta) &
                (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta) else TRUE),
    fosd_pass_delta05 = !is.na(FOSD_sup_CI_U) & (FOSD_sup_CI_U <=  fosd_delta_strict) &
                (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta_strict) else TRUE),
    pass_all  = pass_DI & pass_gap & pass_SMD
  ) %>%
  filter(pass_all) %>%
  arrange(desc(u)) %>%     # <--- prefer the largest u among those that pass
  slice_head(n = 1) %>%
  mutate(decision = "Selected as Proposed u (meets DI, gap, and SMD gates; FOSD reported diagnostically)")

if (nrow(proposed_u_tbl) == 0) {
  proposed_u_tbl <- tibble(
    u = NA_real_,
    decision = "No u in grid satisfies all fairness rules",
    note = "Consider widening thresholds or inspecting CI plots manually."
  )
}

ft_prop <- flextable::flextable(proposed_u_tbl) %>%
  flextable::autofit() %>%
  flextable::align(align = "center", part = "all") %>%
  flextable::bold(part = "header") %>%
  flextable::theme_booktabs() %>%
  flextable::add_header_lines(values = "Proposed u based on fairness criteria")

save_docx_std("Proposed u" = ft_prop,
              path = file.path("artifacts", "Proposed_u_decision_legacy_fairness_tost.docx"))
readr::write_csv(proposed_u_tbl, file.path("artifacts","Proposed_u_decision_legacy_fairness_tost.csv"))

# =============================================================
# Combined Diagnostics Runner (Cumulative Gains + BF + KS FOSD)
# =============================================================
cumgain_top <- function(df, p = 20) {  # p = top p%
  thr <- p
  mean(df$mentor_percentile <= thr, na.rm = TRUE)  # lower is better
}

# Brown–Forsythe (median-based Levene): between-methods (pooled across years by default)
run_bf_between_methods <- function(fair, per_year = FALSE) {
  if (!per_year) {
    return(car::leveneTest(y = fair$mentor_percentile,
                           group = as.factor(fair$method),
                           center = median))
  }
  yrs <- sort(unique(fair$year))
  purrr::map_dfr(yrs, function(y) {
    sub <- dplyr::filter(fair, year == y)
    lt  <- car::leveneTest(y = sub$mentor_percentile,
                           group = as.factor(sub$method),
                           center = median)
    tibble::tibble(year = y,
                   F = unname(lt[["F value"]][1]),
                   p = unname(lt[["Pr(>F)"]][1]))
  })
}

# =======================================================================
# Build one-stop JSON for Word macro ingestion: artifacts/paper_feed.json
# Requires helpers/functions already defined earlier in your script:
#   - load_fair_for_u, build_fairness_summaries, cumgain_top,
#     run_bf_between_methods, run_fosd_bootstrap
# =======================================================================


# ------------- small utilities -------------
.safe_exists <- function(path) isTRUE(file.exists(path))

.safe_read_csv <- function(path) {
  if (.safe_exists(path)) readr::read_csv(path, show_col_types = FALSE) else NULL
}

# jittered KS for diagnostic only (ties are expected with rank-derived percentiles)
# using jitter to eliminate warnings that mean percentiles repeat ACROSS participants:
# Warning messages:
#   1: In ks.test.default(x_cos, x_mw, alternative = "less") :
#   p-value will be approximate in the presence of ties
# 2: In ks.test.default(x_cos, x_mw, alternative = "greater") :
#   p-value will be approximate in the presence of ties

.ks_one_sided_diag <- function(x_cos, x_mw, eps = 1e-8) {
  x_cos <- x_cos[!is.na(x_cos)]; x_mw <- x_mw[!is.na(x_mw)]
  if (length(x_cos) < 5 || length(x_mw) < 5) {
    return(list(
      D_cos_greater = NA_real_, p_cos_greater = NA_real_,
      D_mw_less     = NA_real_, p_mw_less     = NA_real_
    ))
  }
  x_cos_j <- x_cos + runif(length(x_cos), -eps, eps)
  x_mw_j  <- x_mw  + runif(length(x_mw),  -eps, eps)
  ks_cg <- suppressWarnings(ks.test(x_cos_j, x_mw_j, alternative = "greater")) # Cos better: F_cos >= F_mw
  ks_ml <- suppressWarnings(ks.test(x_cos_j, x_mw_j, alternative = "less"))    # MW better:  F_cos <= F_mw
  list(
    D_cos_greater = as.numeric(ks_cg$statistic),
    p_cos_greater = as.numeric(ks_cg$p.value),
    D_mw_less     = as.numeric(ks_ml$statistic),
    p_mw_less     = as.numeric(ks_ml$p.value)
  )
}

# summarize cumulative gains at selected thresholds per year x method
.gains_by_year_method <- function(fair, p_seq = c(10, 20, 30, 40, 50)) {
  # Use group_by + reframe to avoid rowwise self-reference bug
  # (filter(year==year) inside rowwise compared column to itself, returning all rows)
  fair %>%
    dplyr::group_by(year, method) %>%
    dplyr::reframe(
      p        = p_seq,
      cum_gain = sapply(p, function(pv) mean(mentor_percentile <= pv, na.rm = TRUE))
    )
}

# ensure Table A csv exists; if not, build it
.ensure_tableA <- function(years, presentation_u) {
  path <- "artifacts/Table_A_rank_distribution.csv"
  if (!.safe_exists(path) && exists("build_table_A_combined", mode = "function")) {
    build_table_A_combined(years, presentation_u)
  }
  .safe_read_csv(path)
}

# ensure u_sweep csv exists; if not, try to derive from in-memory u_sweep
.ensure_u_sweep <- function() {
  path <- "artifacts/u_sweep_fairness_summary.csv"
  if (.safe_exists(path)) return(.safe_read_csv(path))
  if (exists("u_sweep", inherits = TRUE)) {
    readr::write_csv(get("u_sweep", inherits = TRUE), path)
    return(.safe_read_csv(path))
  }
  warning("u_sweep_fairness_summary.csv not found and u_sweep object not present; returning NULL")
  NULL
}

# ensure proposed_u decision csv exists; if not, try to derive from rules on u_sweep
.ensure_proposed_u <- function() {
  path <- "artifacts/Proposed_u_decision.csv"
  if (.safe_exists(path)) return(.safe_read_csv(path))
  if (exists("u_sweep", inherits = TRUE)) {
    us <- get("u_sweep", inherits = TRUE)
    proposed <- us |>
      dplyr::mutate(
        pass_DI     = !is.na(DI)  & DI >= 0.80 & !is.na(DI_L) & DI_L >= 0.75,
        pass_fisher = !is.na(fisher_p) & fisher_p >= 0.05,
        pass_gap    = !is.na(mean_gap) & abs(mean_gap) <= 3,
        pass_smd    = !is.na(SMD) & abs(SMD) <= 0.30,
        pass_all    = pass_DI & pass_fisher & pass_gap & pass_smd
      ) |>
      dplyr::filter(pass_all) |>
      dplyr::arrange(u) |>
      dplyr::slice_head(n = 1)
    if (nrow(proposed) == 0) {
      proposed <- tibble::tibble(
        u = NA_real_,
        decision = "No u in grid satisfies all fairness rules",
        note = "Consider widening thresholds or inspecting CI plots manually."
      )
    }
    readr::write_csv(proposed, path)
    return(.safe_read_csv(path))
  }
  warning("Proposed_u_decision.csv not found and u_sweep not present; returning NULL")
  NULL
}

# compute all diagnostics for the current presentation_u (and write fosd csv if not present)
.compute_presentation_u_block <- function(presentation_u, years, out_dir = "artifacts") {
  fair <- load_fair_for_u(presentation_u, years, out_dir)
  
  # Fairness tables for presentation_u
  fair_summ <- build_fairness_summaries(
    fair,
    thr_pos_pct = thr_pos_pct,
    B = B_boot,
    seed = 42
  )
  
  # Per-year & method gains at common thresholds
  gains_tbl <- .gains_by_year_method(fair, p_seq = c(10, 20, 30, 40, 50))
  
  # Brown–Forsythe between methods
  bf_overall <- run_bf_between_methods(fair, per_year = FALSE)
  bf_yearly  <- tryCatch(run_bf_between_methods(fair, per_year = TRUE), error = function(e) NULL)
  
  # KS (diagnostic) + bootstrap FOSD (inference) at the method level
  x_cos <- fair %>% dplyr::filter(method == "Cosine Similarity") %>% dplyr::pull(mentor_percentile)
  x_mw  <- fair %>% dplyr::filter(method == "Matching Words")    %>% dplyr::pull(mentor_percentile)
  
  ks_diag <- .ks_one_sided_diag(x_cos, x_mw)
  fosd    <- run_fosd_bootstrap(x_cos = x_cos, x_mw = x_mw, B = 10000, seed = 42, grid = seq(0, 100, by = 0.5))
  
  # Persist a compact FOSD CSV for audit trail (method-level)
  u_tag <- gsub("\\.", "p", sprintf("%.3f", presentation_u))
  fosd_out <- tibble::tibble(
    u = presentation_u,
    obs_sup = fosd$obs_sup, sup_L = fosd$sup_CI[1], sup_U = fosd$sup_CI[2],
    obs_inf = fosd$obs_inf, inf_L = fosd$inf_CI[1], inf_U = fosd$inf_CI[2],
    mw_dominance_prob  = fosd$mw_dominance_prob,
    cos_dominance_prob = fosd$cos_dominance_prob,
    KS_D_cos_greater = ks_diag$D_cos_greater, KS_p_cos_greater = ks_diag$p_cos_greater,
    KS_D_mw_less     = ks_diag$D_mw_less,     KS_p_mw_less     = ks_diag$p_mw_less
  )
  readr::write_csv(fosd_out, file.path(out_dir, sprintf("fosd_summary_u%s.csv", u_tag)))
  
  list(
    fair       = fair,
    di_table   = fair_summ$di_table,
    dist_table = fair_summ$dist_table,
    gains_tbl  = gains_tbl,
    bf_overall = tryCatch({
      data.frame(
        F = unname(bf_overall[["F value"]][1]),
        p = unname(bf_overall[["Pr(>F)"]][1])
      )
    }, error = function(e) NULL),
    bf_yearly  = bf_yearly,
    ks         = ks_diag,
    fosd       = fosd
  )
}

# discover figure paths if present
.collect_figures <- function() {
  figs <- c(
    "Figure_1_Cumulative_Gains.png",
    "Figure_2_Density_Cos_Sim.png",
    "Figure_3_Density_Word_Matching.png",
    "Figure_4_Percentiles_Density_By_Year.png",
    "Figure_6_Selection_Rates_By_Grade_Group.png",
    "Figure_u_sweep_DI_bootstrap.png",
    "Figure_u_sweep_SRdiff_bootstrap.png",
    "Figure_u_sweep_MeanPercentileGap_bootstrap.png"
  )
  paths <- file.path("artifacts", figs)
  tibble::tibble(name = figs, path = paths, exists = file.exists(paths))
}

.collect_result_artifacts <- function(out_dir = "artifacts") {
  docs <- c(
    "Table_A_rank_distribution.docx",
    "DI_summary.docx",
    "Distributional_Fairness.docx",
    "results_grade_detail.docx",
    "results_mentor_balance.docx"
  )
  paths <- file.path(out_dir, docs)
  tibble::tibble(name = docs, path = paths, exists = file.exists(paths))
}

# ----- main builder -----
build_paper_feed <- function(years, u_grid, presentation_u, out_dir = "artifacts") {
  # 1) ensure foundational artifacts
  tableA       <- .ensure_tableA(years, presentation_u)
  u_sweep_tbl  <- .ensure_u_sweep()
  proposed_tbl <- .ensure_proposed_u()
  
  # 2) compute diagnostics for presentation_u
  diag_u <- .compute_presentation_u_block(presentation_u, years, out_dir)
  
  # 3) figures list
  figs <- .collect_figures()
  result_docs <- .collect_result_artifacts(out_dir)
  u_grid_meta <- if (exists("u_grid_all", inherits = TRUE)) {
    as.numeric(get("u_grid_all", inherits = TRUE))
  } else {
    as.numeric(u_grid)
  }
  
  # 4) assemble JSON-ready list
  feed <- list(
    meta = list(
      run_ts        = as.character(Sys.time()),
      years         = as.integer(years),
      u_grid        = u_grid_meta,
      u_grid_run    = as.numeric(u_grid),
      presentation_u= as.numeric(presentation_u),
      ## Repository-relative: an absolute path would leak the generating machine's
      ## filesystem layout into a published artifact.
      artifacts_dir = as.character(out_dir)
    ),
    figures   = as.data.frame(figs),
    documents = as.data.frame(result_docs),
    tableA    = tableA,
    u_sweep   = u_sweep_tbl,
    proposed_u= proposed_tbl,
    results = list(
      grade_counts_by_year           = .safe_read_csv(file.path(out_dir, "results_grade_counts_by_year.csv")),
      selection_rates_by_year_grade  = .safe_read_csv(file.path(out_dir, "results_selection_rates_by_year_grade.csv")),
      mean_percentile_by_year_grade  = .safe_read_csv(file.path(out_dir, "results_mean_percentile_by_year_grade.csv")),
      mentor_balance                 = .safe_read_csv(file.path(out_dir, "results_mentor_balance.csv"))
    ),
    diagnostics = list(
      gains_by_year_method    = diag_u$gains_tbl,
      DI_summary              = diag_u$di_table,
      distributional_fairness = diag_u$dist_table,
      brown_forsythe_overall  = diag_u$bf_overall,
      brown_forsythe_yearly   = diag_u$bf_yearly,
      ks_one_sided_diag       = diag_u$ks,
      # pass method-level FOSD (the list from run_fosd_bootstrap) directly
      fosd_bootstrap          = diag_u$fosd
    )
  )
  
  # 5) write JSON
  jsonlite::write_json(
    feed,
    file.path(out_dir, "paper_feed.json"),
    pretty = TRUE, auto_unbox = TRUE, digits = NA
  )
  message(sprintf("✓ Wrote %s", file.path(out_dir, "paper_feed.json")))
  invisible(feed)
}

combined_out <- run_combined_diagnostics(presentation_u, years)
message("Deferring paper_feed.json until after auto presentation_u selection to keep a single consistent decision path.")

.compute_deficits <- function(df, di_floor, sr_equiv_margin, gap_margin, smd_max, fisher_alpha) {
  df %>%
    dplyr::mutate(
      di_def  = dplyr::if_else(is.na(DI_L), 1e6, pmax(0, di_floor - DI_L)),
      sr_def  = dplyr::if_else(
        is.na(SR_diff_L) | is.na(SR_diff_U),
        1e6,
        pmax(0, SR_diff_U - sr_equiv_margin) +
          pmax(0, (-sr_equiv_margin) - SR_diff_L)
      ),
      gap_def = dplyr::if_else(
        is.na(mean_gap_L) | is.na(mean_gap_U),
        1e6,
        pmax(0, mean_gap_U - gap_margin) +
          pmax(0, (-gap_margin) - mean_gap_L)
      ),
      smd_def = dplyr::if_else(is.na(SMD), 1e6, pmax(0, abs(SMD) - smd_max)),
      fish_def= dplyr::if_else(is.na(fisher_p), 1e6, pmax(0, fisher_alpha - fisher_p)),
      total_def = di_def + sr_def + gap_def + smd_def + fish_def
    )
}

.load_upstream_winner_support <- function(
    run_history_path = "run_history_progress_2.csv",
    successes_path = "dominance_successes_2.csv") {
  rh <- if (file.exists(run_history_path)) {
    tryCatch(readr::read_csv(run_history_path, show_col_types = FALSE), error = function(e) NULL)
  } else NULL
  sc <- if (file.exists(successes_path)) {
    tryCatch(readr::read_csv(successes_path, show_col_types = FALSE), error = function(e) NULL)
  } else NULL

  rh_summary <- tibble::tibble()
  if (!is.null(rh) && nrow(rh) > 0 && "u" %in% names(rh)) {
    if (!"pass_core" %in% names(rh)) {
      rh <- rh %>%
        dplyr::mutate(
          pass_core = dplyr::if_else(
            "mw_visual_dominates" %in% names(rh) & "cs_visual_dominates" %in% names(rh),
            dplyr::coalesce(mw_visual_dominates, FALSE) | dplyr::coalesce(cs_visual_dominates, FALSE),
            FALSE
          )
        )
    }
    rh_summary <- rh %>%
      dplyr::mutate(u = round(as.numeric(u), 3)) %>%
      dplyr::group_by(u) %>%
      dplyr::summarise(
        winner_rows_run_history = sum(dplyr::coalesce(pass_core, FALSE), na.rm = TRUE),
        winner_methods = paste(sort(unique(trigger_method[dplyr::coalesce(pass_core, FALSE) & !is.na(trigger_method)])), collapse = ";"),
        .groups = "drop"
      )
  }

  sc_summary <- tibble::tibble()
  if (!is.null(sc) && nrow(sc) > 0 && "u" %in% names(sc)) {
    sc_summary <- sc %>%
      dplyr::mutate(u = round(as.numeric(u), 3)) %>%
      dplyr::group_by(u) %>%
      dplyr::summarise(
        winner_rows_successes = dplyr::n(),
        .groups = "drop"
      )
  }

  if (nrow(rh_summary) == 0 && nrow(sc_summary) == 0) {
    return(tibble::tibble(
      u = numeric(),
      winner_rows_run_history = integer(),
      winner_rows_successes = integer(),
      winner_methods = character()
    ))
  }

  if (nrow(rh_summary) == 0) {
    rh_summary <- tibble::tibble(
      u = numeric(),
      winner_rows_run_history = integer(),
      winner_methods = character()
    )
  }

  if (nrow(sc_summary) == 0) {
    sc_summary <- tibble::tibble(
      u = numeric(),
      winner_rows_successes = integer()
    )
  }

  dplyr::full_join(rh_summary, sc_summary, by = "u") %>%
    dplyr::mutate(
      winner_rows_run_history = dplyr::coalesce(winner_rows_run_history, 0L),
      winner_rows_successes = dplyr::coalesce(winner_rows_successes, 0L),
      winner_methods = dplyr::coalesce(winner_methods, "")
    )
}

# =============================================================
# Auto-choose presentation_u (Equivalence gates + Stability + Utility)
# Outputs:
#   artifacts/auto_presentation_u_candidates.csv
#   artifacts/Proposed_u_decision.csv
#   artifacts/auto_presentation_u_decision.docx
# Returns: list(u_selected=..., candidates=..., decision_row=...)
# =============================================================
choose_presentation_u <- function(
    u_sweep_path = "artifacts/u_sweep_fairness_summary.csv",
    di_floor = 0.80,          # DI lower bound
    gap_margin = 3,           # |mean gap| <= margin via 90% CI containment
    smd_max = 0.30,           # |SMD| threshold
  smd_as_gate = FALSE,      # Salami & Lo alignment: treat SMD as supporting by default
    fisher_alpha = NULL,      # NULL => supportive only
    stability_neighbor = 0.10,
    top_k = 5,
    out_dir = "artifacts",
    fosd_delta = 0.10,        # TOST margin on ECDF gap (Lo, Datta & Salami 2025)
    fosd_delta_strict = 0.05  # sensitivity margin
) {
  # back-compat alias for older callsites
  fosd_eps <- fosd_delta
  # --- input guard (stop if the file is missing) ---
  if (!file.exists(u_sweep_path)) stop("Cannot find ", u_sweep_path)
  us <- readr::read_csv(u_sweep_path, show_col_types = FALSE)

  winner_support <- .load_upstream_winner_support()
  if (nrow(winner_support) > 0) {
    us <- us %>%
      dplyr::mutate(u = round(as.numeric(u), 3)) %>%
      dplyr::left_join(winner_support, by = "u")
  }

  # --- dynamic columns (90% preferred for TOST) ---
  diL <- if ("DI_L90" %in% names(us)) "DI_L90" else "DI_L"
  mgL <- if ("mean_gap_L90" %in% names(us)) "mean_gap_L90" else "mean_gap_L"
  mgU <- if ("mean_gap_U90" %in% names(us)) "mean_gap_U90" else "mean_gap_U"
  has_inf_L <- "FOSD_inf_CI_L" %in% names(us)

  # --- primary gates & supportive flags ---
  us <- us %>%
    dplyr::mutate(
      avg_pct   = (mean_pct_low + mean_pct_high) / 2,
      pass_DI   = !is.na(.data[[diL]]) & (.data[[diL]] >= di_floor),
      pass_gap  = !is.na(.data[[mgL]]) & !is.na(.data[[mgU]]) &
        (.data[[mgL]] >= -gap_margin) & (.data[[mgU]] <=  gap_margin),
      pass_SMD  = !is.na(SMD) & (abs(SMD) <= smd_max),
      # NOTE: FOSD here measures grade-group distributional gap (Grades 1-4 vs 5+),
      # NOT CS-vs-MW method equivalence. Method-equivalence FOSD was evaluated in
      # search_dominance.R and used to select the weight vector upstream.
      # Grade-group FOSD is structurally non-zero (senior mentees compete for better
      # mentors by design) and is reported as a diagnostic only, not a selection gate.
      # TOST equivalence columns retained for reporting.
      pass_FOSD = !is.na(FOSD_sup_CI_U) & (FOSD_sup_CI_U <=  fosd_delta) &
                  (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta) else TRUE),
      fosd_pass_delta10 = !is.na(FOSD_sup_CI_U) & (FOSD_sup_CI_U <=  fosd_delta) &
                  (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta) else TRUE),
      fosd_pass_delta05 = !is.na(FOSD_sup_CI_U) & (FOSD_sup_CI_U <=  fosd_delta_strict) &
                  (if (has_inf_L) (!is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta_strict) else TRUE),
      pass_Fisher = if (is.null(fisher_alpha)) NA else (!is.na(fisher_p) & fisher_p >= fisher_alpha),
      # Tiered gating:
      # - pass_all_core: primary decision gate (DI + mean-gap equivalence)
      # - pass_all_strict: adds SMD cap for sensitivity reporting
      # Grade-group FOSD remains diagnostic (not a gate).
      pass_all_core = pass_DI & pass_gap,
      pass_all_strict = pass_DI & pass_gap & pass_SMD,
      pass_all = if (isTRUE(smd_as_gate)) pass_all_strict else pass_all_core
    ) %>%
    dplyr::arrange(u)
  
  # --- neighbor-stability helpers ---
  passes_at <- function(u0) {
    r <- us %>% dplyr::filter(abs(u - u0) < 1e-9)
    if (nrow(r) == 0) return(NA)
    isTRUE(r$pass_all[1])
  }
  neighbor_stable <- function(u0) {
    current <- passes_at(u0)
    u_minus <- round(u0 - stability_neighbor, 1)
    u_plus  <- round(u0 + stability_neighbor, 1)
    left  <- passes_at(u_minus); right <- passes_at(u_plus)
    same_left  <- isTRUE(left  == current)
    same_right <- isTRUE(right == current)
    if (is.na(left) && is.na(right)) return(FALSE)
    if (is.na(left))  return(same_right)
    if (is.na(right)) return(same_left)
    same_left && same_right
  }
  
  # --- candidate path ---
  cands <- us %>%
    dplyr::filter(pass_all) %>%
    dplyr::mutate(stable = purrr::map_lgl(u, neighbor_stable)) %>%
    dplyr::arrange(avg_pct, u)
  
  if (nrow(cands) == 0) {
    # -------- fallback: least-violating (compute deficits) --------
    us_def <- us %>%
      dplyr::mutate(
        # deficits are expressed as "how much to fix" to reach thresholds
        di_def   = dplyr::if_else(is.na(DI_L),           1e6, pmax(0, di_floor - DI_L)),
        gap_def  = dplyr::if_else(is.na(mean_gap_L) | is.na(mean_gap_U), 1e6,
                                  pmax(0, mean_gap_U - gap_margin) + pmax(0, (-gap_margin) - mean_gap_L)),
        smd_def  = dplyr::if_else(is.na(SMD),            1e6, pmax(0, abs(SMD) - smd_max)),
        fosd_def = dplyr::if_else(is.na(FOSD_sup_CI_U),  0,   pmax(0, FOSD_sup_CI_U - fosd_eps)),
        total_def = di_def + gap_def + smd_def + 0.1 * fosd_def
      ) %>%
      dplyr::arrange(total_def, avg_pct, u) %>%
      dplyr::mutate(stable = purrr::map_lgl(u, neighbor_stable))
    
    chosen  <- us_def %>% dplyr::slice(1) %>%
      dplyr::mutate(decision = "No u meets all gates — selected least-violating u",
                    passes_all = FALSE)
    top_tbl <- us_def %>% dplyr::slice_head(n = top_k)
    
  } else {
    # -------- success: pick among passes (compute deficits too, for consistency) --------
    cands_ordered <- cands %>% dplyr::arrange(dplyr::desc(stable), avg_pct, u) %>%
      dplyr::mutate(
        di_def   = dplyr::if_else(is.na(DI_L),           1e6, pmax(0, di_floor - DI_L)),
        gap_def  = dplyr::if_else(is.na(mean_gap_L) | is.na(mean_gap_U), 1e6,
                                  pmax(0, mean_gap_U - gap_margin) + pmax(0, (-gap_margin) - mean_gap_L)),
        smd_def  = dplyr::if_else(is.na(SMD),            1e6, pmax(0, abs(SMD) - smd_max)),
        fosd_def = dplyr::if_else(is.na(FOSD_sup_CI_U),  0,   pmax(0, FOSD_sup_CI_U - fosd_eps)),
        total_def = di_def + gap_def + smd_def + 0.1 * fosd_def
      )
    
    chosen  <- cands_ordered %>% dplyr::slice(1) %>%
      dplyr::mutate(
        decision   = dplyr::if_else(stable,
                                    "Selected (passes gates; neighbor-stable)",
                                    "Selected (passes gates; neighbor-unstable)"),
        passes_all = TRUE
      )
    top_tbl <- cands_ordered %>% dplyr::slice_head(n = top_k)
  }
  
  # --- write artifacts ---
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  readr::write_csv(top_tbl, file.path(out_dir, "auto_presentation_u_candidates.csv"))
  
  # decision CSV (use any_of so the select never fails even if columns are absent)
  proposed_csv <- dplyr::select(
    chosen,
    u, decision, passes_all, stable,
    avg_pct, DI, dplyr::all_of(diL), DI_U,
    mean_gap, dplyr::all_of(mgL), dplyr::all_of(mgU),
    SMD, fisher_p,
    dplyr::any_of(c("winner_rows_run_history", "winner_rows_successes", "winner_methods")),
    dplyr::any_of(c("FOSD_obs_sup","FOSD_sup_CI_L","FOSD_sup_CI_U",
                    "FOSD_obs_inf","FOSD_inf_CI_L","FOSD_inf_CI_U")),
    dplyr::any_of(c("di_def","gap_def","smd_def","fosd_def","total_def"))
  )
  
  readr::write_csv(proposed_csv, file.path(out_dir, "Proposed_u_decision.csv"))
  
  # DOCX
  ft_head <- flextable::flextable(proposed_csv) %>% flextable::autofit() %>%
    flextable::align(align = "center", part = "all") %>% flextable::bold(part = "header") %>%
    flextable::theme_booktabs() %>%
    flextable::add_header_lines(values = "Auto-selected presentation_u (DI + Distributional Fairness)") %>%
    flextable::add_footer_lines(values = sprintf(
      "Core gates: DI lower bound ≥ %.2f and |mean_gap| within ±%.1f by 90%% CI (TOST). Strict sensitivity gate additionally checks |SMD| ≤ %.2f. Grade-group FOSD and Fisher are diagnostic only.",
      di_floor, gap_margin, smd_max
    ))
  
  ft_top <- flextable::flextable(top_tbl) %>% flextable::autofit() %>%
    flextable::align(align = "center", part = "all") %>% flextable::bold(part = "header") %>%
    flextable::theme_booktabs() %>%
    flextable::add_header_lines(values = sprintf("Top-%d candidates", top_k))
  
  save_docx_std("Decision" = ft_head, "Top candidates" = ft_top,
                path = file.path(out_dir, "auto_presentation_u_decision.docx"))
  
  list(u_selected = chosen$u[1], decision = proposed_csv, candidates = top_tbl)
}

# ---- Auto-choose u and (optionally) re-run diagnostics/feed ----
auto_sel <- choose_presentation_u()

# Pick DI lower bound column (prefer 90% for TOST-style logic; else 95%)
diL_col <- if ("DI_L90" %in% names(auto_sel$decision)) "DI_L90" else "DI_L"

# Pick mean-gap CI columns (prefer 90% if present; else 95%)
mgL_col <- if ("mean_gap_L90" %in% names(auto_sel$decision)) "mean_gap_L90" else "mean_gap_L"
mgU_col <- if ("mean_gap_U90" %in% names(auto_sel$decision)) "mean_gap_U90" else "mean_gap_U"

dec <- auto_sel$decision %>%
  dplyr::mutate(
    gap_margin = 3,
    DI_def     = pmax(0, 0.80 - .data[[diL_col]]),
    # Deficiency = how far the CI bound sits OUTSIDE the margin, 0 when inside.
    # Same form as .compute_deficits() above; the earlier
    # pmax(0, gap_margin - (-mgL)) read the lower side backwards, reporting a
    # deficiency for bounds inside the margin and 0 for bounds outside it.
    gap_def_L  = pmax(0, (-gap_margin) - .data[[mgL_col]]),
    gap_def_U  = pmax(0, .data[[mgU_col]] - gap_margin)
  ) %>%
  dplyr::select(
    u, passes_all, dplyr::any_of(c("pass_all_core", "pass_all_strict", "pass_DI", "pass_gap", "pass_SMD")), decision,
    # show the actual DI column we used so the reader sees the bound applied
    !!diL_col, DI_def,
    # same for the mean-gap CI columns
    !!mgL_col, !!mgU_col, gap_def_L, gap_def_U,
    SMD, FOSD_obs_sup, FOSD_sup_CI_L, FOSD_sup_CI_U, fisher_p
  )
# ---------------------------------------------------------------
# Make a nicely formatted DOCX of u_sweep_fairness_summary.csv
# - Rounds display to 3 decimals
# - Bolds the chosen u row (default 0.55)
# - Colors threshold violations RED
# - Splits into 3 subtables while keeping 'u' in each
# - Writes artifacts/u_sweep_formatted.docx
# ---------------------------------------------------------------

make_u_sweep_docx <- function(
  csv_path   = file.path("artifacts", "u_sweep_fairness_summary.csv"),
  out_path   = file.path("artifacts", "u_sweep_formatted.docx"),
  u_chosen   = 0.55,
  # thresholds (edit as needed)
  di_floor   = 0.80,
  sr_margin  = 0.02,
  gap_margin = 3,
  smd_max    = 0.20,
  fisher_alpha = 0.05
) {
  stopifnot(file.exists(csv_path))
  us_raw <- readr::read_csv(csv_path, show_col_types = FALSE)

  # --------- column groups (keep only if present) ----------
  keep_if_present <- function(nms) intersect(nms, names(us_raw))

  cols1 <- keep_if_present(c(
    "u","n_low","sr_low","n_high","sr_high","fisher_p",
    "DI","DI_L","DI_U","DI_L90","DI_U90"
  ))
  cols2 <- keep_if_present(c(
    "u","SR_diff","SR_diff_L","SR_diff_U","SR_diff_L90","SR_diff_U90"
  ))
  cols3 <- keep_if_present(c(
    "u","mean_pct_low","mean_pct_high",
    "mean_gap","mean_gap_L","mean_gap_U","mean_gap_L90","mean_gap_U90",
    "SMD"
  ))

  # Basic guard if some groups end up empty
  if (length(cols1) == 0) cols1 <- keep_if_present(c("u"))
  if (length(cols2) == 0) cols2 <- keep_if_present(c("u"))
  if (length(cols3) == 0) cols3 <- keep_if_present(c("u"))

  # Subframes for display
  df1 <- us_raw[, cols1, drop = FALSE]
  df2 <- us_raw[, cols2, drop = FALSE]
  df3 <- us_raw[, cols3, drop = FALSE]

  # Index of chosen u (tolerant to small float diffs)
  idx_chosen <- which( abs(us_raw$u - u_chosen) < 1e-9 | round(us_raw$u, 2) == round(u_chosen, 2) )

  # --------- helper: apply red color for violations (safe against missing cols) ----------
  apply_violations <- function(ft, df_sub, df_raw, group_cols,
                               di_floor = 0.80, sr_margin = 0.02,
                               gap_margin = 3, smd_max = 0.20, fisher_alpha = 0.05,
                               idx_chosen = integer(0)) {
    
    # columns actually in this flextable:
    ft_cols <- names(df_sub)
    
    # small helper to color only if the column is present in this ft
    safe_color <- function(ft_obj, idx_rows, colname) {
      if (length(idx_rows) == 0L) return(ft_obj)
      if (!(colname %in% ft_cols)) return(ft_obj)
      flextable::color(ft_obj, i = idx_rows, j = colname, color = "red", part = "body")
    }
    
    col_present_raw <- function(x) x %in% names(df_raw)
    
    # --- DI lower bound (both 95% & 90% if present in this ft) ---
    for (coln in c("DI_L", "DI_L90")) {
      if (col_present_raw(coln) && (coln %in% ft_cols)) {
        idx <- which(df_raw[[coln]] < di_floor)
        ft  <- safe_color(ft, idx, coln)
      }
    }
    
    # --- SR diff CI containment (both 95% & 90%) ---
    for (coln in c("SR_diff_L", "SR_diff_L90")) {
      if (col_present_raw(coln) && (coln %in% ft_cols)) {
        idx <- which(df_raw[[coln]] < -sr_margin)
        ft  <- safe_color(ft, idx, coln)
      }
    }
    for (coln in c("SR_diff_U", "SR_diff_U90")) {
      if (col_present_raw(coln) && (coln %in% ft_cols)) {
        idx <- which(df_raw[[coln]] > sr_margin)
        ft  <- safe_color(ft, idx, coln)
      }
    }
    
    # --- Mean gap CI containment (both 95% & 90%) ---
    for (coln in c("mean_gap_L", "mean_gap_L90")) {
      if (col_present_raw(coln) && (coln %in% ft_cols)) {
        idx <- which(df_raw[[coln]] < -gap_margin)
        ft  <- safe_color(ft, idx, coln)
      }
    }
    for (coln in c("mean_gap_U", "mean_gap_U90")) {
      if (col_present_raw(coln) && (coln %in% ft_cols)) {
        idx <- which(df_raw[[coln]] > gap_margin)
        ft  <- safe_color(ft, idx, coln)
      }
    }
    
    # --- SMD threshold ---
    if ("SMD" %in% ft_cols && "SMD" %in% names(df_raw)) {
      idx <- which(abs(df_raw$SMD) > smd_max)
      ft  <- safe_color(ft, idx, "SMD")
    }
    
    # --- Fisher’s exact p-value ---
    if ("fisher_p" %in% ft_cols && "fisher_p" %in% names(df_raw)) {
      idx <- which(df_raw$fisher_p < fisher_alpha)
      ft  <- safe_color(ft, idx, "fisher_p")
    }
    
    # --- Bold the chosen u row (if present in this subtable) ---
    if (length(idx_chosen)) {
      ft <- flextable::bold(ft, i = idx_chosen, bold = TRUE, part = "body")
    }
    
    ft
  }

  # --------- helper: build a formatted flextable ----------
  make_ft <- function(df_sub, title_line) {
    ft <- flextable::flextable(df_sub) |>
      flextable::theme_booktabs() |>
      flextable::autofit() |>
      flextable::align(align = "center", part = "all") |>
      flextable::bold(part = "header") |>
      flextable::add_header_lines(values = title_line)

    # Format numeric display to 3 decimals without changing underlying values
    num_cols <- names(df_sub)[vapply(df_sub, is.numeric, logical(1))]
    if (length(num_cols)) {
      ft <- flextable::colformat_num(ft, j = num_cols, digits = 3)
    }
    ft
  }

  # Build the three ft objects
  ft1 <- make_ft(df1, "u-sweep Summary — Core Rates & Disparate Impact")
  ft1 <- apply_violations(
    ft1, df1, us_raw, cols1,
    di_floor   = di_floor,
    sr_margin  = sr_margin,
    gap_margin = gap_margin,
    smd_max    = smd_max,
    fisher_alpha = fisher_alpha,
    idx_chosen = idx_chosen
  )
  
  ft2 <- make_ft(df2, "u-sweep Summary — Δ Selection Rate (Equivalence CIs)")
  ft2 <- apply_violations(
    ft2, df2, us_raw, cols2,
    di_floor   = di_floor,
    sr_margin  = sr_margin,
    gap_margin = gap_margin,
    smd_max    = smd_max,
    fisher_alpha = fisher_alpha,
    idx_chosen = idx_chosen
  )
  
  ft3 <- make_ft(df3, "u-sweep Summary — Mean Percentile Gap & Effect Size")
  ft3 <- apply_violations(
    ft3, df3, us_raw, cols3,
    di_floor   = di_floor,
    sr_margin  = sr_margin,
    gap_margin = gap_margin,
    smd_max    = smd_max,
    fisher_alpha = fisher_alpha,
    idx_chosen = idx_chosen
  )

  # Save to DOCX (matches your established style)
  save_docx_std(
    "Table: u-sweep (Core rates & DI)"        = ft1,
    "Table: u-sweep (ΔSR Equivalence CIs)"    = ft2,
    "Table: u-sweep (Mean gap & SMD)"         = ft3,
    path = out_path
  )

  message(sprintf("✓ Wrote %s", out_path))
}

# ---- run it ----
make_u_sweep_docx()

us <- readr::read_csv("artifacts/u_sweep_fairness_summary.csv", show_col_types = FALSE)

augment_u_sweep_with_fosd <- function(
    us_path   = "artifacts/u_sweep_fairness_summary.csv",
    years     = 2023:2025,
    out_dir   = "artifacts",
    B         = 2000,
    seed      = 42,
    grid      = seq(0, 100, by = 0.5),
    prefer = c("recomputed", "existing")  # choose which value to keep on overlap
) {
  prefer <- match.arg(prefer)
  stopifnot(file.exists(us_path))
  us <- readr::read_csv(us_path, show_col_types = FALSE)
  
  fosd_cols <- c(
    "FOSD_obs_sup", "FOSD_sup_CI_L", "FOSD_sup_CI_U",
    "FOSD_obs_inf", "FOSD_inf_CI_L", "FOSD_inf_CI_U"
  )
  
  # --- per-u recomputation using grade groups (Grades 1–4 vs 5+) ---
  calc_fosd_for_u <- function(u) {
    fair <- load_fair_for_u(u = u, years = years, out_dir = out_dir)
    
    fair2 <- fair %>%
      mutate(
        grade_num = suppressWarnings(as.numeric(str_extract(as.character(grade_mentee), "\\d+"))),
        grade_group = case_when(
          !is.na(grade_num) & grade_num <= 4 ~ "Grades 1–4",
          !is.na(grade_num) & grade_num >= 5 ~ "Grades 5+",
          TRUE ~ NA_character_
        )
      ) %>%
      filter(!is.na(grade_group), !is.na(mentor_percentile))
    
    x_low  <- fair2 %>% filter(grade_group == "Grades 1–4") %>% pull(mentor_percentile)
    x_high <- fair2 %>% filter(grade_group == "Grades 5+")   %>% pull(mentor_percentile)
    
    fosd <- run_fosd_bootstrap(x_low = x_low, x_high = x_high, B = B, seed = seed, grid = grid)
    
    tibble::tibble(
      u = u,
      FOSD_obs_sup = fosd$obs_sup,
      FOSD_sup_CI_L = fosd$sup_CI[1],
      FOSD_sup_CI_U = fosd$sup_CI[2],
      FOSD_obs_inf = fosd$obs_inf,
      FOSD_inf_CI_L = fosd$inf_CI[1],
      FOSD_inf_CI_U = fosd$inf_CI[2]
    )
  }
  
  fosd_by_u <- purrr::map_dfr(us$u, calc_fosd_for_u)
  
  # --- Join with explicit suffix, then coalesce and drop temp columns ---
  us_joined <- us %>%
    left_join(fosd_by_u, by = "u", suffix = c("", "_new"))
  
  # Decide precedence for coalescing
  # If prefer == "recomputed": take *_new first, else take existing first
  coalesce_pair <- function(df, base) {
    new <- paste0(base, "_new")
    if (!(base %in% names(df)) && !(new %in% names(df))) return(df)
    if (prefer == "recomputed") {
      df[[base]] <- dplyr::coalesce(df[[new]], df[[base]])
    } else {
      df[[base]] <- dplyr::coalesce(df[[base]], df[[new]])
    }
    df[[new]] <- NULL
    df
  }
  
  us_clean <- Reduce(coalesce_pair, fosd_cols, init = us_joined)
  
  # Persist a clean CSV (no suffixes)
  out_path <- file.path(out_dir, "u_sweep_fairness_summary_with_fosd.csv")
  readr::write_csv(us_clean, out_path)
  message(sprintf("✓ wrote %s", out_path))
  us_clean
}


# Usage:
us2 <- augment_u_sweep_with_fosd()
  
audit <- us2 %>%
  mutate(
    # Prefer 90% CI for equivalence; fallback to 95% if 90% missing
    mgL = dplyr::coalesce(.data[["mean_gap_L90"]], .data[["mean_gap_L"]]),
    mgU = dplyr::coalesce(.data[["mean_gap_U90"]], .data[["mean_gap_U"]]),

    pass_DI   = !is.na(DI_L) & DI_L >= di_floor,
    pass_gap  = !is.na(mgL) & !is.na(mgU) & mgL >= -gap_margin & mgU <=  gap_margin,
    pass_SMD  = !is.na(SMD) & abs(SMD) <= smd_max,
    # Two-sided TOST equivalence on ECDF gap at delta = fosd_delta.
    pass_FOSD = !is.na(FOSD_sup_CI_U) & FOSD_sup_CI_U <=  fosd_delta &
                !is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta,

    pass_all  = pass_DI & pass_gap & pass_SMD & pass_FOSD
  ) %>%
  transmute(
    u,
    DI_L, pass_DI,
    mgL, mgU, pass_gap,
    SMD, pass_SMD,
    FOSD_sup_CI_U, FOSD_inf_CI_L, pass_FOSD,
    pass_all
  ) %>%
  arrange(u)


us %>%
  # Prefer 90% CI for TOST if available, otherwise fall back to 95%
  mutate(
    mgL = if ("mean_gap_L90" %in% names(.)) mean_gap_L90 else mean_gap_L,
    mgU = if ("mean_gap_U90" %in% names(.)) mean_gap_U90 else mean_gap_U
  ) %>%
  summarise(
    total_u = dplyr::n(),
    # Primary gates (counts)
    n_DI    = sum(!is.na(DI_L) & DI_L >= di_floor),
    n_gap   = sum(!is.na(mgL) & !is.na(mgU) & mgL >= -gap_margin & mgU <= gap_margin),
    n_SMD   = sum(!is.na(SMD) & abs(SMD) <= smd_max),
    n_FOSD  = sum(!is.na(FOSD_sup_CI_U) & FOSD_sup_CI_U <=  fosd_delta &
                  !is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta),
    
    # Diagnostic-only (not a gate)
    n_Fisher_diag = sum(!is.na(fisher_p) & fisher_p >= 0.05),
    
    # How many u pass ALL primary gates (choose one SMD rule)
    n_pass_all_SMD0 = sum(
        !is.na(DI_L) & DI_L >= di_floor &
        !is.na(mgL) & !is.na(mgU) & mgL >= -gap_margin & mgU <= gap_margin &
        !is.na(SMD) & abs(SMD) <= smd_max &
        !is.na(FOSD_sup_CI_U) & FOSD_sup_CI_U <=  fosd_delta &
        !is.na(FOSD_inf_CI_L) & FOSD_inf_CI_L >= -fosd_delta
    )
  )
  


# S8 fix (2026-08-08). This line used to read
#   presentation_u <- auto_sel$u_selected
# which overwrote the u = 1.5 set at the top of the file, but only for the
# outputs built BELOW it. Figures and Word tables written above kept 1.5 while
# the results tables, the method TOST and the combined diagnostics silently
# switched to the selector's choice (0.9). One run emitted both
# Diagnostics_Combined_u1p500.docx and _u0p900.docx, and the published TOST
# table was computed at a different u from the fairness-checks table beside it.
# presentation_u now stays fixed at the value declared at the top of the file,
# as its comment there always claimed. The selector's recommendation is kept
# separately and reported, not silently applied.
auto_selected_u <- auto_sel$u_selected
if (!isTRUE(all.equal(auto_selected_u, presentation_u))) {
  message(sprintf(paste0("Selector recommends u = %.2f; presentation stays at ",
                         "u = %.2f (declared at the top of this script). ",
                         "Every published table uses the presentation u."),
                  auto_selected_u, presentation_u))
}

# Re-run combined diagnostics and paper feed with the presentation u
combined_out <- run_combined_diagnostics(presentation_u, years)

print(dec, width = Inf)

# Orientation smoke test: many mentees should be in the best deciles
prop_top20 <- mean(fair_u$mentor_percentile <= 20, na.rm=TRUE)
if (prop_top20 < 0.20) warning("Unusually low Top-20% share; check percentile orientation.")

# =============================================================
# 9) Results summary tables for the paper results section
#    Addresses: per-year grade counts, preference fulfillment
#    rates, mean compatibility scores per tier, and duplicate
#    mentor slot counts (data balancing documentation).
# =============================================================

# Ensure fair_u reflects the final auto-selected presentation_u
fair_u <- load_fair_for_u(presentation_u, years)

# ---- 9a. Grade counts, selection rates, mean percentiles ----
build_results_tables <- function(fair_all, presentation_u, thr_pos_pct = 20,
                                 out_dir = "artifacts") {

  # Mentee count by year × individual grade stratum (one row per mentee, not doubled by method)
  grade_n_by_year <- fair_all %>%
    dplyr::filter(method == "Cosine Similarity") %>%
    dplyr::group_by(year, grade_stratum) %>%
    dplyr::summarise(n = dplyr::n(), .groups = "drop") %>%
    dplyr::arrange(year, grade_stratum)

  # Preference fulfillment: per-year selection rate by grade group × method
  sr_by_year_grp <- fair_all %>%
    dplyr::mutate(positive = as.integer(mentor_percentile <= thr_pos_pct)) %>%
    dplyr::group_by(year, grade_group, method) %>%
    dplyr::summarise(
      n                  = dplyr::n(),
      n_positive         = sum(positive),
      selection_rate_pct = round(n_positive / n * 100, 2),
      .groups = "drop"
    ) %>%
    dplyr::arrange(year, grade_group, method)

  # Mean compatibility score per tier: per-year × grade level × method
  mean_pct_tbl <- fair_all %>%
    dplyr::group_by(year, grade_stratum, method) %>%
    dplyr::summarise(
      n                 = dplyr::n(),
      mean_percentile   = round(mean(mentor_percentile, na.rm = TRUE), 2),
      median_percentile = round(median(mentor_percentile, na.rm = TRUE), 2),
      pct_top20         = round(mean(mentor_percentile <= thr_pos_pct, na.rm = TRUE) * 100, 1),
      .groups = "drop"
    ) %>%
    dplyr::arrange(year, grade_stratum, method)

  # Save CSVs
  readr::write_csv(grade_n_by_year, file.path(out_dir, "results_grade_counts_by_year.csv"))
  readr::write_csv(sr_by_year_grp,  file.path(out_dir, "results_selection_rates_by_year_grade.csv"))
  readr::write_csv(mean_pct_tbl,    file.path(out_dir, "results_mean_percentile_by_year_grade.csv"))

  # Build Word tables
  ft_n <- flextable::flextable(grade_n_by_year) %>%
    flextable::theme_booktabs() %>% flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(
      sprintf("Mentee Count by Year and Grade Level (u = %.2f)", presentation_u)) %>%
    flextable::add_footer_lines(
      "One row per mentee per year; grade_stratum is the individual grade from the survey.")

  ft_sr <- flextable::flextable(sr_by_year_grp) %>%
    flextable::theme_booktabs() %>% flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(
      sprintf("Preference Fulfillment Rates by Year, Grade Group, and Method (Top-%d%%; u = %.2f)",
              thr_pos_pct, presentation_u)) %>%
    flextable::add_footer_lines(c(
      sprintf("Positive outcome = mentor_percentile <= %d (mentor in top-%d%% predicted compatibility).",
              thr_pos_pct, thr_pos_pct),
      "selection_rate_pct = percentage of mentees receiving that positive outcome."
    ))

  ft_mp <- flextable::flextable(mean_pct_tbl) %>%
    flextable::theme_booktabs() %>% flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(
      sprintf("Mean Mentor Compatibility Percentile by Year, Grade Level, and Method (u = %.2f)",
              presentation_u)) %>%
    flextable::add_footer_lines(c(
      "mentor_percentile: rank-derived score where 0 = highest compatibility, 100 = lowest.",
      "pct_top20 = % of mentees matched with a mentor in the top-20% predicted compatibility.",
      "Lower mean_percentile and higher pct_top20 both indicate better matching outcomes."
    ))

  save_docx_std(
    `Grade Counts`             = ft_n,
    `Selection Rates`          = ft_sr,
    `Mean Percentile by Grade` = ft_mp,
    path = file.path(out_dir, "results_grade_detail.docx")
  )

  message(sprintf(
    "Results tables saved: grade counts (%d rows), selection rates (%d rows), mean percentiles (%d rows)",
    nrow(grade_n_by_year), nrow(sr_by_year_grp), nrow(mean_pct_tbl)
  ))
  invisible(list(
    grade_n_by_year = grade_n_by_year,
    sr_by_year_grp  = sr_by_year_grp,
    mean_pct_tbl    = mean_pct_tbl
  ))
}

# ---- 9b. Mentor balance: duplicate slots per year ----
build_mentor_balance_table <- function(presentation_u, years, out_dir = "artifacts") {
  u_tag <- gsub("\\.", "p", sprintf("%.3f", presentation_u))
  adir  <- file.path(out_dir, paste0("u_", u_tag))

  balance_rows <- purrr::map_dfr(years, function(yr) {
    f <- file.path(adir, sprintf("fair_df_cos_sim_%s.rds", yr))
    .check_artifact(f)
    df <- readRDS(f)

    n_mentees      <- nrow(df)

    ## `max_rank` is max(assigned rank), not the size of the mentor pool, so it
    ## understates the slot count whenever no mentee is matched to their worst
    ## candidate. Read the pool size recorded by the Rmd instead; fall back to the
    ## old expression only when that artifact is absent.
    pool_file <- file.path(out_dir, sprintf("matching_pool_%s.csv", yr))
    n_mentor_slots <- if (file.exists(pool_file)) {
      as.integer(readr::read_csv(pool_file, show_col_types = FALSE)$n_mentor_post_duplication[1])
    } else if ("max_rank" %in% names(df)) {
      as.integer(max(df$max_rank, na.rm = TRUE))
    } else NA_integer_

    mentor_counts <- df %>%
      dplyr::filter(!is.na(GaleShapley_Matched_Mentor_Name)) %>%
      dplyr::count(GaleShapley_Matched_Mentor_Name, name = "n_assigned")

    n_unique_mentors    <- nrow(mentor_counts)
    n_mentors_2_mentees <- sum(mentor_counts$n_assigned >= 2)
    n_duplicate_slots   <- if (!is.na(n_mentor_slots))
      as.integer(n_mentor_slots - n_unique_mentors) else NA_integer_

    tibble::tibble(
      year                      = yr,
      n_mentees                 = n_mentees,
      n_mentor_slots            = n_mentor_slots,
      n_unique_mentors_matched  = n_unique_mentors,
      n_mentors_with_2_mentees  = n_mentors_2_mentees
    )
  })

  readr::write_csv(balance_rows, file.path(out_dir, "results_mentor_balance.csv"))

  ft_bal <- flextable::flextable(balance_rows) %>%
    flextable::theme_booktabs() %>% flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(
      sprintf("Mentor:Mentee Balance by Year (u = %.2f)", presentation_u)) %>%
    flextable::add_footer_lines(c(
      "n_mentor_slots: total mentor entries given to Gale-Shapley, including virtual duplicate slots.",
      "n_mentors_with_2_mentees: mentors in the final matching who received two mentee assignments."
    ))

  save_docx_std(`Mentor Balance` = ft_bal,
                path = file.path(out_dir, "results_mentor_balance.docx"))

  message(sprintf("Mentor balance table saved (%d years).", nrow(balance_rows)))
  invisible(balance_rows)
}

# ---- Execute section 9 ----
results_tbls   <- build_results_tables(fair_u, presentation_u, thr_pos_pct)
mentor_balance <- build_mentor_balance_table(presentation_u, years)

# ---- TOST for method equivalence: Cosine Similarity vs Matching Words ----
# Implements the two one-sided tests (TOST) from Lo, Datta & Salami (2025),
# AI and Ethics 5:2149-2164, applied to the difference in Top-p% selection
# rates between the two scoring methods (Statistical Parity framework).
# Equivalence is concluded when the (1-2*alpha)*100% CI lies within [-delta, delta].
# Legacy independent-samples Wald TOST. VERIFICATION ONLY as of 2026-08-08: both
# methods score the SAME mentees, so the arms are correlated and this SE is wrong
# for the design. Retained so the paired result can be compared against the
# construction Lo et al. (2025) published. Not used for any reported interval.
tost_sp_equiv_wald <- function(x1, n1, x2, n2, delta = 0.05, alpha = 0.05) {
  # x1/n1 = successes/total for Method 1 (Cosine Similarity)
  # x2/n2 = successes/total for Method 2 (Matching Words)
  # delta  = equivalence margin (theta in Lo et al.)
  # Reference: Lo et al. (2025), Eq (5)-(6)
  p1  <- x1 / n1
  p2  <- x2 / n2
  diff <- p1 - p2
  se   <- sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
  z1a  <- stats::qnorm(1 - alpha)
  # Two one-sided test statistics following Lo et al. (2025)
  Z1 <- (diff + delta) / se   # H01: diff <= -delta  =>  reject when Z1 >= z_{1-alpha}
  Z2 <- (diff - delta) / se   # H02: diff >= +delta  =>  reject when Z2 <= -z_{1-alpha}
  pass  <- (Z1 >= z1a) && (Z2 <= -z1a)
  p_val <- max(1 - stats::pnorm(Z1), stats::pnorm(Z2))
  ci_L  <- diff - z1a * se   # (1-2*alpha)*100% CI
  ci_U  <- diff + z1a * se
  list(
    p1 = p1, p2 = p2, diff = diff, se = se,
    Z1 = Z1, Z2 = Z2,
    ci_L = ci_L, ci_U = ci_U,
    p_value = p_val, pass = pass,
    delta = delta, alpha = alpha,
    ci_level_pct = (1 - 2 * alpha) * 100
  )
}

# ---- Paired construction (Tango 1998 score interval) ----
# Both methods score the same mentees, so the two arms are correlated and the
# independent-samples SE above overstates the interval width. The paired score
# interval of Tango (1998), as implemented in PropCIs::scoreci.mp, is the
# construction the design calls for.
#
# ORIENTATION TRAP -- read before changing the argument order.
# scoreci.mp(x, y, n) estimates (y - x)/n. This repo reports Cosine - Matching
# Words throughout (column Delta_rate_cos_minus_mw, and the README headline), so
# with b = Cosine-only and c = MW-only discordant counts, the call must be
# scoreci.mp(c, b, n) to yield (b - c)/n = Rate(Cosine) - Rate(MW).
# NOTE: Paper 1 uses the OPPOSITE orientation (MW - Cosine) and therefore calls
# scoreci.mp(b, c, n). Do not copy its argument order into this file.
tango_ci_cs_minus_mw <- function(b, c, n, conf = 0.90) {
  ci <- PropCIs::scoreci.mp(c, b, n, conf.level = conf)
  c(lower = ci$conf.int[1], upper = ci$conf.int[2])
}

# TOST p-value by CI inversion: the smallest alpha at which the (1 - 2*alpha)
# Tango interval still fits inside [-delta, +delta]. Stays entirely inside
# scoreci.mp, so there is no hand-derived formula to verify against Tango (1998).
tost_p_tango <- function(b, c, n, delta) {
  inside <- function(conf) {
    ci <- tango_ci_cs_minus_mw(b, c, n, conf)
    ci[["lower"]] > -delta && ci[["upper"]] < delta
  }
  if (!inside(1e-6))  return(1)
  if (inside(0.9999)) return(.Machine$double.eps)
  lo <- 1e-6; hi <- 0.9999
  for (i in 1:60) {
    mid <- (lo + hi) / 2
    if (inside(mid)) lo <- mid else hi <- mid
  }
  (1 - lo) / 2
}

tost_paired_tango <- function(b, c, n, x11, delta = 0.05, alpha = 0.05) {
  p1   <- (x11 + b) / n            # Rate(Cosine Similarity)
  p2   <- (x11 + c) / n            # Rate(Matching Words)
  diff <- (b - c) / n              # Cosine - MW; same orientation as the CI
  ci   <- tango_ci_cs_minus_mw(b, c, n, conf = 1 - 2 * alpha)
  list(p1 = p1, p2 = p2, diff = diff,
       ci_L = ci[["lower"]], ci_U = ci[["upper"]],
       p_value = tost_p_tango(b, c, n, delta),
       pass = (ci[["lower"]] > -delta) && (ci[["upper"]] < delta),
       delta = delta, alpha = alpha,
       ci_level_pct = (1 - 2 * alpha) * 100)
}

build_method_tost_table <- function(fair_u, thr_pos_pct = 20,
                                     delta_primary = 0.05,
                                     delta_strict  = 0.02,
                                     alpha = 0.05,
                                     pair_id_col = "Mentee_corp_id") {
  # Per-year plus overall PAIRED TOST for top-p% selection rate parity.
  # Positive outcome = mentor_percentile <= thr_pos_pct.
  if (!pair_id_col %in% names(fair_u))
    stop(sprintf(paste0("Paired TOST needs a mentee identifier shared by both ",
                        "methods; '%s' not found. Columns: %s"),
                 pair_id_col, paste(names(fair_u), collapse = ", ")))
  fair2 <- fair_u %>%
    dplyr::mutate(
      positive = as.integer(mentor_percentile <= thr_pos_pct),
      # Mentee ids are only unique WITHIN a year -- the same CID recurs across
      # cohorts -- so the pairing key must carry the year.
      .pair_key = paste(.data$year, .data[[pair_id_col]])
    )
  years_all <- c(as.character(sort(unique(fair2$year))), "Overall")
  purrr::map_dfr(years_all, function(yr) {
    sub <- if (yr == "Overall") fair2 else
             fair2 %>% dplyr::filter(year == suppressWarnings(as.integer(yr)))
    cos <- sub %>% dplyr::filter(method == "Cosine Similarity")
    mw  <- sub %>% dplyr::filter(method == "Matching Words")
    dup <- sum(duplicated(cos$.pair_key)) + sum(duplicated(mw$.pair_key))
    if (dup > 0)
      stop(sprintf(paste0("Pairing key '%s' is not unique within year x method ",
                          "(%d duplicates at %s). Fix the key before running ",
                          "the paired TOST."), pair_id_col, dup, yr))
    j <- dplyr::inner_join(
      cos %>% dplyr::select(.pair_key, pos_cos = positive),
      mw  %>% dplyr::select(.pair_key, pos_mw  = positive),
      by = ".pair_key")
    dropped <- (nrow(cos) - nrow(j)) + (nrow(mw) - nrow(j))
    if (dropped > 0)
      message(sprintf(paste0("Paired TOST (%s): %d method-rows lacked a partner ",
                             "and were dropped from pairing."), yr, dropped))
    b   <- sum(j$pos_cos == 1L & j$pos_mw == 0L)   # Cosine-only
    cc  <- sum(j$pos_cos == 0L & j$pos_mw == 1L)   # MW-only
    x11 <- sum(j$pos_cos == 1L & j$pos_mw == 1L)
    n   <- nrow(j)
    r1 <- tost_paired_tango(b, cc, n, x11, delta = delta_primary, alpha = alpha)
    r2 <- tost_paired_tango(b, cc, n, x11, delta = delta_strict,  alpha = alpha)
    tibble::tibble(
      Year                        = yr,
      n_Cosine                    = n,
      Rate_Cosine                 = round(r1$p1, 4),
      n_MW                        = n,
      Rate_MW                     = round(r1$p2, 4),
      Delta_rate_cos_minus_mw     = round(r1$diff, 4),
      CI_L_90pct                  = round(r1$ci_L, 4),
      CI_U_90pct                  = round(r1$ci_U, 4),
      p_value                     = round(r1$p_value, 4),
      Equiv_primary_delta5pp      = ifelse(r1$pass, "Pass", "Fail"),
      Equiv_strict_delta2pp       = ifelse(r2$pass, "Pass", "Fail"),
      n_discordant_cos_only       = b,
      n_discordant_mw_only        = cc
    )
  })
}

build_manuscript_metrics_doc <- function(
    fair_u,
    results_tbls,
    mentor_balance,
    combined_out,
    presentation_u,
    thr_pos_pct = 20,
    out_dir = "artifacts") {
  grade_counts <- results_tbls$grade_n_by_year

  grade_split <- grade_counts %>%
    dplyr::mutate(is_g14 = stringr::str_detect(grade_stratum, "^Grade [1-4]$")) %>%
    dplyr::mutate(year = as.character(year)) %>%
    dplyr::group_by(year) %>%
    dplyr::summarise(
      n_grades_1_4 = sum(n[is_g14]),
      n_grades_5_plus = sum(n[!is_g14]),
      n_total = sum(n),
      pct_grades_1_4 = round(100 * n_grades_1_4 / n_total, 1),
      pct_grades_5_plus = round(100 * n_grades_5_plus / n_total, 1),
      .groups = "drop"
    ) %>%
    dplyr::bind_rows(
      grade_counts %>%
        dplyr::mutate(is_g14 = stringr::str_detect(grade_stratum, "^Grade [1-4]$")) %>%
        dplyr::summarise(
          year = "Overall",
          n_grades_1_4 = sum(n[is_g14]),
          n_grades_5_plus = sum(n[!is_g14]),
          n_total = sum(n),
          pct_grades_1_4 = round(100 * n_grades_1_4 / n_total, 1),
          pct_grades_5_plus = round(100 * n_grades_5_plus / n_total, 1),
          .groups = "drop"
        )
    )

  cohort_tbl <- mentor_balance %>%
    dplyr::mutate(
      n_total = n_mentees + n_unique_mentors_matched,
      mentor_capacity_proxy = n_mentor_slots - n_unique_mentors_matched
    ) %>%
    dplyr::select(
      year,
      n_mentees,
      n_mentor_slots,
      n_unique_mentors_matched,
      mentor_capacity_proxy,
      n_mentors_with_2_mentees,
      n_total
    )

  compat_tbl <- fair_u %>%
    dplyr::group_by(method) %>%
    dplyr::summarise(
      n = dplyr::n(),
      mean_percentile = round(mean(mentor_percentile, na.rm = TRUE), 2),
      median_percentile = round(stats::median(mentor_percentile, na.rm = TRUE), 2),
      top20_rate_pct = round(100 * mean(mentor_percentile <= thr_pos_pct, na.rm = TRUE), 1),
      .groups = "drop"
    )

  # --- Formal TOST equivalence for Cosine Similarity vs Matching Words ---
  tost_tbl <- build_method_tost_table(fair_u, thr_pos_pct = thr_pos_pct)
  tost_overall <- tost_tbl %>% dplyr::filter(Year == "Overall")
  tost_status_str <- sprintf(
    "%s (delta = 5pp; 90%% CI [%+.3f, %+.3f] vs acceptance [%.2f, %.2f]); strict 2pp: %s",
    tost_overall$Equiv_primary_delta5pp,
    tost_overall$CI_L_90pct,
    tost_overall$CI_U_90pct,
    -0.05, 0.05,
    tost_overall$Equiv_strict_delta2pp
  )

  method_diag_tbl <- tibble::tibble(
    metric = c(
      "Brown-Forsythe F",
      "Brown-Forsythe p",
      "KS D (Cosine greater)",
      "KS p (Cosine greater)",
      "KS D (Matching Words less)",
      "KS p (Matching Words less)",
      "Bootstrap sup gap",
      "Bootstrap sup CI L",
      "Bootstrap sup CI U",
      "Bootstrap inf gap",
      "Bootstrap inf CI L",
      "Bootstrap inf CI U",
      "Cosine dominance prob",
      "Matching Words dominance prob",
      "Equivalence status"
    ),
    value = c(
      round(as.numeric(combined_out$brown_forsythe_overall$F), 4),
      signif(as.numeric(combined_out$brown_forsythe_overall$p), 4),
      round(as.numeric(combined_out$ks_one_sided_diag$D_cos_greater), 4),
      signif(as.numeric(combined_out$ks_one_sided_diag$p_cos_greater), 4),
      round(as.numeric(combined_out$ks_one_sided_diag$D_mw_less), 4),
      signif(as.numeric(combined_out$ks_one_sided_diag$p_mw_less), 4),
      round(as.numeric(combined_out$fosd_bootstrap$obs_sup), 4),
      round(as.numeric(combined_out$fosd_bootstrap$sup_CI[1]), 4),
      round(as.numeric(combined_out$fosd_bootstrap$sup_CI[2]), 4),
      round(as.numeric(combined_out$fosd_bootstrap$obs_inf), 4),
      round(as.numeric(combined_out$fosd_bootstrap$inf_CI[1]), 4),
      round(as.numeric(combined_out$fosd_bootstrap$inf_CI[2]), 4),
      round(100 * as.numeric(combined_out$fosd_bootstrap$cos_dominance_prob), 2),
      round(100 * as.numeric(combined_out$fosd_bootstrap$mw_dominance_prob), 2),
      tost_status_str
    )
  )

  scoring_tbl <- tibble::tibble(
    item = c(
      "Final compatibility score used to choose u",
      "Predicted compatibility percentile",
      "Positive match threshold",
      "Capacity proxy used in balance table"
    ),
    logic = c(
      "total_score = abs(1 - DI) + abs(mean_gap) + 0.5 * abs(SMD) + 0.1 * abs(DI_U - DI_L)",
      "mentor_percentile = 100 * ((GS_mentee_rank_of_mentor - 1) / (max_rank - 1)); 0 = best",
      sprintf("mentor_percentile <= %d (Top-%d%%)", thr_pos_pct, thr_pos_pct),
      "n_mentor_slots = max(max_rank) in the matched frame; duplicate-slot proxy = n_mentor_slots - n_unique_mentors_matched"
    )
  )

  ft1 <- flextable::flextable(cohort_tbl) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(values = sprintf("Cohort Size and Mentor Balance by Year (u = %.2f)", presentation_u))

  ft2 <- flextable::flextable(grade_split) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(values = "Grade Representation Across the Three Program Years")

  ft3 <- flextable::flextable(compat_tbl) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(values = sprintf("Compatibility Summary for Final Matches (u = %.2f)", presentation_u)) %>%
    flextable::add_footer_lines(values = c(
      sprintf("Top-%d%% success is defined as mentor_percentile <= %d.", thr_pos_pct, thr_pos_pct),
      "Lower percentile values indicate better predicted compatibility."
    ))

  ft4 <- flextable::flextable(method_diag_tbl) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(values = "Method Comparison Diagnostics: Cosine Similarity vs Matching Words") %>%
    flextable::add_footer_lines(values = c(
      "The saved diagnostics are one-sided KS and bootstrap FOSD summaries; they do not establish formal equivalence by themselves.",
      "If equivalence is required in the manuscript, the 90% CI containment gate in the u-sweep tables is the intended criterion."
    ))

  ft5 <- flextable::flextable(scoring_tbl) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::add_header_lines(values = "Algorithmic Parameters and Score Logic")

  ft6 <- flextable::flextable(tost_tbl) %>%
    flextable::theme_booktabs() %>%
    flextable::autofit() %>%
    flextable::bold(part = "header") %>%
    flextable::align(align = "center", part = "all") %>%
    flextable::set_header_labels(
      Year                    = "Year",
      n_Cosine                = "n (Cosine)",
      Rate_Cosine             = "Rate (Cosine)",
      n_MW                    = "n (MW)",
      Rate_MW                 = "Rate (MW)",
      Delta_rate_cos_minus_mw = "\u0394 Rate (Cos\u2212MW)",
      CI_L_90pct              = "90% CI L",
      CI_U_90pct              = "90% CI U",
      p_value                 = "p-value",
      Equiv_primary_delta5pp  = "Equiv \u00b15pp",
      Equiv_strict_delta2pp   = "Equiv \u00b12pp"
    ) %>%
    flextable::color(
      i = ~ Equiv_primary_delta5pp == "Pass", j = "Equiv_primary_delta5pp",
      color = "#006600", part = "body"
    ) %>%
    flextable::color(
      i = ~ Equiv_primary_delta5pp == "Fail", j = "Equiv_primary_delta5pp",
      color = "#CC0000", part = "body"
    ) %>%
    flextable::color(
      i = ~ Equiv_strict_delta2pp == "Pass", j = "Equiv_strict_delta2pp",
      color = "#006600", part = "body"
    ) %>%
    flextable::color(
      i = ~ Equiv_strict_delta2pp == "Fail", j = "Equiv_strict_delta2pp",
      color = "#CC0000", part = "body"
    ) %>%
    flextable::add_header_lines(
      values = sprintf(
        "Formal TOST Equivalence: Cosine Similarity vs Matching Words (Top-%d%%; u = %.2f)",
        thr_pos_pct, presentation_u
      )
    ) %>%
    flextable::add_footer_lines(values = c(
      "TOST follows Lo, Datta & Salami (2025), AI and Ethics 5:2149-2164, Section 3.2 (Statistical Parity framework).",
      "Positive outcome: mentor_percentile <= Top-p% threshold. Rate = proportion of mentees receiving a top-p% match.",
      "Delta Rate = Rate(Cosine) - Rate(Matching Words). Equivalence margin: primary +/-5pp, strict +/-2pp.",
      "90% CI = (1 - 2*alpha)*100% confidence interval at alpha = 0.05; equivalence is concluded when the entire CI lies within the acceptance band.",
      "p-value = max(1 - Phi(Z1), Phi(Z2)) per Lo et al.; values below alpha = 0.05 support equivalence."
    ))

  save_docx_std(
    "Cohort and balance" = ft1,
    "Grade representation" = ft2,
    "Compatibility summary" = ft3,
    "Method diagnostics" = ft4,
    "Score logic" = ft5,
    "Method TOST equivalence" = ft6,
    path = file.path(out_dir, "manuscript_metrics_summary.docx")
  )

  invisible(list(
    cohort_tbl = cohort_tbl,
    grade_split = grade_split,
    compat_tbl = compat_tbl,
    method_diag_tbl = method_diag_tbl,
    scoring_tbl = scoring_tbl,
    tost_tbl = tost_tbl
  ))
}

manuscript_metrics <- build_manuscript_metrics_doc(
  fair_u = fair_u,
  results_tbls = results_tbls,
  mentor_balance = mentor_balance,
  combined_out = combined_out,
  presentation_u = presentation_u,
  thr_pos_pct = thr_pos_pct,
  out_dir = "artifacts"
)

# Refresh paper feed after the section 9 artifacts exist so Word sees the new tables.
if (exists("build_paper_feed")) {
  build_paper_feed(years, u_grid, presentation_u, out_dir = "artifacts")
}

# =============================================================
# 10a) Response-exclusion gate summary (all years combined)
# Reads per-year CSVs written by the Rmd artifacts chunk.
# =============================================================
exclusion_csvs <- file.path(
  "artifacts",
  sprintf("exclusion_summary_%d.csv", years)
)
exclusion_all_years <- purrr::map_dfr(
  exclusion_csvs,
  ~ if (file.exists(.x)) readr::read_csv(.x, show_col_types = FALSE) else NULL
) %>%
  dplyr::arrange(year, role)

if (nrow(exclusion_all_years) > 0) {
  readr::write_csv(
    exclusion_all_years,
    file.path("artifacts", "exclusion_summary_all_years.csv")
  )
  cat("\n================================================================\n")
  cat("Response exclusion gate — all years\n")
  cat("Gate: identity + role + role-specific required questions\n")
  cat("(anything-to-add / special-considerations fields are optional)\n")
  cat("----------------------------------------------------------------\n")
  print(as.data.frame(exclusion_all_years), row.names = FALSE)
  cat("================================================================\n\n")
} else {
  message("No exclusion_summary_YYYY.csv files found in artifacts/ — re-run with rendering enabled to generate them.")
}

# =============================================================
# 10) Speed-session headline stats
#     Reproduces the metrics highlighted in the presentation pack
#     (scale, top-20% mentor share, DI, |SMD|, method equivalence)
#     with per-year and Overall breakdowns plus the fraction of
#     mentees paired with their #1 (most preferred) mentor.
# =============================================================
build_speed_session_summary <- function(fair_u,
                                        u_sweep,
                                        presentation_u,
                                        thr_pos_pct = 20,
                                        out_dir = "artifacts") {

  # One row per mentee: pick a canonical method for cohort/#1 counts.
  # #1 mentor pairing is defined by GS_mentee_rank_of_mentor == 1 and
  # is method-specific (the ranking uses each method's compatibility).
  headline_rows <- fair_u %>%
    dplyr::mutate(
      year = as.character(year),
      is_top20 = as.integer(mentor_percentile <= thr_pos_pct),
      is_rank1 = as.integer(GS_mentee_rank_of_mentor == 1)
    ) %>%
    dplyr::group_by(year, method) %>%
    dplyr::summarise(
      n_mentees        = dplyr::n(),
      pct_top20        = round(100 * mean(is_top20, na.rm = TRUE), 1),
      pct_rank1_mentor = round(100 * mean(is_rank1, na.rm = TRUE), 1),
      mean_percentile  = round(mean(mentor_percentile, na.rm = TRUE), 2),
      .groups = "drop"
    )

  overall_rows <- fair_u %>%
    dplyr::mutate(
      is_top20 = as.integer(mentor_percentile <= thr_pos_pct),
      is_rank1 = as.integer(GS_mentee_rank_of_mentor == 1)
    ) %>%
    dplyr::group_by(method) %>%
    dplyr::summarise(
      year             = "Overall",
      n_mentees        = dplyr::n(),
      pct_top20        = round(100 * mean(is_top20, na.rm = TRUE), 1),
      pct_rank1_mentor = round(100 * mean(is_rank1, na.rm = TRUE), 1),
      mean_percentile  = round(mean(mentor_percentile, na.rm = TRUE), 2),
      .groups = "drop"
    ) %>%
    dplyr::select(year, method, n_mentees, pct_top20, pct_rank1_mentor, mean_percentile)

  headline_tbl <- dplyr::bind_rows(headline_rows, overall_rows) %>%
    dplyr::arrange(year, method)

  # Fairness diagnostics at the presented u
  fair_row <- u_sweep %>% dplyr::filter(abs(u - presentation_u) < 1e-8)
  if (nrow(fair_row) == 0) {
    fair_row <- u_sweep %>% dplyr::slice_min(abs(u - presentation_u), n = 1)
  }
  di_val   <- if (nrow(fair_row) == 1) fair_row$DI       else NA_real_
  smd_val  <- if (nrow(fair_row) == 1) fair_row$SMD      else NA_real_
  gap_val  <- if (nrow(fair_row) == 1) fair_row$mean_gap else NA_real_

  # Method TOST at the presented u (Cosine vs Matching Words)
  tost_tbl <- build_method_tost_table(fair_u, thr_pos_pct = thr_pos_pct)

  # Persist for downstream review
  readr::write_csv(headline_tbl,
                   file.path(out_dir, "speed_session_headline_stats.csv"))
  readr::write_csv(tost_tbl,
                   file.path(out_dir, "speed_session_method_tost.csv"))

  # Print to console at the end of the run
  cat("\n\n============================================================\n")
  cat("Speed-Session Headline Stats (synthetic run; u = ",
      sprintf("%.2f", presentation_u), ")\n", sep = "")
  cat("Metrics: mentee count, % with a Top-", thr_pos_pct,
      "% mentor, % paired with their #1 mentor.\n", sep = "")
  cat("(#1 mentor = GS_mentee_rank_of_mentor == 1; each method scored separately.)\n")
  cat("------------------------------------------------------------\n")
  print(as.data.frame(headline_tbl), row.names = FALSE)

  cat("\nFairness diagnostics at presented u = ",
      sprintf("%.2f", presentation_u), ":\n", sep = "")
  cat(sprintf("  Disparate Impact (Grades 1-4 vs 5+)   : %s\n",
              if (is.na(di_val))  "NA" else sprintf("%.3f", di_val)))
  cat(sprintf("  |SMD| on mentor_percentile            : %s\n",
              if (is.na(smd_val)) "NA" else sprintf("%.3f", abs(smd_val))))
  cat(sprintf("  Mean percentile gap (High minus Low)  : %s pp\n",
              if (is.na(gap_val)) "NA" else sprintf("%.2f", gap_val)))

  cat("\nMethod equivalence (Cosine Similarity vs Matching Words)\n")
  cat("Top-", thr_pos_pct,
      "% selection-rate TOST per year and Overall (delta = 5pp / 2pp):\n",
      sep = "")
  print(as.data.frame(tost_tbl), row.names = FALSE)
  cat("============================================================\n\n")

  invisible(list(headline_tbl = headline_tbl, tost_tbl = tost_tbl))
}

speed_session_summary <- build_speed_session_summary(
  fair_u          = fair_u,
  u_sweep         = u_sweep,
  presentation_u  = presentation_u,
  thr_pos_pct     = thr_pos_pct,
  out_dir         = "artifacts"
)

