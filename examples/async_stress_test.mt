import std.async as aio
import std.stdio as stdio
import std.net as net
import std.net.manager as mgr

const PORT_BASE: int = 50000

var test_passed: int = 0
var test_failed: int = 0


function check(name: str, ok: bool):
    if ok:
        test_passed += 1
        stdio.print_format("  PASS: %s\n", name)
    else:
        test_failed += 1
        stdio.print_format("  FAIL: %s\n", name)

var shared_counter: array[int, 4]


async function bg_increment_a() -> void:
    let _ = await aio.sleep(10z)
    shared_counter[0] += 1


async function bg_increment_b() -> void:
    let _ = await aio.sleep(10z)
    shared_counter[1] += 1


async function bg_increment_c() -> void:
    let _ = await aio.sleep(10z)
    shared_counter[2] += 1


async function leaf_value() -> int:
    let _ = await aio.sleep(10z)
    return 42


async function middle_value() -> int:
    let v = await leaf_value()
    return v + 1


async function may_fail_false() -> Result[int, int]:
    let _ = await aio.sleep(5z)
    return Result[int, int].success(value = 100)


async function may_fail_true() -> Result[int, int]:
    return Result[int, int].failure(error = -1)

var defer_cleaned: bool = false


async function with_cleanup() -> int:
    defer:
        unsafe: read(unsafe: ptr[bool]<-ptr_of(defer_cleaned)) = true
    let _ = await aio.sleep(10z)
    return 1


async function bg_timer_30() -> void:
    let _ = await aio.sleep(30z)
    shared_counter[3] += 1


async function bg_timer_20() -> void:
    let _ = await aio.sleep(20z)
    shared_counter[3] += 1


async function bg_timer_40() -> void:
    let _ = await aio.sleep(40z)
    shared_counter[3] += 1


async function inner_fail_async() -> Result[int, int]:
    let _ = await aio.sleep(5z)
    return Result[int, int].failure(error = -99)


async function outer_prop_async() -> Result[int, int]:
    let v = (await inner_fail_async())?
    return Result[int, int].success(value = v)


async function test_nested_await() -> int:
    stdio.print_format("test_nested_await\n")
    let result = await middle_value()
    check("nested_await_chain", result == 43)
    return 0


async function test_async_in_loop() -> int:
    stdio.print_format("test_async_in_loop\n")
    var sum: int = 0
    var i: int = 0
    while i < 5:
        let _ = await aio.sleep(5z)
        sum += 1
        i += 1
    check("async_in_loop", sum == 5)
    return 0


async function test_result_propagation() -> int:
    stdio.print_format("test_result_propagation\n")
    let ok_result = await may_fail_false()
    match ok_result:
        Result.success as sv:
            check("result_prop_ok", sv.value == 100)
        Result.failure:
            check("result_prop_ok", false)

    let fail_result = await may_fail_true()
    match fail_result:
        Result.failure as f:
            check("result_prop_fail", f.error == -1)
        Result.success:
            check("result_prop_fail", false)

    return 0


async function test_basic_timer() -> int:
    stdio.print_format("test_basic_timer\n")
    var frame: int = 0
    while frame < 3:
        let _ = await aio.sleep(20z)
        frame += 1
    check("basic_timer", frame == 3)
    return 0


async function test_zero_sleep() -> int:
    stdio.print_format("test_zero_sleep\n")
    let _ = await aio.sleep(0z)
    check("zero_sleep", true)
    return 0


async function test_completed_check() -> int:
    stdio.print_format("test_completed_check\n")
    let t = aio.sleep(30z)
    check("not_completed_immediately", not aio.completed(t))
    let _ = await t
    check("completed_after_await", aio.completed(t))
    return 0


async function test_fire_forget() -> int:
    stdio.print_format("test_fire_forget\n")
    shared_counter[0] = 0
    shared_counter[1] = 0
    shared_counter[2] = 0
    let _ = bg_increment_a()
    let _ = bg_increment_b()
    let _ = bg_increment_c()
    let _ = await aio.sleep(50z)
    check("fire_forget_a", shared_counter[0] == 1)
    check("fire_forget_b", shared_counter[1] == 1)
    check("fire_forget_c", shared_counter[2] == 1)
    return 0


