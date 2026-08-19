# Data provenance

Three scripts stood between the restricted source workbooks and the committed
`data/*.csv`, and each removes a different kind of information. They ran once; what is
committed here is their output. See the main [README](../README.md) for
the resulting vocabulary-collapse defect and its fix.

## `build_synthetic_inputs.R`

Replaces names with `PERSON_####` labels, derives `CID####` identifiers from those
labels, relabels business groups and units as `Practice Group NN` and `Business Unit NN`
while preserving relative frequencies, and rewrites every free-text answer through a
seeded, frequency-ordered substitution into a generated vocabulary. **The substitution
map is discarded when the build finishes** (`rm(word_map)`), so the mapping cannot be run
backwards.

## `scrub_org_fields.R`

Removes the organisational structure that survived the first pass. Relabelling groups and
units left the labels meaningless but the shape underneath intact: how many groups and
units exist, the headcount distribution across them, and which participants share one. A
generic label does not de-identify an org chart. This script reassigns every participant
to a group and unit drawn uniformly at random from a fixed, arbitrary number of categories
chosen in the script rather than derived from any source. Assignment is stable per
participant across years, so the data stays internally coherent. Grade is deliberately
retained, because it is the protected attribute the fairness analysis rests on and an
ordinal band rather than an organisational identifier.

## `repair_synthetic_vocabulary.R`

Fixes a defect the first build introduced. The generated vocabulary fell back to
`sprintf("term%04d", i)` labels once its 900-item stem pool ran out, and the analysis
scores text after stripping non-letters with
`str_replace_all(toupper(x), "[^A-Z ]", "")`. That strip deleted the digits, so
`term0001`, `term0002` and the rest all collapsed into a single word, `TERM`. In the
shipped data that was 77.6% of all token mass and 2,748 of 3,647 distinct words folding
into one. Every document became roughly three-quarters the same word, cosine similarity
between any two sat near 0.99, and the text component stopped carrying information. The
repair relabels the offending tokens with alphabetic-only names. That is a bijection on
the vocabulary, so the document-term matrix is unchanged up to a permutation of its
columns and every downstream statistic is what it would have been had the vocabulary
never contained digits. The repair reads no original data.

## Confidentiality boundary

**The restricted source workbooks are not in this repository, are not referenced by any
committed path, and are not needed to reproduce anything.** `.gitignore` excludes
`source_workbooks/` and `GS_SOURCE_ROOT/`; the pipeline reads the committed `data/*.csv`
and never looks anywhere else unless a reader deliberately sets `GS_SOURCE_ROOT` to
something of their own. The three scripts above ran once, on a machine holding those
inputs, and are published here so that the de-identification can be audited rather than
so that it can be repeated.
