#!/usr/bin/env Rscript
## check_palette.R -- colour-vision and contrast validation for committed figures.
##
## Every PNG in this repository is rendered on a GitHub README page that may be
## displayed on a light or a dark background, so figure colours are held to three
## measurable gates rather than to judgement:
##
##   1. Adjacent-pair separation under deuteranopia and protanopia,
##      measured as Euclidean distance in OKLab x 100 (target >= 8).
##   2. Normal-vision separation for the same pairs (floor >= 15) -- a palette that
##      fails here is unreadable even to full-colour viewers.
##   3. WCAG contrast of every colour against the figure surface (>= 3:1).
##
## Colour-vision simulation follows Vienot, Brettel & Mollon (1999); OKLab follows
## Ottosson (2020). No network access and no non-base dependencies.
##
## Usage:
##   Rscript tools/check_palette.R "#2a78d6,#eb6834" --surface "#f2f1ec"
##   Rscript tools/check_palette.R "#2a78d6,#256abf" --surface "#f2f1ec" --ordinal
##
## --ordinal relaxes the pair gates to neighbouring steps of a ramp only, where a
## deliberate light-to-dark progression is the encoding and hue separation is not.

## ---- sRGB <-> linear ----------------------------------------------------------

hex_to_rgb <- function(hex) {
  hex <- gsub("^#", "", trimws(hex))
  if (!all(grepl("^[0-9A-Fa-f]{6}$", hex))) {
    stop("Colours must be 6-digit hex, e.g. #2a78d6. Got: ",
         paste(hex[!grepl("^[0-9A-Fa-f]{6}$", hex)], collapse = ", "))
  }
  t(sapply(hex, function(h) {
    c(strtoue <- strtoi(substr(h, 1, 2), 16L),
      strtoi(substr(h, 3, 4), 16L),
      strtoi(substr(h, 5, 6), 16L)) / 255
  }))
}

srgb_to_linear <- function(v) ifelse(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055)^2.4)
linear_to_srgb <- function(v) {
  v <- pmin(pmax(v, 0), 1)
  ifelse(v <= 0.0031308, v * 12.92, 1.055 * v^(1 / 2.4) - 0.055)
}

## ---- OKLab (Ottosson 2020) ----------------------------------------------------

linear_to_oklab <- function(rgb_lin) {
  r <- rgb_lin[, 1]; g <- rgb_lin[, 2]; b <- rgb_lin[, 3]
  l <- 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  m <- 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  s <- 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
  l_ <- sign(l) * abs(l)^(1 / 3); m_ <- sign(m) * abs(m)^(1 / 3); s_ <- sign(s) * abs(s)^(1 / 3)
  cbind(
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
  )
}

hex_to_oklab <- function(hex) linear_to_oklab(srgb_to_linear(hex_to_rgb(hex)))

## Euclidean distance in OKLab, scaled x100 to match the convention used in the
## design guidance this repository follows.
oklab_delta <- function(lab1, lab2) 100 * sqrt(rowSums((lab1 - lab2)^2))

## ---- Dichromat simulation (Vienot, Brettel & Mollon 1999) ---------------------

.rgb2lms <- matrix(c(17.8824,   43.5161,  4.11935,
                      3.45565,  27.1554,  3.86714,
                      0.0299566, 0.184309, 1.46709),
                   nrow = 3, byrow = TRUE)
.lms2rgb <- solve(.rgb2lms)

simulate_cvd <- function(rgb_lin, type = c("deuteranopia", "protanopia")) {
  type <- match.arg(type)
  lms <- rgb_lin %*% t(.rgb2lms)
  out <- lms
  if (type == "protanopia") {
    out[, 1] <- 2.02344 * lms[, 2] - 2.52581 * lms[, 3]
  } else {
    out[, 2] <- 0.494207 * lms[, 1] + 1.24827 * lms[, 3]
  }
  pmin(pmax(out %*% t(.lms2rgb), 0), 1)
}

## ---- WCAG relative luminance and contrast -------------------------------------

relative_luminance <- function(rgb_lin) {
  0.2126 * rgb_lin[, 1] + 0.7152 * rgb_lin[, 2] + 0.0722 * rgb_lin[, 3]
}

contrast_ratio <- function(hex_a, hex_b) {
  la <- relative_luminance(srgb_to_linear(hex_to_rgb(hex_a)))
  lb <- relative_luminance(srgb_to_linear(hex_to_rgb(hex_b)))
  (pmax(la, lb) + 0.05) / (pmin(la, lb) + 0.05)
}

## ---- The check ----------------------------------------------------------------

CVD_TARGET      <- 8
NORMAL_FLOOR    <- 15
CONTRAST_FLOOR  <- 3
ORDINAL_CONTRAST_FLOOR <- 2

