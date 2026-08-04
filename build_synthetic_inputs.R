suppressPackageStartupMessages({
  library(openxlsx)
  library(janitor)
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
})

source_root <- Sys.getenv("GS_SOURCE_ROOT", unset = "")
if (!nzchar(source_root)) {
  stop("Set GS_SOURCE_ROOT to the folder holding the original year-based input workbooks.")
}
target_root <- normalizePath(".", winslash = "/", mustWork = TRUE)
data_dir <- file.path(target_root, "data")
dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)

survey_years <- 2023:2025
prior_years <- 2022:2024

required_cols <- c(
  "start_date",
  "recipient_last_name",
  "recipient_first_name",
  "corp_id",
  "display_name",
  "first_name",
  "last_name",
  "what_is_your_grade_level",
  "would_you_like_to_be_a_mentor_or_a_mentee",
  "would_you_prefer_a_mentee_within_your_business_unit_group",
  "what_are_your_strongest_skills_please_choose_your_top_3",
  "what_topics_are_you_knowledgeable_on_please_choose_your_top_3",
  "which_expectations_can_you_help_fulfill_please_choose_your_top_3",
  "do_you_prefer_2_2_or_would_you_be_comfortable_mentoring_more_than_one_associate",
  "would_you_consider_yourself_an_extrovert_or_an_introvert",
  "which_personality_type_would_you_prefer_to_be_paired_with",
  "please_tell_us_in_your_own_words_why_you_want_to_be_a_mentor_what_are_your_expectations_and_intended_outcomes_please_provide_a_detailed_response_of_3_4_sentences",
  "are_there_any_special_considerations_that_you_would_like_known_when_your_application_is_reviewed_is_your_desire_to_participate_based_on_certain_criteria_that_you_have_in_mind_that_was_not_covered_in_the_previous_questions_please_list_that_information_here",
  "would_you_prefer_a_mentor_with_your_current_job_role_or_one_above",
  "what_skills_would_you_like_to_improve_please_choose_your_top_3",
  "what_topics_are_you_interested_in_please_choose_your_top_3",
  "what_are_your_expectations_for_this_program_please_choose_your_top_3",
  "would_you_consider_yourself_an_extrovert_or_an_introvert_2",
  "which_personality_type_would_you_prefer_to_be_paired_with_2",
  "please_tell_us_in_your_own_words_why_you_want_to_be_a_mentee_what_are_your_expectations_and_intended_outcomes_please_provide_a_detailed_response_of_3_4_sentences",
  "are_there_any_special_considerations_that_you_would_like_known_when_your_application_is_reviewed_is_your_desire_to_participate_based_on_certain_criteria_that_you_have_in_mind_that_was_not_covered_in_the_previous_questions_please_list_that_information_here_2",
  ## Source-workbook column names. The synthetic outputs rename these to
  ## affiliation_group / affiliation_unit, because the published data carries no real
  ## organizational structure and should not use language implying that it does.
  "business_group",
  "business_unit"
)

text_cols <- c(
  "what_are_your_strongest_skills_please_choose_your_top_3",
  "what_topics_are_you_knowledgeable_on_please_choose_your_top_3",
  "which_expectations_can_you_help_fulfill_please_choose_your_top_3",
  "please_tell_us_in_your_own_words_why_you_want_to_be_a_mentor_what_are_your_expectations_and_intended_outcomes_please_provide_a_detailed_response_of_3_4_sentences",
  "are_there_any_special_considerations_that_you_would_like_known_when_your_application_is_reviewed_is_your_desire_to_participate_based_on_certain_criteria_that_you_have_in_mind_that_was_not_covered_in_the_previous_questions_please_list_that_information_here",
  "what_skills_would_you_like_to_improve_please_choose_your_top_3",
  "what_topics_are_you_interested_in_please_choose_your_top_3",
  "what_are_your_expectations_for_this_program_please_choose_your_top_3",
  "please_tell_us_in_your_own_words_why_you_want_to_be_a_mentee_what_are_your_expectations_and_intended_outcomes_please_provide_a_detailed_response_of_3_4_sentences",
  "are_there_any_special_considerations_that_you_would_like_known_when_your_application_is_reviewed_is_your_desire_to_participate_based_on_certain_criteria_that_you_have_in_mind_that_was_not_covered_in_the_previous_questions_please_list_that_information_here_2"
)

sanitize_name <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x[is.na(x)] <- ""
  x
}

