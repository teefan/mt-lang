import std.vec as vec

public enum PlanningStatus: ubyte
    found = 0
    not_found = 1
    iteration_limit = 2

public struct Action[World, Context]:
    name: str
    precondition: fn(context: ptr[Context], world: World) -> bool
    apply: fn(context: ptr[Context], world: World) -> World
    cost: fn(context: ptr[Context], world: World) -> float

public struct PlanStep:
    action_index: ptr_uint
    action_name: str

public struct Plan[World]:
    steps: vec.Vec[PlanStep]
    total_cost: float
    final_world: World

public struct PlanningResult[World]:
    status: PlanningStatus
    plan: Option[Plan[World]]
    iterations: ptr_uint
    expanded_nodes: ptr_uint

public struct Planner[World, Goal, Context]:
    actions: vec.Vec[Action[World, Context]]
    is_goal: fn(context: ptr[Context], world: World, goal: Goal) -> bool
    heuristic: fn(context: ptr[Context], world: World, goal: Goal) -> float
    worlds_equal: fn(left: World, right: World) -> bool
    max_iterations: ptr_uint

struct SearchNode[World]:
    world: World
    parent_index: ptr_uint
    has_parent: bool
    action_index: ptr_uint
    cost_so_far: float
    closed: bool


function find_node_index[World, Goal, Context](
    planner: ref[Planner[World, Goal, Context]],
    nodes: ref[vec.Vec[SearchNode[World]]],
    world: World
) -> Option[ptr_uint]:
    var index: ptr_uint = 0
    for entry in nodes:
        unsafe:
            if planner.worlds_equal(read(entry).world, world):
                return Option[ptr_uint].some(value = index)
        index += 1

    return Option[ptr_uint].none


function open_list_contains(open_list: ref[vec.Vec[ptr_uint]], node_index: ptr_uint) -> bool:
    for entry in open_list:
        unsafe:
            if read(entry) == node_index:
                return true

    return false


function choose_best_open[World, Goal, Context](
    planner: ref[Planner[World, Goal, Context]],
    nodes: ref[vec.Vec[SearchNode[World]]],
    open_list: ref[vec.Vec[ptr_uint]],
    context: ref[Context],
    goal: Goal
) -> Option[ptr_uint]:
    var best_open_index: ptr_uint = 0
    var best_score: float = 0.0
    var saw_candidate = false

    var open_index: ptr_uint = 0
    for entry in open_list:
        unsafe:
            let node_index = read(entry)
            let node_ptr = nodes.get(node_index) else:
                continue

            let node = read(node_ptr)
            if node.closed:
                open_index += 1
                continue

            let score = node.cost_so_far + planner.heuristic(ptr_of(context), node.world, goal)
            if not saw_candidate or score < best_score:
                best_score = score
                best_open_index = open_index
                saw_candidate = true
        open_index += 1

    if not saw_candidate:
        return Option[ptr_uint].none

    return Option[ptr_uint].some(value = best_open_index)


function build_plan[World, Goal, Context](
    planner: ref[Planner[World, Goal, Context]],
    nodes: ref[vec.Vec[SearchNode[World]]],
    goal_index: ptr_uint
) -> Plan[World]:
    let goal_node_ptr = nodes.get(goal_index) else:
        fatal(c"goap.build_plan missing goal node")

    unsafe:
        let goal_node = read(goal_node_ptr)
        var reverse_steps = vec.Vec[PlanStep].create()
        var current_index = goal_index
        while true:
            let current_ptr = nodes.get(current_index) else:
                fatal(c"goap.build_plan missing current node")

            let current = read(current_ptr)
            if not current.has_parent:
                break

            let action_ptr = planner.actions.get(current.action_index) else:
                fatal(c"goap.build_plan missing action")

            reverse_steps.push(
                PlanStep(
                    action_index = current.action_index,
                    action_name = read(action_ptr).name
                )
            )
            current_index = current.parent_index

        var plan = Plan[World](
            steps = vec.Vec[PlanStep].with_capacity(reverse_steps.len()),
            total_cost = goal_node.cost_so_far,
            final_world = goal_node.world
        )

        while true:
            let step = reverse_steps.pop() else:
                break

            plan.steps.push(step)

        reverse_steps.release()
        return plan


extending Action[World, Context]:
    public static function create(
        name: str,
        precondition: fn(context: ptr[Context], world: World) -> bool,
        apply: fn(context: ptr[Context], world: World) -> World,
        cost: fn(context: ptr[Context], world: World) -> float
    ) -> Action[World, Context]:
        return Action[World, Context](
            name = name,
            precondition = precondition,
            apply = apply,
            cost = cost
        )


extending Plan[World]:
    public editable function release() -> void:
        this.steps.release()


    public function step_count() -> ptr_uint:
        return this.steps.len()


    public function iter() -> vec.Iter[PlanStep]:
        return this.steps.iter()


    public function step(index: ptr_uint) -> ptr[PlanStep]?:
        return this.steps.get(index)


