# In-language tests for the package version/requirement port
# (`lib/milk_tea/packages/version.rb`).
# Run with: mtc test projects/mtc/test/package_version_test.mt

import std.string as string

import mtc.packages.version as version


@[test]
function test_parse_and_compare() -> void:
    let left = version.parse("1.2.3", "package version").expect("1.2.3")
    let right = version.parse("1.10.0", "package version").expect("1.10.0")
    expect(left.major == 1)
    expect(left.minor == 2)
    expect(left.patch == 3)
    expect(left.compare_to(right) < 0)
    expect(left.compare_to(left) == 0)
    var rendered = left.to_string()
    defer: rendered.release()
    expect(rendered.as_str().equal("1.2.3"))


@[test]
function test_rejects_non_semver() -> void:
    match version.parse("1.2", "package version"):
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            expect(
                message.as_str().equal(
                    "package version \"1.2\" must use semantic version format MAJOR.MINOR.PATCH"
                )
            )
        Result.success:
            expect(false, "1.2 should not parse")


@[test]
function test_rejects_leading_zero() -> void:
    expect(version.parse("01.2.3", "package version").is_failure())


@[test]
function test_exact_requirement() -> void:
    var req = version.parse_requirement("1.2.3", "req").expect("exact")
    defer: req.release()
    expect(req.exact())
    let exact = req.exact_version().expect("exact version")
    expect(exact.patch == 3)
    expect(req.matches_text("1.2.3").expect("matches"))
    expect(not req.matches_text("1.2.4").expect("does not match"))


@[test]
function test_range_requirement() -> void:
    var req = version.parse_requirement(">=1.2.3, <2.0.0", "req").expect("range")
    defer: req.release()
    expect(not req.exact())
    expect(req.matches_text("1.2.3").expect("lower bound"))
    expect(req.matches_text("1.9.9").expect("middle"))
    expect(not req.matches_text("1.2.2").expect("below"))
    expect(not req.matches_text("2.0.0").expect("upper bound"))


@[test]
function test_caret_and_tilde() -> void:
    var caret = version.parse_requirement("^1.2.3", "req").expect("caret")
    defer: caret.release()
    expect(caret.matches_text("1.9.9").expect("caret middle"))
    expect(not caret.matches_text("2.0.0").expect("caret upper"))

    var zero_caret = version.parse_requirement("^0.2.3", "req").expect("zero caret")
    defer: zero_caret.release()
    expect(zero_caret.matches_text("0.2.9").expect("zero caret middle"))
    expect(not zero_caret.matches_text("0.3.0").expect("zero caret upper"))

    var tilde = version.parse_requirement("~1.2.3", "req").expect("tilde")
    defer: tilde.release()
    expect(tilde.matches_text("1.2.9").expect("tilde middle"))
    expect(not tilde.matches_text("1.3.0").expect("tilde upper"))


@[test]
function test_requirement_rendering() -> void:
    var req = version.parse_requirement(">=1.2.3, <2.0.0", "req").expect("range")
    defer: req.release()
    var rendered = req.to_string()
    defer: rendered.release()
    expect(rendered.as_str().equal(">=1.2.3, <2.0.0"))


@[test]
function test_empty_segment_rejected() -> void:
    match version.parse_requirement(">=1.2.3,, <2.0.0", "req"):
        Result.failure as failure:
            var message = failure.error
            defer: message.release()
            expect(
                message.as_str().equal(
                    "req \">=1.2.3,, <2.0.0\" contains an empty constraint"
                )
            )
        Result.success:
            expect(false, "empty segment should fail")
