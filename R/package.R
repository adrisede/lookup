#' @importFrom methods .S4methods getMethod isGeneric is methodSignatureMatrix
#' @importFrom stats na.omit setNames
#' @importFrom utils .S3methods capture.output getS3method packageDescription getAnywhere head tail browseURL getSrcFilename getSrcref
#' @importFrom memoise memoise
#' @importFrom highlite highlight_string
#' @useDynLib lookup, .registration = TRUE
#' @importFrom Rcpp sourceCpp
#' @export print.function
NULL

the <- new.env(parent = emptyenv())

as_lookup <- function(x, envir = parent.frame(), ...) {
  UseMethod("as_lookup")
}

as_lookup.lookup <- function(x, envir = parent.frame(), ...) {
  x
}

as_lookup.character <- function(x, envir = parent.frame(), ...) {
  res <- list()
  tryCatch({
    res[c("package", "name")] <- parse_name(x)
    res$def <- get(res$name, envir = res$package %||% envir, mode = "function")
    res$package <- res$package %||% function_package(res$def)
    res$type <- typeof(res$def)
    res$visible <- is_visible(res$name)
  }, error = function(e) NULL)
  class(res) <- "lookup"
  res
}

as_lookup.getAnywhere <- function(x, ...) {

  # getAnywhere can return multiple definitions with the same name in different namespaces
  lapply(which(!x$dups), function(idx) {
    package <- sub("^registered S3 method for [^ ]+ from namespace (\\w+):?.*", "\\1", x$where[[idx]])
    package <- sub("^namespace:", "", package)
    package <- sub("^package:", "", package)
    def <- x$objs[[idx]]
    structure(
      list(
        package = package,
        name = x$name,
        def = def,
        type = typeof(def),
        visible = x$visible[[idx]]),
      class = "lookup")
  })
}

function_package <- function(x) {
  if (is.primitive(x)) {
    return("base")
  }
  e <- topenv(environment(x))
  nme <- environmentName(e)
  if (!nzchar(nme)) {
    stop("Could not find associated package", call. = FALSE)
  }
  nme
}

find_fun_name <- function(x, env) {
  for (name in ls(env, all.names = TRUE)) {
    if (name == ".Last.value") { next }
    if (exists(name, envir = env) &&
      identical(x, get(name, envir = env))) {
      return(name)
    }
  }
  stop("Function does not exist in ", bq(capture.output(print.default(env))), call. = FALSE)
}


as_lookup.function <- function(x, envir = environment(x), name = substitute(x)) {
  res <- list(def = x)

  tryCatch({
    res$package <- function_package(res$def)
    env <- topenv(envir)
    res$name <- find_fun_name(x, env)
    res$type <- typeof(res$def)
    res$visible <- is_visible(res$name)},
    error = function(e) NULL)

  class(res) <- "lookup"
  res
}

as_lookup.MethodDefinition <- function(x, envir = environment(x), name = substitute(x)) {
  res <- list(def = x)

  res$package <- function_package(res$def)
  res$name <- x@generic
  res$type <- typeof(res$def)
  if (!is(res$def, "genericFunction")) {
    res$signature <- methodSignatureMatrix(x)
  }
  res$visible <- TRUE
  class(res) <- "lookup"
  res
}

