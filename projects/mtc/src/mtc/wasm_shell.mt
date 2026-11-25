## The embedded wasm HTML shell.  The three fragments the archived host's
## `Build#render_wasm_shell_template` substituted into its template are
## preserved here, so the self-hosted compiler needs no external template file.

import std.str
import std.string as string

public const SCRIPT_PLACEHOLDER: str = "{{{ SCRIPT }}}"
public const CANVAS_PLACEHOLDER: str = "{{{ MILK_TEA_CANVAS }}}"
public const OUTPUT_PLACEHOLDER: str = "{{{ MILK_TEA_OUTPUT }}}"
public const BOOTSTRAP_PLACEHOLDER: str = "{{{ MILK_TEA_BOOTSTRAP }}}"

public const DEFAULT_TEMPLATE: str = "<!doctype html>\n<html lang=\"en\">\n  <head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n    <title>Milk Tea App</title>\n    <style>\n      html, body {\n        margin: 0;\n        height: 100%;\n        background: #111;\n        color: #f5f5f5;\n        font-family: monospace;\n      }\n\n      body {\n        overflow: hidden;\n      }\n\n      #canvas {\n        display: block;\n        width: 100vw;\n        height: 100vh;\n        border: 0;\n        background: #000;\n      }\n\n      #output {\n        position: fixed;\n        left: 0;\n        right: 0;\n        bottom: 0;\n        max-height: 30vh;\n        margin: 0;\n        padding: 0.75rem;\n        overflow: auto;\n        white-space: pre-wrap;\n        background: rgba(0, 0, 0, 0.72);\n      }\n    </style>\n  </head>\n  <body>\n    {{{ MILK_TEA_CANVAS }}}\n    {{{ MILK_TEA_OUTPUT }}}\n    {{{ MILK_TEA_BOOTSTRAP }}}\n    {{{ SCRIPT }}}\n  </body>\n</html>\n"

public const CANVAS_TEMPLATE: str = "<canvas id=\"canvas\" oncontextmenu=\"event.preventDefault()\" tabindex=\"-1\"></canvas>\n"

public const OUTPUT_TEMPLATE: str = "<pre id=\"output\"></pre>\n"

public const BOOTSTRAP_TEMPLATE: str = "<script>\n  var Module = {\n    print: (function() {\n      var element = document.getElementById('output');\n      if (element) element.textContent = '';\n      return function(text) {\n        if (arguments.length > 1) text = Array.prototype.slice.call(arguments).join(' ');\n        console.log(text);\n        if (element) {\n          element.textContent += text + \"\\n\";\n          element.scrollTop = element.scrollHeight;\n        }\n      };\n    })(),\n    printErr: (function() {\n      var element = document.getElementById('output');\n      return function(text) {\n        if (arguments.length > 1) text = Array.prototype.slice.call(arguments).join(' ');\n        console.error(text);\n        if (element) {\n          element.textContent += \"[err] \" + text + \"\\n\";\n          element.scrollTop = element.scrollHeight;\n        }\n      };\n    })(),\n    canvas: (function() {\n      return document.getElementById('canvas');\n    })()\n  };\n</script>\n"


function count_occurrences(source: str, needle: str) -> ptr_uint:
    var count: ptr_uint = 0
    var start: ptr_uint = 0
    while start <= source.len:
        let remaining = source.slice(start, source.len - start)
        match remaining.find_substring(needle):
            Option.some as position:
                count += 1
                start = start + position.value + needle.len
            Option.none:
                return count
    return count


function validate_placeholder(
    source: str,
    placeholder: str,
    label: str,
    template_path: str,
) -> Result[bool, string.String]:
    if count_occurrences(source, placeholder) == 1:
        return Result[bool, string.String].success(value = true)

    var message = string.String.from_str("wasm HTML template must contain ")
    message.append(label)
    message.append(" exactly once: ")
    message.append(template_path)
    return Result[bool, string.String].failure(error = message)


## Validate and render a shell template (the host's
## `render_wasm_shell_template`).  `template_path` is only used in the
## error message for a malformed custom template.
public function render(
    template_source: str,
    template_path: str,
) -> Result[string.String, string.String]:
    let _ = validate_placeholder(
        template_source, SCRIPT_PLACEHOLDER, "Emscripten {{{ SCRIPT }}}", template_path
    )?
    let _ = validate_placeholder(
        template_source, CANVAS_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_CANVAS }}}", template_path
    )?
    let _ = validate_placeholder(
        template_source, OUTPUT_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_OUTPUT }}}", template_path
    )?
    let _ = validate_placeholder(
        template_source, BOOTSTRAP_PLACEHOLDER, "Milk Tea {{{ MILK_TEA_BOOTSTRAP }}}", template_path
    )?

    var rendered = string.String.from_str(template_source)
    var replaced = rendered.replace(CANVAS_PLACEHOLDER, CANVAS_TEMPLATE)
    rendered.release()
    rendered = replaced
    replaced = rendered.replace(OUTPUT_PLACEHOLDER, OUTPUT_TEMPLATE)
    rendered.release()
    rendered = replaced
    replaced = rendered.replace(BOOTSTRAP_PLACEHOLDER, BOOTSTRAP_TEMPLATE)
    rendered.release()
    rendered = replaced
    return Result[string.String, string.String].success(value = rendered)
