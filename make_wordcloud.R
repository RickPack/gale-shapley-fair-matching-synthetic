#!/usr/bin/env Rscript
## make_wordcloud.R -- provenance figure for the synthetic free-text fields.
##
## The survey free-text answers in data/survey_synthetic_*.csv are not paraphrases of
## real answers. build_synthetic_inputs.R replaces every word with a draw from a
## generated vocabulary of compound stems ("studypath", "learnview", ...) through a
## seeded, frequency-ordered map, and that map is discarded at the end of the build.
## The figure exists to make that visible: the vocabulary on screen is manufactured,
## and no substitution can be run backwards to recover an original response.
##
## Token frequencies are counted as they appear. No stopword list, no stemming, no
## minimum-length filter -- filtering would hide exactly the behaviour the figure is
## meant to show, which is that the synthetic vocabulary has its own frequency
## structure inherited from the rank order of the original tokens.
##
## Usage:
##   Rscript make_wordcloud.R
##   Rscript make_wordcloud.R --inputs "data/survey_synthetic_2023.csv,data/survey_synthetic_2024.csv" \
##                            --out artifacts/Figure_WordCloud_Synthetic_Vocab.png \
##                            --seed 726 --max-words 130

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(ggplot2)
  library(ggwordcloud)
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
    inputs    = get("--inputs", paste(sprintf("data/survey_synthetic_%d.csv", 2023:2025),
                                      collapse = ",")),
    out       = get("--out", "artifacts/Figure_WordCloud_Synthetic_Vocab.png"),
    seed      = as.integer(get("--seed", "726")),
    max_words = as.integer(get("--max-words", "60")),
    min_pt    = as.numeric(get("--min-pt", "10")),
    max_pt    = as.numeric(get("--max-pt", "46"))
  )
}

opt <- parse_args(commandArgs(trailingOnly = TRUE))
input_files <- trimws(strsplit(opt$inputs, ",")[[1]])
input_files <- input_files[nzchar(input_files)]

if (length(input_files) == 0) stop("No input files given. Use --inputs a.csv,b.csv")
missing <- input_files[!file.exists(input_files)]
if (length(missing) > 0) {
  stop(sprintf(paste0("Missing synthetic input file(s): %s\n",
                      "This figure may only be built from approved synthetic CSVs in data/. ",
                      "Run run_all_synthetic.r (or build_synthetic_inputs.R with GS_SOURCE_ROOT set) first."),
               paste(missing, collapse = ", ")))
}

## ---- provenance gate -----------------------------------------------------------

## Refuse to draw anything from a file that does not look like the de-identified
## output of build_synthetic_inputs.R. A word cloud is the one figure here that puts
## raw response text on screen, so it checks its input rather than trusting the path.
assert_synthetic <- function(df, path) {
  if (!"display_name" %in% names(df)) {
    stop(sprintf("%s has no display_name column; cannot confirm it is synthetic.", path))
  }
  nm <- df$display_name[!is.na(df$display_name)]
  bad <- nm[!str_detect(nm, "^PERSON_[0-9]{4}$")]
  if (length(bad) > 0) {
    stop(sprintf(paste0("%s contains %d display_name value(s) that are not synthetic ",
                        "PERSON_#### labels. Refusing to build a figure from it."),
                 path, length(bad)))
  }
  if ("corp_id" %in% names(df)) {
    cid <- df$corp_id[!is.na(df$corp_id)]
    bad_cid <- cid[!str_detect(cid, "^CID[0-9]{4}$")]
    if (length(bad_cid) > 0) {
      stop(sprintf("%s contains %d non-synthetic corp_id value(s).", path, length(bad_cid)))
    }
  }
  invisible(TRUE)
}

## The genuinely free-text questions: the two "in your own words" narratives and the
## two special-considerations boxes. The "choose your top 3" items are pick-lists.
FREE_TEXT_PATTERN <- "^please_tell_us_in_your_own_words|^are_there_any_special_considerations"

text_values <- character(0)
for (f in input_files) {
  df <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE))
  assert_synthetic(df, f)
  cols <- names(df)[str_detect(names(df), FREE_TEXT_PATTERN)]
  if (length(cols) == 0) {
    stop(sprintf("%s has no free-text columns matching the expected question names.", f))
  }
  text_values <- c(text_values, unlist(df[, cols], use.names = FALSE))
}

text_values <- text_values[!is.na(text_values) & nzchar(trimws(text_values))]
if (length(text_values) == 0) stop("No free-text content found in the supplied inputs.")

## Digits are part of a token: the generated vocabulary overflows into term0001,
## term0002, ... once the 900 stem compounds are exhausted. A letters-only pattern
## would collapse that entire tail into a single word called "term".
tokens <- tolower(unlist(str_extract_all(text_values, "[A-Za-z][A-Za-z0-9']*")))
tokens <- tokens[nzchar(tokens)]
if (length(tokens) == 0) stop("No word tokens found in the free-text fields.")

