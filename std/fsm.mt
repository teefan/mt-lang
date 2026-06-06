import std.vec as vec

public enum DispatchKind: ubyte
    ignored = 0
    transitioned = 1

public struct DispatchResult[State]:
    kind: DispatchKind
    previous_state: State
    current_state: State

public struct Transition[State, Event, Context]:
    from_state: State
    input: Event
    to_state: State
    guard: fn(context: ptr[Context], input: Event, current_state: State, next_state: State) -> bool
    action: fn(context: ptr[Context], input: Event, previous_state: State, next_state: State) -> void

public struct StateHooks[State, Context]:
    state: State
    on_enter: fn(context: ptr[Context], state: State) -> void
    on_exit: fn(context: ptr[Context], state: State) -> void
    on_update: fn(context: ptr[Context], state: State) -> void

public struct StateMachine[State, Event, Context]:
    current_state: State
    transitions: vec.Vec[Transition[State, Event, Context]]
    hooks: vec.Vec[StateHooks[State, Context]]
    states_equal: fn(left: State, right: State) -> bool
    events_equal: fn(left: Event, right: Event) -> bool


function always_allow_transition[State, Event, Context](
    _context: ptr[Context],
    _input: Event,
    _current_state: State,
    _next_state: State
) -> bool:
    return true


function noop_transition_action[State, Event, Context](
    _context: ptr[Context],
    _input: Event,
    _previous_state: State,
    _next_state: State
) -> void:
    pass


function noop_state_hook[State, Context](_context: ptr[Context], _state: State) -> void:
    pass


function find_state_hooks[State, Event, Context](
    machine: ref[StateMachine[State, Event, Context]],
    state: State
) -> ptr[StateHooks[State, Context]]?:
    for entry in machine.hooks:
        unsafe:
            let current = read(entry)
            if machine.states_equal(current.state, state):
                return entry

    return null


extending DispatchResult[State]:
    public function did_transition() -> bool:
        return this.kind == DispatchKind.transitioned


extending Transition[State, Event, Context]:
    public static function create(
        from_state: State,
        input: Event,
        to_state: State,
        guard: fn(context: ptr[Context], input: Event, current_state: State, next_state: State) -> bool,
        action: fn(context: ptr[Context], input: Event, previous_state: State, next_state: State) -> void
    ) -> Transition[State, Event, Context]:
        return Transition[State, Event, Context](
            from_state = from_state,
            input = input,
            to_state = to_state,
            guard = guard,
            action = action
        )


    public static function always(
        from_state: State,
        input: Event,
        to_state: State,
        action: fn(context: ptr[Context], input: Event, previous_state: State, next_state: State) -> void
    ) -> Transition[State, Event, Context]:
        return Transition[State, Event, Context].create(
            from_state,
            input,
            to_state,
            always_allow_transition[State, Event, Context],
            action
        )


    public static function simple(
        from_state: State,
        input: Event,
        to_state: State
    ) -> Transition[State, Event, Context]:
        return Transition[State, Event, Context].create(
            from_state,
            input,
            to_state,
            always_allow_transition[State, Event, Context],
            noop_transition_action[State, Event, Context]
        )


extending StateHooks[State, Context]:
    public static function create(
        state: State,
        on_enter: fn(context: ptr[Context], state: State) -> void,
        on_exit: fn(context: ptr[Context], state: State) -> void,
        on_update: fn(context: ptr[Context], state: State) -> void
    ) -> StateHooks[State, Context]:
        return StateHooks[State, Context](
            state = state,
            on_enter = on_enter,
            on_exit = on_exit,
            on_update = on_update
        )


    public static function noop(state: State) -> StateHooks[State, Context]:
        return StateHooks[State, Context].create(
            state,
            noop_state_hook[State, Context],
            noop_state_hook[State, Context],
            noop_state_hook[State, Context]
        )


