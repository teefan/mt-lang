# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module MilkTea
  module Steamworks
    class Error < StandardError; end

    SOURCE_NAME = "steamworks_sdk"
    HELPER_HEADER_BASENAME = "steamworks.h"
    SDK_ROOT_ENV_VAR = "STEAMWORKS_SDK_ROOT"
    API_JSON_ENV_VAR = "STEAMWORKS_API_JSON"
    API_JSON_RELATIVE_PATH = "public/steam/steam_api.json"

    REDISTRIBUTABLE_DIRECTORY_BY_PLATFORM = {
      linux: "redistributable_bin/linux64",
      macos: "redistributable_bin/osx",
      windows: "redistributable_bin/win64",
    }.freeze

    LINK_LIBRARY_NAME_BY_PLATFORM = {
      linux: "steam_api",
      macos: "steam_api",
      windows: "steam_api64",
    }.freeze

    IMPORT_LIBRARY_BASENAME_BY_PLATFORM = {
      linux: "libsteam_api.so",
      macos: "libsteam_api.dylib",
      windows: "steam_api64.lib",
    }.freeze

    RUNTIME_LIBRARY_BASENAME_BY_PLATFORM = {
      linux: "libsteam_api.so",
      macos: "libsteam_api.dylib",
      windows: "steam_api64.dll",
    }.freeze

    module_function

    def helper_header_path(root: MilkTea.root)
      root.join("std/c/#{HELPER_HEADER_BASENAME}")
    end

    def source(root: MilkTea.root)
      UpstreamSources.default_sources(root:).find { |entry| entry.name == SOURCE_NAME } ||
        raise(Error, "missing upstream source definition for #{SOURCE_NAME}")
    end

    def host_platform
      return :windows if /mswin|mingw|cygwin/ === RUBY_PLATFORM
      return :macos if /darwin/ === RUBY_PLATFORM

      :linux
    end

    def default_link_libraries(platform: host_platform)
      [LINK_LIBRARY_NAME_BY_PLATFORM.fetch(platform)]
    end

    def sdk_root(root: MilkTea.root, env: ENV, bootstrap: false)
      candidates = []
      env_root = env[SDK_ROOT_ENV_VAR]
      candidates << canonical_sdk_root(env_root) if env_root && !env_root.empty?

      third_party_sdk = root.join("third_party/steamworks-sdk")
      candidates << canonical_sdk_root(third_party_sdk) if File.directory?(third_party_sdk)

      upstream_root = source(root:).checkout_root
      candidates << canonical_sdk_root(upstream_root) if File.directory?(upstream_root)

      if bootstrap && candidates.none? { |path| sdk_layout_present?(path) }
        source(root:).bootstrap!
        candidates << canonical_sdk_root(upstream_root)
      end

      candidates.find { |path| sdk_layout_present?(path) }
    end

    def api_json_path(root: MilkTea.root, env: ENV, bootstrap: false)
      explicit_path = env[API_JSON_ENV_VAR]
      if explicit_path && !explicit_path.empty?
        candidate = Pathname.new(File.expand_path(explicit_path))
        return candidate if File.file?(candidate)

        raise Error, "Steamworks metadata not found: #{candidate}"
      end

      resolved_sdk_root = sdk_root(root:, env:, bootstrap:)
      return unless resolved_sdk_root

      candidate = resolved_sdk_root.join(API_JSON_RELATIVE_PATH)
      return candidate if File.file?(candidate)

      raise Error, "Steamworks metadata not found under #{resolved_sdk_root}"
    end

    def redistributable_directory(root: MilkTea.root, env: ENV, platform: host_platform, bootstrap: false)
      resolved_sdk_root = sdk_root(root:, env:, bootstrap:)
      return unless resolved_sdk_root

      directory = resolved_sdk_root.join(REDISTRIBUTABLE_DIRECTORY_BY_PLATFORM.fetch(platform))
      return directory if File.directory?(directory)

      nil
    end

    def import_library_path(root: MilkTea.root, env: ENV, platform: host_platform, bootstrap: false)
      directory = redistributable_directory(root:, env:, platform:, bootstrap:)
      return unless directory

      candidate = directory.join(IMPORT_LIBRARY_BASENAME_BY_PLATFORM.fetch(platform))
      return candidate if File.file?(candidate)

      nil
    end

    def runtime_library_path(root: MilkTea.root, env: ENV, platform: host_platform, bootstrap: false)
      directory = redistributable_directory(root:, env:, platform:, bootstrap:)
      return unless directory

      candidate = directory.join(RUNTIME_LIBRARY_BASENAME_BY_PLATFORM.fetch(platform))
      return candidate if File.file?(candidate)

      nil
    end

    def prepare!(root: MilkTea.root, env: ENV)
      path = helper_header_path(root:)
      existing = File.exist?(path)
      json_path = api_json_path(root:, env:, bootstrap: !existing)
      return path.to_s if json_path.nil? && existing
      raise Error, "Steamworks metadata unavailable; set #{API_JSON_ENV_VAR} or #{SDK_ROOT_ENV_VAR}" unless json_path

      generated = Generator.new(json_path:).generate
      FileUtils.mkdir_p(path.dirname)
      return path.to_s if existing && File.read(path) == generated

      File.write(path, generated)
      path.to_s
    end

    def canonical_sdk_root(path)
      root = Pathname.new(File.expand_path(path.to_s))
      sdk_child = root.join("sdk")
      return sdk_child if sdk_layout_present?(sdk_child)

      root
    end
    private_class_method :canonical_sdk_root

    def sdk_layout_present?(root)
      File.file?(root.join(API_JSON_RELATIVE_PATH))
    end
    private_class_method :sdk_layout_present?

    class Generator
      HEADER_GUARD = "MT_LANG_STEAMWORKS_H"

      MANUAL_OPAQUE_TYPES = %w[
        CCallbackBase
        CallbackMsg_t
        ISteamNetworkingConnectionSignaling
        ISteamNetworkingSignalingRecvContext
        ScePadTriggerEffectParam
        SteamDatagramRelayAuthTicket
      ].freeze

      SPECIAL_TYPE_REWRITES = {
        "CGameID" => "uint64_gameid",
        "CSteamID" => "uint64_steamid",
        "SteamInputActionEvent_t::AnalogAction_t" => "SteamInputActionEvent_t_AnalogAction_t",
        "SteamInputActionEvent_t::DigitalAction_t" => "SteamInputActionEvent_t_DigitalAction_t",
      }.freeze

      MANUAL_FUNCTION_POINTER_TYPEDEFS = {
        "SteamAPIWarningMessageHook_t" => ["void", ["int", "const char *"]],
      }.freeze

      MANUAL_SUPPORT_STRUCT_DEFINITIONS = [
        "typedef struct SteamInputActionEvent_t_AnalogAction_t {",
        "    InputAnalogActionHandle_t actionHandle;",
        "    InputAnalogActionData_t analogActionData;",
        "} SteamInputActionEvent_t_AnalogAction_t;",
        "",
        "typedef struct SteamInputActionEvent_t_DigitalAction_t {",
        "    InputDigitalActionHandle_t actionHandle;",
        "    InputDigitalActionData_t digitalActionData;",
        "} SteamInputActionEvent_t_DigitalAction_t;",
      ].freeze

      MANUAL_FUNCTIONS = [
        { return_type: "ESteamAPIInitResult", name: "SteamAPI_InitFlat", params: [{ name: "pOutErrMsg", type: "SteamErrMsg *" }] },
        { return_type: "void", name: "SteamAPI_Shutdown", params: [] },
        { return_type: "bool", name: "SteamAPI_RestartAppIfNecessary", params: [{ name: "unOwnAppID", type: "uint32" }] },
        { return_type: "void", name: "SteamAPI_ReleaseCurrentThreadMemory", params: [] },
        { return_type: "void", name: "SteamAPI_WriteMiniDump", params: [{ name: "uStructuredExceptionCode", type: "uint32" }, { name: "pvExceptionInfo", type: "void *" }, { name: "uBuildID", type: "uint32" }] },
        { return_type: "void", name: "SteamAPI_SetMiniDumpComment", params: [{ name: "pchMsg", type: "const char *" }] },
        { return_type: "bool", name: "SteamAPI_IsSteamRunning", params: [] },
        { return_type: "const char *", name: "SteamAPI_GetSteamInstallPath", params: [] },
        { return_type: "void", name: "SteamAPI_SetTryCatchCallbacks", params: [{ name: "bTryCatchCallbacks", type: "bool" }] },
        { return_type: "bool", name: "SteamAPI_InitSafe", params: [] },
        { return_type: "void", name: "SteamAPI_UseBreakpadCrashHandler", params: [{ name: "pchVersion", type: "const char *" }, { name: "pchDate", type: "const char *" }, { name: "pchTime", type: "const char *" }, { name: "bFullMemoryDumps", type: "bool" }, { name: "pvContext", type: "void *" }, { name: "pfnPreMinidumpCallback", type: "PFNPreMinidumpCallback" }] },
        { return_type: "void", name: "SteamAPI_SetBreakpadAppID", params: [{ name: "unAppID", type: "uint32" }] },
        { return_type: "void", name: "SteamAPI_ManualDispatch_Init", params: [] },
        { return_type: "void", name: "SteamAPI_ManualDispatch_RunFrame", params: [{ name: "hSteamPipe", type: "HSteamPipe" }] },
        { return_type: "bool", name: "SteamAPI_ManualDispatch_GetNextCallback", params: [{ name: "hSteamPipe", type: "HSteamPipe" }, { name: "pCallbackMsg", type: "CallbackMsg_t *" }] },
        { return_type: "void", name: "SteamAPI_ManualDispatch_FreeLastCallback", params: [{ name: "hSteamPipe", type: "HSteamPipe" }] },
        { return_type: "bool", name: "SteamAPI_ManualDispatch_GetAPICallResult", params: [{ name: "hSteamPipe", type: "HSteamPipe" }, { name: "hSteamAPICall", type: "SteamAPICall_t" }, { name: "pCallback", type: "void *" }, { name: "cubCallback", type: "int" }, { name: "iCallbackExpected", type: "int" }, { name: "pbFailed", type: "bool *" }] },
        { return_type: "ESteamAPIInitResult", name: "SteamInternal_SteamAPI_Init", params: [{ name: "pszInternalCheckInterfaceVersions", type: "const char *" }, { name: "pOutErrMsg", type: "SteamErrMsg *" }] },
        { return_type: "void", name: "SteamAPI_RunCallbacks", params: [] },
        { return_type: "void", name: "SteamGameServer_RunCallbacks", params: [] },
        { return_type: "HSteamPipe", name: "SteamAPI_GetHSteamPipe", params: [] },
        { return_type: "HSteamUser", name: "SteamAPI_GetHSteamUser", params: [] },
        { return_type: "HSteamPipe", name: "SteamGameServer_GetHSteamPipe", params: [] },
        { return_type: "HSteamUser", name: "SteamGameServer_GetHSteamUser", params: [] },
        { return_type: "void *", name: "SteamInternal_ContextInit", params: [{ name: "pContextInitData", type: "void *" }] },
        { return_type: "void *", name: "SteamInternal_CreateInterface", params: [{ name: "ver", type: "const char *" }] },
        { return_type: "void *", name: "SteamInternal_FindOrCreateUserInterface", params: [{ name: "hSteamUser", type: "HSteamUser" }, { name: "pszVersion", type: "const char *" }] },
        { return_type: "void *", name: "SteamInternal_FindOrCreateGameServerInterface", params: [{ name: "hSteamUser", type: "HSteamUser" }, { name: "pszVersion", type: "const char *" }] },
        { return_type: "void", name: "SteamAPI_RegisterCallback", params: [{ name: "pCallback", type: "CCallbackBase *" }, { name: "iCallback", type: "int" }] },
        { return_type: "void", name: "SteamAPI_UnregisterCallback", params: [{ name: "pCallback", type: "CCallbackBase *" }] },
        { return_type: "void", name: "SteamAPI_RegisterCallResult", params: [{ name: "pCallback", type: "CCallbackBase *" }, { name: "hAPICall", type: "SteamAPICall_t" }] },
        { return_type: "void", name: "SteamAPI_UnregisterCallResult", params: [{ name: "pCallback", type: "CCallbackBase *" }, { name: "hAPICall", type: "SteamAPICall_t" }] },
        { return_type: "void", name: "SteamGameServer_Shutdown", params: [] },
        { return_type: "bool", name: "SteamGameServer_BSecure", params: [] },
        { return_type: "uint64", name: "SteamGameServer_GetSteamID", params: [] },
        { return_type: "ESteamAPIInitResult", name: "SteamInternal_GameServer_Init_V2", params: [{ name: "unIP", type: "uint32" }, { name: "usGamePort", type: "uint16" }, { name: "usQueryPort", type: "uint16" }, { name: "eServerMode", type: "EServerMode" }, { name: "pchVersionString", type: "const char *" }, { name: "pszInternalCheckInterfaceVersions", type: "const char *" }, { name: "pOutErrMsg", type: "SteamErrMsg *" }] },
      ].freeze

      def initialize(json_path: nil, json_source: nil, source_label: nil)
        raise ArgumentError, "json_path or json_source is required" if json_path.nil? && json_source.nil?

        @json_source = json_source || File.read(json_path)
        @source_label = source_label || File.expand_path(json_path.to_s)
      end

      def generate
        lines = []
        lines << "/* generated by mtc steamworks from #{@source_label} */"
        lines << "#ifndef #{HEADER_GUARD}"
        lines << "#define #{HEADER_GUARD}"
        lines << ""
        lines << "#include <stdbool.h>"
        lines << "#include <stddef.h>"
        lines << "#include <stdint.h>"
        lines << ""
        lines << "#ifdef __cplusplus"
        lines << 'extern "C" {'
        lines << "#endif"
        lines << ""
        lines.concat(emit_forward_declarations)
        lines << "" unless lines.last.empty?
        lines.concat(emit_typedefs)
        lines << "" unless lines.last.empty?
        lines.concat(emit_flat_aliases)
        lines << "" unless lines.last.empty?
        lines.concat(emit_enums)
        lines << "" unless lines.last.empty?
        lines.concat(emit_structs)
        lines << "" unless lines.last.empty?
        lines.concat(emit_manual_function_pointer_typedefs)
        lines << "" unless lines.last.empty?
        lines.concat(emit_constants)
        lines << "" unless lines.last.empty?
        lines.concat(emit_manual_functions)
        lines << "" unless lines.last.empty?
        lines.concat(emit_accessors)
        lines << "" unless lines.last.empty?
        lines.concat(emit_interface_methods)
        lines << "" unless lines.last.empty?
        lines.concat(emit_struct_methods)
        lines << "" unless lines.last.empty?
        lines.concat(emit_inline_wrappers)
        lines << ""
        lines << "#ifdef __cplusplus"
        lines << "}"
        lines << "#endif"
        lines << ""
        lines << "#endif"
        lines.join("\n") + "\n"
      end

      private

      def metadata
        @metadata ||= JSON.parse(@json_source)
      rescue JSON::ParserError => e
        raise Error, "failed to parse Steamworks metadata #{@source_label}: #{e.message}"
      end

      def typedefs
        metadata.fetch("typedefs", [])
      end

      def interfaces
        metadata.fetch("interfaces", [])
      end

      def structs
        metadata.fetch("structs", [])
      end

      def callback_structs
        metadata.fetch("callback_structs", [])
      end

      def all_enums
        @all_enums ||= begin
          enums = {}
          metadata.fetch("enums", []).each { |entry| enums[entry.fetch("enumname")] ||= entry }
          [interfaces, structs, callback_structs].each do |group|
            group.each do |entry|
              Array(entry["enums"]).each do |enum_entry|
                enums[enum_entry.fetch("enumname")] ||= enum_entry
              end
            end
          end
          enums.values
        end
      end

      def scoped_type_rewrites
        @scoped_type_rewrites ||= begin
          rewrites = {}
          [interfaces, structs, callback_structs].each do |group|
            group.each do |entry|
              Array(entry["enums"]).each do |enum_entry|
                fqname = enum_entry["fqname"]
                rewrites[fqname] = enum_entry.fetch("enumname") if fqname
              end
            end
          end
          rewrites
        end
      end

      def emit_forward_declarations
        lines = []
        opaque_types = []
        opaque_types.concat(interfaces.map { |entry| entry.fetch("classname") })
        opaque_types.concat(MANUAL_OPAQUE_TYPES)
        opaque_types.uniq.sort.each do |name|
          lines << "typedef struct #{name} #{name};"
        end

        record_names = structs.map { |entry| entry.fetch("struct") } + callback_structs.map { |entry| entry.fetch("struct") }
        record_names.uniq.sort.each do |name|
          lines << "typedef struct #{name} #{name};"
        end

        lines
      end

      def emit_typedefs
        typedefs.filter_map { |entry| emit_typedef(entry) }
      end

      def emit_typedef(entry)
        name = entry.fetch("typedef")
        source = entry.fetch("type")

        return if function_pointer_type?(source)

        if (match = split_array_type(source))
          return "typedef #{normalize_type(match[0])} #{name}[#{match[1]}];"
        end

        "typedef #{normalize_type(source)} #{name};"
      end

      def emit_manual_function_pointer_typedefs
        lines = []

        typedefs.each do |entry|
          next unless function_pointer_type?(entry.fetch("type"))

          match = entry.fetch("type").strip.match(/\A(.+?)\(\s*\*\s*\)\s*\((.*)\)\z/)
          return_type = normalize_type(match[1])
          params = normalize_function_pointer_params(match[2])
          lines << "typedef #{return_type} (*#{entry.fetch('typedef')})(#{params.join(', ')});"
        end

        MANUAL_FUNCTION_POINTER_TYPEDEFS.each do |name, (return_type, params)|
          lines << "typedef #{normalize_type(return_type)} (*#{name})(#{params.map { |param| normalize_type(param) }.join(', ')});"
        end

        lines
      end

      def emit_flat_aliases
        [
          "typedef uint64 uint64_steamid;",
          "typedef uint64 uint64_gameid;",
        ]
      end

      def emit_enums
        all_enums.flat_map do |entry|
          lines = []
          name = entry.fetch("enumname")
          lines << "typedef enum #{name} {"
          Array(entry.fetch("values", [])).each do |value|
            lines << "    #{value.fetch('name')} = #{value.fetch('value')},"
          end
          lines << "} #{name};"
          lines << ""
          lines
        end[0..-2] || []
      end

      def emit_structs
        regular_entries = []
        delayed_entries = []

        (structs + callback_structs).each do |entry|
          if entry.fetch("struct") == "SteamInputActionEvent_t"
            delayed_entries << entry
          else
            regular_entries << entry
          end
        end

        lines = regular_entries.flat_map { |entry| emit_generic_struct(entry) + [""] }
        unless delayed_entries.empty?
          lines.concat(MANUAL_SUPPORT_STRUCT_DEFINITIONS)
          lines << ""
          delayed_entries.each do |entry|
            lines.concat(emit_generic_struct(entry))
            lines << ""
          end
        end

        lines[0..-2] || []
      end

      def emit_generic_struct(entry)
        name = entry.fetch("struct")
        return emit_steam_input_action_event_struct(entry) if name == "SteamInputActionEvent_t"

        fields = Array(entry.fetch("fields", []))
        lines = []
        lines << "struct #{name} {"
        if fields.empty?
          lines << "    char _mt_dummy;"
        end
        fields.each do |field|
          lines << "    #{format_declarator(normalize_type(field.fetch('fieldtype')), field.fetch('fieldname'))};"
        end
        lines << "};"
        lines
      end

      def emit_steam_input_action_event_struct(entry)
        fields = Array(entry.fetch("fields", []))
        lines = []
        lines << "struct SteamInputActionEvent_t {"
        fields.each do |field|
          next if field.fetch("fieldname") == "analogAction"

          lines << "    #{format_declarator(normalize_type(field.fetch('fieldtype')), field.fetch('fieldname'))};"
        end
        lines << "    union {"
        lines << "        SteamInputActionEvent_t_AnalogAction_t analogAction;"
        lines << "        SteamInputActionEvent_t_DigitalAction_t digitalAction;"
        lines << "    };"
        lines << "};"
        lines
      end

      def emit_constants
        lines = []
        metadata.fetch("consts", []).each do |entry|
          lines << emit_constant(name: entry.fetch("constname"), type: entry.fetch("consttype"), value: entry.fetch("constval"))
        end

        structs.each do |entry|
          Array(entry["consts"]).each do |const_entry|
            scoped_name = "#{entry.fetch('struct')}_#{const_entry.fetch('constname')}"
            lines << emit_constant(name: scoped_name, type: const_entry.fetch("consttype"), value: const_entry.fetch("constval"))
          end
        end

        callback_structs.each do |entry|
          callback_name = entry.fetch("struct")
          if entry["callback_id"]
            lines << emit_constant(name: "#{callback_name}_k_iCallback", type: "int", value: entry.fetch("callback_id").to_s)
          end
          Array(entry["consts"]).each do |const_entry|
            scoped_name = "#{callback_name}_#{const_entry.fetch('constname')}"
            lines << emit_constant(name: scoped_name, type: const_entry.fetch("consttype"), value: const_entry.fetch("constval"))
          end
        end

        lines
      end

      def emit_constant(name:, type:, value:)
        normalized_type = normalize_type(type)
        return "static const #{normalized_type} #{name} = #{value};" if normalized_type == "float"

        "enum { #{name} = #{value} };"
      end

      def emit_manual_functions
        MANUAL_FUNCTIONS.map do |entry|
          emit_function(entry.fetch(:return_type), entry.fetch(:name), entry.fetch(:params))
        end
      end

      def emit_accessors
        interfaces.flat_map do |entry|
          interface_name = entry.fetch("classname")
          Array(entry["accessors"]).map do |accessor|
            emit_function("#{interface_name} *", accessor.fetch("name_flat"), [])
          end
        end
      end

      def emit_interface_methods
        interfaces.flat_map do |entry|
          interface_name = entry.fetch("classname")
          Array(entry.fetch("methods", [])).map do |method|
            params = [{ name: "self", type: "#{interface_name} *" }]
            params.concat(Array(method["params"]).map { |param| { name: param.fetch("paramname"), type: param["paramtype_flat"] || param.fetch("paramtype") } })
            emit_function(method["returntype_flat"] || method.fetch("returntype"), method.fetch("methodname_flat"), params)
          end
        end
      end

      def emit_struct_methods
        structs.flat_map do |entry|
          struct_name = entry.fetch("struct")
          Array(entry["methods"]).map do |method|
            params = [{ name: "self", type: "#{struct_name} *" }]
            params.concat(Array(method["params"]).map { |param| { name: param.fetch("paramname"), type: param["paramtype_flat"] || param.fetch("paramtype") } })
            emit_function(method["returntype_flat"] || method.fetch("returntype"), method.fetch("methodname_flat"), params)
          end
        end
      end

      def emit_inline_wrappers
        lines = []
        lines << "static inline bool SteamAPI_Init(void) {"
        lines << "    return SteamAPI_InitFlat(NULL) == k_ESteamAPIInitResult_OK;"
        lines << "}"
        lines << ""
        lines << "static inline void SteamGameServer_ReleaseCurrentThreadMemory(void) {"
        lines << "    SteamAPI_ReleaseCurrentThreadMemory();"
        lines << "}"

        accessor_wrappers = interfaces.flat_map do |entry|
          interface_name = entry.fetch("classname")
          Array(entry["accessors"]).flat_map do |accessor|
            wrapper_name = accessor.fetch("name_flat").sub(/_v[0-9A-Za-z]+\z/, "")
            [
              "",
              "static inline #{interface_name} * #{wrapper_name}(void) {",
              "    return #{accessor.fetch('name_flat')}();",
              "}",
            ]
          end
        end

        lines.concat(accessor_wrappers)
        lines
      end

      def emit_function(return_type, name, params)
        signature = params.map { |param| format_declarator(normalize_type(param.fetch(:type)), param.fetch(:name)) }
        signature = ["void"] if signature.empty?
        "#{normalize_type(return_type)} #{name}(#{signature.join(', ')});"
      end

      def normalize_type(type)
        value = type.to_s.strip
        return value if value.empty?

        if (match = split_array_type(value))
          return "#{normalize_type(match[0])}[#{match[1]}]"
        end

        scoped_type_rewrites.each do |source, target|
          value = value.gsub(source, target)
        end

        SPECIAL_TYPE_REWRITES.each do |source, target|
          value = value.gsub(source, target)
        end

        value = value.gsub(/\b(?:class|struct|enum)\s+/, "")
        value = value.gsub(/\s*&/, " *")
        value = value.gsub(/\s*\*\s*/, " *")
        value = value.gsub(/\s+/, " ").strip
        value
      end

      def format_declarator(type, name)
        if (match = type.match(/\A(.+?)\(\s*\*\s*\)\s*\((.*)\)\z/))
          params = normalize_function_pointer_params(match[2]).join(', ')
          return "#{normalize_type(match[1])} (*#{name})(#{params})"
        end

        if (match = split_array_type(type))
          return "#{match[0]} #{name}[#{match[1]}]"
        end

        "#{type} #{name}"
      end

      def normalize_function_pointer_params(source)
        params = source.strip
        return ["void"] if params.empty? || params == "void"

        params.split(/\s*,\s*/).map { |param| normalize_type(param) }
      end

      def function_pointer_type?(source)
        source.to_s.strip.match?(/\A.+?\(\s*\*\s*\)\s*\(.*\)\z/)
      end

      def split_array_type(source)
        match = source.strip.match(/\A(.+?)\s*\[(.+)\]\z/)
        return unless match

        [match[1].strip, match[2].strip]
      end
    end
  end
end