freq <- as.data.frame(table(tokens), stringsAsFactors = FALSE)
names(freq) <- c("word", "n")
freq <- freq[order(-freq$n, freq$word), ]
n_distinct_tokens <- nrow(freq)
n_tokens_total <- length(tokens)

## The full frequency table is written out so that limiting how many words are drawn
## never amounts to hiding the vocabulary's behaviour: everything counted is on disk,
## and the figure shows the head of the same distribution.
dir.create(dirname(opt$out), recursive = TRUE, showWarnings = FALSE)
freq_path <- file.path(dirname(opt$out), "wordcloud_token_frequencies.csv")
write_csv(freq, freq_path)

## Words are drawn with area proportional to frequency, so size = max_pt * sqrt(n/n_max).
## Cut the tail at the frequency where that formula falls below min_pt rather than at a
## round word count, so no word in the figure is too small to read at README width.
n_max <- max(freq$n)
n_floor <- n_max * (opt$min_pt / opt$max_pt)^2
top <- freq[freq$n >= n_floor, ]
if (nrow(top) > opt$max_words) top <- head(top, opt$max_words)
if (nrow(top) < 2) stop("Fewer than two words clear the legibility floor; check --min-pt/--max-pt.")

## ---- colour ---------------------------------------------------------------------

## Single-hue sequential ramp, darkest for the most frequent token. Every step clears
## 3:1 against the figure surface, and the surface is a light neutral rather than pure
## white so the figure does not glare on GitHub's dark theme or vanish on its light
## one. Validated by tools/check_palette.R.
SURFACE     <- "#f2f1ec"
INK_TITLE   <- "#0b0b0b"
INK_CAPTION <- "#52514e"
BORDER      <- "#c3c2b7"
RAMP <- c("#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b")

top$shade <- RAMP[cut(rank(top$n, ties.method = "first"),
                      breaks = length(RAMP), labels = FALSE)]

set.seed(opt$seed)

p <- ggplot(top, aes(label = word, size = n, colour = shade)) +
  geom_text_wordcloud_area(family = "sans", eccentricity = 0.85, rm_outside = FALSE) +
  scale_size_area(max_size = opt$max_pt) +
  scale_colour_identity() +
  labs(
    title = "Synthetic vocabulary from free-text fields after irreversible token substitution",
    caption = paste0(
      "Every word above was produced by a seeded synthetic token mapping applied to the original survey responses.\n",
      "The mapping is discarded once the synthetic CSVs are built, so no word here can be reverse-mapped to any\n",
      "original response. Word area is proportional to frequency.\n",
      sprintf("Sources: %s.\n",
              paste(basename(input_files), collapse = ", ")),
      sprintf("%s free-text tokens, %s distinct synthetic words (frequencies %s to %s). The %d most frequent are\n",
              format(n_tokens_total, big.mark = ","),
              format(n_distinct_tokens, big.mark = ","),
              format(min(freq$n), big.mark = ","), format(n_max, big.mark = ","),
              nrow(top)),
      sprintf("drawn; the full table is in %s. Build seed %d, layout seed %d.",
              basename(freq_path), 726L, opt$seed)
    )
  ) +
  theme_minimal(base_size = 15, base_family = "sans") +
  theme(
    plot.background  = element_rect(fill = SURFACE, colour = BORDER, linewidth = 0.8),
    panel.background = element_rect(fill = SURFACE, colour = NA),
    panel.grid       = element_blank(),
    plot.title = element_text(colour = INK_TITLE, face = "bold", size = 16,
                              hjust = 0.5, margin = margin(b = 4)),
    plot.caption = element_text(colour = INK_CAPTION, size = 10.5, hjust = 0,
                                lineheight = 1.3, margin = margin(t = 10)),
    plot.caption.position = "plot",
    plot.title.position = "plot",
    plot.margin = margin(14, 16, 12, 16)
  )

## 8.9 in at 200 dpi = 1780 px. GitHub caps README images near 890 px, so the figure
## displays at half its pixel width -- crisp on high-density screens, and 8.9 in of
## layout across 890 CSS px means an in-figure point size renders at roughly the same
## point size on screen. Every drawn word is therefore at least --min-pt.
ggsave(opt$out, plot = p, width = 8.9, height = 5.9, dpi = 200,
       units = "in", bg = SURFACE)

cat(sprintf("Wrote %s\n", opt$out))
cat(sprintf("  %s tokens, %s distinct synthetic words; %d drawn (frequency %s and up)\n",
            format(n_tokens_total, big.mark = ","),
            format(n_distinct_tokens, big.mark = ","), nrow(top),
            format(min(top$n), big.mark = ",")))
cat(sprintf("  full frequency table: %s\n", freq_path))