#' Lookup a function definiton
#'
#' @param x name or definition of a function
#' @param name function name if not given in x
#' @param envir the environment the function was defined in
#' @param all Whether to return just loaded definitions or all definitions
#' @param ... Additional arguments passed to internal functions
#' @aliases print.function
#' @export
lookup <- function(x, name = substitute(x), envir = environment(x) %||% baseenv(), all = FALSE, ...) {
  fun <- as_lookup(x, envir = envir, name = name)

  if (is.null(fun$type)) {
    return(fun$def)
  }

  if (fun$type %in% c("builtin", "special")) {
    fun$internal <- list(lookup_function(fun$name, type = "internal"))
  } else {
    fun$internal <- lapply(call_names(fun$def, type = ".Internal", subset = c(2, 1)), lookup_function, type = "internal")
    fun$external <- lapply(call_names(fun$def, type = ".External", subset = c(2)), lookup_function, type = "external", package = fun$package)
    fun$ccall <- lapply(call_names(fun$def, type = c(".C", ".Call", ".Call2"), subset = c(2)), lookup_function, type = "call", package = fun$package)
  }
  if (uses_rcpp(fun$package)) {
    rcpp_exports <- rcpp_exports(fun$package)
    fun$ccall <- c(fun$ccall, lapply(call_names(fun$def, type = rcpp_exports, subset = c(1)), lookup_function, type = "rcpp", package = fun$package))
  }
  if (isS4(fun$def)) {
    if (is(fun$def, "genericFunction")) {
      fun$type <- append(fun$type, "S4 generic", 0)
      fun$S4_methods <- lookup_S4_methods(fun, envir = envir, all = all)
    } else {
      fun$type <- append(fun$type, "S4 method")
    }
  } else {
    if (is_s3_method(fun$name, env = envir)) {
      fun$type <- append(fun$type, "S3 method", 0)
    }
    if (is_s3_generic(fun$name, env = envir)) {
      fun$type <- append(fun$type, "S3 generic", 0)
      fun$S3_methods <- lookup_S3_methods(fun, envir = envir, all = all)

      # Could also potentially have S4 methods
      if (.isMethodsDispatchOn()) {
        fun$S4_methods <- lookup_S4_methods(fun, envir = envir, all = all)
      }
    }
  }

  the$last_lookup <- fun

  fun
}

loaded_functions <- memoise(function(envs = loadedNamespaces()) {
  fnames <- lapply(envs,
    function(e) ls(envir = asNamespace(e), all.names = TRUE))
  data.frame(name = unlist(fnames),
    package = rep.int(envs, lengths(fnames)),
    stringsAsFactors = FALSE)
})

#' @export
print.function <- function(x, ...) print.lookup(lookup(x, ...))

setMethod("show", "genericFunction", function(object) print(lookup(object)))

parse_name <- function(x) {
  split <- strsplit(x, ":::?")[[1]]
  if (length(split) == 2) {
    list(package = split[[1]],
         name = split[[2]])
  } else {
    list(package = NULL,
         name = split[[1]])
  }
}
`%==%` <- function(x, y) {
  identical(x, as.name(y))
}

lookup_S3_methods <- function(f, envir = parent.frame(), all = FALSE, ...) {

  S3_methods <- suppressWarnings(.S3methods(f$name, envir = envir))
  if (length(S3_methods) == 0) {
    return()
  }

  res <- flatten_list(lapply(S3_methods, function(name) as_lookup(getAnywhere(name))), "lookup")

  pkgs <- vapply(res, `[[`, character(1), "package")
  nms <- vapply(res, `[[`, character(1), "name")
  visible <- vapply(res, `[[`, logical(1), "visible")

  funs <- paste0(pkgs, ifelse(visible, "::", ":::"), nms)

  res <- method_dialog(funs, res, "S3")

  lapply(res, lookup)
}

lookup_S4_methods <- function(f, envir = parent.frame(), all = FALSE, ...) {

  S4_methods <- .S4methods(f$name)
  if (length(S4_methods) == 0) {
    return()
  }

  info <- attr(S4_methods, "info")

  signatures <- strsplit(sub(paste0("^", escape(f$name), ",", "(.*)-method$"), "\\1", S4_methods), ",")

  res <- Map(getMethod, f$name, signatures)

  # Some methods don't have a package in from, so lookup the package from the function definition
  missing_pkg <- !nzchar(info$from)
  info$from[missing_pkg] <- lapply(res[missing_pkg], function(x) getNamespaceName(topenv(environment(x))))

  funs <- paste0(info$from, ifelse(info$visible, "::", ":::"), info$generic, "(", lapply(signatures, paste0, collapse = ", "), ")")

  res <- method_dialog(funs, res, "S4")

  lapply(res, lookup)
}

globalVariables("View", "lookup")

