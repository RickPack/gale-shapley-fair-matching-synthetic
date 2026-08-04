#!/usr/bin/env Rscript
## scrub_org_fields.R -- remove real organizational structure from the synthetic inputs.
##
## WHY
## build_synthetic_inputs.R relabelled business_group and business_unit as
## "Practice Group NN" / "Business Unit NN" while preserving relative frequencies. The
## labels are meaningless, but the STRUCTURE underneath them is not: the number of
## groups (34+) and units (92+), the headcount distribution (226, 129, 29, 14, ...),
## and which participants share a unit are all real organizational facts. A generic
## label does not de-identify an org chart.
##
## Grade is retained deliberately -- it is the protected attribute the fairness analysis
## is built on, and it is an ordinal band rather than an organizational identifier.
##
## WHAT THIS DOES
## Reassigns every participant to a group and unit drawn uniformly at random from a
## fixed, arbitrary number of categories. The category counts are chosen here, not
## derived from any source data, so neither the counts, the size distribution, nor
## co-membership carry information about any real organization. Assignment is stable
## per participant across years, which keeps the data internally coherent.
##
## Only business_group feeds the compatibility score (as BG_mentor / BG_mentee, via the
## same-business-group preference). business_unit is carried through the pipeline but
## never scored. Both are randomized regardless.
##
## Usage:
##   Rscript scrub_org_fields.R --in data --out data --in-place
##   Rscript scrub_org_fields.R --in data --out data_scrubbed --seed 20260804

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(stringr)
})

parse_args <- function(args) {
  get <- function(flag, default) {
    i <- which(args == flag)
    if (length(i) == 0) return(default)
    if (i + 1 > length(args)) stop(sprintf("%s needs a value.", flag))
    args[i + 1]
  }
  list(indir  = get("--in", "data"),
       outdir = get("--out", "data_scrubbed"),
       seed   = as.integer(get("--seed", "20260804")),
       n_group = as.integer(get("--n-group", "6")),
       n_unit  = as.integer(get("--n-unit", "12")),
       in_place = "--in-place" %in% args)
}
opt <- parse_args(commandArgs(trailingOnly = TRUE))

if (!dir.exists(opt$indir)) stop(sprintf("Input folder not found: %s", opt$indir))
if (!opt$in_place && normalizePath(opt$indir, mustWork = FALSE) ==
      normalizePath(opt$outdir, mustWork = FALSE)) {
  stop("Refusing to overwrite the input folder. Pass --in-place if that is the intent.")
}

files <- list.files(opt$indir, pattern = "^survey_synthetic_[0-9]{4}\\.csv$", full.names = TRUE)
if (length(files) == 0) stop(sprintf("No survey_synthetic_<year>.csv in %s.", opt$indir))

## One shared assignment across years so a participant does not change group between
## survey rounds. Keyed on the synthetic person label, which is already de-identified.
people <- character(0)
frames <- list()
for (f in files) {
  d <- suppressWarnings(read_csv(f, show_col_types = FALSE, progress = FALSE))
  for (cl in c("business_group", "business_unit", "display_name")) {
    if (!cl %in% names(d)) stop(sprintf("%s has no %s column.", basename(f), cl))
  }
  people <- c(people, d$display_name[!is.na(d$display_name)])
  frames[[f]] <- d
}
people <- sort(unique(people))

cat(sprintf("Participants: %d\n", length(people)))
before <- bind_rows(lapply(frames, function(d) tibble(g = d$business_group, u = d$business_unit)))
cat(sprintf("BEFORE  groups: %d distinct   units: %d distinct\n",
            n_distinct(na.omit(before$g)), n_distinct(na.omit(before$u))))
cat(sprintf("        largest group holds %d rows (real headcount structure)\n",
            max(table(na.omit(before$g)))))

set.seed(opt$seed)
group_of <- setNames(sprintf("Group %02d", sample.int(opt$n_group, length(people), replace = TRUE)),
                     people)
unit_of  <- setNames(sprintf("Unit %02d",  sample.int(opt$n_unit,  length(people), replace = TRUE)),
                     people)

dir.create(opt$outdir, recursive = TRUE, showWarnings = FALSE)
for (f in names(frames)) {
  d <- frames[[f]]
  d$business_group <- unname(group_of[d$display_name])
  d$business_unit  <- unname(unit_of[d$display_name])
  out <- file.path(opt$outdir, basename(f))
  write_csv(d, out, na = "")
  message("Wrote ", out)
}

after <- bind_rows(lapply(list.files(opt$outdir, pattern = "^survey_synthetic_", full.names = TRUE),
                          function(p) {
                            d <- suppressWarnings(read_csv(p, show_col_types = FALSE, progress = FALSE))
                            tibble(g = d$business_group, u = d$business_unit)
                          }))
cat(sprintf("AFTER   groups: %d distinct   units: %d distinct (both chosen, not derived)\n",
            n_distinct(na.omit(after$g)), n_distinct(na.omit(after$u))))
cat(sprintf("        assignment uniform at random, seed %d\n", opt$seed))
cat("\nNo real organizational structure remains in these fields.\n")
