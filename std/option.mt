module std.option

pub struct Option[T]:
    is_some: bool
    value: T


pub def some[T](item: T) -> Option[T]:
    return Option[T](is_some = true, value = item)


pub def none[T]() -> Option[T]:
    return Option[T](is_some = false, value = zero[T]())


pub def is_some[T](item: Option[T]) -> bool:
    return item.is_some


pub def is_none[T](item: Option[T]) -> bool:
    return not item.is_some


pub def unwrap[T](item: Option[T]) -> T:
    if not item.is_some:
        panic(c"option.unwrap called on none")
    return item.value


pub def unwrap_or[T](item: Option[T], fallback: T) -> T:
    if item.is_some:
        return item.value
    return fallback


pub def set_some[T](item: ref[Option[T]], value_item: T) -> void:
    item.is_some = true
    item.value = value_item
    return


pub def clear[T](item: ref[Option[T]]) -> void:
    item.is_some = false
    item.value = zero[T]()
    return
