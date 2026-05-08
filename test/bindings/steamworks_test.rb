# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaSteamworksTest < Minitest::Test
  def test_generator_emits_c_compatible_helper_header
    header = MilkTea::Steamworks::Generator.new(json_source: fixture_json, source_label: "<fixture>").generate

    assert_includes header, "typedef void (*PFNPreMinidumpCallback)(void *);"
    assert_includes header, "typedef char SteamErrMsg[1024];"
    assert_includes header, "typedef uint64 uint64_steamid;"
    assert_includes header, "typedef enum EHTMLMouseButton {"
    assert_includes header, "struct SteamInputActionEvent_t_AnalogAction_t {"
    assert_includes header, "struct SteamInputActionEvent_t {"
    assert_includes header, "union {"
    assert_includes header, "EHTMLMouseButton eMouseButton"
    assert_includes header, "SteamInputActionEvent_t_DigitalAction_t digitalAction"
    assert_includes header, "ISteamHTMLSurface * SteamAPI_SteamHTMLSurface_v001(void);"
    assert_includes header, "static inline ISteamHTMLSurface * SteamAPI_SteamHTMLSurface(void) {"
    assert_includes header, "ESteamAPIInitResult SteamAPI_InitFlat(SteamErrMsg * pOutErrMsg);"
    assert_includes header, "static inline bool SteamAPI_Init(void) {"
    assert_includes header, "enum { DemoCallback_t_k_iCallback = 123 };"
    refute_includes header, "SteamAPI_InitEx"
  end

  def test_registry_binding_prepare_generates_header_and_bindgen_reads_it
    Dir.mktmpdir("milk-tea-steamworks") do |dir|
      root = Pathname.new(dir)
      sdk_root = root.join("sdk")
      json_path = sdk_root.join("public/steam/steam_api.json")
      library_path = sdk_root.join("redistributable_bin/linux64/libsteam_api.so")
      FileUtils.mkdir_p(json_path.dirname)
      FileUtils.mkdir_p(library_path.dirname)
      File.write(json_path, fixture_json)
      File.write(library_path, "steam")

      binding = MilkTea::RawBindings.default_registry(root:).fetch("steamworks")
      env = {
        "STEAMWORKS_API_JSON" => json_path.to_s,
        "STEAMWORKS_SDK_ROOT" => sdk_root.to_s,
      }

      binding.prepare!(env:, cc: "cc")

      assert File.exist?(root.join("std/c/steamworks.h"))
      assert File.exist?(root.join("tmp/vendored-steamworks/libsteam_api.so"))

      source = binding.generate(env:)

      assert_includes source, "external module std.c.steamworks:"
      assert_includes source, 'link "steam_api"'
      assert_includes source, "external function SteamAPI_Init"
      assert_includes source, "external function SteamAPI_InitFlat"
      assert_includes source, "external function SteamAPI_SteamHTMLSurface"
    end
  end

  private

  def fixture_json
    JSON.generate(
      "typedefs" => [
        { "typedef" => "uint8", "type" => "uint8_t" },
        { "typedef" => "uint16", "type" => "uint16_t" },
        { "typedef" => "uint32", "type" => "uint32_t" },
        { "typedef" => "uint64", "type" => "uint64_t" },
        { "typedef" => "int32", "type" => "int32_t" },
        { "typedef" => "AppId_t", "type" => "uint32" },
        { "typedef" => "HSteamPipe", "type" => "int32" },
        { "typedef" => "HSteamUser", "type" => "int32" },
        { "typedef" => "SteamAPICall_t", "type" => "uint64" },
        { "typedef" => "InputHandle_t", "type" => "uint64" },
        { "typedef" => "InputAnalogActionHandle_t", "type" => "uint64" },
        { "typedef" => "InputDigitalActionHandle_t", "type" => "uint64" },
        { "typedef" => "SteamErrMsg", "type" => "char [1024]" },
        { "typedef" => "PFNPreMinidumpCallback", "type" => "void (*)(void *)" },
      ],
      "consts" => [
        { "constname" => "k_uAppIdInvalid", "consttype" => "AppId_t", "constval" => "0x0" },
      ],
      "enums" => [
        { "enumname" => "ESteamAPIInitResult", "values" => [{ "name" => "k_ESteamAPIInitResult_OK", "value" => "0" }] },
        { "enumname" => "EServerMode", "values" => [{ "name" => "eServerModeInvalid", "value" => "0" }] },
        { "enumname" => "ESteamInputActionEventType", "values" => [{ "name" => "k_ESteamInputActionEventTypeAnalog", "value" => "0" }] },
      ],
      "structs" => [
        { "struct" => "CallbackMsg_t", "fields" => [{ "fieldname" => "m_iCallback", "fieldtype" => "int32" }] },
        { "struct" => "InputAnalogActionData_t", "fields" => [{ "fieldname" => "x", "fieldtype" => "float" }] },
        { "struct" => "InputDigitalActionData_t", "fields" => [{ "fieldname" => "bState", "fieldtype" => "bool" }] },
        {
          "struct" => "SteamInputActionEvent_t",
          "fields" => [
            { "fieldname" => "controllerHandle", "fieldtype" => "InputHandle_t" },
            { "fieldname" => "eEventType", "fieldtype" => "ESteamInputActionEventType" },
            { "fieldname" => "analogAction", "fieldtype" => "SteamInputActionEvent_t::AnalogAction_t" },
          ],
        },
        {
          "struct" => "DemoStruct",
          "fields" => [
            { "fieldname" => "bytes", "fieldtype" => "uint8 [16]" },
            { "fieldname" => "friendId", "fieldtype" => "CSteamID" },
          ],
          "methods" => [
            { "methodname" => "IsReady", "methodname_flat" => "SteamAPI_DemoStruct_IsReady", "params" => [], "returntype" => "bool" },
          ],
          "consts" => [
            { "constname" => "k_cchMaxString", "consttype" => "int", "constval" => "48" },
          ],
        },
      ],
      "callback_structs" => [
        {
          "struct" => "DemoCallback_t",
          "callback_id" => 123,
          "fields" => [{ "fieldname" => "result", "fieldtype" => "int" }],
          "consts" => [{ "constname" => "k_nMaxReturnPorts", "consttype" => "int", "constval" => "8" }],
        },
      ],
      "interfaces" => [
        {
          "classname" => "ISteamHTMLSurface",
          "version_string" => "SteamHTMLSurface001",
          "accessors" => [{ "kind" => "user", "name" => "SteamHTMLSurface", "name_flat" => "SteamAPI_SteamHTMLSurface_v001" }],
          "enums" => [
            { "enumname" => "EHTMLMouseButton", "fqname" => "ISteamHTMLSurface::EHTMLMouseButton", "values" => [{ "name" => "k_EHTMLMouseButton_Left", "value" => "0" }] },
            { "enumname" => "EHTMLKeyModifiers", "fqname" => "ISteamHTMLSurface::EHTMLKeyModifiers", "values" => [{ "name" => "k_EHTMLKeyModifiers_None", "value" => "0" }] },
          ],
          "methods" => [
            {
              "methodname" => "MouseUp",
              "methodname_flat" => "SteamAPI_ISteamHTMLSurface_MouseUp",
              "params" => [
                { "paramname" => "unBrowserHandle", "paramtype" => "uint32" },
                { "paramname" => "eMouseButton", "paramtype" => "ISteamHTMLSurface::EHTMLMouseButton" },
              ],
              "returntype" => "void",
            },
            {
              "methodname" => "KeyDown",
              "methodname_flat" => "SteamAPI_ISteamHTMLSurface_KeyDown",
              "params" => [
                { "paramname" => "unBrowserHandle", "paramtype" => "uint32" },
                { "paramname" => "nNativeKeyCode", "paramtype" => "uint32" },
                { "paramname" => "eHTMLKeyModifiers", "paramtype" => "ISteamHTMLSurface::EHTMLKeyModifiers" },
                { "paramname" => "bIsSystemKey", "paramtype" => "bool" },
              ],
              "returntype" => "void",
            },
          ],
        },
      ],
    )
  end
end