extending PlanningResult[World]:
    public editable function release() -> void:
        match this.plan:
            Option.none:
                pass
            Option.some as payload:
                var plan = payload.value
                plan.release()
        this.plan = Option[Plan[World]].none


    public function has_plan() -> bool:
        match this.plan:
            Option.none:
                return false
            Option.some:
                return true


extending Planner[World, Goal, Context]:
    public static function create(
        is_goal: fn(context: ptr[Context], world: World, goal: Goal) -> bool,
        heuristic: fn(context: ptr[Context], world: World, goal: Goal) -> float,
        worlds_equal: fn(left: World, right: World) -> bool
    ) -> Planner[World, Goal, Context]:
        return Planner[World, Goal, Context](
            actions = vec.Vec[Action[World, Context]].create(),
            is_goal = is_goal,
            heuristic = heuristic,
            worlds_equal = worlds_equal,
            max_iterations = 256
        )


    public editable function release() -> void:
        this.actions.release()


    public function action_count() -> ptr_uint:
        return this.actions.len()


    public editable function add_action(action: Action[World, Context]) -> void:
        this.actions.push(action)


    public editable function set_max_iterations(limit: ptr_uint) -> void:
        this.max_iterations = limit


    public editable function plan(context: ref[Context], initial_world: World, goal: Goal) -> PlanningResult[World]:
        var nodes = vec.Vec[SearchNode[World]].create()
        defer nodes.release()
        var open_list = vec.Vec[ptr_uint].create()
        defer open_list.release()

        nodes.push(
            SearchNode[World](
                world = initial_world,
                parent_index = 0,
                has_parent = false,
                action_index = 0,
                cost_so_far = 0.0,
                closed = false
            )
        )
        open_list.push(0)

        var iterations: ptr_uint = 0
        var expanded_nodes: ptr_uint = 0

        while not open_list.is_empty():
            if iterations >= this.max_iterations:
                return PlanningResult[World](
                    status = PlanningStatus.iteration_limit,
                    plan = Option[Plan[World]].none,
                    iterations = iterations,
                    expanded_nodes = expanded_nodes
                )

            let best_open_index = choose_best_open(ref_of(this), ref_of(nodes), ref_of(open_list), context, goal) else:
                break

            let current_index_option = open_list.swap_remove(best_open_index)
            match current_index_option:
                Option.none:
                    break
                Option.some as current_payload:
                    iterations += 1
                    let current_index = current_payload.value
                    let current_ptr = nodes.get(current_index) else:
                        continue

                    unsafe:
                        if read(current_ptr).closed:
                            continue

                        if this.is_goal(ptr_of(context), read(current_ptr).world, goal):
                            let plan = build_plan(ref_of(this), ref_of(nodes), current_index)
                            return PlanningResult[World](
                                status = PlanningStatus.found,
                                plan = Option[Plan[World]].some(value = plan),
                                iterations = iterations,
                                expanded_nodes = expanded_nodes
                            )

                        read(current_ptr).closed = true

                    expanded_nodes += 1

                    var action_index: ptr_uint = 0
                    for action_ptr in this.actions:
                        unsafe:
                            let action = read(action_ptr)
                            let current_node = read(current_ptr)
                            if not action.precondition(ptr_of(context), current_node.world):
                                action_index += 1
                                continue

                            let next_world = action.apply(ptr_of(context), current_node.world)
                            let next_cost = current_node.cost_so_far + action.cost(ptr_of(context), current_node.world)
                            let existing_index = find_node_index(ref_of(this), ref_of(nodes), next_world)
                            match existing_index:
                                Option.none:
                                    let next_node_index = nodes.len()
                                    nodes.push(
                                        SearchNode[World](
                                            world = next_world,
                                            parent_index = current_index,
                                            has_parent = true,
                                            action_index = action_index,
                                            cost_so_far = next_cost,
                                            closed = false
                                        )
                                    )
                                    open_list.push(next_node_index)

                                Option.some as existing_payload:
                                    let existing_ptr = nodes.get(existing_payload.value) else:
                                        action_index += 1
                                        continue

                                    if next_cost < unsafe: read(existing_ptr).cost_so_far:
                                        unsafe:
                                            read(existing_ptr).parent_index = current_index
                                            read(existing_ptr).has_parent = true
                                            read(existing_ptr).action_index = action_index
                                            read(existing_ptr).cost_so_far = next_cost
                                            read(existing_ptr).closed = false
                                        if not open_list_contains(ref_of(open_list), existing_payload.value):
                                            open_list.push(existing_payload.value)
                        action_index += 1

        return PlanningResult[World](
            status = PlanningStatus.not_found,
            plan = Option[Plan[World]].none,
            iterations = iterations,
            expanded_nodes = expanded_nodes
        )