check_palette <- function(colours, surface, ordinal = FALSE, label = "palette") {
  if (length(colours) < 1) stop("Supply at least one colour.")
  rgb_lin <- srgb_to_linear(hex_to_rgb(colours))
  lab_norm <- linear_to_oklab(rgb_lin)
  lab_deut <- linear_to_oklab(simulate_cvd(rgb_lin, "deuteranopia"))
  lab_prot <- linear_to_oklab(simulate_cvd(rgb_lin, "protanopia"))

  ## Adjacent pairs: the order in which slots are assigned is the safety mechanism,
  ## so only neighbouring slots have to clear the gates.
  pairs <- if (length(colours) < 2) NULL else
    cbind(seq_len(length(colours) - 1), seq_len(length(colours) - 1) + 1)

  rows <- list()
  failures <- character(0)

  if (!is.null(pairs)) {
    for (k in seq_len(nrow(pairs))) {
      i <- pairs[k, 1]; j <- pairs[k, 2]
      d_norm <- oklab_delta(lab_norm[i, , drop = FALSE], lab_norm[j, , drop = FALSE])
      d_deut <- oklab_delta(lab_deut[i, , drop = FALSE], lab_deut[j, , drop = FALSE])
      d_prot <- oklab_delta(lab_prot[i, , drop = FALSE], lab_prot[j, , drop = FALSE])
      worst_cvd <- min(d_deut, d_prot)

      ## An ordinal ramp encodes magnitude by lightness, so neighbouring steps are
      ## meant to be close; only the endpoints must be tellable apart.
      pass_norm <- ordinal || d_norm >= NORMAL_FLOOR
      pass_cvd  <- ordinal || worst_cvd >= CVD_TARGET

      rows[[length(rows) + 1]] <- data.frame(
        check      = sprintf("pair %d-%d", i, j),
        detail     = sprintf("%s vs %s", colours[i], colours[j]),
        normal_dE  = round(d_norm, 1),
        deut_dE    = round(d_deut, 1),
        prot_dE    = round(d_prot, 1),
        result     = if (pass_norm && pass_cvd) "PASS" else "FAIL",
        stringsAsFactors = FALSE
      )
      if (!(pass_norm && pass_cvd)) {
        failures <- c(failures, sprintf(
          "%s: %s vs %s -- normal dE %.1f (floor %d), worst CVD dE %.1f (target %d)",
          label, colours[i], colours[j], d_norm, NORMAL_FLOOR, worst_cvd, CVD_TARGET))
      }
    }
    if (ordinal) {
      d_ends <- oklab_delta(lab_norm[1, , drop = FALSE],
                            lab_norm[length(colours), , drop = FALSE])
      ok <- d_ends >= NORMAL_FLOOR
      rows[[length(rows) + 1]] <- data.frame(
        check = "ramp endpoints", detail = sprintf("%s vs %s", colours[1], colours[length(colours)]),
        normal_dE = round(d_ends, 1), deut_dE = NA_real_, prot_dE = NA_real_,
        result = if (ok) "PASS" else "FAIL", stringsAsFactors = FALSE)
      if (!ok) failures <- c(failures, sprintf(
        "%s: ramp endpoints only %.1f apart (floor %d)", label, d_ends, NORMAL_FLOOR))
    }
  }

  floor_used <- if (ordinal) ORDINAL_CONTRAST_FLOOR else CONTRAST_FLOOR
  cr <- contrast_ratio(colours, rep(surface, length(colours)))
  for (i in seq_along(colours)) {
    ok <- cr[i] >= floor_used
    rows[[length(rows) + 1]] <- data.frame(
      check = sprintf("contrast %d", i),
      detail = sprintf("%s on %s", colours[i], surface),
      normal_dE = round(cr[i], 2), deut_dE = NA_real_, prot_dE = NA_real_,
      result = if (ok) "PASS" else "FAIL", stringsAsFactors = FALSE)
    if (!ok) failures <- c(failures, sprintf(
      "%s: %s has contrast %.2f:1 on %s (floor %.0f:1)",
      label, colours[i], cr[i], surface, floor_used))
  }

  report <- do.call(rbind, rows)
  names(report)[3] <- if (ordinal) "normal_dE_or_contrast" else "normal_dE_or_contrast"
  list(report = report, failures = failures, ok = length(failures) == 0)
}

## ---- CLI ----------------------------------------------------------------------

if (sys.nframe() == 0L || identical(environment(), globalenv())) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) == 0) {
    ## No arguments: validate the palettes this repository actually ships.
    surface <- "#f2f1ec"
    specs <- list(
      list(label = "match-quality series", cols = c("#2a78d6", "#d95926"), ordinal = FALSE),
      list(label = "word-cloud frequency ramp",
           cols = c("#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"),
           ordinal = TRUE)
    )
    all_ok <- TRUE
    for (s in specs) {
      res <- check_palette(s$cols, surface, ordinal = s$ordinal, label = s$label)
      cat("\n==", s$label, "on surface", surface, "==\n")
      print(res$report, row.names = FALSE)
      if (!res$ok) { all_ok <- FALSE; cat("FAILURES:\n"); cat(paste0("  ", res$failures, collapse = "\n"), "\n") }
    }
    cat("\nOVERALL:", if (all_ok) "PASS" else "FAIL", "\n")
    if (!all_ok) quit(status = 1)
  } else {
    cols <- trimws(strsplit(args[1], ",")[[1]])
    surface <- if ("--surface" %in% args) args[which(args == "--surface") + 1] else "#f2f1ec"
    ordinal <- "--ordinal" %in% args
    res <- check_palette(cols, surface, ordinal = ordinal)
    print(res$report, row.names = FALSE)
    cat("\nOVERALL:", if (res$ok) "PASS" else "FAIL", "\n")
    if (!res$ok) { cat(paste0("  ", res$failures, collapse = "\n"), "\n"); quit(status = 1) }
  }
}
