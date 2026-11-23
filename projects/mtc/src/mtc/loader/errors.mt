## Module-loading errors.  Mirrors Ruby's ModuleLoadError
## (module_loader/errors.rb): a human-readable message plus the offending
## module name or source-file path.

import std.string as string


public struct ModuleLoadError:
    message: string.String
    path: string.String


public function module_load_error(message: str, path: str) -> ModuleLoadError:
    return ModuleLoadError(
        message = string.String.from_str(message),
        path = string.String.from_str(path),
    )


extending ModuleLoadError:
    public editable function release() -> void:
        this.message.release()
        this.path.release()
