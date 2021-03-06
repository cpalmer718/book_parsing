#' Process raw submitter data
#'
#' This function loads an Excel spreadsheet containing formatted output
#' from an initial user submission, and parses it into a format more readily
#' usable by experts for manual inspection and correction. Some degree of
#' ML/NLP is applied to try to harmonize data across multiple (very) similiar
#' entries. This functionality can be disabled if desired.
#'
#' @param input.filename character string, file containing input string data
#' @param output.prefix character string, prefix of files that will contain output for user intervention
#' @param preprocessing.overrides character string, a file of Content/Replacement pairs delimited by TABs, or NA
#' @param postprocessing.overrides character string, a file of Content/Replacement pairs delimited by TABs, or NA
#' @param known.matches character string, a file of curated {Entry -> {Title, Author}} pairs, or NA
#' @param remove.duplicates logical, whether to remove rows in input data that are absolutely identical (will report on this if so)
#' @param disable.nlp.correction logical, whether to just report the data as detected from input, without applying NLP corrections
#' @param cutree.h.combined numeric, `cutree` h parameter for hierarchical cluster calling for combined title/author queries
#' @param cutree.h.title numeric, `cutree` h parameter for hierarchical cluster calling for titles only
#' @param cutree.h.author numeric, `cutree` h parameter for hierarchical cluster calling for authors only
#' @export
parse_raw_data <- function(input.filename,
						   output.prefix,
						   preprocessing.overrides = NA,
						   postprocessing.overrides = NA,
						   known.matches = NA,
						   remove.duplicates = TRUE,
						   disable.nlp.correction = FALSE,
						   cutree.h.combined = 5,
						   cutree.h.title = 3,
						   cutree.h.author = 3) {
	## input parameter consistency checks
	stopifnot(is.vector(input.filename, mode = "character"))
	stopifnot(is.vector(output.prefix, mode = "character"))
	stopifnot(is.vector(preprocessing.overrides, mode = "character") |
			  is.na(preprocessing.overrides))
	stopifnot(is.vector(postprocessing.overrides, mode = "character") |
			  is.na(postprocessing.overrides))
	stopifnot(is.vector(known.matches, mode = "character") |
			  is.na(known.matches))
	stopifnot(is.logical(remove.duplicates))
	stopifnot(is.logical(disable.nlp.correction))
	stopifnot(is.numeric(cutree.h.combined))
	stopifnot(is.numeric(cutree.h.title))
	stopifnot(is.numeric(cutree.h.author))
	stopifnot(cutree.h.combined > 0)
	stopifnot(cutree.h.title > 0)
	stopifnot(cutree.h.author > 0)
	print(paste("reading input from '", input.filename, "' and parsing out into individual entries", sep=""))
	h <- openxlsx::read.xlsx(input.filename)
	if (remove.duplicates) {
		## preprocess: remove identical rows as possible dups
		h <- handle.duplicates(h, output.prefix)
	}
	## aggregate all information for clustering
	all.candidates <- unname(unlist(h[,-1]))
	## similarly aggregate which *categories* the votes were from
	all.categories <- rep(gsub("\\.", " ", gsub("^(.*)\\.-\\..*$", "\\1", colnames(h)[seq(2,ncol(h),3)], perl = TRUE)), each = 3 * nrow(h))
	## remove empty values
	all.categories <- all.categories[!is.na(all.candidates)]
	all.candidates <- all.candidates[!is.na(all.candidates)]
	raw.string <- all.candidates
	if (!is.na(preprocessing.overrides)) {
		print(paste("applying preprocessing overrides from '", preprocessing.overrides, "'", sep=""))
	}
	all.candidates <- book.parsing::apply.initial.overrides(all.candidates, preprocessing.overrides)
	## start building a result data frame
	result.df <- data.frame(raw.string = raw.string,
							original.string = all.candidates,
							category = all.categories)
	## a few people provided parentheticals that most others didn't
	## separate those out and add them as separate comments
	all.comments <- rep(NA, length(all.candidates))
	parenthetical.pattern <- "^(.*)(\\(.*\\)).*$"
	parenthetical.match <- grepl(parenthetical.pattern, all.candidates)
	all.comments[parenthetical.match] <- gsub(parenthetical.pattern, "\\2", all.candidates[parenthetical.match], perl = TRUE)
	result.df[,"submitter.comments"] <- all.comments
	all.candidates[parenthetical.match] <- gsub(parenthetical.pattern, "\\1", all.candidates[parenthetical.match], perl = TRUE)
	## apply names attribute for linking back later
	names(all.candidates) <- all.candidates
	## parse out into "Title" "Author" pairs
	## note that not all entries have title/author pairs,
	## and not all are delimited coherently. the most common
	## annotation styles are
	## Title by Author
	## Title - Author
	## Title / Author
	## there are also some with no delimiter, and some with no author at all.
	print("splitting entries by recognized 'TITLE - AUTHOR' and 'title by author' structures")
	title.by.author.pattern <- "^ *(.+[A-Za-z]) +by +(.+[A-Za-z]) *$"
	title.dash.author.pattern <- "^ *(.+[A-Za-z]) *[/-] *(.+[A-Za-z]) *$"
	title.by.author.match <- grepl(title.by.author.pattern, all.candidates, perl = TRUE)
	title.dash.author.match <- grepl(title.dash.author.pattern, all.candidates, perl = TRUE)
	both.match <- title.by.author.match & title.dash.author.match
	#if (length(which(both.match)) > 0) {
	#	print("both match error! following example(s):")
	#	print(all.candidates[both.match])
	#}
	#stopifnot(length(which(both.match)) == 0)
	## temporary fix: if both.match has TRUE entries, prioritize the " by " match, as it seems to work on the data
	if (length(which(both.match)) > 0) {
		title.dash.author.match[both.match] <- FALSE
	}
	neither.match <- !title.by.author.match & !title.dash.author.match
	## extract titles
	all.titles <- rep(NA, length(all.candidates))
	all.titles[title.by.author.match] <- gsub(title.by.author.pattern, "\\1", all.candidates[title.by.author.match], perl = TRUE)
	all.titles[title.dash.author.match] <- gsub(title.dash.author.pattern, "\\1", all.candidates[title.dash.author.match], perl = TRUE)
	## extract authors
	all.authors <- rep(NA, length(all.candidates))
	all.authors[title.by.author.match] <- gsub(title.by.author.pattern, "\\2", all.candidates[title.by.author.match], perl = TRUE)
	all.authors[title.dash.author.match] <- gsub(title.dash.author.pattern, "\\2", all.candidates[title.dash.author.match], perl = TRUE)

	result.df$predicted.title <- all.titles
	result.df$predicted.author <- all.authors

	## glue them back together in standard fashion
	all.merged <- paste(all.titles[!is.na(all.titles)], all.authors[!is.na(all.authors)], sep="!")
	all.merged.withblanks <- rep(NA, length(all.candidates))
	all.merged.withblanks[!neither.match] <- all.merged

	## run multi-step clustering and labeling on the combined "title author" queries
	print("running multistep clustering")
	print("    on combined data")
	all.query <- all.merged.withblanks
	all.query[neither.match] <- as.vector(result.df$original.string, mode = "character")[neither.match]
	result.df <- book.parsing::run.multistep.clustering(result.df, all.query, "combined", cutree.h.combined)
	## run multi-step clustering and labeling on just the titles, and the unmatched patterns
	print("    on titles only")
	title.query <- result.df$predicted.title
	title.query[neither.match] <- as.vector(result.df$original.string, mode = "character")[neither.match]
	result.df <- book.parsing::run.multistep.clustering(result.df, title.query, "title", cutree.h.title)
	## run multi-step clustering and labeling on just the authors, without the unmatched patterns
	print("    on authors only")
	result.df.nomatch <- result.df[neither.match,]
	result.df.withmatch <- result.df[!neither.match,]
	author.query <- result.df.withmatch$predicted.author
	result.df.withmatch <- book.parsing::run.multistep.clustering(result.df.withmatch, author.query, "author", cutree.h.author)
	result.df.nomatch$author.search.input <- NA
	result.df.nomatch$author.consensus.label <- NA
	result.df <- rbind(result.df.withmatch, result.df.nomatch)
	neither.match <- c(neither.match[!neither.match], neither.match[neither.match])
	## time to assign final calls
	## here's the logic:
	## 1) if the original submission matched the query format:
	##   - make sure that the consensus author is the same for all votes with that title
	##   - if not, for now set as unknown
	## 2) if the original submission did not match the query format:
	##   - if the title matched a combined consensus label
	##     - make sure the title only has one author in all other votes
	##     - otherwise this is definitely unknown
	##   - else if the title matched a title consensus label (but no author)
	##     - if there's only one author present for that title label
	##       - assume the title belongs to the author, successful
	##     - otherwise be conservative and say unknown
	##   - otherwise tentatively set as unknown
	print("processing final assignments")
	final.title <- rep(NA, nrow(result.df))
	final.author <- rep(NA, nrow(result.df))
	final.message <- rep(NA, nrow(result.df))
	for (i in seq_len(nrow(result.df))) {
		if (neither.match[i]) {
			if (grepl("!", result.df[i, "combined.consensus.label"])) {
				matched.authors <- result.df[result.df$combined.consensus.label == result.df[i, "combined.consensus.label"], "author.consensus.label"]
				matched.authors <- matched.authors[!is.na(matched.authors)]
				if (length(unique(matched.authors)) == 1) {
					final.title[i] <- gsub("^(.*)!(.*)$", "\\1", result.df[i, "combined.consensus.label"], perl = TRUE)
					final.author[i] <- gsub("^(.*)!(.*)$", "\\2", result.df[i, "combined.consensus.label"], perl = TRUE)
					final.message[i] <- "Success: submission did not match standard formatting, but clustering came up with an unambiguous guess"
				} else {
					final.message[i] <- "Failure: submission did not match standard formatting and while a guess was made, there are conflicting author calls suggesting more than one book with the same or similar name"
				}
			} else if (length(which(!neither.match & result.df$title.consensus.label == result.df[i, "title.consensus.label"])) > 0) {
				matched.authors <- result.df[result.df$title.consensus.label == result.df[i, "title.consensus.label"], "author.consensus.label"]
				matched.authors <- matched.authors[!is.na(matched.authors)]
				if (length(unique(matched.authors)) == 1) {
					final.title[i] <- result.df[i, "title.consensus.label"]
					final.author[i] <- unique(matched.authors)
					final.message[i] <- "Success: submission did not match standard formatting, but title clustering found only a single title/author pair"
				} else {
					final.message[i] <- "Failure: submission did not match standard formatting; title clustering found something, but the author was ambiguous so this is being left blank"
				}
			} else {
				final.message[i] <- "Failure: submission did not match standard formatting and clustering did not resolve the issue"
			}
		} else {
			matched.authors <- result.df[result.df$combined.consensus.label == result.df[i, "combined.consensus.label"], "author.consensus.label"]
			matched.authors <- matched.authors[!is.na(matched.authors)]
			if (length(unique(matched.authors)) == 1) {
				final.title[i] <- result.df$title.consensus.label[i]
				final.author[i] <- result.df$author.consensus.label[i]
				final.message[i] <- "Success: submission format was recognized, harmonization with other votes was successful"
			} else {
				final.message[i] <- "Failure: submission format was recognized but clustering found too many similar votes that still seemed different, so this can't be standardized confidently"
			}
		}
	}
	## apply title case
	print("applying modified title case to labels")
	result.df[,"final.title"] <- book.parsing::apply.standard.case(final.title, TRUE)
	result.df[,"final.author"] <- book.parsing::apply.standard.case(final.author, FALSE)
	## apply user-specified post-NLP replacements if necessary
	if (!is.na(postprocessing.overrides)) {
		print(paste("applying postprocessing overrides from '", postprocessing.overrides, "'", sep=""))
	}
	replaced.data <- book.parsing::apply.posthoc.overrides(result.df$raw.string, result.df$final.title, result.df$final.author, postprocessing.overrides)
	result.df[,"final.title"] <- replaced.data[["title"]]
	result.df[,"final.author"] <- replaced.data[["author"]]
	result.df[,"final.message"] <- final.message
	## if the user has specified a known.matches file, use it to check the results
	if (!is.na(known.matches)) {
		print("running checks versus known good matches")
		book.parsing::check.known.matches(result.df, known.matches)
	}
	## pass handling to separate output formatter
	book.parsing::process.output(result.df, output.prefix, create.summary.data = FALSE)
}
