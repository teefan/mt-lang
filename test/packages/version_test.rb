# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaPackageVersionTest < Minitest::Test
  def test_package_version_parses_and_compares_semantic_versions
    left = MilkTea::PackageVersion.parse("1.2.3")
    right = MilkTea::PackageVersion.parse("1.10.0")

    assert_equal 1, left.major
    assert_equal 2, left.minor
    assert_equal 3, left.patch
    assert left < right
    assert_equal "1.2.3", left.to_s
  end

  def test_package_version_req_parses_exact_requirement
    req = MilkTea::PackageVersionReq.parse("1.2.3")

    assert req.exact?
    assert_equal "1.2.3", req.exact_version.to_s
    assert req.matches?("1.2.3")
    refute req.matches?("1.2.4")
  end

  def test_package_version_req_parses_range_conjunction
    req = MilkTea::PackageVersionReq.parse(">=1.2.3, <2.0.0")

    refute req.exact?
    assert req.matches?("1.2.3")
    assert req.matches?("1.9.9")
    refute req.matches?("1.2.2")
    refute req.matches?("2.0.0")
  end

  def test_package_version_req_expands_caret_requirement
    req = MilkTea::PackageVersionReq.parse("^1.2.3")

    assert req.matches?("1.2.3")
    assert req.matches?("1.9.9")
    refute req.matches?("2.0.0")
  end

  def test_package_version_req_expands_zero_major_caret_requirement
    req = MilkTea::PackageVersionReq.parse("^0.2.3")

    assert req.matches?("0.2.3")
    assert req.matches?("0.2.9")
    refute req.matches?("0.3.0")
  end

  def test_package_version_req_expands_tilde_requirement
    req = MilkTea::PackageVersionReq.parse("~1.2.3")

    assert req.matches?("1.2.3")
    assert req.matches?("1.2.9")
    refute req.matches?("1.3.0")
  end

  def test_package_version_req_rejects_invalid_versions
    error = assert_raises(MilkTea::PackageVersionError) do
      MilkTea::PackageVersionReq.parse("banana")
    end

    assert_match(/semantic version format/, error.message)
  end
end
