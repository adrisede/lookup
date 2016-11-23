context("call")

test_that("has_call works", {
  # non_function arguments just return FALSE
  expect_false(has_call("blah"))

  # types that don't exist in the function return FALSE
  expect_false(has_call(identical, "wrong"))

  expect_true(has_call(identical, ".Internal"))
})

test_that("call_name works", {
  expect_equal(call_name(identical, "wrong"), character(0))

  expect_equal(call_name(identical, ".Internal"), "identical")

  expect_equal(call_name(print.default, ".Internal"), "print.default")
})

with_local_package("TestRcpp", {
  context("local-call")

  s <- NULL
  test_that("fetch_symbol_map", {
    s <<- as.source_type("TestRcpp", "call", "add_call_impl")
    expect_equal(class(s), c("call_local", "call", "local"))

    s <<- fetch_symbol_map(s)
    expect_true(length(s$map_lines) > 1)

    expect_error(as.source_type("missing", "call"), "no package 'missing' was found")
  })

  test_that("parse_symbol_map", {
    s <<- parse_symbol_map(s)
    expect_true(length(s$map) > 1)
  })

  test_that("source_files", {
    s <<- source_files(s)
    expect_equal(basename(s$src_files), "add.c")
  })

  test_that("fetch_source", {
    s <<- fetch_source(s, s$src_files[[1]])
    expect_true(length(s$src_lines) > 1)
  })

  test_that("parse_source", {
    s <<- parse_source(s, s$map[s$search])
    expect_true(length(s$fun_lines) > 1)

    expect_true(s$fun_start > 1)
    expect_true(s$fun_end > s$fun_start)
  })

  test_that("lookup_function", {
    res <- lookup_function("add_call_impl", "call", "TestRcpp")

    expect_true(nchar(res$content) > 0)
    expect_equal(res$remote_type, "local")
    expect_equal(res$type, "call")
    expect_equal(res$language, "c")

    expect_null(lookup_function("missing", "call", "TestRcpp"))
  })
})