## Call-argument parsing — the last unsplit parser section.  Extracted from
## parser.mt; the parser state helpers are called through the `parser` alias.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.state as pstate
import mtc.parser.parser as parser
import mtc.parser.expressions as expressions


public function parse_call_args(s: ref[pstate.ParserState]) -> span[ast.Argument]:
    var args = vec.Vec[ast.Argument].create()
    if pstate.check(s, tk.TokenKind.rparen):
        return span[ast.Argument]()
    while true:
        pstate.step(s)
        if pstate.check(s, tk.TokenKind.rparen):
            break
        if (parser.check_name(s) or parser.keyword_token_check(pstate.peek(s))) and parser.check_next(s, tk.TokenKind.equal):
            let name_tok = pstate.peek(s) else:
                break
            var arg_name: str
            unsafe:
                arg_name = token_mod.token_lexeme(read(name_tok), s.source)
            pstate.advance(s)
            pstate.advance(s)
            var val = expressions.parse_expr(s)
            var arg = ast.Argument(arg_name = Option[str].some(value = arg_name), arg_value = val)
            args.push(arg)
        else:
            var val = expressions.parse_expr(s)
            var arg = ast.Argument(arg_name = Option[str].none, arg_value = val)
            args.push(arg)
        if not pstate.match_kind(s, tk.TokenKind.comma):
            break
        if pstate.check(s, tk.TokenKind.rparen):
            break
    let result = args.as_span()
    return result