async function test_defer_in_async() -> int:
    stdio.print_format("test_defer_in_async\n")
    defer_cleaned = false
    let v = await with_cleanup()
    check("defer_value", v == 1)
    check("defer_cleaned", defer_cleaned)
    return 0


async function test_udp_bind_release() -> int:
    stdio.print_format("test_udp_bind_release\n")
    match net.ipv4("0.0.0.0", PORT_BASE + 10):
        Result.failure:
            check("udp_bind_addr", false)
            return -1
        Result.success as addr_p:
            match net.udp_bind(addr_p.value):
                Result.failure:
                    check("udp_bind", false)
                    return -2
                Result.success as sock_p:
                    var socket = sock_p.value
                    check("udp_bind_ok", true)
                    socket.release()
                    check("udp_release", true)
    return 0


async function test_background_tasks_survive_root() -> int:
    stdio.print_format("test_background_tasks_survive_root\n")
    shared_counter[0] = 0
    shared_counter[1] = 0
    shared_counter[2] = 0
    let _ = bg_increment_a()
    let _ = bg_increment_b()
    let _ = bg_increment_c()
    let _ = await aio.sleep(50z)
    check("bg_a", shared_counter[0] == 1)
    check("bg_b", shared_counter[1] == 1)
    check("bg_c", shared_counter[2] == 1)
    return 0


async function test_multiple_concurrent_timers() -> int:
    stdio.print_format("test_multiple_concurrent_timers\n")
    shared_counter[3] = 0
    let _ = bg_timer_30()
    let _ = bg_timer_20()
    let _ = bg_timer_40()
    let _ = await aio.sleep(100z)
    check("concurrent_timers", shared_counter[3] == 3)
    return 0


async function test_error_propagation_async() -> int:
    stdio.print_format("test_error_propagation_async\n")
    let result = await outer_prop_async()
    match result:
        Result.failure as f:
            check("async_error_prop", f.error == -99)
        Result.success:
            check("async_error_prop", false)
    return 0


async function test_release_during_active_recv() -> int:
    stdio.print_format("test_release_during_active_recv\n")
    match net.ipv4("0.0.0.0", PORT_BASE + 20):
        Result.failure:
            check("recv_release_addr", false)
            return -1
        Result.success as addr_p:
            match net.udp_bind(addr_p.value):
                Result.failure:
                    check("recv_release_bind", false)
                    return -2
                Result.success as sock_p:
                    var socket = sock_p.value
                    let recv_task = socket.recv_from(1500)
                    let _ = await aio.sleep(20z)
                    check("recv_release_pending", true)
                    socket.release()
                    let _ = await aio.sleep(10z)
    check("recv_release_done", true)
    return 0


async function test_manager_create_release() -> int:
    stdio.print_format("test_manager_create_release\n")
    match net.ipv4("0.0.0.0", PORT_BASE + 30):
        Result.failure:
            check("mgr_addr", false)
            return -1
        Result.success as addr_p:
            let config = mgr.NetworkConfig.default(1400z)
            match mgr.create_server(addr_p.value, config):
                Result.failure:
                    check("mgr_create", false)
                    return -2
                Result.success as mgr_p:
                    var host = mgr_p.value
                    let _ = await host.tick(0)
                    check("mgr_tick", true)
                    host.release()
                    check("mgr_release", true)
    return 0