name_map <- new.env(parent = emptyenv())
next_id <- 1L

get_synth_name <- function(x) {
  x <- sanitize_name(x)
  out <- character(length(x))
  for (i in seq_along(x)) {
    key <- x[[i]]
    if (key == "") {
      out[[i]] <- NA_character_
    } else {
      if (!exists(key, envir = name_map, inherits = FALSE)) {
        assign(key, sprintf("PERSON_%04d", next_id), envir = name_map)
        next_id <<- next_id + 1L
      }
      out[[i]] <- get(key, envir = name_map, inherits = FALSE)
    }
  }
  out
}

build_safe_vocab <- function(n) {
  stems1 <- c("study","learn","team","focus","skill","goal","logic","value","growth","mentor",
              "career","insight","method","review","design","practice","impact","report","detail","plan",
              "leader","result","support","effort","change","reason","future","option","context","project")
  stems2 <- c("path","view","point","model","topic","frame","guide","signal","effort","match",
              "share","thread","route","bridge","track","outcome","summary","window","choice","process",
              "system","field","group","network","insight","analysis","dialog","profile","record","approach")
  pool <- as.vector(outer(stems1, stems2, paste0))
  if (n <= length(pool)) return(pool[seq_len(n)])

  ## Overflow labels must contain NO digits. The analysis scores text through
  ## str_replace_all(toupper(x), "[^A-Z ]", ""), which deletes every non-letter, so a
  ## digit-bearing label such as "term0001" is indistinguishable from "term0002" by the
  ## time it reaches the scorer. Numbering the overflow that way once collapsed 2,748
  ## distinct words into the single word TERM -- 77.6% of all token mass -- which drove
  ## cosine similarity between any two documents to roughly 0.99 and made the text
  ## component of the compatibility score carry no information.
  ##
  ## Base-26 letter suffixes keep the labels unique, obviously synthetic, and intact
  ## under that transform.
  extra_n <- n - length(pool)
  width <- max(3L, ceiling(log(extra_n, base = 26)))
  letter_label <- function(i, width) {
    vapply(i, function(k) {
      v <- k - 1L
      s <- character(width)
      for (p in seq(width, 1)) { s[p] <- letters[(v %% 26L) + 1L]; v <- v %/% 26L }
      paste0(s, collapse = "")
    }, character(1))
  }
  extra <- paste0("term", letter_label(seq_len(extra_n), width))

  out <- c(pool, extra)
  ## A relabelling is only safe if it is injective after the scorer strips non-letters.
  collapsed <- gsub("[^a-z]", "", out)
  if (anyDuplicated(collapsed)) {
    stop("Safe vocabulary is not collision-free once non-letters are stripped.")
  }
  out
}

replace_tokens <- function(text_vec, word_map) {
  pat <- "[A-Za-z][A-Za-z']*"
  vapply(text_vec, function(txt) {
    if (is.na(txt) || txt == "") return(txt)
    m <- gregexpr(pat, txt, perl = TRUE)[[1]]
    if (m[1] == -1) return(txt)
    words <- regmatches(txt, list(m))[[1]]
    low <- tolower(words)
    rep_words <- unname(word_map[low])
    rep_words[is.na(rep_words)] <- "term"
    regmatches(txt, list(m)) <- list(rep_words)
    txt
  }, character(1))
}

all_text <- character(0)
survey_raw <- list()

for (yr in survey_years) {
  src <- list.files(
    source_root,
    pattern = sprintf("Qualtrics_Survey_%d\\.xlsx$", yr),
    full.names = TRUE,
    ignore.case = TRUE
  )
  if (length(src) != 1) {
    stop(sprintf("Expected exactly one survey workbook for year %d in GS_SOURCE_ROOT.", yr))
  }
  dat <- openxlsx::read.xlsx(src, startRow = 2)
  dat <- dat[, !grepl("BALLOT", toupper(names(dat))), drop = FALSE]
  dat <- janitor::clean_names(dat)
  names(dat) <- gsub("_1", "_2", names(dat))

  missing <- setdiff(required_cols, names(dat))
  if (length(missing) > 0) {
    stop(sprintf("Missing required columns in %s: %s", basename(src), paste(missing, collapse = ", ")))
  }

  d <- dat[, required_cols, drop = FALSE]
  d$source_year <- yr
  survey_raw[[as.character(yr)]] <- d
  all_text <- c(all_text, unlist(d[, intersect(text_cols, names(d)), drop = FALSE], use.names = FALSE))
}

