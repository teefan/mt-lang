# Recursive-descent parser for the self-hosting Milk Tea compiler.
# Mirrors lib/milk_tea/core/parser.rb.
#
# Uses inline `is` checks since variant equality isn't directly comparable.
# Input: SyntaxTokenStream → Output: ast.SourceFile with arena storage.

import mtc.token
import mtc.token_stream
import mtc.ast
import mtc.diagnostics
import std.vec

public struct Parser:
    tokens: token_stream.SyntaxTokenStream
    current: ptr_uint
    file: ast.SourceFile
    diagnostics: diagnostics.DiagnosticList

extending Parser:
    static function empty_source_file() -> ast.SourceFile:
        return ast.SourceFile(
            module_name = ast.QualifiedName(parts = vec.Vec[str].create()),
            module_kind = "module",
            imports = vec.Vec[ast.Import].create(),
            declarations = vec.Vec[ast.Decl].create(),
            exprs = vec.Vec[ast.Expr].create(),
            stmts = vec.Vec[ast.Stmt].create(),
            type_nodes = vec.Vec[ast.TypeRef].create(),
            arguments = vec.Vec[ast.Argument].create(),
            if_branches = vec.Vec[ast.IfBranch].create(),
            match_arms = vec.Vec[ast.MatchArm].create(),
            match_expr_arms = vec.Vec[ast.MatchExprArm].create(),
            when_branches = vec.Vec[ast.WhenBranch].create(),
            for_bindings = vec.Vec[ast.ForBinding].create(),
            params = vec.Vec[ast.Param].create(),
            foreign_params = vec.Vec[ast.ForeignParam].create(),
            fields = vec.Vec[ast.Field].create(),
            variant_arms = vec.Vec[ast.VariantArm].create(),
            variant_arm_fields = vec.Vec[ast.VariantArmField].create(),
            enum_members = vec.Vec[ast.EnumMember].create(),
            format_parts = vec.Vec[ast.FormatStringPart].create(),
            attributes = vec.Vec[ast.Attribute].create(),
            type_arguments = vec.Vec[ast.TypeArgument].create(),
            line = 1,
        )

    public static function create(
        token_vec: vec.Vec[token.Token],
    ) -> Parser:
        return Parser(
            tokens = token_stream.SyntaxTokenStream.from_tokens(token_vec),
            current = 0z,
            file = Parser.empty_source_file(),
            diagnostics = diagnostics.DiagnosticList.create(),
        )

    # ── Token stream interface ──

    public editable function parse() -> ast.SourceFile:
        this.parse_source_file()
        return this.file

    function peek() -> token.Token:
        let t = this.tokens.at(this.current) else:
            return this.eof_token()
        return t

    function at_end() -> bool:
        return this.peek().kind is token.TokenKind.eof

    editable function advance() -> void:
        if not this.at_end():
            this.current += 1

    function previous() -> token.Token:
        if this.current > 0z:
            let t = this.tokens.at(this.current - 1) else:
                return this.eof_token()
            return t
        return this.eof_token()

    function eof_token() -> token.Token:
        return token.Token(
            kind = token.TokenKind.eof,
            lexeme = "",
            line = 0,
            column = 0,
            start_offset = 0z,
        )

    editable function emit_error(tok: token.Token, message: str) -> void:
        this.diagnostics.add(
            diagnostics.Severity.error,
            "P0001",
            message,
            "",
            tok.line,
            tok.column,
        )

    # ── Top-level parsing ──

    editable function parse_source_file() -> void:
        this.skip_newlines()
        while not this.at_end():
            this.parse_top_level_item()
            this.skip_newlines()

    editable function skip_newlines() -> void:
        while not this.at_end() and this.peek().kind is token.TokenKind.newline:
            this.advance()

    editable function parse_top_level_item() -> void:
        let tok = this.peek()
        if tok.kind is token.TokenKind.keyword_import:
            this.parse_import()
        else if tok.kind is token.TokenKind.keyword_public:
            this.advance()
            this.parse_declaration("public")
        else if tok.kind is token.TokenKind.keyword_function:
            this.parse_function_def("private")
        else if tok.kind is token.TokenKind.keyword_external:
            this.advance()
            this.file.module_kind = "external"
            this.skip_newlines()
        else:
            this.parse_declaration("private")

    editable function parse_import() -> void:
        this.advance()
        var parts = vec.Vec[str].create()
        this.parse_import_path(parts)
        var alias: str = ""
        if this.peek().kind is token.TokenKind.keyword_as:
            this.advance()
            alias = this.parse_identifier()
        let imp = ast.Import(
            path = parts,
            alias_name = alias,
            line = 0,
            column = 0,
        )
        this.file.imports.push(imp)

    editable function parse_import_path(parts: ref[vec.Vec[str]]) -> void:
        while true:
            let name = this.parse_identifier()
            parts.push(name)
            if not (this.peek().kind is token.TokenKind.op_dot):
                return
            this.advance()

    # ── Declaration dispatch ──

    editable function parse_declaration(visibility: str) -> void:
        let tok = this.peek()
        if tok.kind is token.TokenKind.keyword_const:
            this.parse_const_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_var:
            this.parse_var_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_struct:
            this.parse_struct_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_enum:
            this.parse_enum_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_flags:
            this.parse_flags_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_variant:
            this.parse_variant_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_type:
            this.parse_type_alias_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_opaque:
            this.parse_opaque_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_interface:
            this.parse_interface_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_extending:
            this.parse_extending_block()
        else if tok.kind is token.TokenKind.keyword_event:
            this.parse_event_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_static_assert:
            this.parse_static_assert()
        else if tok.kind is token.TokenKind.keyword_attribute:
            this.parse_attribute_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_foreign:
            this.parse_foreign_func_decl(visibility)
        else if tok.kind is token.TokenKind.keyword_when:
            this.parse_module_when()
        else if tok.kind is token.TokenKind.keyword_emit:
            this.parse_emit_decl()
        else if tok.kind is token.TokenKind.keyword_async:
            this.advance()
            this.parse_function_def(visibility)
        else:
            this.emit_error(tok, "expected declaration")

    # ── Identifier helpers ──

    editable function parse_identifier() -> str:
        let tok = this.peek()
        match tok.kind:
            token.TokenKind.identifier(name):
                this.advance()
                return name
            _:
                this.emit_error(tok, "expected identifier")
                return ""

    editable function parse_name_token() -> token.Token:
        let tok = this.peek()
        if tok.kind is token.TokenKind.identifier:
            this.advance()
            return tok
        this.emit_error(tok, "expected name")
        return this.eof_token()

    # ── Expression parsing ──
    #
    # Precedence (low → high): or → and → | → ^ → & → ==/!= → < > <= >= → << >> → + - → * / %
    # Uses recursive-descent with parse_left_associative helper.

    editable function parse_expression() -> ast.NodeId:
        return this.parse_or()

    editable function alloc_expr(expr: ast.Expr) -> ast.NodeId:
        this.file.exprs.push(expr)
        return this.file.exprs.len - 1

    editable function parse_or() -> ast.NodeId:
        var left = this.parse_and()
        while this.peek().kind is token.TokenKind.keyword_or:
            this.advance()
            let right = this.parse_and()
            left = this.alloc_expr(ast.Expr.binary_op(operator = "or", left = left, right = right))
        return left

    editable function parse_and() -> ast.NodeId:
        var left = this.parse_comparison()
        while this.peek().kind is token.TokenKind.keyword_and:
            this.advance()
            let right = this.parse_comparison()
            left = this.alloc_expr(ast.Expr.binary_op(operator = "and", left = left, right = right))
        return left

    editable function parse_comparison() -> ast.NodeId:
        var left = this.parse_additive()
        while true:
            let op_tok = this.peek().kind
            var op: str = ""
            if op_tok is token.TokenKind.op_equal:
                op = "=="
            else if op_tok is token.TokenKind.op_not_equal:
                op = "!="
            else if op_tok is token.TokenKind.op_less:
                op = "<"
            else if op_tok is token.TokenKind.op_less_equal:
                op = "<="
            else if op_tok is token.TokenKind.op_greater:
                op = ">"
            else if op_tok is token.TokenKind.op_greater_equal:
                op = ">="
            else:
                return left
            this.advance()
            let right = this.parse_additive()
            left = this.alloc_expr(ast.Expr.binary_op(operator = op, left = left, right = right))
        return left

    editable function parse_additive() -> ast.NodeId:
        var left = this.parse_multiplicative()
        while true:
            let op_tok = this.peek().kind
            var op: str = ""
            if op_tok is token.TokenKind.op_plus:
                op = "+"
            else if op_tok is token.TokenKind.op_minus:
                op = "-"
            else:
                return left
            this.advance()
            let right = this.parse_multiplicative()
            left = this.alloc_expr(ast.Expr.binary_op(operator = op, left = left, right = right))
        return left

    editable function parse_multiplicative() -> ast.NodeId:
        var left = this.parse_unary()
        while true:
            let op_tok = this.peek().kind
            var op: str = ""
            if op_tok is token.TokenKind.op_star:
                op = "*"
            else if op_tok is token.TokenKind.op_slash:
                op = "/"
            else if op_tok is token.TokenKind.op_percent:
                op = "%"
            else:
                return left
            this.advance()
            let right = this.parse_unary()
            left = this.alloc_expr(ast.Expr.binary_op(operator = op, left = left, right = right))
        return left

    editable function parse_unary() -> ast.NodeId:
        let tok = this.peek().kind
        if tok is token.TokenKind.keyword_not:
            this.advance()
            let operand = this.parse_unary()
            return this.alloc_expr(ast.Expr.unary_op(operator = "not", operand = operand))
        else if tok is token.TokenKind.op_minus:
            this.advance()
            let operand = this.parse_unary()
            return this.alloc_expr(ast.Expr.unary_op(operator = "-", operand = operand))
        else if tok is token.TokenKind.op_tilde:
            this.advance()
            let operand = this.parse_unary()
            return this.alloc_expr(ast.Expr.unary_op(operator = "~", operand = operand))
        return this.parse_postfix()

    editable function parse_postfix() -> ast.NodeId:
        var expr = this.parse_primary()
        while true:
            let tok = this.peek().kind
            if tok is token.TokenKind.op_dot:
                this.advance()
                let member = this.parse_identifier()
                expr = this.alloc_expr(ast.Expr.member_access(
                    receiver = expr,
                    member = member,
                    line = 0,
                    column = 0,
                ))
            else if tok is token.TokenKind.op_lparen:
                expr = this.parse_call(expr)
            else if tok is token.TokenKind.op_lbracket:
                expr = this.parse_specialization_or_index(expr)
            else:
                return expr
        return expr

    editable function parse_call(callee: ast.NodeId) -> ast.NodeId:
        this.advance()
        var args_start: ast.NodeId = 0z
        var args_len: ast.NodeId = 0z
        if not (this.peek().kind is token.TokenKind.op_rparen):
            args_start = this.file.exprs.len
            this.parse_argument_list()
            args_len = this.file.exprs.len - args_start
        this.consume_rparen()
        return this.alloc_expr(ast.Expr.call(
            callee = callee,
            args_start = args_start,
            args_len = args_len,
            line = 0,
            column = 0,
        ))

    editable function parse_specialization_or_index(receiver: ast.NodeId) -> ast.NodeId:
        this.advance()
        let tok = this.peek()
        if tok.kind is token.TokenKind.op_rbracket:
            this.advance()
            return receiver
        var args_start: ast.NodeId = 0z
        var args_len: ast.NodeId = 0z
        args_start = this.file.exprs.len
        this.parse_argument_list()
        args_len = this.file.exprs.len - args_start
        this.consume_rbracket()
        return this.alloc_expr(ast.Expr.index_access(
            receiver = receiver,
            index = 0z,
        ))

    editable function parse_argument_list() -> void:
        while true:
            let _arg = this.parse_expression()
            if this.peek().kind is token.TokenKind.op_comma:
                this.advance()
            else:
                return

    editable function parse_primary() -> ast.NodeId:
        let tok = this.peek()
        let kind = tok.kind
        match kind:
            token.TokenKind.identifier(name):
                this.advance()
                return this.alloc_expr(ast.Expr.identifier(
                    name = name,
                    line = tok.line,
                    column = tok.column,
                ))
            token.TokenKind.int_literal(value):
                this.advance()
                return this.alloc_expr(ast.Expr.integer_literal(value = value))
            token.TokenKind.string_literal(value):
                this.advance()
                return this.alloc_expr(ast.Expr.string_literal(value = value))
            token.TokenKind.keyword_true:
                this.advance()
                return this.alloc_expr(ast.Expr.boolean_literal(value = true))
            token.TokenKind.keyword_false:
                this.advance()
                return this.alloc_expr(ast.Expr.boolean_literal(value = false))
            token.TokenKind.keyword_null:
                this.advance()
                return this.alloc_expr(ast.Expr.null_literal(type_id = 0z))
            token.TokenKind.char_literal(value):
                this.advance()
                return this.alloc_expr(ast.Expr.char_literal(value = value))
            token.TokenKind.op_lparen:
                this.advance()
                let expr = this.parse_expression()
                this.consume_rparen()
                return expr
            _:
                pass
        this.emit_error(tok, "expected expression")
        return this.alloc_expr(ast.Expr.error_expr(
            line = tok.line,
            column = tok.column,
            message = "expected expression",
        ))

    # ── Helpers ──

    editable function consume_rparen() -> void:
        if this.peek().kind is token.TokenKind.op_rparen:
            this.advance()
        else:
            this.emit_error(this.peek(), "expected ')'")

    editable function consume_rbracket() -> void:
        if this.peek().kind is token.TokenKind.op_rbracket:
            this.advance()
        else:
            this.emit_error(this.peek(), "expected ']'")

    editable function consume_colon() -> void:
        if this.peek().kind is token.TokenKind.op_colon:
            this.advance()
        else:
            this.emit_error(this.peek(), "expected ':'")

    editable function consume_newline() -> void:
        if this.peek().kind is token.TokenKind.newline:
            this.advance()

    editable function expect_indent() -> void:
        if this.peek().kind is token.TokenKind.indent:
            this.advance()

    editable function alloc_stmt(stmt: ast.Stmt) -> ast.NodeId:
        this.file.stmts.push(stmt)
        return this.file.stmts.len - 1

    # ── Statement parsing ──

    editable function parse_block_body() -> ast.NodeId:
        this.consume_colon()
        if this.peek().kind is token.TokenKind.newline:
            this.advance()
        if this.peek().kind is token.TokenKind.indent:
            this.advance()
        var first: ast.NodeId = 0z
        while not this.at_end():
            if this.peek().kind is token.TokenKind.dedent:
                this.advance()
                return first
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else:
                let stmt = this.parse_statement()
                if first == 0z:
                    first = stmt
        return first

    editable function parse_statement() -> ast.NodeId:
        let tok = this.peek().kind
        if tok is token.TokenKind.keyword_let:
            return this.parse_let_stmt()
        else if tok is token.TokenKind.keyword_var:
            return this.parse_var_stmt()
        else if tok is token.TokenKind.keyword_return:
            return this.parse_return_stmt()
        else if tok is token.TokenKind.keyword_if:
            return this.parse_if_stmt()
        else if tok is token.TokenKind.keyword_while:
            return this.parse_while_stmt()
        else if tok is token.TokenKind.keyword_for:
            return this.parse_for_stmt()
        else if tok is token.TokenKind.keyword_break:
            this.advance()
            return 0z
        else if tok is token.TokenKind.keyword_continue:
            this.advance()
            return 0z
        else if tok is token.TokenKind.keyword_pass:
            this.advance()
            return 0z
        else if tok is token.TokenKind.keyword_defer:
            return this.parse_defer_stmt()
        else if tok is token.TokenKind.keyword_unsafe:
            return this.parse_unsafe_stmt()
        else if tok is token.TokenKind.keyword_match:
            return this.parse_match_stmt()
        else if tok is token.TokenKind.keyword_when:
            return this.parse_when_stmt()
        else:
            let expr = this.parse_expression()
            if not (this.peek().kind is token.TokenKind.op_assign) and not (this.peek().kind is token.TokenKind.op_plus_assign) and not (this.peek().kind is token.TokenKind.op_minus_assign) and not (this.peek().kind is token.TokenKind.op_star_assign):
                return this.alloc_stmt(ast.Stmt.expression_stmt(expr_id = expr, line = 0))
            let op_tok = this.peek()
            this.advance()
            let value = this.parse_expression()
            return this.alloc_stmt(ast.Stmt.assignment(target = expr, operator = op_tok.lexeme, value = value, line = 0, column = 0))

    editable function parse_let_stmt() -> ast.NodeId:
        this.advance()
        let name = this.parse_identifier()
        var type_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_colon:
            this.advance()
            type_id = this.parse_expression()
        var value_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_assign:
            this.advance()
            value_id = this.parse_expression()
        return this.alloc_stmt(ast.Stmt.local_decl(
            kind = "let", name = name, type_id = type_id, value_id = value_id,
            else_body = 0z, line = 0, column = 0,
        ))

    editable function parse_var_stmt() -> ast.NodeId:
        this.advance()
        let name = this.parse_identifier()
        var type_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_colon:
            this.advance()
            type_id = this.parse_expression()
        var value_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_assign:
            this.advance()
            value_id = this.parse_expression()
        return this.alloc_stmt(ast.Stmt.local_decl(
            kind = "var", name = name, type_id = type_id, value_id = value_id,
            else_body = 0z, line = 0, column = 0,
        ))

    editable function parse_return_stmt() -> ast.NodeId:
        this.advance()
        var value_id: ast.NodeId = 0z
        if not (this.peek().kind is token.TokenKind.newline) and not (this.peek().kind is token.TokenKind.dedent):
            value_id = this.parse_expression()
        return this.alloc_stmt(ast.Stmt.return_stmt(value_id = value_id, line = 0, column = 0))

    editable function parse_if_stmt() -> ast.NodeId:
        this.advance()
        let condition = this.parse_expression()
        let body = this.parse_block_body()
        var else_body: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.keyword_else:
            this.advance()
            if this.peek().kind is token.TokenKind.keyword_if:
                else_body = this.parse_if_stmt()
            else:
                else_body = this.parse_block_body()
        return this.alloc_stmt(ast.Stmt.if_stmt(
            branches_start = 0z, branches_len = 0z, else_body = else_body,
            is_inline = false, line = 0, column = 0,
        ))

    editable function parse_while_stmt() -> ast.NodeId:
        this.advance()
        let condition = this.parse_expression()
        let body = this.parse_block_body()
        return this.alloc_stmt(ast.Stmt.while_stmt(
            condition = condition, body = body, is_inline = false, line = 0, column = 0,
        ))

    editable function parse_for_stmt() -> ast.NodeId:
        pass
        return 0z

    editable function parse_match_stmt() -> ast.NodeId:
        pass
        return 0z

    editable function parse_defer_stmt() -> ast.NodeId:
        pass
        return 0z

    editable function parse_unsafe_stmt() -> ast.NodeId:
        pass
        return 0z

    editable function parse_when_stmt() -> ast.NodeId:
        pass
        return 0z

    # ── Declaration parsing (implemented) ──

    editable function parse_function_def(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        var params_start: ast.NodeId = 0z
        var params_len: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_lparen:
            this.advance()
            params_start = this.file.params.len
            this.parse_params()
            params_len = this.file.params.len - params_start
            this.consume_rparen()
        var return_type: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_arrow:
            this.advance()
            return_type = this.parse_expression()
        let body = this.parse_block_body()
        this.file.declarations.push(ast.Decl.func_def(
            name = name, params_start = params_start, params_len = params_len,
            return_type = return_type, body = body, visibility = visibility,
            is_async = false, is_const = false,
        ))

    editable function parse_params() -> void:
        if this.peek().kind is token.TokenKind.op_rparen:
            return
        this.parse_param()
        while this.peek().kind is token.TokenKind.op_comma:
            this.advance()
            this.parse_param()

    editable function parse_param() -> void:
        let name = this.parse_identifier()
        this.consume_colon()
        let _type_expr = this.parse_expression()
        this.file.params.push(ast.Param(
            name = name, param_type = this.empty_type_ref(), line = 0, column = 0,
        ))

    editable function parse_const_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        var type_id: ast.NodeId = 0z
        var value_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_arrow:
            this.advance()
            type_id = this.parse_type_ref_expr()
            let body = this.parse_block_body()
            this.file.declarations.push(ast.Decl.const_decl(
                name = name, type_id = type_id, value_id = 0z, visibility = visibility,
            ))
            return
        this.consume_colon()
        type_id = this.parse_type_ref_expr()
        this.consume_equal()
        value_id = this.parse_expression()
        this.file.declarations.push(ast.Decl.const_decl(
            name = name, type_id = type_id, value_id = value_id, visibility = visibility,
        ))

    editable function parse_var_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        var type_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_colon:
            this.advance()
            type_id = this.parse_type_ref_expr()
        var value_id: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_assign:
            this.advance()
            value_id = this.parse_expression()
        this.file.declarations.push(ast.Decl.var_decl(
            name = name, type_id = type_id, value_id = value_id, visibility = visibility,
        ))

    editable function parse_type_alias_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_equal()
        let target = this.parse_type_ref_expr()
        this.file.declarations.push(ast.Decl.type_alias_decl(
            name = name, target_type = target, visibility = visibility,
        ))

    editable function parse_struct_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_colon()
        this.consume_newline()
        this.expect_indent()
        var fields_start: ast.NodeId = 0z
        var fields_count: ast.NodeId = 0z
        fields_start = this.file.fields.len
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else:
                this.parse_struct_field()
                fields_count += 1
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()
        this.file.declarations.push(ast.Decl.struct_decl(
            name = name,
            fields_start = fields_start,
            fields_len = fields_count,
            visibility = visibility,
        ))

    editable function parse_struct_field() -> void:
        let field_name = this.parse_identifier()
        this.consume_colon()
        let _field_type = this.parse_expression()
        this.file.fields.push(ast.Field(name = field_name, field_type = this.empty_type_ref()))

    editable function empty_type_ref() -> ast.TypeRef:
        return ast.TypeRef(
            arguments = vec.Vec[ast.TypeArgument].create(),
            nullable = false,
            name = ast.QualifiedName(parts = vec.Vec[str].create()),
        )

    editable function parse_enum_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_colon()
        let _backing_type = this.parse_type_ref_expr()
        this.consume_newline()
        this.expect_indent()
        var members_start: ast.NodeId = 0z
        var members_count: ast.NodeId = 0z
        members_start = this.file.enum_members.len
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else:
                let m_name = this.parse_identifier()
                this.consume_equal()
                let m_value = this.parse_expression()
                this.file.enum_members.push(ast.EnumMember(name = m_name, value = m_value))
                members_count += 1
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()
        this.file.declarations.push(ast.Decl.enum_decl(
            name = name,
            backing_type = 0z,
            members_start = members_start,
            members_len = members_count,
            visibility = visibility,
        ))

    editable function parse_flags_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_colon()
        let _backing_type = this.parse_type_ref_expr()
        this.consume_newline()
        this.expect_indent()
        var members_start: ast.NodeId = 0z
        var members_count: ast.NodeId = 0z
        members_start = this.file.enum_members.len
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else:
                let m_name = this.parse_identifier()
                this.consume_equal()
                let m_value = this.parse_expression()
                this.file.enum_members.push(ast.EnumMember(name = m_name, value = m_value))
                members_count += 1
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()
        this.file.declarations.push(ast.Decl.flags_decl(
            name = name,
            backing_type = 0z,
            members_start = members_start,
            members_len = members_count,
            visibility = visibility,
        ))

    editable function parse_variant_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_colon()
        this.consume_newline()
        this.expect_indent()
        var arms_start: ast.NodeId = 0z
        var arms_count: ast.NodeId = 0z
        arms_start = this.file.variant_arms.len
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else:
                let arm_name = this.parse_identifier()
                var fields_start: ast.NodeId = 0z
                var fields_count: ast.NodeId = 0z
                if this.peek().kind is token.TokenKind.op_lparen:
                    this.advance()
                    fields_start = this.file.variant_arm_fields.len
                    if not (this.peek().kind is token.TokenKind.op_rparen):
                        while true:
                            let f_name = this.parse_identifier()
                            this.consume_colon()
                            let _f_type = this.parse_type_ref_expr()
                            this.file.variant_arm_fields.push(ast.VariantArmField(
                                name = f_name,
                                field_type = this.empty_type_ref(),
                            ))
                            fields_count += 1
                            if this.peek().kind is token.TokenKind.op_comma:
                                this.advance()
                            else:
                                break
                    this.consume_rparen()
                var arm = ast.VariantArm(name = arm_name, fields = vec.Vec[ast.VariantArmField].create())
                this.file.variant_arms.push(arm)
                arms_count += 1
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()
        this.file.declarations.push(ast.Decl.variant_decl(
            name = name,
            type_params_start = 0z,
            type_params_len = 0z,
            arms_start = arms_start,
            arms_len = arms_count,
            visibility = visibility,
        ))

    editable function parse_opaque_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.file.declarations.push(ast.Decl.opaque_decl(
            name = name, c_name = "", visibility = visibility,
        ))

    editable function parse_interface_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_colon()
        this.consume_newline()
        this.expect_indent()
        var methods_count: ast.NodeId = 0z
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_editable:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_static:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_function:
                this.advance()
                this.parse_identifier()
                this.consume_colon()
                this.consume_newline()
                this.expect_indent()
                if this.peek().kind is token.TokenKind.dedent:
                    this.advance()
                methods_count += 1
            else:
                this.advance()
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()
        this.file.declarations.push(ast.Decl.interface_decl(
            name = name,
            methods_start = 0z,
            methods_len = 0z,
            visibility = visibility,
        ))

    editable function parse_extending_block() -> void:
        this.advance()
        let _type_name = this.parse_identifier()
        this.consume_colon()
        this.consume_newline()
        this.expect_indent()
        while not this.at_end() and not (this.peek().kind is token.TokenKind.dedent):
            if this.peek().kind is token.TokenKind.newline:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_editable:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_static:
                this.advance()
            else if this.peek().kind is token.TokenKind.keyword_function:
                this.advance()
                let m_name = this.parse_identifier()
                this.skip_to_body()
            else:
                this.advance()
        if this.peek().kind is token.TokenKind.dedent:
            this.advance()

    editable function parse_event_decl(visibility: str) -> void:
        this.advance()
        let name = this.parse_identifier()
        this.consume_lbracket()
        let capacity_tok = this.peek()
        this.advance()
        var capacity: int = 4
        match capacity_tok.kind:
            token.TokenKind.int_literal(value):
                capacity = value
            _:
                pass
        this.consume_rbracket()
        var payload_type: ast.NodeId = 0z
        if this.peek().kind is token.TokenKind.op_lparen:
            this.advance()
            payload_type = this.parse_type_ref_expr()
            this.consume_rparen()
        this.file.declarations.push(ast.Decl.event_decl(
            name = name,
            capacity = capacity,
            payload_type = payload_type,
            visibility = visibility,
        ))

    editable function parse_static_assert() -> void:
        this.advance()
        let _condition = this.parse_expression()
        this.file.declarations.push(ast.Decl.static_assert_decl(
            condition = 0z, message = "", line = 0,
        ))

    editable function parse_attribute_decl(visibility: str) -> void:
        this.advance()

    editable function parse_foreign_func_decl(visibility: str) -> void:
        this.advance()

    editable function parse_module_when() -> void:
        this.advance()

    editable function parse_emit_decl() -> void:
        this.advance()

    # ── Helpers ──

    editable function consume_equal() -> void:
        if this.peek().kind is token.TokenKind.op_assign:
            this.advance()
        else:
            this.emit_error(this.peek(), "expected '='")

    editable function consume_lbracket() -> void:
        if this.peek().kind is token.TokenKind.op_lbracket:
            this.advance()
        else:
            this.emit_error(this.peek(), "expected '['")

    editable function parse_type_ref_expr() -> ast.NodeId:
        return this.parse_expression()

    editable function skip_to_body() -> void:
        while not this.at_end():
            if this.peek().kind is token.TokenKind.op_colon:
                this.advance()
                while not this.at_end() and not (this.peek().kind is token.TokenKind.newline):
                    this.advance()
                let _body = this.parse_block_body()
                return
            this.advance()
