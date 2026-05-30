import std.raylib as rl
import std.libc as libc


public function env_flag(name: str) -> bool:
    return libc.get_environment_variable(name) != null


public function require_ptr[T](value: ptr[T]?, message: str) -> ptr[T]:
    if value == null:
        fatal(message)

    return ptr[T]<-value


public function enter_asset_directory(directory_name: str) -> bool:
    let working_dir = rl.get_working_directory()
    let application_dir = rl.get_application_directory()

    if rl.change_directory(application_dir):
        if rl.change_directory(directory_name):
            return true

        rl.change_directory(working_dir)

    return rl.change_directory(directory_name)


public function enter_assets_directory() -> bool:
    return enter_asset_directory("assets")