all_tokens <- tolower(unlist(str_extract_all(paste(all_text, collapse = " "), "[A-Za-z][A-Za-z']*")))
all_tokens <- all_tokens[nzchar(all_tokens)]
freq <- sort(table(all_tokens), decreasing = TRUE)
vocab <- names(freq)

safe_vocab <- build_safe_vocab(length(vocab))
set.seed(726)
safe_vocab <- sample(safe_vocab, length(safe_vocab), replace = FALSE)
word_map <- setNames(safe_vocab, vocab)

for (yr in survey_years) {
  d <- survey_raw[[as.character(yr)]]

  base_name <- ifelse(
    is.na(d$display_name) | trimws(d$display_name) == "",
    paste(d$first_name, d$last_name),
    d$display_name
  )
  synth_name <- get_synth_name(base_name)

  d$display_name <- synth_name
  d$corp_id <- paste0("CID", str_sub(synth_name, -4, -1))
  d$first_name <- paste0("First", str_sub(synth_name, -4, -1))
  d$last_name <- paste0("Last", str_sub(synth_name, -4, -1))
  d$recipient_first_name <- d$first_name
  d$recipient_last_name <- d$last_name

  d$would_you_like_to_be_a_mentor_or_a_mentee <- str_to_title(str_trim(d$would_you_like_to_be_a_mentor_or_a_mentee))

  for (tc in intersect(text_cols, names(d))) {
    d[[tc]] <- replace_tokens(as.character(d[[tc]]), word_map)
  }

  ## Read under the source names, publish under neutral ones.
  d$affiliation_group <- as.character(d$business_group)
  d$affiliation_unit  <- as.character(d$business_unit)
  d$business_group <- NULL
  d$business_unit  <- NULL

  ## Organizational fields are REASSIGNED AT RANDOM, not relabelled.
  ##
  ## Relabelling these one-to-one preserves the number of groups and units, their
  ## headcount distribution, and which participants share one. That is a real org
  ## chart wearing generic names, and it must not leave the source system. Grade is
  ## treated differently and is retained: it is the protected attribute the fairness
  ## analysis rests on, and it is an ordinal band rather than an organizational unit.
  ##
  ## Category counts below are chosen, not derived from the source workbooks, so
  ## neither the counts, the size distribution, nor co-membership carry any real
  ## information. Assignment is keyed on the synthetic person label so a participant
  ## keeps the same group across survey years.
  n_group_synth <- 6L
  n_unit_synth  <- 12L
  bg_seed <- 20260804L

  set.seed(bg_seed)
  people_yr <- sort(unique(na.omit(d$display_name)))
  grp <- setNames(sprintf("Group %02d", sample.int(n_group_synth, length(people_yr), replace = TRUE)),
                  people_yr)
  unt <- setNames(sprintf("Unit %02d",  sample.int(n_unit_synth,  length(people_yr), replace = TRUE)),
                  people_yr)
  d$affiliation_group <- unname(grp[d$display_name])
  d$affiliation_unit  <- unname(unt[d$display_name])

  out_survey <- file.path(data_dir, sprintf("survey_synthetic_%d.csv", yr))
  readr::write_csv(d, out_survey, na = "")
}

for (yr in prior_years) {
  src <- list.files(
    source_root,
    pattern = sprintf("deliverable_%d\\.xlsx$", yr),
    full.names = TRUE,
    ignore.case = TRUE
  )
  if (length(src) != 1) {
    stop(sprintf("Expected exactly one prior-year deliverable workbook for year %d in GS_SOURCE_ROOT.", yr))
  }
  dat <- janitor::clean_names(openxlsx::read.xlsx(src, startRow = 1))

  if (!"mentee_name" %in% names(dat)) {
    stop(sprintf("Missing mentee_name in %s", basename(src)))
  }
  if (!"gale_shapley_matched_mentor_name" %in% names(dat)) {
    stop(sprintf("Missing gale_shapley_matched_mentor_name in %s", basename(src)))
  }

  out <- dat %>%
    transmute(
      mentee_name = get_synth_name(mentee_name),
      gale_shapley_matched_mentor_name = get_synth_name(gale_shapley_matched_mentor_name)
    ) %>%
    distinct()

  readr::write_csv(out, file.path(data_dir, sprintf("prior_year_matches_synthetic_%d.csv", yr)), na = "")
}

rm(word_map)
message("Synthetic inputs created in: ", data_dir)
