# frozen_string_literal: true

require_relative "../../test_helper"

class DAPSessionTest < Minitest::Test
  def setup
    @session = MilkTea::DAP::Session.new
  end

  def test_initial_state_is_not_initialized
    refute @session.initialized?
    refute @session.configuration_done?
    refute @session.launched?
    refute @session.terminated?
    refute @session.should_exit?
    refute @session.runtime_started?
    refute @session.entry_stop_emitted?
  end

  def test_initialize_sets_flag
    @session.initialize!
    assert @session.initialized?
  end

  def test_configuration_done_sets_flag
    @session.configuration_done!
    assert @session.configuration_done?
  end

  def test_request_start_stores_launch_parameters
    @session.request_start!(
      program_path: "/tmp/test.mt",
      runnable_path: "/tmp/test",
      program_args: ["--verbose"],
      stop_on_entry: false,
      backend_kind: "lldb-dap",
    )
    assert_equal "/tmp/test.mt", @session.program_path
    assert_equal "/tmp/test", @session.runnable_path
    assert_equal ["--verbose"], @session.program_args
    refute @session.stop_on_entry?
    assert_equal "lldb-dap", @session.backend_kind
  end

  def test_request_start_defaults
    @session.request_start!(program_path: "/tmp/demo.mt", runnable_path: "/tmp/demo")
    assert_equal [], @session.program_args
    assert @session.stop_on_entry?
    assert_equal "process", @session.backend_kind
  end

  def test_launch_and_terminate_state_transitions
    refute @session.launched?
    @session.launch!
    assert @session.launched?

    refute @session.terminated?
    @session.terminate!
    assert @session.terminated?
  end

  def test_exit_state_transition
    refute @session.should_exit?
    @session.request_exit!
    assert @session.should_exit?
  end

  def test_entry_stop_emitted_tracks_flag
    refute @session.entry_stop_emitted?
    @session.mark_entry_stop_emitted!
    assert @session.entry_stop_emitted?
  end

  def test_runtime_started_tracks_flag
    refute @session.runtime_started?
    @session.mark_runtime_started!
    assert @session.runtime_started?
  end

  def test_set_breakpoints_assigns_ids_and_normalizes_keys
    breakpoints = [
      { "line" => 3, "condition" => "x > 0" },
      { "line" => 7 },
    ]
    result = @session.set_breakpoints("/tmp/demo.mt", breakpoints)
    assert_equal 2, result.length
    assert_equal 1, result[0]["id"]
    assert_equal true, result[0]["verified"]
    assert_equal 3, result[0]["line"]
    assert_equal "x > 0", result[0]["condition"]
    assert_equal 2, result[1]["id"]
    assert_equal 7, result[1]["line"]
  end

  def test_set_breakpoints_assigns_consecutive_ids_across_sources
    bp1 = @session.set_breakpoints("/tmp/a.mt", [{ "line" => 1 }])
    bp2 = @session.set_breakpoints("/tmp/b.mt", [{ "line" => 2 }])
    assert_equal 1, bp1[0]["id"]
    assert_equal 2, bp2[0]["id"]
  end

  def test_set_breakpoints_normalizes_symbol_keys
    breakpoints = [{ line: 10, condition: "y == 0" }]
    result = @session.set_breakpoints("/tmp/t.mt", breakpoints)
    assert_equal 1, result.length
    assert_equal 10, result[0]["line"]
    assert_equal "y == 0", result[0]["condition"]
  end

  def test_set_function_breakpoints_assigns_ids
    breakpoints = [{ "name" => "myFunc" }, { "name" => "otherFunc" }]
    result = @session.set_function_breakpoints(breakpoints)
    assert_equal 2, result.length
    assert_equal 1, result[0]["id"]
    assert_equal true, result[0]["verified"]
    assert_equal "myFunc", result[0]["name"]
    assert_equal "otherFunc", result[1]["name"]
  end

  def test_set_exception_breakpoints_stores_configuration
    config = { "filters" => ["all"] }
    @session.set_exception_breakpoints(config)
    assert_equal({ "filters" => ["all"] }, @session.exception_breakpoints)
  end

  def test_each_breakpoint_source_iterates_over_registered_sources
    @session.set_breakpoints("/tmp/a.mt", [{ "line" => 1 }])
    @session.set_breakpoints("/tmp/b.mt", [{ "line" => 5 }])

    sources = []
    @session.each_breakpoint_source { |path, bps| sources << [path, bps.length] }
    assert_equal [["/tmp/a.mt", 1], ["/tmp/b.mt", 1]], sources
  end

  def test_each_breakpoint_source_empty_when_no_breakpoints
    sources = []
    @session.each_breakpoint_source { |path, _bps| sources << path }
    assert_empty sources
  end

  def test_next_seq_increments_monotonically
    assert_equal 1, @session.next_seq
    assert_equal 2, @session.next_seq
    assert_equal 3, @session.next_seq
  end

  def test_stop_on_entry_defaults_to_true
    assert @session.stop_on_entry?
  end

  def test_default_backend_kind_is_process
    assert_equal "process", @session.backend_kind
  end

  def test_multiple_breakpoint_sets_preserve_previous_sources
    @session.set_breakpoints("/tmp/a.mt", [{ "line" => 1 }])
    @session.set_breakpoints("/tmp/b.mt", [{ "line" => 5 }])

    sources = {}
    @session.each_breakpoint_source { |path, bps| sources[path] = bps }
    assert_equal 1, sources.fetch("/tmp/a.mt").length
    assert_equal 5, sources.fetch("/tmp/b.mt")[0]["line"]
  end
end
