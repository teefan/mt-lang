# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerHover
        private

        KEYWORD_HOVER_INFO = {
          'size_of' => {
            signature: 'size_of(Type) -> ptr_uint',
            docs: '`size_of(Type)` evaluates the compile-time size (in bytes) of the type.',
          },
          'align_of' => {
            signature: 'align_of(Type) -> ptr_uint',
            docs: '`align_of(Type)` evaluates the compile-time alignment (in bytes) of the type.',
          },
          'offset_of' => {
            signature: 'offset_of(Type, field) -> ptr_uint',
            docs: '`offset_of(Type, field)` evaluates the compile-time byte offset of `field` within `Type`.',
          },
        }.freeze

        LANGUAGE_KEYWORD_HOVER_INFO = {
          'let' => {
            signature: 'let',
            docs: 'Immutable local variable declaration: `let name = value` or `let name: Type`. Supports `else` guard with `T?`, `Option[T]`, or `Result[T, E]`.',
          },
          'var' => {
            signature: 'var',
            docs: 'Mutable local or module-level variable: `var name: Type = initializer`. Supports `else` guard. Module `var` requires explicit type.',
          },
          'const' => {
            signature: 'const',
            docs: 'Compile-time constant, requires explicit type and initializer. Block-bodied form `const NAME -> TYPE:` evaluates at compile time.',
          },
          'function' => {
            signature: 'function',
            docs: 'Ordinary function declaration: `function name(params) -> ReturnType:`. Parameters are non-rebindable. Return type defaults to `void`.',
          },
          'async' => {
            signature: 'async',
            docs: 'Marks a function as async; the declared return type is lifted to `Task[T]`. Use `await` inside async functions.',
          },
          'await' => {
            signature: 'await',
            docs: 'Awaits a `Task[T]` inside an async function, yielding the unwrapped `T`. Only allowed in async function bodies.',
          },
          'struct' => {
            signature: 'struct',
            docs: 'Value-type struct with named, typed fields: `struct Name: field: Type`. Supports generics, nested structs, and `implements`.',
          },
          'enum' => {
            signature: 'enum',
            docs: 'Integer-backed enumeration: `enum Name: BackingType`. Backing type defaults to `int`. Values auto-increment from 0 or the last explicit value.',
          },
          'flags' => {
            signature: 'flags',
            docs: 'Bitmask type backed by an integer primitive: `flags Name: uint`. Members must be compile-time integer constants.',
          },
          'union' => {
            signature: 'union',
            docs: 'Overlapped storage union: `union Name: field1: Type1, field2: Type2`. All fields share the same memory.',
          },
          'variant' => {
            signature: 'variant',
            docs: 'Tagged union: `variant Name: arm1(field: Type), arm2`. Arms may carry named payload fields. No-payload arms are bare identifiers.',
          },
          'opaque' => {
            signature: 'opaque',
            docs: 'Externally-defined type with unknown layout: `opaque Name`. May declare `implements` for interface conformance.',
          },
          'type' => {
            signature: 'type',
            docs: 'Type alias: `type Name = ExistingType`. Generic type parameters are supported.',
          },
          'interface' => {
            signature: 'interface',
            docs: 'Declares a method contract: `interface Name: function method(params) -> T`. Implemented via `implements`; used at runtime via `dyn[Interface]`.',
          },
          'extending' => {
            signature: 'extending',
            docs: 'Extends an existing type with methods: `extending Type: function method():`. Supports `function`, `editable function`, and `static function`.',
          },
          'implements' => {
            signature: 'implements',
            docs: 'Nominal interface conformance on `struct` or `opaque`: `struct Foo implements Interface`. Must be declared on the type definition.',
          },
          'editable' => {
            signature: 'editable',
            docs: 'Method receiver modifier: `editable function`. Grants mutable access to `this`. Used in interfaces and extending blocks.',
          },
          'static' => {
            signature: 'static',
            docs: 'Static method modifier: `static function`. No `this` receiver. Used in interfaces and extending blocks for constructors and utilities.',
          },
          'import' => {
            signature: 'import',
            docs: 'Module import: `import module.path` or `import module.path as alias`. Module lookup resolves `a.b.c` to `a/b/c.mt`.',
          },
          'public' => {
            signature: 'public',
            docs: 'Export visibility modifier: `public function`, `public type`, etc. Rejected on `extending`, `external`, and `static_assert` declarations.',
          },
          'if' => {
            signature: 'if',
            docs: 'Conditional branch: `if condition:`. Condition must be `bool`. Supports `else if` and `else`. Inline form: `if cond: stmt else: stmt`.',
          },
          'else' => {
            signature: 'else',
            docs: 'Else branch for `if`. Chains as `else if condition:` for additional branches. Supports inline single-statement form `else: stmt`.',
          },
          'match' => {
            signature: 'match',
            docs: 'Pattern match on enum, variant, integer, `str`, or tuple. Expression form produces a value. Must be exhaustive without `_` wildcard.',
          },
          'for' => {
            signature: 'for',
            docs: 'Loop: `for i in 0..count:` (exclusive range) or `for item in iterable:`. Multi-iteration `for left, right in xs, ys:` iterates arrays/spans in lockstep.',
          },
          'while' => {
            signature: 'while',
            docs: 'Conditional loop: `while condition:`. Condition must be `bool`. Supports `break`, `continue`, and `defer` inside the body.',
          },
          'return' => {
            signature: 'return',
            docs: 'Returns a value from a function. Not allowed inside `defer` blocks.',
          },
          'break' => {
            signature: 'break',
            docs: 'Exits the nearest enclosing `for`, `while`, or `parallel for` loop.',
          },
          'continue' => {
            signature: 'continue',
            docs: 'Skips to the next iteration of the nearest enclosing `for` or `while` loop.',
          },
          'defer' => {
            signature: 'defer',
            docs: 'Defers an expression or block to function exit: `defer expr` or `defer:`. Multiple defers execute in LIFO order. `return` is not allowed inside.',
          },
          'unsafe' => {
            signature: 'unsafe',
            docs: 'Required for pointer indexing, raw pointer dereference, pointer arithmetic, pointer casts, and `reinterpret[...]`. Single-expr or block form.',
          },
          'external' => {
            signature: 'external',
            docs: 'Raw C ABI surface: `external function name(params) -> T`. No body, supports variadic `...`. Also marks external files with `external` header.',
          },
          'foreign' => {
            signature: 'foreign',
            docs: 'Foreign function bridging: `foreign function name(params) -> T = c.FuncName`. Supports `in`, `out`, `inout`, and `consuming` parameter modes.',
          },
          'consuming' => {
            signature: 'consuming',
            docs: 'Foreign function parameter mode: takes ownership of the argument. The caller\'s binding is consumed. Only on `foreign function` params.',
          },
          'when' => {
            signature: 'when',
            docs: 'Compile-time conditional: `when CONSTANT:`. Only the chosen branch is type-checked and emitted. Requires `else` unless exhaustive.',
          },
          'inline' => {
            signature: 'inline',
            docs: 'Compile-time unrolling modifier: `inline for` (loop unrolling), `inline while`, `inline match`, `inline if`. Only the active branch emits code.',
          },
          'emit' => {
            signature: 'emit',
            docs: 'Emits a declaration at compile time: `emit function ...`. Only allowed inside `const function` or `inline` bodies.',
          },
          'parallel' => {
            signature: 'parallel',
            docs: 'Concurrency construct: `parallel for i in 0..N:` (data-parallel loop) or `parallel:` block (concurrent statement dispatch). Uses OS threads via libuv.',
          },
          'detach' => {
            signature: 'detach',
            docs: 'Spawns work on a separate thread, returning a `Handle`: `let h = detach func()`. Use `gather` to wait. Supports global function calls only.',
          },
          'gather' => {
            signature: 'gather',
            docs: 'Blocks until one or more `detach` handles complete: `gather h1, h2`. Takes one or more `Handle` values.',
          },
          'event' => {
            signature: 'event',
            docs: 'Typed publisher/subscriber: `event name[capacity]` or `event name[capacity](PayloadType)`. Supports `subscribe`, `emit`, `unsubscribe`, `wait`.',
          },
          'attribute' => {
            signature: 'attribute',
            docs: 'Declares a reusable declaration attribute: `attribute[target, ...] name(params)`. Targets: struct, field, callable, const, event, enum, flags, union, variant.',
          },
          'proc' => {
            signature: 'proc',
            docs: 'Ref-counted closure: `proc(params...) -> T: body`. Captures values by value. Storable in structs, arrays, and tuples.',
          },
          'fn' => {
            signature: 'fn',
            docs: 'Function pointer type: `fn(params...) -> T`. Points to module-level functions. No captured state; capture-free.',
          },
          'dyn' => {
            signature: 'dyn',
            docs: 'Runtime interface value: `dyn[Interface]`. A fat pointer carrying a data pointer and vtable. Constructed via `adapt[Interface](value)`.',
          },
          'is' => {
            signature: 'is',
            docs: 'Variant arm membership test: `expr is Variant.arm`. Desugars to a `match` expression evaluating to `bool`. Supports `not` negation.',
          },
          'pass' => {
            signature: 'pass',
            docs: 'Explicit no-op statement for intentionally empty block bodies.',
          },
          'null' => {
            signature: 'null',
            docs: 'Null value for nullable types (`T?`). Use typed `null[T]` when context cannot determine the target type.',
          },
          'true' => {
            signature: 'true',
            docs: 'Boolean literal `true`. Type is `bool`.',
          },
          'false' => {
            signature: 'false',
            docs: 'Boolean literal `false`. Type is `bool`.',
          },
          'static_assert' => {
            signature: 'static_assert',
            docs: 'Compile-time assertion: `static_assert(condition, message)`. Fails compilation if the compile-time condition is false.',
          },
        }.freeze

        BUILTIN_TYPE_DOCS = {
          'bool' => '1-byte boolean: `true` or `false`.',
          'byte' => '8-bit signed integer. Range: -128 to 127.',
          'ubyte' => '8-bit unsigned integer. Range: 0 to 255. Also used for `char` literals like `\'A\'`.',
          'char' => '8-bit character type (alias for `ubyte`).',
          'short' => '16-bit signed integer. Range: -32,768 to 32,767.',
          'ushort' => '16-bit unsigned integer. Range: 0 to 65,535.',
          'int' => '32-bit signed integer. Range: -2,147,483,648 to 2,147,483,647. Default enum backing type.',
          'uint' => '32-bit unsigned integer. Range: 0 to 4,294,967,295.',
          'long' => '64-bit signed integer.',
          'ulong' => '64-bit unsigned integer.',
          'ptr_int' => 'Pointer-sized signed integer. Width matches the target platform pointer size.',
          'ptr_uint' => 'Pointer-sized unsigned integer. Return type for `size_of`, `align_of`, `offset_of`.',
          'float' => '32-bit IEEE 754 single-precision float.',
          'double' => '64-bit IEEE 754 double-precision float.',
          'void' => 'Empty type for functions with no return value. Not a storable type.',
          'str' => 'Non-owning UTF-8 string view (pointer + length). Not null-terminated.',
          'cstr' => 'Null-terminated C string. Used at FFI boundaries.',
          'vec2' => '2-component float vector. Fields: `.x`, `.y`. Supports component-wise arithmetic.',
          'vec3' => '3-component float vector. Fields: `.x`, `.y`, `.z`. Supports component-wise arithmetic and `dot`/`cross`/`length` via `std.linear_algebra`.',
          'vec4' => '4-component float vector. Fields: `.x`, `.y`, `.z`, `.w`. Supports component-wise arithmetic.',
          'ivec2' => '2-component integer vector. Fields: `.x`, `.y`. Supports component-wise arithmetic.',
          'ivec3' => '3-component integer vector. Fields: `.x`, `.y`, `.z`. Supports component-wise arithmetic.',
          'ivec4' => '4-component integer vector. Fields: `.x`, `.y`, `.z`, `.w`. Supports component-wise arithmetic.',
          'mat3' => '3×3 column-major float matrix. Columns: `.col0`–`.col2` (each `vec3`). Supports `identity`, `transpose` via `std.linear_algebra`.',
          'mat4' => '4×4 column-major float matrix. Columns: `.col0`–`.col3` (each `vec4`). Supports `identity`, `transpose` via `std.linear_algebra`.',
          'quat' => 'Quaternion. Fields: `.x`, `.y`, `.z`, `.w`. Layout-compatible with `vec4`. Supports `identity`, `conjugate` via `std.linear_algebra`.',
          'ptr' => 'Generic pointer type: `ptr[T]`. Raw mutable pointer. Requires `unsafe` for indexing, dereference, and arithmetic.',
          'const_ptr' => 'Read-only pointer type: `const_ptr[T]`. Immutable pointer, does not require `unsafe` for dereference.',
          'own' => 'Owning heap pointer: `own[T]`. Auto-dereferences like `ref`. Storable, returnable, and nullable. Allocated via `heap.must_alloc[T](count)`.',
          'ref' => 'Non-null borrow reference: `ref[T]`. Auto-dereferences for member access and method calls. Cannot be stored in module variables or constants.',
          'span' => 'Borrowed pointer-plus-length view: `span[T]`. Constructed via `span[T](data = ..., len = ...)`. Arrays coerce implicitly.',
          'array' => 'Fixed-length array: `array[T, N]`. Constructed via `array[T, N](elements...)`. Omitted trailing elements default to zero.',
          'str_buffer' => 'Fixed-capacity mutable UTF-8 text buffer: `str_buffer[N]`. Methods: `assign`, `append`, `assign_format`, `append_format`, `clear`, `as_str`, `as_cstr`.',
          'atomic' => 'Atomic value for lock-free concurrent access: `atomic[T]`. `T` must be a primitive integer or `bool`. Methods: `load`, `store`, `add`, `sub`, `exchange`. Uses C11 `_Atomic`.',
          'Task' => 'Async task future: `Task[T]`. Returned by `async function`. Use `await` to unwrap, or `aio.wait`/`aio.run` to drive.',
          'Option' => 'Built-in optional type: `Option[T]`. Arms: `some(value: T)` and `none`. Use `let ... else:` or `?` for safe unwrapping.',
          'Result' => 'Built-in result type: `Result[T, E]`. Arms: `success(value: T)` and `failure(error: E)`. Use `let ... else:` or `?` for error propagation.',
          'SoA' => 'Struct-of-Arrays: `SoA[T, N]`. Each struct field becomes a separate array of length `N`. Access `soa[i].field` reads from column `field` at row `i`.',
          'struct_handle' => 'Compile-time handle for a struct type. Obtained via reflection builtins like `fields_of`.',
          'field_handle' => 'Compile-time handle for a struct field. Exposes `.name` and `.type`. Obtained via `field_of` and `fields_of`.',
          'callable_handle' => 'Compile-time handle for a callable declaration. Obtained via `callable_of`. Used with `has_attribute`, `attribute_of`.',
          'attribute_handle' => 'Compile-time handle for an applied attribute. Obtained via `attribute_of` and `attributes_of`. Use `attribute_arg[T]` to read arguments.',
          'member_handle' => 'Compile-time handle for an enum or flags member. Exposes `.name` and `.value`. Obtained via `members_of`.',
          'EventError' => 'Built-in enum returned when event listener capacity is exhausted. Single member: `full`.',
          'Subscription' => 'Opaque handle returned by `event.subscribe`. Pass to `event.unsubscribe` to remove a listener.',
        }.freeze

        BUILTIN_TYPE_METHOD_SIGNATURES = {
          'atomic' => {
            'load' => 'function load() -> T',
            'store' => 'static function store(value: T) -> void',
            'add' => 'static function add(value: T) -> T',
            'sub' => 'static function sub(value: T) -> T',
            'exchange' => 'static function exchange(value: T) -> T',
            'compare_exchange' => 'static function compare_exchange(expected: T, desired: T) -> bool',
          },
          'str_buffer' => {
            'assign' => 'static function assign(value: str) -> void',
            'append' => 'static function append(value: str) -> void',
            'assign_format' => 'static function assign_format(fmt: str) -> void',
            'append_format' => 'static function append_format(fmt: str) -> void',
            'clear' => 'static function clear() -> void',
            'len' => 'static function len() -> ptr_uint',
            'capacity' => 'static function capacity() -> ptr_uint',
            'as_str' => 'static function as_str() -> str',
            'as_cstr' => 'static function as_cstr() -> cstr',
          },
        }.freeze

      def handle_hover(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri       = params['textDocument']['uri']
        lsp_line  = params['position']['line']
        lsp_char  = params['position']['character']
        token_kind = 'none'
        result_state = 'miss'

        context = measure_perf_stage(stages, 'context') { token_context_at(uri, lsp_line, lsp_char) }
        token = context&.fetch(:token, nil)
        token_kind = token&.type || :none
        unless token&.type == :identifier
          info = builtin_keyword_hover_info(token)
          if info
            result_state = 'hit'
            return {
              contents: {
                kind: 'markdown',
                value: render_hover_markdown(info)
              },
              range: token_to_range(token)
            }
          end

          result_state = 'not-identifier'
          return nil
        end

        info = resolve_hover_info(uri, lsp_line, lsp_char, token: token, tokens: context[:tokens], token_index: context[:token_index], stages: stages)
        return nil unless info

        result = measure_perf_stage(stages, 'render') do
          {
            contents: {
              kind: 'markdown',
              value: render_hover_markdown(info)
            },
            range: token_to_range(token)
          }
        end
        result_state = 'hit'
        result
      rescue StandardError => e
        result_state = 'error'
        warn "Error in hover handler: #{e.message}"
        nil
      ensure
        log_request_stage_breakdown('textDocument/hover', total_start, uri: uri, stages: stages, summary: "token=#{token_kind} result=#{result_state}")
      end

      def resolve_hover_info(uri, lsp_line, lsp_char, token: nil, tokens: nil, token_index: nil, stages: nil)
        if token.nil?
          context = measure_perf_stage(stages, 'context') { token_context_at(uri, lsp_line, lsp_char) }
          return nil unless context

          token = context[:token]
          tokens = context[:tokens]
          token_index = context[:token_index]
        end

        return nil unless token&.type == :identifier

        tokens ||= @workspace.get_tokens(uri) || []
        token_index = tokens.index(token) if token_index.nil?
        if token_index
          module_info = module_declaration_info_at(tokens, token_index)
          if module_info
            location = module_definition_location(uri, module_info[:module_name])
            return {
              signature: "module #{module_info[:module_name]}",
              docs: nil,
              source: hover_source_label_from_location(location),
              source_uri: hover_source_uri_from_location(location),
              source_line: hover_source_line_from_location(location),
            }
          end
        end

        if token_index
          import_info = import_path_info_at(tokens, token_index)
          if import_info
            location = module_definition_location(uri, import_info[:module_name])
            return {
              signature: "module #{import_info[:module_name]}",
              docs: nil,
              source: hover_source_label_from_location(location),
              source_uri: hover_source_uri_from_location(location),
              source_line: hover_source_line_from_location(location),
            }
          end
        end

        facts = measure_perf_stage(stages, 'facts') do
          @workspace.get_facts(uri, allow_last_good_fallback: allow_hover_last_good_fallback?(uri))
        end
        return nil unless facts

        if token_index && field_declaration_token?(tokens, token_index)
          return resolve_field_declaration_hover_info(uri, facts, tokens, token_index)
        end

        if token_index && named_argument_label_token?(tokens, token_index)
          return resolve_named_argument_label_hover_info(uri, facts, tokens, token_index)
        end

        if token_index && (member_hover = resolve_member_access_hover_info(uri, facts, tokens, token_index))
          return member_hover
        end

        if token_index && (enum_member_hover = resolve_enum_member_hover_info(uri, facts, tokens, token_index))
          return enum_member_hover
        end

        name = token.lexeme
        signature = nil
        docs = nil
        source_location = nil

        if (binding = method_binding_at_token(facts, token))
          signature = method_signature(binding)
          source_location = module_member_binding_location(uri, facts.module_name, name, binding)
        end

        unless signature
          if token_index && (for_binding_info = resolve_for_binding_hover_info(tokens, token_index))
            signature = for_binding_info[:signature]
          end
        end

        unless signature
          if token_index && match_arm_binding_token?(tokens, token_index)
            if (local_binding = resolve_as_binding_declaration_hover_binding(facts, name, lsp_line + 1, lsp_char + 1))
              signature = value_hover_signature(local_binding)
            end
          end
        end

        unless signature
          if (local_binding = resolve_local_hover_binding(facts, name, lsp_line + 1, lsp_char + 1))
            signature = value_hover_signature(local_binding)
          end
        end

        unless signature
          if (binding = facts.functions[name])
            params_str = format_params(binding.type.params)
            signature = "function #{name}(#{params_str}) -> #{binding.type.return_type}"
          elsif (binding = facts.interfaces[name])
            signature = interface_signature(binding)
            source_location = module_member_definition_location(uri, binding.module_name, name)
          elsif facts.types.key?(name)
            type = facts.types[name]
            signature = type_hover_signature(name, type)
            docs ||= BUILTIN_TYPE_DOCS[name]
          elsif !name.include?(".") && (nested = find_nested_type_by_short_name(facts, name))
            signature = type_hover_signature(name, nested)
            docs ||= BUILTIN_TYPE_DOCS[name]
          elsif (binding = facts.values[name])
            signature = value_hover_signature(binding)
          elsif (member_info = find_member_in_types(facts, name))
            type, member, value = member_info
            signature = value ? "#{type.name}.#{member} = #{value}" : "#{type.name}.#{member}"
            source_location ||= module_member_definition_location(uri, facts.module_name, name) ||
                                module_definition_location(uri, facts.module_name)
          elsif (arm_sig = find_variant_arm_in_types(facts, name))
            signature = arm_sig
            source_location ||= module_member_definition_location(uri, facts.module_name, name) ||
                                module_definition_location(uri, facts.module_name)
          elsif (import_binding = facts.imports[name])
            signature = "module #{import_binding.name}"
            source_location = module_definition_location(uri, import_binding.name)
          else
            dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          dot_receiver_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
          if dot_receiver && (module_binding = facts.imports[dot_receiver])
            if (fn = module_binding.functions[name])
              params_str = format_params(fn.type.params)
              signature = "function #{name}(#{params_str}) -> #{fn.type.return_type}"
              source_location = module_member_binding_location(uri, module_binding.name, name, fn)
            elsif (val = module_binding.values[name])
              signature = value_hover_signature(val)
            elsif module_binding.types.key?(name)
              signature = "type #{name}"
              docs ||= BUILTIN_TYPE_DOCS[name]
            elsif (binding = module_binding.interfaces[name])
              signature = interface_signature(binding)
              source_location = module_member_definition_location(uri, module_binding.name, name)
            end

            if signature
              source_location ||= module_member_definition_location(uri, module_binding.name, name)
              source_location ||= module_definition_location(uri, module_binding.name)
            end
          end

          unless signature
            if (type_method = resolve_static_type_receiver_method(facts, dot_receiver, dot_receiver_path, name))
              signature = method_signature(type_method[:binding])
              source_location = module_member_binding_location(uri, type_method[:module_name], name, type_method[:binding])
              source_location ||= module_member_definition_location(uri, type_method[:module_name], name)
              source_location ||= module_definition_location(uri, type_method[:module_name])
            end
          end

          unless signature
            if dot_receiver
              receiver_name = dot_receiver
              receiver_binding = resolve_local_hover_binding(facts, receiver_name, lsp_line + 1, lsp_char + 1) ||
                                 facts.values[receiver_name] ||
                                 facts.functions[receiver_name]
              if receiver_binding && receiver_binding.type
                receiver_type = receiver_binding.respond_to?(:storage_type) ? receiver_binding.storage_type : receiver_binding.type
                methods = methods_for_receiver_type(facts, receiver_type)
                if (method_binding = methods[name])
                  signature = method_signature(method_binding)
                else
                  type_base = receiver_type.to_s[/^([a-z_]+)/, 1]
                  if type_base && (method_sigs = BUILTIN_TYPE_METHOD_SIGNATURES[type_base])
                    signature = method_sigs[name]
                  end
                end
              end
            end
          end

          unless signature
            if token_index && (builtin_info = builtin_hover_info(name, tokens, token_index))
              signature = builtin_info[:signature]
              docs = builtin_info[:docs]
            end
          end

          unless signature
            unless token_index && tokens && tokens[previous_non_trivia_token_index(tokens, token_index)]&.type == :dot
              local_def = @workspace.find_definition_token_global(
                name,
                preferred_uri: uri,
                before_line: lsp_line + 1,
                before_char: lsp_char + 1,
              )
              if local_def
                signature = resolve_lexical_local_hover_signature(local_def[:uri], name, local_def[:token])
              end
            end
          end
          end

          return nil unless signature
        end

        definition_entry = if source_location
                             measure_perf_stage(stages, 'definition_entry') { hover_definition_entry_from_location(source_location) }
                           else
                             measure_perf_stage(stages, 'global_definition') do
                               @workspace.find_definition_token_global(
                                 name,
                                 preferred_uri: uri,
                                 before_line: lsp_line + 1,
                                 before_char: lsp_char + 1,
                               )
                             end
                           end

        source_uri = hover_source_uri_for_definition(definition_entry) || hover_source_uri_from_location(source_location)
        source_line = hover_source_line_for_definition(definition_entry) || hover_source_line_from_location(source_location)

        {
          signature: signature,
          docs: docs || hover_doc_comment_for_definition(definition_entry),
          doc_comment: hover_doc_comment_data_for_definition(definition_entry),
          source: hover_source_label_for_definition(definition_entry) || hover_source_label_from_location(source_location),
          source_uri: source_uri,
          source_line: source_line,
        }
      end

      def token_context_at(uri, lsp_line, lsp_char)
        tokens = @workspace.get_tokens(uri) || []
        interpolation_context = fstring_interpolation_token_context(tokens, lsp_line, lsp_char)
        return interpolation_context if interpolation_context

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token

        return nil if embedded_heredoc_or_format_heredoc_token?(token)

        {
          token: token,
          tokens: tokens,
          token_index: tokens.index(token),
        }
      end

      def embedded_heredoc_or_format_heredoc_token?(token)
        return false unless [:string, :cstring, :fstring].include?(token.type)

        tag = token.lexeme[/\A(?:f|c)?<<-([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n/, 1]
        return false if tag.nil?

        %w[GLSL VERT FRAG COMP JSON JSONC SQL HTML].include?(tag)
      end

      def fstring_interpolation_token_context(tokens, lsp_line, lsp_char)
        target_line = lsp_line + 1
        target_char = lsp_char + 1

        fstring_token = tokens.find do |token|
          next false unless token.type == :fstring

          token_contains_position?(token, target_line, target_char)
        end
        return nil unless fstring_token

        Array(fstring_token.literal).each do |part|
          next unless part[:kind] == :expr
          next unless part[:line] == target_line

          expression_tokens = interpolation_expression_tokens(part)
          token = expression_tokens.find { |candidate| token_contains_position?(candidate, target_line, target_char) }
          next unless token

          return {
            token: token,
            tokens: expression_tokens,
            token_index: expression_tokens.index(token),
          }
        end

        nil
      end

      def interpolation_expression_tokens(part)
        source = part[:source]
        return [] if source.nil? || source.strip.empty?

        MilkTea::Lexer.new(source).lex
          .reject { |token| [:newline, :indent, :dedent, :eof].include?(token.type) }
          .map do |token|
            adjusted_line = part[:line] + token.line - 1
            adjusted_column = token.line == 1 ? (part[:column] + token.column - 1) : token.column

            token.with(
              line: adjusted_line,
              column: adjusted_column,
              start_offset: nil,
              end_offset: nil,
              leading_trivia: [].freeze,
              trailing_trivia: [].freeze,
            )
          end
      rescue MilkTea::LexError
        []
      end

      def token_contains_position?(token, target_line, target_char)
        segments = token.lexeme.split("\n", -1)
        end_line = token.line + segments.length - 1
        return false if target_line < token.line || target_line > end_line

        if segments.length == 1
          return token.column <= target_char && target_char < (token.column + segments.first.length)
        end

        if target_line == token.line
          return token.column <= target_char && target_char <= (token.column + segments.first.length - 1)
        end

        target_char <= segments.fetch(target_line - token.line).length
      end

      def render_hover_markdown(info)
        lines = []

        signature = info[:signature].to_s
        shortened, modules = shorten_qualified_types(signature)

        lines << "```milk-tea"
        lines << shortened
        lines << "```"

        unless modules.empty?
          prefix = 'From'
          lines << "*#{prefix} #{modules.join(', ')}*"
        end

        rendered_doc_comment = false
        if info[:doc_comment].is_a?(Hash)
          rendered_doc_comment = append_structured_doc_comment_markdown(lines, info[:doc_comment])
        end

        docs = info[:docs].to_s.strip
        unless rendered_doc_comment || docs.empty?
          lines << ""
          lines << docs
        end

        source_uri = info[:source_uri]
        source_line = info[:source_line]
        source_label = info[:source].to_s.strip
        unless source_label.empty?
          lines << ""
          if source_uri && source_line
            link_uri = "#{source_uri}#L#{source_line}"
            lines << "Defined at: [#{source_label}](#{link_uri})"
          else
            lines << "Defined at: #{source_label}"
          end
        end

        lines.join("\n")
      end

      def shorten_qualified_types(signature)
        modules = []
        shortened = signature.gsub(/\b([a-z_][\w]*(?:\.[a-z_][\w]*)*\.)([A-Z]\w*(?:\[[^\]]*\])?(?:\s*\|\s*(?:[a-z_][\w]*(?:\.[a-z_][\w]*)*\.)?[A-Z]\w*(?:\[[^\]]*\])?)*)\b/) do
          prefix = $1
          mod_name = prefix.delete_suffix('.')
          modules << mod_name unless modules.include?(mod_name)
          $2
        end
        [shortened, modules]
      end

      def append_structured_doc_comment_markdown(lines, doc_comment)
        body = doc_comment[:body_markdown].to_s.strip
        tags = doc_comment.fetch(:tags, {})
        params = Array(tags[:params]).reject { |entry| entry[:name].to_s.strip.empty? }
        returns = tags[:returns]
        throws = Array(tags[:throws]).reject { |entry| entry[:text].to_s.strip.empty? }
        see_also = Array(tags[:see]).reject { |entry| entry[:text].to_s.strip.empty? }

        wrote = false
        unless body.empty?
          lines << ""
          lines << body
          wrote = true
        end

        unless params.empty?
          lines << ""
          lines << "**Parameters**"
          params.each do |entry|
            description = entry[:text].to_s.strip
            if description.empty?
              lines << "- `#{entry[:name]}`"
            else
              lines << "- `#{entry[:name]}`: #{description}"
            end
          end
          wrote = true
        end

        if returns
          description = returns[:text].to_s.strip
          unless description.empty?
            lines << ""
            lines << "**Returns**"
            lines << description
            wrote = true
          end
        end

        unless throws.empty?
          lines << ""
          lines << "**Throws**"
          throws.each do |entry|
            lines << "- #{entry[:text]}"
          end
          wrote = true
        end

        unless see_also.empty?
          lines << ""
          lines << "**See Also**"
          see_also.each do |entry|
            lines << "- #{entry[:text]}"
          end
          wrote = true
        end

        wrote
      end

      def hover_doc_comment_for_definition(definition_entry)
        return nil unless definition_entry

        @workspace.doc_comment_for_definition(definition_entry[:uri], definition_entry[:token])
      end

      def hover_doc_comment_data_for_definition(definition_entry)
        return nil unless definition_entry

        @workspace.doc_comment_data_for_definition(definition_entry[:uri], definition_entry[:token])
      end

      def signature_help_doc_comment_for_call(uri, name, lsp_line, lsp_char)
        definition_entry = @workspace.find_definition_token_global(
          name,
          preferred_uri: uri,
          before_line: lsp_line + 1,
          before_char: lsp_char + 1,
        )
        return nil unless definition_entry

        @workspace.doc_comment_data_for_definition(definition_entry[:uri], definition_entry[:token])
      end

      def signature_help_markdown_for_doc_comment(doc_comment)
        return '' unless doc_comment.is_a?(Hash)

        lines = []
        body = doc_comment[:body_markdown].to_s.strip
        lines << body unless body.empty?

        returns = doc_tag_return_description(doc_comment)
        unless returns.empty?
          lines << '' unless lines.empty?
          lines << "**Returns**"
          lines << returns
        end

        lines.join("\n")
      end

      def doc_tag_param_descriptions(doc_comment)
        return {} unless doc_comment.is_a?(Hash)

        Array(doc_comment.dig(:tags, :params)).each_with_object({}) do |entry, docs|
          name = entry[:name].to_s
          next if name.empty?

          text = entry[:text].to_s.strip
          next if text.empty?

          docs[name] = text
        end
      end

      def doc_tag_return_description(doc_comment)
        return '' unless doc_comment.is_a?(Hash)

        doc_comment.dig(:tags, :returns, :text).to_s.strip
      end

      def completion_function_documentation(uri, name, cache:)
        key = [uri, name]
        return cache[key] if cache.key?(key)

        definition_entry = @workspace.find_definition_token_global(name, preferred_uri: uri)
        unless definition_entry
          cache[key] = ''
          return ''
        end

        doc_comment = @workspace.doc_comment_data_for_definition(definition_entry[:uri], definition_entry[:token])
        cache[key] = signature_help_markdown_for_doc_comment(doc_comment)
      end

      def hover_source_label_for_definition(definition_entry)
        return nil unless definition_entry

        hover_source_label(definition_entry[:uri], definition_entry[:token].line)
      end

      def hover_source_uri_for_definition(definition_entry)
        return nil unless definition_entry

        definition_entry[:uri]
      end

      def hover_source_line_for_definition(definition_entry)
        return nil unless definition_entry

        definition_entry[:token].line
      end

      def hover_source_label_from_location(location)
        return nil unless location

        line = location.dig(:range, :start, :line)
        hover_source_label(location[:uri], (line || 0) + 1)
      end

      def hover_source_uri_from_location(location)
        return nil unless location

        location[:uri]
      end

      def hover_source_line_from_location(location)
        return nil unless location

        line = location.dig(:range, :start, :line)
        (line || 0) + 1
      end

      def hover_source_label(uri, line)
        path = uri_to_path(uri)
        return nil unless path

        display = path
        if @root_uri
          root_path = uri_to_path(@root_uri)
          if root_path
            begin
              relative = Pathname.new(path).relative_path_from(Pathname.new(root_path)).to_s
              display = relative unless relative.start_with?('..')
            rescue StandardError
              display = path
            end
          end
        end

        "#{display}:#{line}"
      end

      def hover_definition_entry_from_location(location)
        return nil unless location

        start = location.dig(:range, :start)
        return nil unless start

        token = @workspace.find_token_at(location[:uri], start[:line], start[:character])
        return nil unless token

        { uri: location[:uri], token: token }
      end

      def format_params(params)
        params.map { |p| "#{p.name}: #{p.type}" }.join(', ')
      end

      def interface_signature(binding)
        method_lines = binding.methods.values.map do |method|
          "    #{interface_method_signature(method)}"
        end

        (["interface #{binding.name}"] + method_lines).join("\n")
      end

      def interface_method_signature(binding)
        keyword = binding.kind == :editable ? 'editable function' : 'function'
        keyword = "async #{keyword}" if binding.async
        "#{keyword} #{binding.name}(#{format_params(binding.params)}) -> #{binding.return_type}"
      end

      def resolve_dot_receiver_value_type(facts, receiver_name, line, char)
        local_type = resolve_local_hover_type(facts, receiver_name, line, char)
        return local_type if local_type

        facts.values[receiver_name]&.type
      end

      def resolve_member_access_hover_info(current_uri, facts, tokens, token_index)
        chain = member_access_chain_at(tokens, token_index)
        return nil unless chain

        hovered_segment = chain[:segments].find { |segment| segment[:token_index] == token_index }
        return nil unless hovered_segment && hovered_segment[:position].positive?

        current_type = resolve_dot_receiver_value_type(
          facts,
          chain[:segments].first[:name],
          chain[:line],
          chain[:char],
        )
        unless current_type
          first_name = chain[:segments].first[:name]
          current_type = facts.types[first_name]
        end
        return nil unless current_type

          chain[:segments][1..hovered_segment[:position]].each do |segment|
            field_receiver_type = project_field_receiver_type_for_completion(current_type, facts)
            if field_receiver_type.respond_to?(:field) && (field_type = field_receiver_type.field(segment[:name]))
              source_location = field_definition_location(current_uri, field_receiver_type, segment[:name])

              if segment[:token_index] == token_index
                return {
                  signature: field_hover_signature(segment[:name], field_type),
                  docs: nil,
                  source: hover_source_label_from_location(source_location),
                  source_uri: hover_source_uri_from_location(source_location),
                  source_line: hover_source_line_from_location(source_location),
                }
              end

              current_type = field_type
              next
            end

            if current_type.respond_to?(:nested_types) && (nested = current_type.nested_types[segment[:name]])
              if segment[:token_index] == token_index
                return {
                  signature: type_hover_signature(segment[:name], nested),
                  docs: nil,
                }
              end
              current_type = nested
              next
            end

            next unless segment[:token_index] == token_index

          method_receiver_type = project_method_receiver_type_for_completion(current_type)
          method_info = member_method_info_for_receiver_type(facts, method_receiver_type, segment[:name])
          return nil unless method_info

          source_location = module_member_binding_location(current_uri, method_info[:module_name], segment[:name], method_info[:binding])
          source_location ||= module_member_definition_location(current_uri, method_info[:module_name], segment[:name])

          return {
            signature: method_signature(method_info[:binding]),
            docs: nil,
            source: hover_source_label_from_location(source_location),
            source_uri: hover_source_uri_from_location(source_location),
            source_line: hover_source_line_from_location(source_location),
          }
        end

        nil
      end

      def member_method_info_for_receiver_type(facts, receiver_type, method_name)
        return nil unless receiver_type

        dispatch_receiver_type = method_dispatch_receiver_type_for_completion(receiver_type)

        if (binding = find_method_entry(facts.methods, receiver_type, method_name))
          return {
            binding: binding,
            module_name: facts.module_name,
          }
        end

        if dispatch_receiver_type != receiver_type && (binding = find_method_entry(facts.methods, dispatch_receiver_type, method_name))
          return {
            binding: binding,
            module_name: facts.module_name,
          }
        end

        facts.imports.each_value do |module_binding|
          binding = find_method_entry(module_binding.methods, receiver_type, method_name)
          if binding.nil? && dispatch_receiver_type != receiver_type
            binding = find_method_entry(module_binding.methods, dispatch_receiver_type, method_name)
          end
          next unless binding

          return {
            binding: binding,
            module_name: module_binding.name,
          }
        end

        nil
      end

      def find_method_entry(methods_table, receiver_type, method_name)
        methods_table.fetch(receiver_type, {})[method_name] || methods_table.fetch(receiver_type, {})["static:#{method_name}"]
      end

      def resolve_enum_member_hover_info(current_uri, facts, tokens, token_index)
        member_info = resolve_enum_member_access_info(current_uri, facts, tokens, token_index)
        return nil unless member_info

        signature = "#{member_info[:member_name]}: #{member_info[:receiver_label]}"
        signature += " = #{member_info[:value_text]}" if member_info[:value_text]

        {
          signature: signature,
          docs: nil,
          source: hover_source_label_from_location(member_info[:location]),
          source_uri: hover_source_uri_from_location(member_info[:location]),
          source_line: hover_source_line_from_location(member_info[:location]),
        }
      end

      def resolve_enum_member_definition_location(current_uri, facts, tokens, token_index)
        resolve_enum_member_access_info(current_uri, facts, tokens, token_index)&.fetch(:location, nil)
      end

      def resolve_enum_member_access_info(current_uri, facts, tokens, token_index)
        return nil unless type_name_member_access?(tokens, token_index, facts)

        token = tokens[token_index]
        token_end_char = token.column - 1 + token.lexeme.length
        receiver_name = @workspace.find_dot_receiver(current_uri, token.line - 1, token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(current_uri, token.line - 1, token_end_char)
        receiver_info = resolve_type_receiver_info(facts, receiver_name, receiver_path)
        return nil unless receiver_info

        receiver_type = receiver_info[:type]
        return nil unless receiver_type.is_a?(Types::EnumBase)
        return nil unless receiver_type.member(token.lexeme)

        owner_module_name = receiver_type.respond_to?(:module_name) ? receiver_type.module_name : receiver_info[:module_name]

        {
          receiver_label: receiver_info[:label],
          member_name: token.lexeme,
          value_text: enum_member_value_text(current_uri, owner_module_name, receiver_type.name, token.lexeme),
          location: enum_member_definition_location(current_uri, owner_module_name, receiver_type.name, token.lexeme),
        }
      end

      def resolve_field_declaration_hover_info(current_uri, facts, tokens, token_index)
        receiver_info = field_declaration_receiver_info(facts, tokens, token_index)
        return nil unless receiver_info

        field_name = tokens[token_index].lexeme
        receiver_type = project_field_receiver_type_for_completion(receiver_info[:type], facts)
        return nil unless receiver_type.respond_to?(:field)

        field_type = receiver_type.field(field_name)
        return nil unless field_type

        source_location = field_definition_location(current_uri, receiver_type, field_name)

        {
          signature: field_hover_signature(field_name, field_type),
          docs: nil,
          source: hover_source_label_from_location(source_location),
          source_uri: hover_source_uri_from_location(source_location),
          source_line: hover_source_line_from_location(source_location),
        }
      end

      def resolve_named_argument_label_hover_info(current_uri, facts, tokens, token_index)
        receiver_info = named_argument_label_receiver_info(facts, tokens, token_index)

        field_name = tokens[token_index].lexeme
        if receiver_info
          receiver_type = project_field_receiver_type_for_completion(receiver_info[:type], facts)
          if receiver_type.respond_to?(:field)
            field_type = receiver_type.field(field_name)
            if field_type
              source_location = field_definition_location(current_uri, receiver_type, field_name)
              return {
                signature: field_hover_signature(field_name, field_type),
                docs: nil,
                source: hover_source_label_from_location(source_location),
                source_uri: hover_source_uri_from_location(source_location),
                source_line: hover_source_line_from_location(source_location),
              }
            end
          end
        end

        param_info = named_argument_parameter_info(facts, tokens, token_index)
        return nil unless param_info

        {
          signature: param_info[:signature],
          docs: param_info[:docs],
          source: param_info[:source],
          source_uri: param_info[:source_uri],
          source_line: param_info[:source_line],
        }
      end

      def named_argument_parameter_info(facts, tokens, token_index)
        receiver_name = named_argument_callee_name(tokens, token_index)
        return nil unless receiver_name

        field_name = tokens[token_index].lexeme

        if facts.functions.key?(receiver_name)
          func = facts.functions[receiver_name]
          func.type.params.each do |param|
            next unless param.name == field_name
            return named_argument_param_result(field_name, param, func.ast)
          end
        end

        facts.methods.each_value do |methods|
          method = methods[receiver_name]
          next unless method
          method.type.params.each do |param|
            next unless param.name == field_name
            return named_argument_param_result(field_name, param, method.ast)
          end
        end

        nil
      end

      def named_argument_param_result(field_name, param, callable_ast)
        param_ast = callable_ast.params.find { |p| p.name == field_name }
        source_location = param_ast ? ast_name_range(field_name, param_ast.line, param_ast.column) : nil
        doc_tags = callable_ast.respond_to?(:doc_comment) ? param_doc_for_name(callable_ast, field_name) : nil

        {
          signature: "#{field_name}: #{param.type}",
          docs: doc_tags,
          source: hover_source_label_from_location(source_location),
          source_uri: hover_source_uri_from_location(source_location),
          source_line: hover_source_line_from_location(source_location),
        }
      end

      def param_doc_for_name(callable_ast, param_name)
        return nil unless callable_ast.respond_to?(:doc_comment)
        return nil unless callable_ast.doc_comment

        lines = callable_ast.doc_comment.lines
        param_lines = []
        in_param = false
        lines.each do |line|
          if line =~ /@param\s+#{Regexp.escape(param_name)}\b/
            in_param = true
            param_lines << line.sub(/^\s*##\s*@param\s+#{Regexp.escape(param_name)}\s*/, "")
            next
          end
          if in_param
            if line =~ /@param\b/
              break
            end
            param_lines << line.sub(/^\s*##\s*/, "")
          end
        end
        param_lines.join(" ").strip.empty? ? nil : param_lines.join(" ").strip
      end

      def named_argument_callee_name(tokens, token_index)
        opener_index = parameter_list_opener_index(tokens, token_index)
        return nil unless opener_index

        head_index = previous_non_trivia_token_index(tokens, opener_index)
        return nil unless head_index
        return nil unless tokens[head_index].type == :identifier

        tokens[head_index].lexeme
      end

      def field_declaration_receiver_info(facts, tokens, token_index)
        token = tokens[token_index]
        return nil unless token

        i = token_index - 1
        while i >= 0
          current = tokens[i]
          i -= 1

          next if [:newline, :indent, :dedent, :eof].include?(current.type)
          next if current.line == token.line
          next if current.column >= token.column

          header_line_tokens = non_trivia_tokens_on_line(tokens, current.line)
          header = header_line_tokens.first
          return nil unless [:struct, :union].include?(header&.type)

          type_token = header_line_tokens[1]
          return nil unless type_token&.type == :identifier

          return resolve_type_receiver_info(facts, type_token.lexeme, type_token.lexeme)
        end

        nil
      end

      def named_argument_label_receiver_info(facts, tokens, token_index)
        opener_index = parameter_list_opener_index(tokens, token_index)
        return nil unless opener_index

        head_index = previous_non_trivia_token_index(tokens, opener_index)
        return nil unless head_index

        if tokens[head_index].type == :rbracket
          lbracket_index = matching_opener_index(tokens, head_index)
          return nil unless lbracket_index

          head_index = previous_non_trivia_token_index(tokens, lbracket_index)
          return nil unless head_index
        end

        head = tokens[head_index]
        return nil unless head.type == :identifier

        receiver_name = head.lexeme
        receiver_path = receiver_name

        dot_index = previous_non_trivia_token_index(tokens, head_index)
        if dot_index && tokens[dot_index].type == :dot
          module_index = previous_non_trivia_token_index(tokens, dot_index)
          return nil unless module_index && tokens[module_index].type == :identifier

          receiver_path = "#{tokens[module_index].lexeme}.#{receiver_name}"
        end

        resolve_type_receiver_info(facts, receiver_name, receiver_path)
      end

      def member_access_chain_at(tokens, token_index)
        token = tokens[token_index]
        return nil unless token&.type == :identifier

        indices = [token_index]
        current_index = token_index

        loop do
          dot_index = previous_non_trivia_token_index(tokens, current_index)
          break unless dot_index && tokens[dot_index].type == :dot && tokens[dot_index].line == token.line

          receiver_index = previous_non_trivia_token_index(tokens, dot_index)
          break unless receiver_index && tokens[receiver_index].type == :identifier && tokens[receiver_index].line == token.line

          indices.unshift(receiver_index)
          current_index = receiver_index
        end

        current_index = token_index
        loop do
          dot_index = next_non_trivia_token_index(tokens, current_index + 1)
          break unless dot_index && tokens[dot_index].type == :dot && tokens[dot_index].line == token.line

          member_index = next_non_trivia_token_index(tokens, dot_index + 1)
          break unless member_index && tokens[member_index].type == :identifier && tokens[member_index].line == token.line

          indices << member_index
          current_index = member_index
        end

        return nil if indices.length < 2

        {
          line: token.line,
          char: token.column + token.lexeme.length,
          segments: indices.each_with_index.map do |index, position|
            {
              name: tokens[index].lexeme,
              token_index: index,
              position: position,
            }
          end,
        }
      end

      def method_binding_at_token(facts, token)
        facts.methods.each_value do |methods|
          methods.each_value do |binding|
            next unless binding.name == token.lexeme
            next unless binding.ast.is_a?(AST::MethodDef)
            next unless binding.ast.line == token.line
            next unless binding.ast.respond_to?(:column) && binding.ast.column == token.column

            return binding
          end
        end

        facts.interfaces.each_value do |interface_binding|
          interface_binding.methods.each_value do |method_binding|
            next unless method_binding.name == token.lexeme
            next unless method_binding.ast.respond_to?(:line) && method_binding.ast.line == token.line
            next unless method_binding.ast.respond_to?(:column) && method_binding.ast.column == token.column

            return method_binding
          end
        end

        nil
      end

      def method_signature(binding)
        async_prefix = (binding.respond_to?(:async) && binding.async) || (binding.ast.respond_to?(:async) && binding.ast.async) ? 'async ' : ''
        if binding.respond_to?(:type) && binding.type
          params_str = format_params(binding.type.params)
          keyword = case binding.ast.kind
                    when :editable
                      "editable function"
                    when :static
                      "static function"
                    else
                      "function"
                    end

          "#{async_prefix}#{keyword} #{binding.name}(#{params_str}) -> #{binding.type.return_type}"
        else
          params_str = binding.params.map { |p| "#{p.name}: #{p.type}" }.join(', ')
          keyword = case binding.kind
                    when :editable
                      "editable function"
                    when :static
                      "static function"
                    else
                      "function"
                    end

          "#{async_prefix}#{keyword} #{binding.name}(#{params_str}) -> #{binding.return_type}"
        end
      end

      def type_hover_signature(name, type)
        rendered_type = type.to_s
        return "type #{name}" if rendered_type == name

        "type #{name} = #{rendered_type}"
      end

      def field_hover_signature(name, type)
        "field #{name}: #{type}"
      end

      def find_nested_type_by_short_name(facts, short_name)
        matches = facts.types.keys.select { |k| k.to_s.end_with?(".#{short_name}") }
        return nil unless matches.length == 1

        facts.types[matches.first]
      end

      def find_member_in_types(facts, name)
        facts.types.reverse_each do |_key, type|
          next unless type.respond_to?(:members)

          member = type.members.find { |m| m == name }
          if member
            value = type.respond_to?(:member_value) ? type.member_value(name) : nil
            return [type, member, value]
          end
        end
        nil
      end

      def find_variant_arm_in_types(facts, name)
        facts.types.reverse_each do |_key, type|
          next unless type.respond_to?(:arms)

          arm = type.arms[name]
          next unless arm

          fields = arm.map { |fname, ftype| "#{fname}: #{ftype}" }.join(", ")
          field_str = fields.empty? ? "" : "(#{fields})"
          return "#{type.name}.#{name}#{field_str}"
        end
        nil
      end

      def builtin_hover_info(name, tokens, token_index)
        specialization_info = builtin_value_specialization_info(name, tokens, token_index)
        return specialization_info if specialization_info

        specialized_call_info = builtin_specialized_call_hover_info(name, tokens, token_index)
        return specialized_call_info if specialized_call_info

        type_constructor_info = builtin_type_constructor_hover_info(name, tokens, token_index)
        return type_constructor_info if type_constructor_info

        builtin_call_hover_info(name, tokens, token_index)
      end

      def builtin_in_member_access_context?(tokens, token_index)
        prev_index = previous_non_trivia_token_index(tokens, token_index)
        prev_index && tokens[prev_index].type == :dot
      end

      def builtin_value_specialization_info(name, tokens, token_index)
        return nil unless %w[zero default reinterpret].include?(name)

        return nil if builtin_in_member_access_context?(tokens, token_index)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        target_type = render_builtin_specialization(tokens[(lbracket_index + 1)...rbracket_index])
        return nil if target_type.empty?

        docs = case name
               when 'zero'
                 '`zero[T]` returns the raw zero-initialized value for `T`. It is a value form, not a callable.'
               when 'default'
                 '`default[T]` returns the semantic default value for `T` and requires an accessible zero-argument associated function `T.default()` that returns `T`. It is a value form, not a callable.'
               when 'reinterpret'
                 '`reinterpret[T](value)` bit-casts a value to `T`; it requires `unsafe` and compatible concrete sized types.'
               end

        {
          signature: if name == 'reinterpret'
                       "builtin #{specialization}(value) -> #{target_type}"
                     else
                       "builtin #{specialization} -> #{target_type}"
                     end,
          docs: docs,
        }
      end

      def builtin_type_constructor_hover_info(name, tokens, token_index)
        return nil unless %w[array span Option Result SoA str_buffer].include?(name)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)

        if after_bracket_index && tokens[after_bracket_index].type == :lparen
           docs = case name
                   when 'array'
                    '`array[T, N](...)` constructs a fixed-length array value of type `array[T, N]`.'
                   when 'span'
                    '`span[T](data = ..., len = ...)` constructs a span view over contiguous `T` storage.'
                   when 'SoA'
                    '`SoA[T, N](...)` constructs a Struct-of-Arrays value with `N` elements of type `T`. Fields are stored in separate contiguous arrays.'
                   when 'Option'
                    '`Option[T]` is a built-in optional type with arms `some(value: T)` and `none`.'
                   when 'Result'
                    '`Result[T, E]` is a built-in result type with arms `success(value: T)` and `failure(error: E)`.'
                   end

          return {
            signature: case name
                       when 'array'
                         "builtin #{specialization}(...) -> #{specialization}"
                       when 'span'
                         "builtin #{specialization}(data = ..., len = ...) -> #{specialization}"
                       when 'SoA'
                         "builtin #{specialization}(...) -> #{specialization}"
                       when 'Option'
                         "builtin #{specialization}(some: value = ...) / #{specialization}(none:)"
                       when 'Result'
                         "builtin #{specialization}(success: value = ...) / #{specialization}(failure: error = ...)"
                       end,
            docs: docs,
          }
        end

        docs = case name
               when 'array'
                 '`array[T, N]` is the built-in fixed-length array type.'
               when 'span'
                 '`span[T]` is the built-in non-owning contiguous view type.'
               when 'SoA'
                 '`SoA[T, N]` is the built-in Struct-of-Arrays type. Each struct field is stored in a separate contiguous array of `N` elements, improving SIMD/cache behavior for parallel field access.'
               when 'Option'
                 '`Option[T]` is the built-in optional value type with `some(value = ...)` and `none` arms.'
               when 'Result'
                  '`Result[T, E]` is the built-in success/failure type with `success(value = ...)` and `failure(error = ...)` arms.'
                when 'str_buffer'
                  '`str_buffer[N]` is a fixed-capacity mutable UTF-8 text buffer. Methods: `assign`, `append`, `assign_format`, `append_format`, `clear`, `len`, `as_str`, `as_cstr`.'
                end

        {
          signature: "builtin type #{specialization}",
          docs: docs,
        }
      end

      def builtin_specialized_call_hover_info(name, tokens, token_index)
        return nil unless BUILTIN_ASSOCIATED_HOOK_NAMES.include?(name) || name == 'attribute_arg'

        return nil if builtin_in_member_access_context?(tokens, token_index)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)
        return nil unless after_bracket_index && tokens[after_bracket_index].type == :lparen

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        if name == 'attribute_arg'
          target_type = render_builtin_specialization(tokens[(lbracket_index + 1)...rbracket_index])
          return nil if target_type.empty?

          return {
            signature: "builtin #{specialization}(attribute, param_name) -> #{target_type}",
            docs: '`attribute_arg[T](attribute, param_name)` returns the compile-time argument value for the named attribute parameter; `T` must exactly match the declared parameter type.'
          }
        end

        docs = case name
               when 'hash'
                 '`hash[T](value)` lowers to `T.hash(value: const_ptr[T]) -> uint` after borrowing safe lvalues or forwarding existing refs and pointers.'
               when 'equal'
                 '`equal[T](left, right)` lowers to `T.equal(left: const_ptr[T], right: const_ptr[T]) -> bool` after borrowing safe lvalues or forwarding existing refs and pointers.'
               when 'order'
                 '`order[T](left, right)` lowers to `T.order(left: const_ptr[T], right: const_ptr[T]) -> int` after borrowing safe lvalues or forwarding existing refs and pointers.'
               end

        signature = case name
                    when 'hash'
                      "builtin #{specialization}(value) -> uint"
                    when 'equal'
                      "builtin #{specialization}(left, right) -> bool"
                    when 'order'
                      "builtin #{specialization}(left, right) -> int"
                    end

        {
          signature: signature,
          docs: docs,
        }
      end

      def builtin_call_hover_info(name, tokens, token_index)
        info = BUILTIN_CALL_HOVER_INFO[name]
        return nil unless info

        return nil if builtin_in_member_access_context?(tokens, token_index)

        next_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless next_index
        next_type = tokens[next_index].type
        return nil unless next_type == :lparen || next_type == :lbracket

        info
      end

      def builtin_keyword_hover_info(token)
        return nil unless token

        info = KEYWORD_HOVER_INFO[token.lexeme]
        return info if info && [:size_of, :align_of, :offset_of].include?(token.type)

        LANGUAGE_KEYWORD_HOVER_INFO[token.lexeme]
      end

      def render_builtin_specialization(tokens)
        Array(tokens).map(&:lexeme).join.gsub(',', ', ')
      end

      def value_hover_signature(binding)
        case binding.kind
        when :const
          "const #{binding.name}: #{binding.type} (immutable)"
        when :var
          "var #{binding.name}: #{binding.type} (mutable)"
        when :let
          "let #{binding.name}: #{binding.type} (immutable)"
        when :param
          "parameter #{binding.name}: #{binding.type} (immutable)"
        when :local
          suffix = binding.mutable ? 'mutable' : 'immutable'
          "local #{binding.name}: #{binding.type} (#{suffix})"
        else
          "#{binding.name}: #{binding.type}"
        end
      end

      def resolve_local_hover_binding(facts, name, line, char)
        declared_binding = declared_generic_local_hover_binding(facts, name, line)
        return declared_binding if declared_binding

        frame = enclosing_completion_frame(facts, line)
        return nil unless frame

        snapshot = latest_completion_snapshot(frame, line, char)
        binding = snapshot&.bindings&.dig(name)
        return binding if binding

        future_snapshot = same_line_future_completion_snapshot(frame, line, char)
        future_snapshot&.bindings&.dig(name)
      end

      def resolve_as_binding_declaration_hover_binding(facts, name, line, char)
        frame = enclosing_completion_frame(facts, line)
        return nil unless frame

        Array(frame.snapshots).each do |snapshot|
          next if snapshot.line < line
          next if snapshot.line == line && snapshot.column <= char

          binding = snapshot.bindings[name]
          return binding if binding
        end

        nil
      end

      def resolve_local_hover_type(facts, name, line, char)
        resolve_local_hover_binding(facts, name, line, char)&.type
      end

      def declared_generic_local_hover_binding(facts, name, line)
        binding = generic_function_binding_for_line(facts, line)
        return nil unless binding

        binding.body_params.find { |param| param.name == name }
      end

      def enclosing_completion_frame(facts, line)
        frames = Array(facts.local_completion_frames)
        containing = frames.select { |frame| frame.start_line && frame.end_line && frame.start_line <= line && line <= frame.end_line }
        containing.min_by { |frame| frame.end_line - frame.start_line }
      end

      def latest_completion_snapshot(frame, line, char)
        snapshots = Array(frame.snapshots)
        snapshots.reverse_each do |snapshot|
          next if snapshot.line > line
          next if snapshot.line == line && snapshot.column > char

          return snapshot
        end
        nil
      end

      def same_line_future_completion_snapshot(frame, line, char)
        snapshots = Array(frame.snapshots)
        snapshots.each do |snapshot|
          next unless snapshot.line == line
          next if snapshot.column <= char

          return snapshot
        end
        nil
      end

      def resolve_for_binding_hover_info(tokens, token_index)
        tok = tokens[token_index]
        return nil unless tok&.type == :identifier

        binding_info = for_binding_context_at(tokens, token_index)
        return nil unless binding_info

        binding_name = binding_info[:name]
        iterable_text = binding_info[:iterable_text] || "collection"

        {
          signature: "for binding #{binding_name} (iterating over #{iterable_text})",
          docs: nil,
        }
      end

      def for_binding_context_at(tokens, token_index)
        return nil unless token_index

        i = token_index - 1
        passed_in = false

        while i >= 0
          current = tokens[i]
          break if current.type == :newline && current.line != tokens[token_index].line

          if current.type == :identifier
            case current.lexeme
            when "in"
              passed_in = true
            when "for"
              if passed_in
                ie = token_index + 1
                while ie < tokens.length
                  nt = tokens[ie]
                  break if nt.type == :newline || nt.type == :colon

                  ie += 1
                end
                iterable_text = tokens[(token_index + 1)...ie].map(&:lexeme).join(" ")
                iterable_text = iterable_text.gsub(/\s+/, " ").strip
                return {
                  name: tokens[token_index].lexeme,
                  iterable_text: iterable_text.empty? ? nil : iterable_text,
                }
              end
            end
          end

          i -= 1
        end

        nil
      end

      def resolve_lexical_local_hover_signature(definition_uri, name, definition_token)
        kind = nil
        type_str = nil

        tokens = @workspace.get_tokens(definition_uri)
        if tokens
          def_index = tokens.index(definition_token)
          if def_index
            prev = previous_non_trivia_token_index(tokens, def_index)
            if prev
              case tokens[prev].lexeme
              when "let" then kind = :let
              when "var" then kind = :var
              when "const" then kind = :const
              when "struct" then kind = :struct_type
              when "function", "async", "external", "foreign" then kind = :function
              when "enum" then kind = :enum_type
              when "flags" then kind = :flags_type
              when "union" then kind = :union_type
              when "variant" then kind = :variant_type
              end
            end

            if kind
              next_idx = next_non_trivia_token_index(tokens, def_index + 1)
              if next_idx && tokens[next_idx].type == :colon
                type_start = next_non_trivia_token_index(tokens, next_idx + 1)
                if type_start && tokens[type_start].type == :identifier
                  type_str = tokens[type_start].lexeme
                  type_end = type_start
                  loop do
                    next_tok_idx = next_non_trivia_token_index(tokens, type_end + 1)
                    break unless next_tok_idx && %i[identifier lbracket rbracket integer comma].include?(tokens[next_tok_idx].type)

                    type_str += tokens[next_tok_idx].lexeme
                    type_end = next_tok_idx
                    break if tokens[type_end].type == :equal
                  end
                  type_str = type_str.sub(/\s*=.*/, "").strip
                end
              end
            end
          end
        end

        kind ||= :let
        unless %i[let var const].include?(kind)
          kind = kind.to_s.sub(/_type$/, "")
          return "#{kind} #{name}"
        end

        mutability = kind == :var ? "mutable" : "immutable"
        if type_str && !type_str.empty?
          "#{kind} #{name}: #{type_str} (#{mutability})"
        else
          "#{kind} #{name} (#{mutability})"
        end
      end
      end
    end
  end
end
