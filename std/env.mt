import std.libc as libc
import std.str as text


public function get(name: str) -> Option[str]:
    let raw = libc.get_environment_variable(name) else:
        return Option[str].none
    return Option[str].some(value = text.cstr_as_str(raw))


public function set(name: str, value: str, overwrite: int) -> bool:
    let result = libc.set_environment_variable(name, value, overwrite)
    return result == 0


public function remove(name: str) -> bool:
    let result = libc.unset_environment_variable(name)
    return result == 0


public function home() -> Option[str]:
    return get("HOME")


public function temp_directory() -> Option[str]:
    match get("TMPDIR"):
        Option.some as payload:
            return Option[str].some(value = payload.value)
        Option.none:
            pass
    match get("TMP"):
        Option.some as payload:
            return Option[str].some(value = payload.value)
        Option.none:
            pass
    match get("TEMP"):
        Option.some as payload:
            return Option[str].some(value = payload.value)
        Option.none:
            pass
    return Option[str].none
