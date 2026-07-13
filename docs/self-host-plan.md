# Self-Host Plan: Path to 100% Ruby Parity

Status: **13/13 examples compile. 172/172 tests pass. P1-P51 DONE. Async no-await gap identified.**
Last updated: 2026-07-13

---

## 0. Current State

### 0.1 Compilation

| Example | C Errors |
|---------|:---:|
| `language_baseline.mt` | 0 |
| `integration_test.mt` | 0 |
| `string_test.mt` | 0 |
| `data_structures.mt` | 0 |
| `memory_stress_test.mt` | 0 |
| `multithreading_test.mt` | 0 |
| `option_and_result_surface.mt` | 0 |
| `nested_struct_stress_test.mt` | 0 |
| `nullable_and_variant_test.mt` | 0 |
| `event_stress_test.mt` | 0 |
| `reflection_advanced.mt` | 0 |
| `async_stress_test.mt` | 0 |
| `async_network_lobby.mt` | 0 |

172/172 self-tests pass. All planned fixes P1-P51 implemented.

### 0.2 Verification

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current test projects/mtc -I .                  # 172/172
tmp/mtc-current build examples/async_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"  # 2 (linker, 0 C errors)
tmp/mtc-current build examples/async_network_lobby.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"  # 2 (linker, 0 C errors)
```

---

## 1. Remaining Work: Async No-Await Lowering Gap

### 1.1 Problem

The self-host has two code paths for async functions in `lower_async_fn`:

- **`has_await = true`** (functions containing `await`): Generates full CPS lowering — frame struct, resume function with CPS state machine, vtable functions (ready/set_waiter/release/take_result/cancel), and a constructor that allocates the frame, calls resume, and returns a proper Task aggregate with vtable pointers.

- **`has_await = false`** (functions WITHOUT `await`): Generates a degenerate output — the function body is lowered inline with a `return (mt_task_void){0}` stub. No frame struct, no vtable, no constructor.

### 1.2 Evidence

Self-host IR for `async function bg_increment_a()` (no awaits):

```
fn bg_increment_a as examples_async_stress_test_bg_increment_a() -> Task[void]:
    checked_index<array[int, 4]>(examples_async_stress_test_shared_counter, 0) += 1
```

Generated C from self-host:

```c
static mt_task_void examples_async_stress_test_bg_increment_a(void) {
  (*mt_checked_index_array_int_4(&examples_async_stress_test_shared_counter, 0)) += 1;
}
```

Generated C from Ruby (correct):

```c
static mt_task_void examples_async_stress_test_bg_increment_a(void) {
  __mt_frame = mt_async_alloc(sizeof(frame));
  resume((void*)__mt_frame);
  return (mt_task_void){
    .frame = __mt_frame,
    .ready = examples_async_stress_test_bg_increment_a__ready,
    .set_waiter = examples_async_stress_test_bg_increment_a__set_waiter,
    .release = examples_async_stress_test_bg_increment_a__release,
    .cancel = examples_async_stress_test_bg_increment_a__cancel,
  };
}
```

### 1.3 Impact

Every async function without `await` produces a structurally invalid Task object:
- No `.frame` pointer (null/bogus)
- No vtable function pointers
- No resume function to drive completion
- Any `await` on these tasks would crash or produce undefined behavior

### 1.4 Root Cause

In `lower_async_fn` (line 13633+, `has_await = false` path):
1. The body is lowered with `lower_function_body(ctx, body)` producing inline IR
2. A goto-based return epilogue is appended
3. The resume function is pushed with THIS body (the inline logic)
4. The constructor is pushed with the correct body (frame allocation + resume call + Task return)

But the IR/code that reaches the C backend contains ONLY the inline body — the constructor's frame-allocating body is lost. The `name` function pushed at line 13767 (the constructor) appears to be overridden by a different code path, or the C backend's reachability pruning selects the wrong function.

**Investigation needed**: Determine which code path overwrites the constructor function with the inline body.

### 1.5 Fix Approach

The Ruby compiler treats ALL async functions uniformly: every async function gets a frame struct, resume function, vtable, and constructor. A function with 0 awaits has a single-state CPS machine that immediately reaches the completion epilogue.

The fix should:
1. Remove the `has_await`/no-await split — use the full CPS path for ALL async functions
2. Ensure the `name` function pushed by `lower_async_fn` (the constructor) is not overridden
3. For no-await functions, `lower_async_cps_body` processes the body with 0 await points, creating a single state that contains the full body followed by the completion epilogue

### 1.6 Files

- `projects/mtc/src/mtc/lowering/lowering.mt` — `lower_async_fn` (lines 13548-13767)
- Ruby reference: `lib/milk_tea/core/lowering/async/` — `AsyncLowering`
