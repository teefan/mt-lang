## Imported bindings naming transforms — snake_case, camelize, renaming rules,
## strip_prefix, and reserved-word sanitization.  Each function is pure and
## stateless, taking borrowed str inputs and returning owned string.String.

import std.string as string
import std.str

# =============================================================================
#  Core transforms
# =============================================================================

## Convert CamelCase to snake_case: "HelloWorld" -> "hello_world".
public function snake_case(name: str) -> string.String:
    var result = string.String.with_capacity(name.len + 8)
    var i: ptr_uint = 0
    var prev_lower: bool = false

    while i < name.len:
        let ch = name.byte_at(i)
        let is_upper = ch >= 65 and ch <= 90
        let is_lower = ch >= 97 and ch <= 122
        let is_digit = ch >= 48 and ch <= 57

        if is_upper:
            if prev_lower:
                result.push_byte('_')
            if ch >= 65 and ch <= 90:
                result.push_byte(ch + 32)
            else:
                result.push_byte(ch)
        else if is_lower or is_digit:
            if i > 0 and is_digit and prev_lower:
                result.push_byte('_')
            result.push_byte(ch)
        else:
            result.push_byte(ch)

        prev_lower = is_lower
        i += 1

    return result


## Convert snake_case to CamelCase: "hello_world" -> "HelloWorld".
public function camelize(name: str) -> string.String:
    var result = string.String.with_capacity(name.len)
    var next_upper: bool = true
    var i: ptr_uint = 0

    while i < name.len:
        let ch = name.byte_at(i)
        if ch == '_':
            next_upper = true
            i += 1
            continue

        if next_upper:
            if ch >= 97 and ch <= 122:
                result.push_byte(ch - 32)
            else:
                result.push_byte(ch)
            next_upper = false
        else:
            if ch >= 65 and ch <= 90:
                result.push_byte(ch + 32)
            else:
                result.push_byte(ch)

        i += 1

    return result


## Strip a prefix from a name if matched.  Returns a borrowed str view — the
## original text must outlive it.  If the prefix doesn't match, returns the
## original text unchanged.
public function strip_prefix_str(name: str, prefix: str) -> str:
    if prefix.len == 0:
        return name
    if prefix.len > name.len:
        return name
    if not name.starts_with(prefix):
        return name
    return name.slice(prefix.len, name.len - prefix.len)


# =============================================================================
#  Rename rule application
# =============================================================================

## Apply a single rename rule to a name and return the transformed string.
public function apply_rename_rule(name: str, kind: str, pattern: str, replace_with: str) -> string.String:
    if kind.equal("prefix"):
        if name.starts_with(pattern):
            let suffix = name.slice(pattern.len, name.len - pattern.len)
            var r = string.String.with_capacity(replace_with.len + suffix.len)
            r.append(replace_with)
            r.append(suffix)
            return r
        return string.String.from_str(name)

    if kind.equal("replace"):
        # Simple string replace — handles common cases
        var r = string.String.with_capacity(name.len)
        let pattern_len = pattern.len
        if pattern_len == 0:
            return string.String.from_str(name)
        var idx = name.find_substring(pattern)
        match idx:
            Option.none:
                return string.String.from_str(name)
            Option.some as pos:
                if pos.value != 0:
                    r.append(name.slice(0, pos.value))
                r.append(replace_with)
                if pos.value + pattern_len < name.len:
                    r.append(name.slice(pos.value + pattern_len, name.len - pos.value - pattern_len))
                return r

    if kind.equal("camelize"):
        return camelize(name)

    return string.String.from_str(name)


