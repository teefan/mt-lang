# frozen_string_literal: true

module MilkTea
  module IRJson
    module TypeResolver
      PRIMITIVE_NAMES = MilkTea::BUILTIN_PRIMITIVE_NAMES.to_set.freeze

      module_function

      def resolve_program_types(program)
        type_map = build_type_map(program)
        walk_and_resolve(program, type_map)
      end

      def build_type_map(program)
        mod_name = program.module_name
        map = {}
        PRIMITIVE_NAMES.each { |name| map[name] = Types::Registry.primitive(name) }
        map["void"] = Types::Registry.primitive("void")
        map["str"] = Types::Registry.string_view
        map["null"] = Types::Null.new
        map["bool"] = Types::Registry.primitive("bool")

        program.structs.each do |s|
          struct_type = Types::Struct.new(s.name, module_name: s.source_module || mod_name, linkage_name: s.linkage_name, packed: s.packed, alignment: s.alignment)
          fields = {}
          s.fields.each { |f| fields[f.name] = resolve_type_str(f.type, map, program) }
          struct_type.define_fields(fields.freeze)
          key = [s.source_module, s.name].compact.join(".")
          map[key] = struct_type
          map[s.name] = struct_type
        end

        program.unions.each do |u|
          union_type = Types::Union.new(u.name, module_name: u.source_module || mod_name, linkage_name: u.linkage_name)
          fields = {}
          u.fields.each { |f| fields[f.name] = resolve_type_str(f.type, map, program) }
          union_type.define_fields(fields.freeze)
          key = [u.source_module, u.name].compact.join(".")
          map[key] = union_type
          map[u.name] = union_type
        end

        program.enums.each do |e|
          backing = resolve_type_str(e.backing_type, map, program)
          enum_type = Types::Enum.new(e.name, module_name: mod_name)
          member_names = e.members.map(&:name)
          enum_type.define_members(backing, member_names)
          values = {}
          e.members.each { |m| values[m.name] = m.value }
          enum_type.define_member_values(values)
          map[e.name] = enum_type
        end

        map
      end

      def walk_and_resolve(node, type_map)
        return node unless node.is_a?(::Data)

        updated = node

        node.class.members.each do |member|
          value = node.public_send(member)
          next unless value

          case value
          when ::Data
            updated = updated.with(member => walk_and_resolve(value, type_map))
          when Array
            updated = updated.with(member => value.map { |v| v.is_a?(::Data) ? walk_and_resolve(v, type_map) : v })
          end
        end

        if updated.respond_to?(:type) && (member_val = updated.type)
          resolved = resolve_type_str(member_val, type_map, nil)
          updated = updated.with(type: resolved) if resolved
        end

        %i[target_type source_type backing_type return_type].each do |type_member|
          if updated.class.members.include?(type_member) && (val = updated.public_send(type_member)) && val.is_a?(String)
            resolved = resolve_type_str(val, type_map, nil)
            updated = updated.with(type_member => resolved) if resolved
          end
        end

        updated
      end

      def resolve_type_str(str, type_map, program)
        return str unless str.is_a?(String)
        return type_map[str] if type_map.key?(str)

        case str
        when /^\?(.+)$/
          base = resolve_type_str($1, type_map, program)
          base ? Types::Registry.nullable(base) : nil
        when /^span\[(.+)\]$/
          elem = resolve_type_str($1, type_map, program)
          elem ? Types::Registry.span(elem) : nil
        when /^Task\[(.+)\]$/
          result = resolve_type_str($1, type_map, program)
          result ? Types::Registry.task(result) : nil
        when /^fn\((.*)\) -> (.+)$/
          params = parse_type_list($1, type_map, program)
          ret = resolve_type_str($2.strip, type_map, program)
          params && ret ? Types::Registry.proc(params:, return_type: ret) : nil
        when /^(.+) \*$/
          base = resolve_type_str($1.strip, type_map, program)
          base ? Types::Pointer.new(base) : nil
        when /^([\w.]+)\[(.+)\]$/
          name = $1
          args = parse_type_list($2, type_map, program)
          if type_map.key?(name)
            type_map[name]
          else
            args ? Types::Registry.generic_instance(name, args) : nil
          end
        else
          nil
        end
      end

      def parse_type_list(str, type_map, program)
        return [] if str.strip.empty?

        types = []
        depth = 0
        current = +""
        str.each_char do |c|
          case c
          when ","
            if depth.zero?
              t = resolve_type_str(current.strip, type_map, program)
              types << t if t
              current = +""
            else
              current << c
            end
          when "(", "["
            depth += 1
            current << c
          when ")", "]"
            depth -= 1
            current << c
          else
            current << c
          end
        end
        t = resolve_type_str(current.strip, type_map, program)
        types << t if t
        types
      end
    end
  end
end
