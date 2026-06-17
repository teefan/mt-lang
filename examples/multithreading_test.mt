import std.stdio

const SIZE: int = 1000

var atomic_counter: atomic[int]
var fork_result_a: int = 0
var fork_result_b: int = 0


function fill_via_span(data: span[int], count: int, multiplier: int) -> void:
    parallel for i in 0..count:
        data[i] = int<-i * multiplier


function compute_a() -> void:
    var sum = 0
    for i in 0..500:
        sum += int<-i

    fork_result_a = sum


function compute_b() -> void:
    var sum = 0
    for i in 500..1000:
        sum += int<-i

    fork_result_b = sum


function increment_many(n: int) -> void:
    for _ in 0..n:
        atomic_counter.add(1)


function run_tests() -> int:
    var failures = 0
    var buf: array[int, 1000]

    fill_via_span(buf.as_span(), SIZE, 3)

    for i in 0..SIZE:
        if buf[i] != int<-i * 3:
            failures += 1

    if failures > 0:
        stdio.print_string("FAIL: parallel for")
        return failures

    stdio.print_string("  pass: parallel for — span capture, 1000 elements verified")

    parallel:
        compute_a()
        compute_b()

    let total = fork_result_a + fork_result_b

    if total != 499500:
        stdio.print_string("FAIL: parallel block")
        return 1

    stdio.print_string("  pass: parallel block — fork-join computation correct")

    atomic_counter.store(0)

    let a = detach increment_many(5000)
    let b = detach increment_many(5000)
    gather a, b

    let counter_value = atomic_counter.load()
    if counter_value != 10000:
        stdio.print_string("FAIL: detach + gather")
        return 1

    stdio.print_string("  pass: detach + gather — concurrent increments correct")

    return 0


function main() -> int:
    stdio.print_string("multithreading tests:")

    let result = run_tests()
    if result == 0:
        stdio.print_string("all passed")

    return result
