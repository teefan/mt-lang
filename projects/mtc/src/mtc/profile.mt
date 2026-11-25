## A named-phase timing profile — the host's `Linter::Profile`, shared by the
## formatter's and the linter's `--timings` output.  Phases are recorded in
## first-seen order; `record` accumulates milliseconds and a call count per
## name, and the query helpers reproduce the host's renderings (descending
## totals, one-decimal milliseconds).

import std.fmt as fmt_mod
import std.str
import std.string as string
import std.time
import std.vec as vec

## A profile phase: its name (borrowed — phase names are literals or
## analysis-owned strings) with accumulated milliseconds and call count.
public struct Profile:
    names: vec.Vec[str]
    totals: vec.Vec[double]
    counts: vec.Vec[ptr_uint]

## One `rule.*` phase as the host's `rule_breakdown` renders it: the rule code
## (`rule.prefer_let_else` → `prefer-let-else`), its call count, total, average
## and share of the rule total.
public struct RuleRow:
    code: string.String
    count: ptr_uint
    total_ms: double
    avg_ms: double
    share: double


public function create() -> Profile:
    return Profile(
        names = vec.Vec[str].create(),
        totals = vec.Vec[double].create(),
        counts = vec.Vec[ptr_uint].create(),
    )


public function release(profile: ref[Profile]) -> void:
    profile.names.release()
    profile.totals.release()
    profile.counts.release()


## Milliseconds from the monotonic clock, the shared clock for phase timing.
public function now_ms() -> double:
    var ts = zero[time.TimeSpec]
    let rc = time.monotonic(ref_of(ts))
    if rc != 0:
        return 0.0
    return double<-ts.tv_sec * 1000.0 + double<-ts.tv_nsec / 1000000.0


## Accumulate `ms` into `name` and bump its call count (a no-op without a
## profile, so instrumented sites never branch).
public function record(profile: ptr[Profile]?, name: str, ms: double) -> void:
    let p = profile else:
        return
    var i: ptr_uint = 0
    unsafe:
        while i < read(p).names.len():
            let np = read(p).names.get(i) else:
                break
            if read(np).equal(name):
                let tp = read(p).totals.get(i) else:
                    break
                let cp = read(p).counts.get(i) else:
                    break
                read(tp) = read(tp) + ms
                read(cp) = read(cp) + 1
                return
            i += 1
        read(p).names.push(name)
        read(p).totals.push(ms)
        read(p).counts.push(1)


## The sum of every phase's milliseconds.
public function total_ms(profile: ref[Profile]) -> double:
    var sum: double = 0.0
    var i: ptr_uint = 0
    while i < profile.totals.len():
        let tp = profile.totals.get(i) else:
            break
        sum = sum + unsafe: read(tp)
        i += 1
    return sum


## The summed milliseconds of the phases whose name starts with `prefix`.
public function prefix_total_ms(profile: ref[Profile], prefix: str) -> double:
    var sum: double = 0.0
    var i: ptr_uint = 0
    while i < profile.names.len():
        let np = profile.names.get(i) else:
            break
        if unsafe: read(np).starts_with(prefix):
            let tp = profile.totals.get(i) else:
                break
            sum = sum + unsafe: read(tp)
        i += 1
    return sum


## The phases with a total of at least `min_ms`, by descending total, rendered
## `name: <%.1f>ms` and joined with ", " — the host's `print_file_profiles`
## phase detail.  `include_rule_phases` false skips the `rule.*` phases (the
## lint file-profile block's non-rule detail).  The caller releases the result.
public function phases_desc_text(profile: ref[Profile], min_ms: double, include_rule_phases: bool) -> string.String:
    var order = sorted_indices(profile)
    defer: order.release()
    var text_out = string.String.create()
    var i: ptr_uint = 0
    while i < order.len():
        let idx_ptr = order.get(i) else:
            break
        let idx = unsafe: read(idx_ptr)
        let name_ptr = profile.names.get(idx) else:
            break
        let name = unsafe: read(name_ptr)
        let total_ptr = profile.totals.get(idx) else:
            break
        let total = unsafe: read(total_ptr)
        if (include_rule_phases or not name.starts_with("rule.")) and total >= min_ms:
            if text_out.len() > 0:
                text_out.append(", ")
            text_out.append(name)
            text_out.append(": ")
            fmt_mod.append_double_precision(ref_of(text_out), total, 1)
            text_out.append("ms")
        i += 1
    return text_out