## Apply a sequence of rename rules.  Rules are applied in order, each
## operating on the output of the previous rule.
public function apply_rename_rules(
    name: str,
    rule_kinds: span[str],
    rule_patterns: span[str],
    rule_replacements: span[str],
) -> string.String:
    var current = string.String.from_str(name)
    var i: ptr_uint = 0
    while i < rule_kinds.len:
        let kind = unsafe: read(rule_kinds.data + i)
        let pattern = if i < rule_patterns.len: unsafe: read(rule_patterns.data + i) else: ""
        let replacement = if i < rule_replacements.len: unsafe: read(rule_replacements.data + i) else: ""
        var next = apply_rename_rule(current.as_str(), kind, pattern, replacement)
        current.release()
        current = next
        i += 1
    return current


# =============================================================================
#  Reserved-word sanitization
# =============================================================================

## Check whether a name conflicts with MT keywords or reserved type names.
## Returns true if the name needs a trailing `_` appended.
public function is_reserved_name(name: str) -> bool:
    # Milk Tea keywords
    if name.equal("and"): return true
    if name.equal("or"): return true
    if name.equal("not"): return true
    if name.equal("is"): return true
    if name.equal("in"): return true
    if name.equal("out"): return true
    if name.equal("inout"): return true
    if name.equal("external"): return true
    if name.equal("foreign"): return true
    if name.equal("function"): return true
    if name.equal("static"): return true
    if name.equal("editable"): return true
    if name.equal("async"): return true
    if name.equal("type"): return true
    if name.equal("struct"): return true
    if name.equal("union"): return true
    if name.equal("enum"): return true
    if name.equal("flags"): return true
    if name.equal("variant"): return true
    if name.equal("opaque"): return true
    if name.equal("interface"): return true
    if name.equal("extending"): return true
    if name.equal("const"): return true
    if name.equal("var"): return true
    if name.equal("let"): return true
    if name.equal("if"): return true
    if name.equal("else"): return true
    if name.equal("match"): return true
    if name.equal("while"): return true
    if name.equal("for"): return true
    if name.equal("break"): return true
    if name.equal("continue"): return true
    if name.equal("return"): return true
    if name.equal("defer"): return true
    if name.equal("emit"): return true
    if name.equal("unsafe"): return true
    if name.equal("pass"): return true
    if name.equal("null"): return true
    if name.equal("true"): return true
    if name.equal("false"): return true
    if name.equal("public"): return true
    if name.equal("import"): return true
    if name.equal("when"): return true
    if name.equal("inline"): return true
    if name.equal("parallel"): return true
    if name.equal("await"): return true
    if name.equal("detach"): return true
    if name.equal("gather"): return true
    if name.equal("event"): return true
    if name.equal("ref"): return true
    # Reserved primitive type names
    if name.equal("int"): return true
    if name.equal("uint"): return true
    if name.equal("byte"): return true
    if name.equal("ubyte"): return true
    if name.equal("short"): return true
    if name.equal("ushort"): return true
    if name.equal("long"): return true
    if name.equal("ulong"): return true
    if name.equal("float"): return true
    if name.equal("double"): return true
    if name.equal("bool"): return true
    if name.equal("char"): return true
    if name.equal("str"): return true
    if name.equal("cstr"): return true
    if name.equal("void"): return true
    if name.equal("ptr"): return true
    if name.equal("const_ptr"): return true
    if name.equal("own"): return true
    if name.equal("span"): return true
    if name.equal("array"): return true
    if name.equal("fn"): return true
    if name.equal("proc"): return true
    if name.equal("ptr_int"): return true
    if name.equal("ptr_uint"): return true
    if name.equal("vec2"): return true
    if name.equal("vec3"): return true
    if name.equal("vec4"): return true
    if name.equal("ivec2"): return true
    if name.equal("ivec3"): return true
    if name.equal("ivec4"): return true
    if name.equal("mat3"): return true
    if name.equal("mat4"): return true
    if name.equal("quat"): return true
    return false


## Sanitize a generated binding name.  If the name is a reserved word,
## append an underscore.
public function sanitize_binding_name(name: str) -> string.String:
    if is_reserved_name(name):
        var r = string.String.from_str(name)
        r.push_byte('_')
        return r
    return string.String.from_str(name)
