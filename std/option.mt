module std.option

pub struct Option[T]:
    is_some: bool
    value: T

methods Option[T]:
    pub static def some(item: T) -> Option[T]:
        return Option[T](is_some = true, value = item)


    pub static def none() -> Option[T]:
        return Option[T](is_some = false, value = zero[T])


    pub def is_some() -> bool:
        return this.is_some


    pub def is_none() -> bool:
        return not this.is_some


    pub def unwrap() -> T:
        if not this.is_some:
            panic(c"option.unwrap called on none")
        return this.value


    pub def unwrap_or(fallback: T) -> T:
        if this.is_some:
            return this.value
        return fallback


    pub edit def set_some(value_item: T) -> void:
        this.is_some = true
        this.value = value_item
        return


    pub edit def clear() -> void:
        this.is_some = false
        this.value = zero[T]
        return
