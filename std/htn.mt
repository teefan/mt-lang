## Hierarchical Task Network (HTN) planner.
##
## Total-order forward decomposition. Define a domain of operators
## (primitive tasks) and methods (compound task decompositions),
## then plan from a root task with an initial world state.
##
##   import std.htn as htn
##   var planner = htn.HtnPlanner[World, Context].create()
##   planner.add_operator(...)
##   planner.add_method(...)
##   var result = planner.plan(ref_of(ctx), world, "root_task")
##   match result.plan:
##       Option.some as p: execute(p.value)
##       Option.none: handle failure

import std.vec as vec


public enum HtnStatus: ubyte
    success = 0
    failure = 1
    max_depth = 2
    max_iterations = 3


public struct HtnOperator[World, Context]:
    name: str
    precondition: fn(context: ptr[Context], world: World) -> bool
    effect: fn(context: ptr[Context], world: World) -> World


public struct HtnMethod[World, Context]:
    name: str
    task: str
    precondition: fn(context: ptr[Context], world: World) -> bool
    subtasks: vec.Vec[str]


public struct HtnDomain[World, Context]:
    operators: vec.Vec[HtnOperator[World, Context]]
    methods: vec.Vec[HtnMethod[World, Context]]


public struct HtnPlanStep:
    task_name: str


public struct HtnPlan[World]:
    steps: vec.Vec[HtnPlanStep]
    final_world: World


public struct HtnResult[World]:
    status: HtnStatus
    plan: Option[HtnPlan[World]]
    iterations: ptr_uint
    depth: ptr_uint


public struct HtnPlanner[World, Context]:
    domain: HtnDomain[World, Context]
    max_depth: ptr_uint
    max_iterations: ptr_uint


# ── planner entry point ──

function plan_task[World, Context](
    planner: ref[HtnPlanner[World, Context]],
    context: ptr[Context],
    world: World,
    task: str,
    depth: ptr_uint,
    iterations: ptr[ptr_uint],
    reason: ptr[HtnStatus]
) -> Option[HtnPlan[World]]:
    unsafe:
        read(iterations) += 1
    if depth >= planner.max_depth:
        unsafe:
            if read(reason) != HtnStatus.max_iterations:
                read(reason) = HtnStatus.max_depth
        return Option[HtnPlan[World]].none
    if unsafe: read(iterations) >= planner.max_iterations:
        unsafe:
            read(reason) = HtnStatus.max_iterations
        return Option[HtnPlan[World]].none

    # Try operators (primitive tasks)
    for entry in planner.domain.operators:
        unsafe:
            let op = read(entry)
            if op.name == task:
                if op.precondition(context, world):
                    var steps = vec.Vec[HtnPlanStep].create()
                    steps.push(HtnPlanStep(task_name = task))
                    let result_world = op.effect(context, world)
                    return Option[HtnPlan[World]].some(value =
                        HtnPlan[World](steps = steps, final_world = result_world)
                    )

    # Try methods (compound task decompositions)
    for entry in planner.domain.methods:
        unsafe:
            let method = read(entry)
            if method.task == task and method.precondition(context, world):
                var current_world = world
                var all_steps = vec.Vec[HtnPlanStep].create()
                var success = true

                for subtask_name_ptr in method.subtasks:
                    let subtask_name = unsafe: read(subtask_name_ptr)
                    let sub_plan = plan_task(planner, context, current_world, subtask_name, depth + 1, iterations, reason)
                    match sub_plan:
                        Option.none:
                            success = false
                            break
                        Option.some as sub_payload:
                            for step_ptr in sub_payload.value.steps:
                                unsafe:
                                    all_steps.push(read(step_ptr))
                            current_world = sub_payload.value.final_world
                            sub_payload.value.steps.release()

                if success:
                    return Option[HtnPlan[World]].some(value =
                        HtnPlan[World](steps = all_steps, final_world = current_world)
                    )

                all_steps.release()

    return Option[HtnPlan[World]].none


# ── public types: extensions ──

extending HtnOperator[World, Context]:
    public static function create(
        name: str,
        precondition: fn(context: ptr[Context], world: World) -> bool,
        effect: fn(context: ptr[Context], world: World) -> World
    ) -> HtnOperator[World, Context]:
        return HtnOperator[World, Context](
            name = name,
            precondition = precondition,
            effect = effect
        )


extending HtnMethod[World, Context]:
    public static function create(
        name: str,
        task: str,
        precondition: fn(context: ptr[Context], world: World) -> bool
    ) -> HtnMethod[World, Context]:
        return HtnMethod[World, Context](
            name = name,
            task = task,
            precondition = precondition,
            subtasks = vec.Vec[str].create()
        )


    public editable function add_subtask(task_name: str) -> void:
        this.subtasks.push(task_name)


extending HtnPlan[World]:
    public editable function release() -> void:
        this.steps.release()


    public function step_count() -> ptr_uint:
        return this.steps.len()


    public function step(index: ptr_uint) -> ptr[HtnPlanStep]?:
        return this.steps.get(index)


extending HtnResult[World]:
    public editable function release() -> void:
        match this.plan:
            Option.none:
                pass
            Option.some as payload:
                payload.value.release()
        this.plan = Option[HtnPlan[World]].none


    public function has_plan() -> bool:
        match this.plan:
            Option.none:
                return false
            Option.some:
                return true


extending HtnPlanner[World, Context]:
    public static function create() -> HtnPlanner[World, Context]:
        return HtnPlanner[World, Context](
            domain = HtnDomain[World, Context](
                operators = vec.Vec[HtnOperator[World, Context]].create(),
                methods = vec.Vec[HtnMethod[World, Context]].create()
            ),
            max_depth = 32,
            max_iterations = 4096
        )


    public editable function release() -> void:
        this.domain.operators.release()
        for entry in this.domain.methods:
            unsafe:
                read(entry).subtasks.release()
        this.domain.methods.release()


    public editable function add_operator(op: HtnOperator[World, Context]) -> void:
        this.domain.operators.push(op)


    public editable function add_method(method: HtnMethod[World, Context]) -> void:
        this.domain.methods.push(method)


    public editable function set_max_depth(limit: ptr_uint) -> void:
        this.max_depth = limit


    public editable function set_max_iterations(limit: ptr_uint) -> void:
        this.max_iterations = limit


    public editable function plan(context: ptr[Context], world: World, root_task: str) -> HtnResult[World]:
        var iterations: ptr_uint = 0
        var reason: HtnStatus = HtnStatus.failure
        let res = plan_task(ref_of(this), context, world, root_task, 0, ptr_of(iterations), ptr_of(reason))

        match res:
            Option.none:
                return HtnResult[World](
                    status = reason,
                    plan = Option[HtnPlan[World]].none,
                    iterations = iterations,
                    depth = 0
                )
            Option.some as payload:
                return HtnResult[World](
                    status = HtnStatus.success,
                    plan = Option[HtnPlan[World]].some(value = payload.value),
                    iterations = iterations,
                    depth = 0
                )
