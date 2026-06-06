import std.vec as vec

public enum Status: ubyte
    success = 0
    failure = 1
    running = 2

public enum NodeKind: ubyte
    sequence = 0
    selector = 1
    parallel_all = 2
    parallel_any = 3
    condition = 4
    action = 5
    inverter = 6
    succeeder = 7
    failer = 8
    repeater = 9
    until_success = 10
    until_failure = 11

struct RuntimeState:
    active_child: ptr_uint
    repeat_count: ptr_uint

public struct Node[Context]:
    kind: NodeKind
    condition_fn: fn(context: ptr[Context]) -> bool
    action_fn: fn(context: ptr[Context]) -> Status
    repeat_limit: ptr_uint
    children: vec.Vec[ptr_uint]

public struct Tree[Context]:
    nodes: vec.Vec[Node[Context]]
    runtime: vec.Vec[RuntimeState]
    root: ptr_uint
    has_root: bool


function default_condition[Context](_context: ptr[Context]) -> bool:
    return false


function default_action[Context](_context: ptr[Context]) -> Status:
    return Status.failure


function create_runtime_state() -> RuntimeState:
    return RuntimeState(active_child = 0, repeat_count = 0)


function child_exists[Context](tree: ref[Tree[Context]], node_id: ptr_uint) -> bool:
    return node_id < tree.nodes.len()


function reset_runtime_state(runtime: ptr[RuntimeState]) -> void:
    unsafe:
        read(runtime).active_child = 0
        read(runtime).repeat_count = 0


function tick_node[Context](tree: ref[Tree[Context]], node_id: ptr_uint, context: ref[Context]) -> Status:
    let node_ptr = tree.nodes.get(node_id) else:
        return Status.failure

    let runtime_ptr = tree.runtime.get(node_id) else:
        return Status.failure

    unsafe:
        let node = ptr[Node[Context]]<-node_ptr
        let runtime = ptr[RuntimeState]<-runtime_ptr
        match read(node).kind:
            NodeKind.sequence:
                if read(node).children.is_empty():
                    reset_runtime_state(runtime)
                    return Status.success

                var child_index = read(runtime).active_child
                while child_index < read(node).children.len():
                    let child_ptr = read(node).children.get(child_index) else:
                        reset_runtime_state(runtime)
                        return Status.failure

                    let child_status = tick_node(tree, read(child_ptr), context)
                    match child_status:
                        Status.success:
                            child_index += 1
                            continue
                        Status.failure:
                            reset_runtime_state(runtime)
                            return Status.failure
                        Status.running:
                            read(runtime).active_child = child_index
                            return Status.running

                reset_runtime_state(runtime)
                return Status.success

            NodeKind.selector:
                if read(node).children.is_empty():
                    reset_runtime_state(runtime)
                    return Status.failure

                var child_index = read(runtime).active_child
                while child_index < read(node).children.len():
                    let child_ptr = read(node).children.get(child_index) else:
                        reset_runtime_state(runtime)
                        return Status.failure

                    let child_status = tick_node(tree, read(child_ptr), context)
                    match child_status:
                        Status.success:
                            reset_runtime_state(runtime)
                            return Status.success
                        Status.failure:
                            child_index += 1
                            continue
                        Status.running:
                            read(runtime).active_child = child_index
                            return Status.running

                reset_runtime_state(runtime)
                return Status.failure

            NodeKind.parallel_all:
                if read(node).children.is_empty():
                    return Status.failure

                var saw_running = false
                for child_ptr in read(node).children:
                    let child_status = tick_node(tree, unsafe: read(child_ptr), context)
                    match child_status:
                        Status.success:
                            pass
                        Status.failure:
                            return Status.failure
                        Status.running:
                            saw_running = true

                if saw_running:
                    return Status.running

                return Status.success

            NodeKind.parallel_any:
                if read(node).children.is_empty():
                    return Status.failure

                var saw_running = false
                for child_ptr in read(node).children:
                    let child_status = tick_node(tree, unsafe: read(child_ptr), context)
                    match child_status:
                        Status.success:
                            return Status.success
                        Status.failure:
                            pass
                        Status.running:
                            saw_running = true

                if saw_running:
                    return Status.running

                return Status.failure

            NodeKind.condition:
                if read(node).condition_fn(ptr_of(context)):
                    return Status.success

                return Status.failure

            NodeKind.action:
                return read(node).action_fn(ptr_of(context))

            NodeKind.inverter:
                let child_ptr = read(node).children.first() else:
                    return Status.failure

                let child_status = tick_node(tree, read(child_ptr), context)
                match child_status:
                    Status.success:
                        return Status.failure
                    Status.failure:
                        return Status.success
                    Status.running:
                        return Status.running

            NodeKind.succeeder:
                let child_ptr = read(node).children.first() else:
                    return Status.success

                let child_status = tick_node(tree, read(child_ptr), context)
                if child_status == Status.running:
                    return Status.running

                return Status.success

            NodeKind.failer:
                let child_ptr = read(node).children.first() else:
                    return Status.failure

                let child_status = tick_node(tree, read(child_ptr), context)
                if child_status == Status.running:
                    return Status.running

                return Status.failure

            NodeKind.repeater:
                let child_ptr = read(node).children.first() else:
                    return Status.failure

                if read(node).repeat_limit == 0:
                    return Status.success

                let child_status = tick_node(tree, read(child_ptr), context)
                match child_status:
                    Status.success:
                        read(runtime).repeat_count += 1
                        if read(runtime).repeat_count >= read(node).repeat_limit:
                            reset_runtime_state(runtime)
                            return Status.success
                        return Status.running
                    Status.failure:
                        reset_runtime_state(runtime)
                        return Status.failure
                    Status.running:
                        return Status.running

            NodeKind.until_success:
                let child_ptr = read(node).children.first() else:
                    return Status.failure

                let child_status = tick_node(tree, read(child_ptr), context)
                match child_status:
                    Status.success:
                        return Status.success
                    Status.failure:
                        return Status.running
                    Status.running:
                        return Status.running

            NodeKind.until_failure:
                let child_ptr = read(node).children.first() else:
                    return Status.failure

                let child_status = tick_node(tree, read(child_ptr), context)
                match child_status:
                    Status.success:
                        return Status.running
                    Status.failure:
                        return Status.success
                    Status.running:
                        return Status.running

    return Status.failure