#' @export
print.lookup <-
  local({
    level <- 0

    function(x, ..., envir = parent.frame(), highlight = !in_rstudio() && crayon::has_color(), in_console = getOption("lookup.in_console", rstudioapi::isAvailable())) {
      # Need to evaluate these before the capture.output
      force(x)
      force(highlight)

      # If the object isn't a list fallback to base::print.default
      if (in_completion_function() || !is.list(x) || is.null(x$type)) {
        cat(highlight_output(base::print.function(x), language = "r", highlight), sep = "\n")
        return(invisible(x))
      }

      level <<- level + 1
      on.exit(level <<- level - 1)
      # S4 methods

      str <- capture.output(type = "output", {
        colons <- if (x$visible) "::" else ":::"
        name <- paste0(bold(x$package, colons, x$name, sep = ""), " [", paste(collapse = ", ", x$type), "]")

        filename <- utils::getSrcFilename(x$def)
        if (length(filename) > 0) {
          ref <- utils::getSrcref(x$def)
          name <- paste0(name, " ", crayon::blue(filename, "#L", as.character(ref[[1]]), "-", as.character(ref[[3]]), sep = ""))
        }
        cat(name, "\n")
        if (!is.null(x$signature)) {
          cat("getMethod(\"", x$name, "\", c(", paste0(collapse = ", ", "\"", x$signature[1, ], "\""), "))\n", sep = "")
        }

        def <-
          if (isS4(x$def)) {
            x$def@.Data
          } else {
            x$def
          }

        if (isTRUE(in_console)) {
          View(def, title = name)
        } else {
          cat(highlight_output(base::print.function(def), language = "r", highlight), sep = "\n")
        }
        lapply(x[["internal"]], print, envir = envir, highlight = highlight, in_console = in_console)
        lapply(x[["external"]], print, envir = envir, highlight = highlight, in_console = in_console)
        lapply(x[["ccall"]], print, envir = envir, highlight = highlight, in_console = in_console)
        lapply(x[["S3_methods"]], print, envir = envir, highlight = highlight, in_console = in_console)
        lapply(x[["S4_methods"]], print, envir = envir, highlight = highlight, in_console = in_console)
        invisible()
      })

      if (level == 1 && should_page(str)) {
        page_str(str)
      } else if (!isTRUE(in_console)) {
        cat(str, sep = "\n")
      }

      invisible(x)
    }
  })

escape <- function(x) {
  chars <- c("*", ".", "?", "^", "+", "$", "|", "(", ")", "[", "]", "{", "}", "\\")
  gsub(paste0("([\\", paste0(collapse = "\\", chars), "])"), "\\\\\\1", x, perl = TRUE)
}

highlight_output <- function(code, language = "r", color = TRUE) {
  out <- capture.output(force(code))
  if (isTRUE(color)) {
    # The highlight library uses the same syntax for c and c++
    if (language == "c++") {
      language <- "c"
    }
    highlight_string(out, language = language)
  } else {
    out
  }
}

attached_functions <- memoise(function(sp = search()) {
  fnames <- lapply(seq_along(sp), ls)
  data.frame(name = unlist(fnames),
    package = rep.int(sub("package:", "", sp, fixed = TRUE), lengths(fnames)),
    stringsAsFactors = FALSE)
})

is_visible <- function(x) {
  funs <- attached_functions()
  any(funs$name == x)
}

print.getAnywhere <- function(x, ...) {
  package <- grepl("^package:", x$where)
  namespace <- grepl("^namespace:", x$where)
  defs <- x$objs[namespace]
  name <- if (any(package)) {
    paste0(sub("package:", "", x$where[package]), "::", x$name)
  } else if (any(namespace)) {
    paste0(sub("namespace:", "", x$where[namespace]), ":::", x$name)
  } else {
    x$name
  }

  cat(bold(name), "\n")
  lapply(defs, print)
  invisible()
}

#' Retrieve the source url(s) from a lookup object
#'
#' @param x The object to return the source_url from
#' @param ... Additional arguments passed to methods
#' @export
source_url <- function(x, ...) UseMethod("source_url")

#' @export
source_url.lookup <- function(x = the$last_lookup, ...) {
  stopifnot(inherits(x, "lookup"))

  links <- character()
  for (nme in c("internal", "external", "ccall", "S3_methods", "S4_methods")) {
    links <- append(links, vapply(x[[nme]], source_url, character(1)))
  }
  links
}

#' @export
source_url.compiled <- function(x, ...) {
  if (x$remote_type == "local") {
    x$url
  } else {
    paste0(x$url, "#L", x$start, "-L", x$end)
  }
}

#' Browse a lookup
#'
#' If a github or CRAN lookup, this will open a browser to the github code
#' mirror. If a local file will open the application associated with that file
#' type.
#' @param x The lookup to browse, by default will use the last url of the last lookup found.
#' @export
lookup_browse <- function(x = the$last_lookup) {
  stopifnot(inherits(x, "lookup"))

  browseURL(tail(source_url(x), n = 1))
}