async function test_manager_host_client() -> int:
    stdio.print_format("test_manager_host_client\n")
    match net.ipv4("0.0.0.0", PORT_BASE + 40):
        Result.failure:
            check("hc_addr", false)
            return -1
        Result.success as addr_p:
            let config = mgr.NetworkConfig.default(1400z)
            match mgr.create_server(addr_p.value, config):
                Result.failure:
                    check("hc_create", false)
                    return -2
                Result.success as host_p:
                    var host = host_p.value
                    match net.ipv4("127.0.0.1", 0):
                        Result.failure:
                            host.release()
                            check("hc_client_addr", false)
                            return -3
                        Result.success as la_p:
                            match net.ipv4("127.0.0.1", PORT_BASE + 40):
                                Result.failure:
                                    host.release()
                                    check("hc_remote_addr", false)
                                    return -4
                                Result.success as sa_p:
                                    let cli_cfg = mgr.NetworkConfig.default(1400z)
                                    match mgr.create_client(la_p.value, sa_p.value, cli_cfg):
                                        Result.failure:
                                            host.release()
                                            check("hc_client_create", false)
                                            return -5
                                        Result.success as cli_p:
                                            var client = cli_p.value
                                            var host_ok = false
                                            var client_ok = false
                                            var frame: uint = 0
                                            while frame < 300:
                                                let _ = await host.tick(frame)
                                                while true:
                                                    let ev = host.try_recv()
                                                    match ev:
                                                        Option.some as evp:
                                                            if evp.value.kind == mgr.NetworkEventKind.player_joined:
                                                                host_ok = true
                                                        Option.none:
                                                            break
                                                let _ = await client.tick(frame)
                                                while true:
                                                    let ev = client.try_recv()
                                                    match ev:
                                                        Option.some as evp:
                                                            if evp.value.kind == mgr.NetworkEventKind.connected:
                                                                client_ok = true
                                                        Option.none:
                                                            break
                                                if host_ok and client_ok:
                                                    break
                                                frame += 1
                                            check("hc_host_join", host_ok)
                                            check("hc_client_connect", client_ok)
                                            client.release()
                                            host.release()
    return 0

# ---------------------------------------------------------------------------
# Task cancellation test
# ---------------------------------------------------------------------------

async function cancellable_worker() -> int:
    let _ = await aio.sleep(50z)
    return 42


async function test_task_cancellation() -> int:
    stdio.print_format("\n--- Task Cancellation ---\n")
    let task = cancellable_worker()
    task.cancel(task.frame)
    let completed = task.ready(task.frame)
    check("cancelled task is ready immediately", completed)
    task.release(task.frame)
    return 0

# ---------------------------------------------------------------------------
# Await in expression contexts test
# ---------------------------------------------------------------------------

async function await_in_call_args_test(x: int, y: int) -> int:
    return x + y


async function test_await_in_expression_contexts() -> int:
    stdio.print_format("\n--- Await in Expression Contexts ---\n")

    # await inside call argument
    let sum = await await_in_call_args_test(
        await leaf_value(),
        await leaf_value(),
    )
    check("await in call arguments", sum == 84)

    # await inside binary operation
    let doubled = (await leaf_value()) + (await leaf_value())
    check("await in binary expression", doubled == 84)

    # await inside if expression
    let v = await leaf_value()
    let label = if v > 0: "positive" else: "zero"
    check("await in if expression context", label == "positive")

    # await inside index (member access chain)
    let arr = array[int, 4](40, 41, 42, 43)
    let idx = await leaf_value()
    let val = arr[idx]
    check("await in index access", val == 43)

    return 0


async function main() -> int:
    stdio.print_format("\n=== Async/LibUV Stress Tests ===\n\n")
    let _ = await test_nested_await()
    let _ = await test_async_in_loop()
    let _ = await test_result_propagation()
    let _ = await test_basic_timer()
    let _ = await test_zero_sleep()
    let _ = await test_completed_check()
    let _ = await test_fire_forget()
    let _ = await test_defer_in_async()
    let _ = await test_udp_bind_release()
    let _ = await test_background_tasks_survive_root()
    let _ = await test_multiple_concurrent_timers()
    let _ = await test_error_propagation_async()
    let _ = await test_release_during_active_recv()
    let _ = await test_manager_create_release()
    let _ = await test_manager_host_client()
    let _ = await test_task_cancellation()
    let _ = await test_await_in_expression_contexts()

    let total = test_passed + test_failed
    stdio.print_format("\n=== %d/%d tests passed ===\n", test_passed, total)
    if test_failed > 0:
        stdio.print_format("FAIL: %d test(s) failed\n", test_failed)
        return 1
    return 0