extending Node[Context]:
    static function create(kind: NodeKind) -> Node[Context]:
        return Node[Context](
            kind = kind,
            condition_fn = default_condition[Context],
            action_fn = default_action[Context],
            repeat_limit = 0,
            children = vec.Vec[ptr_uint].create()
        )


    public static function sequence() -> Node[Context]:
        return Node[Context].create(NodeKind.sequence)


    public static function selector() -> Node[Context]:
        return Node[Context].create(NodeKind.selector)


    public static function parallel_all() -> Node[Context]:
        return Node[Context].create(NodeKind.parallel_all)


    public static function parallel_any() -> Node[Context]:
        return Node[Context].create(NodeKind.parallel_any)


    public static function condition(check: fn(context: ptr[Context]) -> bool) -> Node[Context]:
        var result = Node[Context].create(NodeKind.condition)
        result.condition_fn = check
        return result


    public static function action(run: fn(context: ptr[Context]) -> Status) -> Node[Context]:
        var result = Node[Context].create(NodeKind.action)
        result.action_fn = run
        return result


    public static function inverter() -> Node[Context]:
        return Node[Context].create(NodeKind.inverter)


    public static function succeeder() -> Node[Context]:
        return Node[Context].create(NodeKind.succeeder)


    public static function failer() -> Node[Context]:
        return Node[Context].create(NodeKind.failer)


    public static function repeater(limit: ptr_uint) -> Node[Context]:
        var result = Node[Context].create(NodeKind.repeater)
        result.repeat_limit = limit
        return result


    public static function until_success() -> Node[Context]:
        return Node[Context].create(NodeKind.until_success)


    public static function until_failure() -> Node[Context]:
        return Node[Context].create(NodeKind.until_failure)


    public editable function release() -> void:
        this.children.release()


extending Tree[Context]:
    public static function create() -> Tree[Context]:
        return Tree[Context](
            nodes = vec.Vec[Node[Context]].create(),
            runtime = vec.Vec[RuntimeState].create(),
            root = 0,
            has_root = false
        )


    public editable function release() -> void:
        for node_ptr in this.nodes:
            unsafe:
                read(node_ptr).release()
        this.nodes.release()
        this.runtime.release()
        this.root = 0
        this.has_root = false


    public editable function reset() -> void:
        for entry in this.runtime:
            reset_runtime_state(unsafe: ptr[RuntimeState]<-entry)


    public function node_count() -> ptr_uint:
        return this.nodes.len()


    public function root_node() -> Option[ptr_uint]:
        if not this.has_root:
            return Option[ptr_uint].none

        return Option[ptr_uint].some(value = this.root)


    public editable function add_node(node: Node[Context]) -> ptr_uint:
        let node_id = this.nodes.len()
        this.nodes.push(node)
        this.runtime.push(create_runtime_state())
        return node_id


    public editable function set_root(node_id: ptr_uint) -> bool:
        if not child_exists(ref_of(this), node_id):
            return false

        this.root = node_id
        this.has_root = true
        return true


    public editable function add_child(parent_id: ptr_uint, child_id: ptr_uint) -> bool:
        if not child_exists(ref_of(this), parent_id):
            return false
        if not child_exists(ref_of(this), child_id):
            return false

        let parent_ptr = this.nodes.get(parent_id) else:
            return false

        unsafe:
            read(parent_ptr).children.push(child_id)
        return true


    public editable function tick(context: ref[Context]) -> Status:
        if not this.has_root:
            return Status.failure

        return tick_node(ref_of(this), this.root, context)
