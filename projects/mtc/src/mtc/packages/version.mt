## Package semantic versions and requirements — the self-host port of
## `lib/milk_tea/packages/version.rb` (`PackageVersion` and
## `PackageVersionReq`), message-for-message.

import std.str
import std.string as string
import std.vec as vec


public struct PackageVersion:
    major: ptr_uint
    minor: ptr_uint
    patch: ptr_uint


public enum VersionOperator: ubyte
    eq = 0
    gt = 1
    gte = 2
    lt = 3
    lte = 4


public struct VersionConstraint:
    operator: VersionOperator
    version: PackageVersion


public struct PackageVersionReq:
    constraints: vec.Vec[VersionConstraint]


extending PackageVersion:
    public function to_string() -> string.String:
        return string.String.from_str(f"#{this.major}.#{this.minor}.#{this.patch}")

    public function compare_to(other: PackageVersion) -> int:
        if this.major < other.major:
            return -1
        if this.major > other.major:
            return 1
        if this.minor < other.minor:
            return -1
        if this.minor > other.minor:
            return 1
        if this.patch < other.patch:
            return -1
        if this.patch > other.patch:
            return 1
        return 0


extending VersionConstraint:
    public function matches(candidate: PackageVersion) -> bool:
        let order = candidate.compare_to(this.version)
        match this.operator:
            VersionOperator.eq:
                return order == 0
            VersionOperator.gt:
                return order > 0
            VersionOperator.gte:
                return order >= 0
            VersionOperator.lt:
                return order < 0
            VersionOperator.lte:
                return order <= 0
        return false

    public function to_string() -> string.String:
        var prefix: str = ""
        match this.operator:
            VersionOperator.eq:
                prefix = "="
            VersionOperator.gt:
                prefix = ">"
            VersionOperator.gte:
                prefix = ">="
            VersionOperator.lt:
                prefix = "<"
            VersionOperator.lte:
                prefix = "<="
        var result = string.String.create()
        result.append(prefix)
        var version_text = this.version.to_string()
        defer: version_text.release()
        result.append(version_text.as_str())
        return result


extending PackageVersionReq:
    public function exact() -> bool:
        if this.constraints.len() != 1:
            return false
        let first = this.constraints.get(0) else:
            return false
        return unsafe: read(first).operator == VersionOperator.eq

    public function exact_version() -> Option[PackageVersion]:
        if not this.exact():
            return Option[PackageVersion].none
        let first = this.constraints.get(0) else:
            return Option[PackageVersion].none
        return Option[PackageVersion].some(value = unsafe: read(first).version)

    public function matches_text(value: str) -> Result[bool, string.String]:
        match parse(value, "package version"):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success as parsed:
                return Result[bool, string.String].success(value = this.matches(parsed.value))

    public function matches(candidate: PackageVersion) -> bool:
        var i: ptr_uint = 0
        while i < this.constraints.len():
            let constraint = this.constraints.get(i) else:
                break
            if not unsafe: read(constraint).matches(candidate):
                return false
            i += 1
        return true

    public function to_string() -> string.String:
        var result = string.String.create()
        var i: ptr_uint = 0
        while i < this.constraints.len():
            if i > 0:
                result.append(", ")
            let constraint = this.constraints.get(i) else:
                break
            var rendered = unsafe: read(constraint).to_string()
            result.append(rendered.as_str())
            rendered.release()
            i += 1
        return result

    public editable function release() -> void:
        this.constraints.release()


## Ruby's `String#inspect` for the version labels the host interpolates; version
## requirement text is a plain single-line string, so quoting plus the common
## escapes is enough.
public function inspect_text(text: str) -> string.String:
    var result = string.String.create()
    result.push_byte('"')
    var i: ptr_uint = 0
    while i < text.len:
        let byte_value = text.byte_at(i)
        if byte_value == 92:
            result.append("\\\\")
        else if byte_value == 34:
            result.append("\\\"")
        else if byte_value == 10:
            result.append("\\n")
        else if byte_value == 13:
            result.append("\\r")
        else if byte_value == 9:
            result.append("\\t")
        else:
            result.push_byte(byte_value)
        i += 1
    result.push_byte('"')
    return result


function version_error(message: string.String) -> Result[PackageVersion, string.String]:
    return Result[PackageVersion, string.String].failure(error = message)


function digit(value: ubyte) -> bool:
    return value >= 48 and value <= 57


## `/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/` with the host's error text.
public function parse(value: str, label: str) -> Result[PackageVersion, string.String]:
    let text = value.trim_ascii_whitespace()
    if text.len == 0:
        var message = string.String.from_str(label)
        message.append(" cannot be empty")
        return version_error(message)

    var parts = array[ptr_uint, 4](0, 0, 0, text.len)
    var part_count: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text.len:
        if i == text.len or text.byte_at(i) == 46:
            if part_count >= 4:
                break
            parts[part_count] = i
            part_count += 1
        i += 1

    # Three numeric components exactly: two dots, no dot at either end and no
    # empty component (the array above splits on '.').
    var valid = part_count == 3 and text.byte_at(0) != 46 and text.byte_at(text.len - 1) != 46
    var major: ptr_uint = 0
    var minor: ptr_uint = 0
    var patch: ptr_uint = 0
    if valid:
        let dot_one = parts[0]
        let dot_two = parts[1]
        let major_text = text.slice(0, dot_one)
        let minor_text = text.slice(dot_one + 1, dot_two - dot_one - 1)
        let patch_text = text.slice(dot_two + 1, text.len - dot_two - 1)
        valid = valid_component(major_text) and valid_component(minor_text) and valid_component(patch_text)
        if valid:
            major = parse_component(major_text)
            minor = parse_component(minor_text)
            patch = parse_component(patch_text)

    if not valid:
        var message = string.String.from_str(label)
        message.append(" ")
        var inspected = inspect_text(text)
        message.append(inspected.as_str())
        inspected.release()
        message.append(" must use semantic version format MAJOR.MINOR.PATCH")
        return version_error(message)

    return Result[PackageVersion, string.String].success(
        value = PackageVersion(major = major, minor = minor, patch = patch)
    )


