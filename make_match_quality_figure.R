#!/usr/bin/env Rscript
## make_match_quality_figure.R -- the README's headline figure.
##
## Two estimands, three synthetic populations, two matching methods, each with an
## exact binomial interval, against the random-feasible-matching benchmark. A dot and
## interval plot rather than bars: the quantity of interest is an estimate with
## uncertainty, not a magnitude to be compared by area.
##
## Usage:
##   Rscript make_match_quality_figure.R
##   Rscript make_match_quality_figure.R --artifacts artifacts \
##           --out artifacts/Figure_Match_Quality.png

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(tidyr); library(ggplot2)
})

parse_args <- function(args) {
  get <- function(flag, default) {
    i <- which(args == flag)
    if (length(i) == 0) return(default)
    if (i + 1 > length(args)) stop(sprintf("%s needs a value.", flag))
    args[i + 1]
  }
  list(artifacts = get("--artifacts", "artifacts"),
       out       = get("--out", "artifacts/Figure_Match_Quality.png"))
}
opt <- parse_args(commandArgs(trailingOnly = TRUE))

hl_path <- file.path(opt$artifacts, "match_quality_headline.csv")
bm_path <- file.path(opt$artifacts, "match_quality_benchmark.csv")
for (p in c(hl_path, bm_path)) {
  if (!file.exists(p)) {
    stop(sprintf("Missing %s.\nRun analyze_match_quality.R first.", p))
  }
}

hl <- read_csv(hl_path, show_col_types = FALSE)
bm <- read_csv(bm_path, show_col_types = FALSE)

## Colours validated by tools/check_palette.R against this surface.
SURFACE   <- "#f2f1ec"
INK       <- "#0b0b0b"
INK_2     <- "#52514e"
MUTED     <- "#898781"
GRID      <- "#e1e0d9"
BORDER    <- "#c3c2b7"
SERIES    <- c("Cosine Similarity" = "#2a78d6", "Matching Words" = "#d95926")

## Kept short so the strip text is never clipped at README width; the full estimand
## definitions are in the README table this figure sits under.
panel_levels <- c("Assigned mentor in top 20%",
                  "Assigned mentor is number one")

est <- bind_rows(
  hl %>% transmute(year, method, panel = panel_levels[1],
                   value = pct_top20_pool, lo = top20_pool_lo, hi = top20_pool_hi),
  hl %>% transmute(year, method, panel = panel_levels[2],
                   value = pct_rank1, lo = rank1_lo, hi = rank1_hi)
) %>%
  mutate(
    panel = factor(panel, levels = panel_levels),
    year  = factor(year, levels = c("2023", "2024", "2025", "Pooled"))
  )

bench <- bind_rows(
  bm %>% transmute(year, panel = panel_levels[1], value = bench_top20_mean),
  bm %>% transmute(year, panel = panel_levels[2], value = bench_rank1_mean)
) %>%
  mutate(panel = factor(panel, levels = panel_levels),
         year  = factor(year, levels = c("2023", "2024", "2025", "Pooled")))

## Caption counts are read from the artifacts rather than typed in. A hardcoded
## caption silently goes stale the moment the pipeline is re-run on different
## inputs, and the figure is the one place a stale number is invisible to grep.
yr_rows <- hl %>%
  filter(year != "Pooled") %>%
  distinct(year, n_mentees, n_mentor_pool) %>%
  arrange(year)
pooled_n <- hl %>% filter(year == "Pooled") %>% pull(n_mentees) %>% unique()

caption_counts <- sprintf(
  "Mentees: %s; %s pooled. Eligible mentor pool: %s.",
  paste(sprintf("%d (%s)", yr_rows$n_mentees, yr_rows$year), collapse = "; "),
  format(pooled_n[1], big.mark = ","),
  paste(yr_rows$n_mentor_pool, collapse = ", ")
)

dodge <- position_dodge(width = 0.55)

p <- ggplot(est, aes(x = year, y = value, colour = method)) +
  geom_point(data = bench, aes(x = year, y = value),
             inherit.aes = FALSE, shape = 124, size = 6, colour = MUTED) +
  geom_linerange(aes(ymin = lo, ymax = hi), position = dodge, linewidth = 2) +
  geom_point(position = dodge, size = 3.4) +
  facet_wrap(~ panel, ncol = 2, scales = "free_y") +
  scale_colour_manual(values = SERIES, name = NULL) +
  scale_y_continuous(labels = function(x) paste0(x, "%"), expand = expansion(mult = 0.12)) +
  labs(
    title = "Match quality against a random feasible matching, synthetic data",
    subtitle = paste0("Points are estimates with exact 95% binomial intervals. ",
                      "Grey ticks mark the random-matching benchmark.\n",
                      "u = 1.5; denominator is each mentee's post-duplication eligible mentor pool."),
    x = NULL, y = NULL,
    caption = paste0(
      caption_counts, "\n",
      "Benchmark: 2,000 simulated random feasible matchings per year, seed 42. Synthetic data only."
    )
  ) +
  theme_minimal(base_size = 14, base_family = "sans") +
  theme(
    plot.background  = element_rect(fill = SURFACE, colour = BORDER, linewidth = 0.8),
    panel.background = element_rect(fill = SURFACE, colour = NA),
    panel.grid.major.y = element_line(colour = GRID, linewidth = 0.4),
    panel.grid.major.x = element_blank(),
    panel.grid.minor = element_blank(),
    panel.spacing = unit(1.4, "lines"),
    strip.text = element_text(colour = INK, face = "bold", size = 12.5,
                              hjust = 0, margin = margin(b = 6)),
    axis.text = element_text(colour = INK_2, size = 12),
    plot.title = element_text(colour = INK, face = "bold", size = 16,
                              margin = margin(b = 4)),
    plot.subtitle = element_text(colour = INK_2, size = 11.5, lineheight = 1.3,
                                 margin = margin(b = 12)),
    plot.caption = element_text(colour = INK_2, size = 10.5, hjust = 0,
                                lineheight = 1.3, margin = margin(t = 12)),
    plot.caption.position = "plot",
    plot.title.position = "plot",
    legend.position = "top",
    legend.justification = "left",
    legend.text = element_text(colour = INK_2, size = 12),
    plot.margin = margin(14, 18, 12, 16)
  )

dir.create(dirname(opt$out), recursive = TRUE, showWarnings = FALSE)
ggsave(opt$out, plot = p, width = 8.9, height = 5.2, dpi = 200, units = "in", bg = SURFACE)
cat(sprintf("Wrote %s\n", opt$out))
