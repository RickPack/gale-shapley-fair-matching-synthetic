#!/usr/bin/env Rscript
## repair_synthetic_vocabulary.R -- make the synthetic vocabulary survive scoring.
##
## THE DEFECT
## build_synthetic_inputs.R generates a safe vocabulary of 900 stem compounds
## ("effortapproach", "contextfield", ...) and, once those run out, falls back to
## sprintf("term%04d", i). The analysis then scores text with
##
##     str_replace_all(toupper(x), "[^A-Z ]", "")
##
## which deletes digits. Every term0001, term0002, ... becomes the same word, TERM.
## In the shipped data that is 77.6% of all token mass and 2,748 of 3,647 distinct
## words collapsing to one, so every document is roughly three-quarters the same word
## and cosine similarity between any two documents sits near 0.99 with a standard
## deviation around 0.003. The text component stops carrying information, which is why
## the u sweep goes inert and the between-method equivalence test fails.
##
## THE REPAIR
## Relabel the offending tokens with alphabetic-only names. This is a bijection on the
## vocabulary, so the document-term matrix is unchanged up to a permutation of its
## columns: token frequencies, per-document counts, and every downstream statistic are
## exactly what they would have been had the vocabulary never contained digits.
##
## IT NEEDS NO ORIGINAL DATA. The synthetic CSVs are already a relabelling of the
## source text; composing a second bijection with the first is still a bijection. The
## confidential workbooks are not read, required, or referenced.
##
## Usage:
##   Rscript repair_synthetic_vocabulary.R --in data --out data_repaired
##   Rscript repair_synthetic_vocabulary.R --in data --out data --in-place

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(stringr); library(purrr)
})

parse_args <- function(args) {
  get <- function(flag, default) {
    i <- which(args == flag)
    if (length(i) == 0) return(default)
    if (i + 1 > length(args)) stop(sprintf("%s needs a value.", flag))
    args[i + 1]
  }
  list(indir  = get("--in", "data"),
       outdir = get("--out", "data_repaired"),
       in_place = "--in-place" %in% args)
}
opt <- parse_args(commandArgs(trailingOnly = TRUE))

if (!dir.exists(opt$indir)) stop(sprintf("Input folder not found: %s", opt$indir))
if (!opt$in_place && normalizePath(opt$indir, mustWork = FALSE) ==
      normalizePath(opt$outdir, mustWork = FALSE)) {
  stop("Refusing to overwrite the input folder. Pass --in-place if that is the intent.")
}

## The columns build_synthetic_inputs.R passes through replace_tokens().
TEXT_COL_PATTERN <- paste(
  "^what_are_your_strongest_skills",
  "^what_topics_are_you_knowledgeable_on",
  "^which_expectations_can_you_help_fulfill",
  "^please_tell_us_in_your_own_words",
  "^are_there_any_special_considerations",
  "^what_skills_would_you_like_to_improve",
  "^what_topics_are_you_interested_in",
  "^what_are_your_expectations_for_this_program",
  sep = "|")

TOKEN_PATTERN <- "[A-Za-z][A-Za-z0-9']*"

survey_files <- list.files(opt$indir, pattern = "^survey_synthetic_[0-9]{4}\\.csv$",
                           full.names = TRUE)
if (length(survey_files) == 0) {
  stop(sprintf("No survey_synthetic_<year>.csv files in %s.", opt$indir))
}

## ---- pass 1: collect the vocabulary across every year -------------------------
## One shared map, because the original substitution was global; the same word must
## relabel identically in every file or cross-year comparisons would break.

message("Scanning ", length(survey_files), " survey file(s) for vocabulary...")
all_tokens <- character(0)
frames <- list()
for (f in survey_files) {
  d <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE))
  cols <- names(d)[str_detect(names(d), TEXT_COL_PATTERN)]
  if (length(cols) == 0) stop(sprintf("%s has no recognised free-text columns.", basename(f)))
  txt <- unlist(d[, cols], use.names = FALSE)
  txt <- txt[!is.na(txt)]
  all_tokens <- c(all_tokens, tolower(unlist(str_extract_all(txt, TOKEN_PATTERN))))
  frames[[f]] <- list(data = d, cols = cols)
}

vocab <- sort(unique(all_tokens))
needs_fix <- vocab[str_detect(vocab, "[^a-z]")]