function valid_component(text: str) -> bool:
    if text.len == 0:
        return false
    if text.byte_at(0) == 48:
        return text.len == 1
    var i: ptr_uint = 0
    while i < text.len:
        if not digit(text.byte_at(i)):
            return false
        i += 1
    return true


function parse_component(text: str) -> ptr_uint:
    var result: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        result = result * 10 + ptr_uint<-(text.byte_at(i) - 48)
        i += 1
    return result


function requirement_error(message: string.String) -> Result[PackageVersionReq, string.String]:
    return Result[PackageVersionReq, string.String].failure(error = message)


function segment_error(label: str, text: str, suffix: str) -> Result[PackageVersionReq, string.String]:
    var message = string.String.from_str(label)
    message.append(" ")
    var inspected = inspect_text(text)
    message.append(inspected.as_str())
    inspected.release()
    message.append(suffix)
    return requirement_error(message)


## Parse a comma-separated requirement: `1.2.3`, `>=1.2.3, <2.0.0`, `^1.2.3`,
## `~1.2.3` (the host's `PackageVersionReq.parse`).
public function parse_requirement(value: str, label: str) -> Result[PackageVersionReq, string.String]:
    let text = value.trim_ascii_whitespace()
    if text.len == 0:
        var message = string.String.from_str(label)
        message.append(" cannot be empty")
        return requirement_error(message)

    var constraints = vec.Vec[VersionConstraint].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= text.len:
        if i == text.len or text.byte_at(i) == 44:
            let raw_segment = text.slice(start, i - start)
            let segment = raw_segment.trim_ascii_whitespace()
            if segment.len == 0:
                constraints.release()
                return segment_error(label, text, " contains an empty constraint")
            match parse_segment_pair(segment, label, ref_of(constraints)):
                Result.failure as failure:
                    constraints.release()
                    return Result[PackageVersionReq, string.String].failure(error = failure.error)
                Result.success:
                    pass
            start = i + 1
        i += 1

    if constraints.len() == 0:
        constraints.release()
        return segment_error(label, text, " contains an empty constraint")

    return Result[PackageVersionReq, string.String].success(
        value = PackageVersionReq(constraints = constraints)
    )


function parse_segment_pair(segment: str, label: str, out_constraints: ref[vec.Vec[VersionConstraint]]) -> Result[bool, string.String]:
    if segment.starts_with("^"):
        let version_text = segment.slice(1, segment.len - 1)
        match parse(version_text, label):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success as parsed:
                let version = parsed.value
                out_constraints.push(VersionConstraint(operator = VersionOperator.gte, version = version))
                out_constraints.push(VersionConstraint(operator = VersionOperator.lt, version = caret_upper_bound(version)))
                return Result[bool, string.String].success(value = true)
    if segment.starts_with("~"):
        let version_text = segment.slice(1, segment.len - 1)
        match parse(version_text, label):
            Result.failure as failure:
                return Result[bool, string.String].failure(error = failure.error)
            Result.success as parsed:
                let version = parsed.value
                out_constraints.push(VersionConstraint(operator = VersionOperator.gte, version = version))
                out_constraints.push(VersionConstraint(operator = VersionOperator.lt, version = tilde_upper_bound(version)))
                return Result[bool, string.String].success(value = true)

    # `>=|<=|>|<|=` optionally followed by whitespace, else an exact version.
    var operator = VersionOperator.eq
    var version_start: ptr_uint = 0
    if segment.len >= 2 and segment.byte_at(0) == 62 and segment.byte_at(1) == 61:
        operator = VersionOperator.gte
        version_start = 2
    else if segment.len >= 2 and segment.byte_at(0) == 60 and segment.byte_at(1) == 61:
        operator = VersionOperator.lte
        version_start = 2
    else if segment.len >= 1 and segment.byte_at(0) == 62:
        operator = VersionOperator.gt
        version_start = 1
    else if segment.len >= 1 and segment.byte_at(0) == 60:
        operator = VersionOperator.lt
        version_start = 1
    else if segment.len >= 1 and segment.byte_at(0) == 61:
        operator = VersionOperator.eq
        version_start = 1

    var version_text = segment.slice(version_start, segment.len - version_start)
    version_text = version_text.trim_ascii_whitespace()
    match parse(version_text, label):
        Result.failure as failure:
            return Result[bool, string.String].failure(error = failure.error)
        Result.success as parsed:
            out_constraints.push(VersionConstraint(operator = operator, version = parsed.value))
            return Result[bool, string.String].success(value = true)


function caret_upper_bound(version: PackageVersion) -> PackageVersion:
    if version.major > 0:
        return PackageVersion(major = version.major + 1, minor = 0, patch = 0)
    if version.minor > 0:
        return PackageVersion(major = 0, minor = version.minor + 1, patch = 0)
    return PackageVersion(major = 0, minor = 0, patch = version.patch + 1)


function tilde_upper_bound(version: PackageVersion) -> PackageVersion:
    return PackageVersion(major = version.major, minor = version.minor + 1, patch = 0)