## The non-`rule.` phases with a total of at least `min_ms`, by descending
## total, the first `limit` rendered `<name>:<count>x/<%.1f>ms` and joined
## with ", " — the host's "non-rule hot phases".  The caller releases the
## result.
public function hot_phases_text(profile: ref[Profile], limit: ptr_uint, min_ms: double) -> string.String:
    var order = sorted_indices(profile)
    defer: order.release()
    var text_out = string.String.create()
    var taken: ptr_uint = 0
    var i: ptr_uint = 0
    while i < order.len() and taken < limit:
        let idx_ptr = order.get(i) else:
            break
        let idx = unsafe: read(idx_ptr)
        let name_ptr = profile.names.get(idx) else:
            break
        let name = unsafe: read(name_ptr)
        let total_ptr = profile.totals.get(idx) else:
            break
        let count_ptr = profile.counts.get(idx) else:
            break
        if not name.starts_with("rule.") and unsafe: read(total_ptr) >= min_ms:
            if taken > 0:
                text_out.append(", ")
            text_out.append(name)
            text_out.append_format(f":#{unsafe: read(count_ptr)}x/")
            fmt_mod.append_double_precision(ref_of(text_out), unsafe: read(total_ptr), 1)
            text_out.append("ms")
            taken += 1
        i += 1
    return text_out


## The `rule.*` rows by descending total (at most `limit`, totals >= `min_ms`),
## with the code rendered hyphenated.  The caller releases each row's code and
## the vector.
public function rule_rows(profile: ref[Profile], limit: ptr_uint, min_ms: double) -> vec.Vec[RuleRow]:
    var rows = vec.Vec[RuleRow].create()
    let rule_total = prefix_total_ms(profile, "rule.")
    var order = sorted_indices(profile)
    defer: order.release()
    var i: ptr_uint = 0
    while i < order.len() and rows.len() < limit:
        let idx_ptr = order.get(i) else:
            break
        let idx = unsafe: read(idx_ptr)
        let name_ptr = profile.names.get(idx) else:
            break
        let name = unsafe: read(name_ptr)
        if name.starts_with("rule."):
            let total_ptr = profile.totals.get(idx) else:
                break
            let count_ptr = profile.counts.get(idx) else:
                break
            let total = unsafe: read(total_ptr)
            let count = unsafe: read(count_ptr)
            if total >= min_ms:
                var code = string.String.create()
                var ci: ptr_uint = 5
                while ci < name.len:
                    let b = name.byte_at(ci)
                    if b == 95:
                        code.push_byte(45)
                    else:
                        code.push_byte(b)
                    ci += 1
                var avg = total
                if count > 0:
                    avg = total / double<-count
                var share: double = 0.0
                if rule_total > 0.0:
                    share = total / rule_total * 100.0
                rows.push(RuleRow(code = code, count = count, total_ms = total, avg_ms = avg, share = share))
        i += 1
    return rows


## Indices into the profile ordered by descending total (insertion sort; the
## phase counts are small).
function sorted_indices(profile: ref[Profile]) -> vec.Vec[ptr_uint]:
    var order = vec.Vec[ptr_uint].create()
    var i: ptr_uint = 0
    while i < profile.totals.len():
        let total_ptr = profile.totals.get(i) else:
            break
        let entry_total = unsafe: read(total_ptr)
        order.push(i)
        var j = i
        while j > 0:
            let prev_ptr = order.get(j - 1) else:
                break
            let prev_index = unsafe: read(prev_ptr)
            let prev_total_ptr = profile.totals.get(prev_index) else:
                break
            if unsafe: read(prev_total_ptr) >= entry_total:
                break
            let cur_ptr = order.get(j) else:
                break
            unsafe:
                read(cur_ptr) = prev_index
            j -= 1
        let slot_ptr = order.get(j) else:
            break
        unsafe:
            read(slot_ptr) = i
        i += 1
    return order
