module examples.async.runtime_task_pipeline

import std.async as aio
import std.libuv as uv
import std.status as status


function delayed_worker() -> int:
    uv.sleep(uint<-60)
    return 7


async function fetch_with_delay(runtime: aio.Runtime) -> int:
    let timer_task = aio.sleep_on(runtime, 25)
    let payload_task = aio.work_on(runtime, delayed_worker)
    let timer_status = await timer_task
    let payload = await payload_task
    return timer_status + payload + 44


function main() -> int:
    let runtime_result = aio.create_runtime()
    if status.is_err(runtime_result):
        return 1

    match runtime_result:
        status.Status.err:
            return 1
        status.Status.ok as payload:
            var runtime = payload.value

            # Proof 1: work_on must not complete synchronously.
            let probe_task = aio.work_on(runtime, delayed_worker)
            if aio.ready(probe_task):
                aio.finish(probe_task)
                if aio.release_runtime(ref_of(runtime)) != 0:
                    return 2
                return 90

            var probe_pumps = 0
            while not aio.ready(probe_task):
                aio.pump(runtime)
                probe_pumps += 1

            let probe_value = aio.finish(probe_task)
            if probe_pumps == 0:
                if aio.release_runtime(ref_of(runtime)) != 0:
                    return 2
                return 91
            if probe_value != 7:
                if aio.release_runtime(ref_of(runtime)) != 0:
                    return 2
                return 92

            # Proof 2: async function task should begin pending and complete after pumping.
            let task = fetch_with_delay(runtime)
            if aio.ready(task):
                if aio.release_runtime(ref_of(runtime)) != 0:
                    return 2
                return 93

            var pumps = 0
            while not aio.ready(task):
                aio.pump(runtime)
                pumps += 1

            let value = aio.finish(task)
            if pumps == 0:
                if aio.release_runtime(ref_of(runtime)) != 0:
                    return 2
                return 94

            if aio.release_runtime(ref_of(runtime)) != 0:
                return 2
            return value

    return 3