extending StateMachine[State, Event, Context]:
    public static function create(
        initial_state: State,
        states_equal: fn(left: State, right: State) -> bool,
        events_equal: fn(left: Event, right: Event) -> bool
    ) -> StateMachine[State, Event, Context]:
        return StateMachine[State, Event, Context](
            current_state = initial_state,
            transitions = vec.Vec[Transition[State, Event, Context]].create(),
            hooks = vec.Vec[StateHooks[State, Context]].create(),
            states_equal = states_equal,
            events_equal = events_equal
        )


    public editable function release() -> void:
        this.transitions.release()
        this.hooks.release()


    public function state() -> State:
        return this.current_state


    public function transitions_len() -> ptr_uint:
        return this.transitions.len()


    public function hooks_len() -> ptr_uint:
        return this.hooks.len()


    public function is_in_state(state: State) -> bool:
        return this.states_equal(this.current_state, state)


    public editable function add_transition(transition: Transition[State, Event, Context]) -> void:
        this.transitions.push(transition)


    public editable function add_state_hooks(hooks: StateHooks[State, Context]) -> void:
        let existing = find_state_hooks(ref_of(this), hooks.state)
        if existing != null:
            unsafe:
                read(ptr[StateHooks[State, Context]]<-existing) = hooks
            return

        this.hooks.push(hooks)


    public editable function tick(context: ref[Context]) -> void:
        let maybe_hooks = find_state_hooks(ref_of(this), this.current_state) else:
            return

        unsafe:
            let hooks = read(ptr[StateHooks[State, Context]]<-maybe_hooks)
            hooks.on_update(ptr_of(context), this.current_state)


    public editable function set_state(context: ref[Context], next_state: State) -> DispatchResult[State]:
        let previous_state = this.current_state
        if this.states_equal(previous_state, next_state):
            return DispatchResult[State](
                kind = DispatchKind.ignored,
                previous_state = previous_state,
                current_state = previous_state
            )

        let previous_hooks = find_state_hooks(ref_of(this), previous_state)
        if previous_hooks != null:
            unsafe:
                let hooks = read(ptr[StateHooks[State, Context]]<-previous_hooks)
                hooks.on_exit(ptr_of(context), previous_state)

        this.current_state = next_state

        let next_hooks = find_state_hooks(ref_of(this), next_state)
        if next_hooks != null:
            unsafe:
                let hooks = read(ptr[StateHooks[State, Context]]<-next_hooks)
                hooks.on_enter(ptr_of(context), next_state)

        return DispatchResult[State](
            kind = DispatchKind.transitioned,
            previous_state = previous_state,
            current_state = next_state
        )


    public editable function dispatch(context: ref[Context], input: Event) -> DispatchResult[State]:
        for entry in this.transitions:
            unsafe:
                let transition = read(entry)
                if not this.states_equal(transition.from_state, this.current_state):
                    continue
                if not this.events_equal(transition.input, input):
                    continue
                if not transition.guard(ptr_of(context), input, transition.from_state, transition.to_state):
                    continue

                let previous_state = this.current_state
                let previous_hooks = find_state_hooks(ref_of(this), previous_state)
                if previous_hooks != null:
                    let hooks = read(ptr[StateHooks[State, Context]]<-previous_hooks)
                    hooks.on_exit(ptr_of(context), previous_state)

                transition.action(ptr_of(context), input, previous_state, transition.to_state)
                this.current_state = transition.to_state

                let next_hooks = find_state_hooks(ref_of(this), this.current_state)
                if next_hooks != null:
                    let hooks = read(ptr[StateHooks[State, Context]]<-next_hooks)
                    hooks.on_enter(ptr_of(context), this.current_state)

                return DispatchResult[State](
                    kind = DispatchKind.transitioned,
                    previous_state = previous_state,
                    current_state = this.current_state
                )

        return DispatchResult[State](
            kind = DispatchKind.ignored,
            previous_state = this.current_state,
            current_state = this.current_state
        )
