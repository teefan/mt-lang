## prefer-own-ptr — a `ptr[T]` binding whose every use is inside `unsafe:`.
##
## The host records a *candidate* per local declaration (`record_ptr_candidate`:
## an explicit `ptr[...]` annotation, or a `heap.must_alloc`-family initializer)
## and counts every identifier use by whether it sits inside an `unsafe:` context
## (`track_binding_unsafe_use`); the warning fires at the scope pop when the
## binding is not a parameter, has at least one unsafe use and no safe one.
##
## The state lives here; the linter's walk fills it (a candidate at the local
## declaration, a use at every identifier) and reads it at each scope pop.

import std.str
import std.vec as vec

import mtc.parser.ast as ast

## One binding's use counts (the host's `@binding_ptr_unsafe_uses[name]`).
public struct PtrUse:
    name: str
    safe: ptr_uint
    unsafe: ptr_uint

## The host's `@ptr_candidates` + `@binding_ptr_unsafe_uses`: the candidate
## names, and one use counter per seen name.
public struct PtrState:
    candidates: vec.Vec[str]
    uses: vec.Vec[PtrUse]


extending PtrState:
    public static function create() -> PtrState:
        return PtrState(candidates = vec.Vec[str].create(), uses = vec.Vec[PtrUse].create())


    public editable function release() -> void:
        this.candidates.release()
        this.uses.release()

    ## `record_ptr_candidate`: only a local declaration with an initializer is
    ## a candidate — an explicit `ptr[...]` annotation or a heap allocation
    ## (`heap.must_alloc` and friends).
    public editable function record_local(name: str, stmt_type: ptr[ast.TypeRef]?, value: ptr[ast.Expr]?) -> void:
        if name.len == 0 or value == null:
            return
        # The host's `record_ptr_candidate`: an annotated declaration tests
        # `type_ref_source(...).include?("ptr[")`, but `type_ref_source` returns
        # the *last* name part — always the bare `ptr`/`const_ptr` head — so that
        # test never passes.  Only an unannotated heap allocation or an
        # `alloc_expr`/`alloc_stmt`/`alloc_decl` wrapper records a candidate.
        if stmt_type != null:
            return
        if not (is_heap_alloc(value) or is_alloc_wrapper(value)):
            return
        var i: ptr_uint = 0
        while i < this.candidates.len():
            let cp = this.candidates.get(i) else:
                break
            if unsafe: read(cp).equal(name):
                return
            i += 1
        this.candidates.push(name)

    ## `track_binding_unsafe_use`: every identifier use counts, keyed by name.
    public editable function record_use(name: str, unsafe_depth: ptr_uint) -> void:
        var i: ptr_uint = 0
        while i < this.uses.len():
            let up = this.uses.get(i) else:
                break
            if unsafe: read(up).name.equal(name):
                unsafe:
                    if unsafe_depth > 0:
                        read(up).unsafe += 1
                    else:
                        read(up).safe += 1
                return
            i += 1
        var entry = PtrUse(name = name, safe = 0, unsafe = 0)
        if unsafe_depth > 0:
            entry.unsafe = 1
        else:
            entry.safe = 1
        this.uses.push(entry)

    ## The host's `emit_scope_warnings` gate: `binding_kind != :param &&
    ## uses[:unsafe] > 0 && uses[:safe] == 0 && @ptr_candidates.include?(name)`.
    public function fires(name: str, is_param: bool) -> bool:
        if is_param or not this.has_candidate(name):
            return false
        var i: ptr_uint = 0
        while i < this.uses.len():
            let up = this.uses.get(i) else:
                break
            var u = unsafe: read(up)
            if u.name.equal(name):
                return u.unsafe > 0 and u.safe == 0
            i += 1
        return false


    public function has_candidate(name: str) -> bool:
        var i: ptr_uint = 0
        while i < this.candidates.len():
            let cp = this.candidates.get(i) else:
                break
            if unsafe: read(cp).equal(name):
                return true
            i += 1
        return false


## An explicit `ptr[...]`/`const_ptr[...]` annotation.
## The host's `heap_alloc_call?` / `alloc_wrapper_name`: a `heap.must_alloc…`
## family call, or a call whose callee name wraps one.
function is_heap_alloc(value: ptr[ast.Expr]?) -> bool:
    let vp = value else:
        return false
    unsafe:
        match read(vp):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_member_access as ma:
                        return ma.member_name.equal("must_alloc") or ma.member_name.equal("alloc") or ma.member_name.equal("must_alloc_zeroed") or ma.member_name.equal("must_resize")
                    _:
                        return false
            _:
                return false


## The host's `alloc_wrapper_name`: `alloc_expr(...)`, `alloc_stmt(...)`,
## `alloc_decl(...)` are wrapper calls whose result is a fresh allocation.
function is_alloc_wrapper(value: ptr[ast.Expr]?) -> bool:
    let vp = value else:
        return false
    unsafe:
        match read(vp):
            ast.Expr.expr_call as call:
                match read(call.callee):
                    ast.Expr.expr_identifier as id:
                        return id.name.equal("alloc_expr") or id.name.equal("alloc_stmt") or id.name.equal("alloc_decl")
                    _:
                        return false
            _:
                return false