cat(sprintf("\nVocabulary: %d distinct tokens\n", length(vocab)))
cat(sprintf("  alphabetic already : %d\n", length(vocab) - length(needs_fix)))
cat(sprintf("  containing non-letters (collapse under [^A-Z ]) : %d\n", length(needs_fix)))

## What the scorer currently sees: tokens sharing a letters-only form are one word.
collapsed_form <- str_replace_all(vocab, "[^a-z]", "")
cat(sprintf("  effective vocabulary as scored today : %d (%.0f%% of the real vocabulary)\n",
            n_distinct(collapsed_form), 100 * n_distinct(collapsed_form) / length(vocab)))

if (length(needs_fix) == 0) {
  message("\nNothing to repair; the vocabulary is already alphabetic.")
  quit(status = 0)
}

## ---- build the replacement labels ---------------------------------------------
## Base-26 letter suffixes keep the labels obviously synthetic, unique, and free of
## any character the scorer strips. Width is chosen to fit the vocabulary with slack.

letter_label <- function(i, width) {
  ## i is 1-based; render as a fixed-width base-26 string over a..z
  out <- character(length(i))
  for (k in seq_along(i)) {
    n <- i[k] - 1L
    s <- character(width)
    for (p in seq(width, 1)) { s[p] <- letters[(n %% 26L) + 1L]; n <- n %/% 26L }
    out[k] <- paste0(s, collapse = "")
  }
  out
}
width <- max(3L, ceiling(log(length(needs_fix), base = 26)))
new_labels <- paste0("term", letter_label(seq_along(needs_fix), width))

## The map must stay a bijection: no new label may equal an existing alphabetic token
## or another new label, or two originally distinct words would merge.
existing_alpha <- setdiff(vocab, needs_fix)
if (any(new_labels %in% existing_alpha)) {
  stop("Generated labels collide with existing vocabulary; widen the label space.")
}
stopifnot(!any(duplicated(new_labels)), length(new_labels) == length(needs_fix))

token_map <- setNames(new_labels, needs_fix)

## Verify the repaired vocabulary is collision-free under the scorer's own transform.
repaired_vocab <- c(existing_alpha, new_labels)
if (n_distinct(str_replace_all(repaired_vocab, "[^a-z]", "")) != length(repaired_vocab)) {
  stop("Repaired vocabulary still collapses under [^A-Z ]; aborting.")
}
cat(sprintf("  effective vocabulary after repair : %d (100%% of the real vocabulary)\n",
            length(repaired_vocab)))

## ---- pass 2: rewrite ------------------------------------------------------------

relabel <- function(text_vec, map) {
  vapply(text_vec, function(txt) {
    if (is.na(txt) || !nzchar(txt)) return(txt)
    m <- gregexpr(TOKEN_PATTERN, txt, perl = TRUE)[[1]]
    if (m[1] == -1) return(txt)
    words <- regmatches(txt, list(m))[[1]]
    repl  <- unname(map[tolower(words)])
    repl[is.na(repl)] <- words[is.na(repl)]   # already-alphabetic tokens pass through
    regmatches(txt, list(m)) <- list(repl)
    txt
  }, character(1), USE.NAMES = FALSE)
}

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)

for (f in names(frames)) {
  d    <- frames[[f]]$data
  cols <- frames[[f]]$cols
  for (cl in cols) d[[cl]] <- relabel(as.character(d[[cl]]), token_map)
  out <- file.path(opt$outdir, basename(f))
  write_csv(d, out, na = "")
  message("Wrote ", out)
}

## Prior-year match files hold only PERSON_#### labels; copy them through unchanged
## so the output folder is a complete, self-sufficient input set.
for (f in list.files(opt$indir, pattern = "^prior_year_matches_synthetic_[0-9]{4}\\.csv$",
                     full.names = TRUE)) {
  tgt <- file.path(opt$outdir, basename(f))
  if (normalizePath(f, mustWork = FALSE) != normalizePath(tgt, mustWork = FALSE)) {
    file.copy(f, tgt, overwrite = TRUE)
    message("Copied ", tgt)
  }
}

map_path <- file.path(opt$outdir, "vocabulary_repair_map.csv")
write_csv(tibble(old_token = needs_fix, new_token = new_labels), map_path)
message("Wrote ", map_path)

cat("\nThe repair is a relabelling only. Token frequencies and per-document counts are\n",
    "unchanged; the scorer can now tell the tokens apart.\n", sep = "")
