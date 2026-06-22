# frozen_string_literal: true

require_relative "helpers"

class InterfaceImportTest < Minitest::Test
  include SemaTestHelpers

  def test_allows_import_alias_named_after_primitive_type
    program = check_program_source(<<~MT)
      # module demo.ok

      import std.async as str

      function main() -> int:
          return 0
    MT

    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_rejects_import_alias_named_after_reserved_builtin_result_type
    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(<<~MT)
        # module demo.bad

        import std.async as Result

        function main() -> int:
            return 0
      MT
    end

    assert_match(/import alias Result uses reserved built-in type name Result/, error.message)
  end

  def test_type_checks_nominal_interface_constraint_calls
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          editable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          editable function take_damage(amount: int):
              this.hp -= amount

          function is_alive() -> bool:
              return this.hp > 0

      function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = NPC(hp = 10)
          damage_one(npc, 3)
          return npc.hp
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_nominal_interface_constraint_without_explicit_implements
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          editable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC:
          hp: int

      extending NPC:
          editable function take_damage(amount: int):
              this.hp -= amount

          function is_alive() -> bool:
              return this.hp > 0

      function damage_one[T implements Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = NPC(hp = 10)
          damage_one(npc, 3)
          return npc.hp
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/does not implement interface Damageable/, error.message)
  end

  def test_rejects_explicit_interface_conformance_with_missing_method
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          editable function take_damage(amount: int) -> void
          function is_alive() -> bool

      struct NPC implements Damageable:
          hp: int

      extending NPC:
          editable function take_damage(amount: int):
              this.hp -= amount

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/missing method is_alive/, error.message)
  end

  def test_rejects_explicit_interface_conformance_with_generic_method
    source = <<~MT
      # module demo.interfaces

      interface Drawable:
          function draw() -> void

      struct Screen implements Drawable:
          ticks: int

      extending Screen:
          function draw[T]() -> void:
              return
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/cannot be implemented by generic methods/, error.message)
  end

  def test_type_checks_multiple_interfaces_on_single_type
    source = <<~MT
      # module demo.interfaces

      interface Damageable:
          editable function take_damage(amount: int) -> void

      interface Named:
          function name() -> str

      struct NPC implements Damageable, Named:
          label: str
          hp: int

      extending NPC:
          editable function take_damage(amount: int):
              this.hp -= amount

          function name() -> str:
              return this.label

      function tag_and_damage[T implements Damageable and Named](target: ref[T]) -> str:
          target.take_damage(1)
          return target.name()

      function main() -> int:
          var npc = NPC(label = "orc", hp = 10)
          let label = tag_and_damage(npc)
          if label == "orc" and npc.hp == 9:
              return 0
          return 1
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_default_specialization_with_interface_requirement_without_defaults_constraint
    source = <<~MT
      # module demo.default_interface_ok

      interface Named:
          function value() -> int

      struct Counter implements Named:
          count: int

      extending Counter:
          static function default() -> Counter:
              return Counter(count = 7)

          function value() -> int:
              return this.count

      function make_and_read[T implements Named]() -> int:
          let item = default[T]
          return item.value()

      function main() -> int:
          return make_and_read[Counter]()
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_static_interface_requirements_and_associated_calls_on_specialized_type_params
    source = <<~MT
      # module demo.static_interface_requirements

      interface Tagged:
          static function tag() -> int

      struct Counter implements Tagged:
          value: int

      extending Counter:
          static function tag() -> int:
              return 17

      function read_tag[T implements Tagged]() -> int:
          return T.tag()

      function main() -> int:
          return read_tag[Counter]()
    MT

    result = check_source(source)
    counter_type = result.types.fetch("Counter")
    methods = result.methods.fetch(counter_type)

    assert_nil methods.fetch("static:tag").type.receiver_type
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_static_interface_requirement_implemented_by_instance_method
    source = <<~MT
      # module demo.static_interface_mismatch

      interface Tagged:
          static function tag() -> int

      struct Counter implements Tagged:
          value: int

      extending Counter:
          function tag() -> int:
              return this.value
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/method kind does not match/, error.message)
  end

  def test_type_checks_imported_public_interface_constraints
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function damage_one[T implements sample.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = sample.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/sample.mt" => <<~MT,
        # module std.sample

        public interface Damageable:
            editable function take_damage(amount: int) -> void
            function is_alive() -> bool

        public struct NPC implements Damageable:
            hp: int

        extending NPC:
            public editable function take_damage(amount: int):
                this.hp -= amount

            public function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_downstream_imported_public_interface_conformance
    root_source = <<~MT
      # module demo.main

      import std.contracts as contracts
      import std.entities as entities

      function damage_one[T implements contracts.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = entities.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/contracts.mt" => <<~MT,
        # module std.contracts

        public interface Damageable:
            editable function take_damage(amount: int) -> void
            function is_alive() -> bool
      MT
      "std/entities.mt" => <<~MT,
        # module std.entities

        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            public editable function take_damage(amount: int):
                this.hp -= amount

            public function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_downstream_imported_interface_conformance_with_private_methods
    root_source = <<~MT
      # module demo.main

      import std.contracts as contracts
      import std.entities as entities

      function damage_one[T implements contracts.Damageable](target: ref[T], amount: int) -> void:
          if target.is_alive():
              target.take_damage(amount)

      function main() -> int:
          var npc = entities.NPC(hp = 5)
          damage_one(npc, 2)
          return npc.hp
    MT

    imported_sources = {
      "std/contracts.mt" => <<~MT,
        # module std.contracts

        public interface Damageable:
            editable function take_damage(amount: int) -> void
            function is_alive() -> bool
      MT
      "std/entities.mt" => <<~MT,
        # module std.entities

        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            editable function take_damage(amount: int):
                this.hp -= amount

            function is_alive() -> bool:
                return this.hp > 0
      MT
    }

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/type std\.entities\.NPC does not implement interface Damageable for function damage_one/, error.message)
  end

  def test_allows_import_alias_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      import std.async as str

      function main() -> int:
          return 0
    MT

    program = check_program_source(source)
    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_type_checks_import_of_public_declarations_and_methods
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let counter = lib.Counter(value = lib.answer)
          return counter.read()
    MT

    imported = {
      "demo/lib.mt" => <<~MT,

# module demo.lib

public const answer: int = 7

public struct Counter:
    value: int

extending Counter:
    public function read() -> int:
        return this.value

    function times_two() -> int:
        return this.value * 2
      MT
    }

    result = check_program_source(source, imported).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_import_of_public_methods_on_imported_receiver_types
    source = <<~MT
      # module demo.main

      import demo.ext as ext

      function main() -> int:
          let counter = ext.make_counter()
          return counter.read()
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/ext.mt" => <<~MT,
        # module demo.ext

        import demo.dep as dep

        extending dep.Counter:
            public function read() -> int:
                return this.value

        public function make_counter() -> dep.Counter:
            return dep.Counter(value = 7)
      MT
    }

    result = check_program_source(source, imported).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_import_of_private_module_member
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          return lib.hidden
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        const hidden: int = 7
      MT
    }

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.hidden is private to module demo\.lib/, error.message)
  end

  def test_rejects_import_of_private_method
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let counter = lib.Counter(value = 1)
          counter.times_two()
          return 0
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        public struct Counter:
            value: int

        extending Counter:
            function times_two() -> int:
                return this.value * 2
      MT
    }

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source, imported)
    end

    assert_match(/demo\.lib\.Counter\.times_two is private to module demo\.lib/, error.message)
  end

  def test_rejects_import_of_private_type_constructor
    source = <<~MT
      # module demo.main

      import demo.lib as lib

      function main() -> int:
          let hidden = lib.Hidden(value = 7)
          return hidden.value
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        # module demo.lib

        struct Hidden:
            value: int
      MT
    }

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.Hidden is private to module demo\.lib/, error.message)
  end

  def test_type_checks_module_scope_mutable_vars_and_zero_initialized_storage
    source = <<~MT
      # module demo.module_vars

      function identity(value: int) -> int:
          return value

      var counter: int = 1
      var scratch: array[ubyte, 4]
      var callbacks: array[fn(value: int) -> int, 1] = array[fn(value: int) -> int, 1](identity)

      function main() -> int:
          counter = callbacks[0](counter + 1)
          scratch[0] = 7
          return counter + int<-scratch[0]
    MT

    result = check_source(source)
    counter = result.values.fetch("counter")
    scratch = result.values.fetch("scratch")
    callbacks = result.values.fetch("callbacks")

    assert_equal true, counter.mutable
    assert_equal :var, counter.kind
    assert_equal "int", counter.type.to_s
    assert_equal true, scratch.mutable
    assert_equal "array[ubyte, 4]", scratch.type.to_s
    assert_equal true, callbacks.mutable
    assert_equal "array", callbacks.type.name
    assert_instance_of MilkTea::Types::Function, callbacks.type.arguments[0]
    assert_equal "int", callbacks.type.arguments[0].return_type.to_s
    assert_equal "int", callbacks.type.arguments[0].params.first.type.to_s
    assert_equal 1, callbacks.type.arguments[1].value
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_module_scope_var_with_non_static_initializer
    source = <<~MT
      # module demo.bad_module_var

      function seed() -> int:
          return 41

      var counter: int = seed()
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_source(source)
    end

    assert_match(/module variable initializer must be static-storage-safe/, error.message)
  end

  def test_rejects_cross_module_event_emit
    source = <<~MT
      # module demo.consumer

      import demo.publisher as publisher

      function main() -> void:
          publisher.ready.emit()
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source, {
        File.join("demo", "publisher.mt") => <<~PUBLISHER,
          # module demo.publisher

          public event ready[4]
        PUBLISHER
      })
    end

    assert_match(/emit is only available inside module demo\.publisher/, error.message)
  end

  def test_type_checks_cross_module_event_subscribe
    source = <<~MT
      # module demo.consumer

      import demo.publisher as publisher

      function on_ready() -> void:
          return

      function main() -> Result[Subscription, EventError]:
          return publisher.ready.subscribe(on_ready)
    MT

    program = check_program_source(source, {
      File.join("demo", "publisher.mt") => <<~PUBLISHER,
        # module demo.publisher

        public event ready[4]
      PUBLISHER
    })

    assert program.root_analysis.functions.key?("main")
  end

  def test_type_checks_cross_module_event_subscribe_once
    source = <<~MT
      # module demo.consumer

      import demo.publisher as publisher

      function on_ready() -> void:
          return

      function main() -> Result[Subscription, EventError]:
          return publisher.ready.subscribe_once(on_ready)
    MT

    program = check_program_source(source, {
      File.join("demo", "publisher.mt") => <<~PUBLISHER,
        # module demo.publisher

        public event ready[4]
      PUBLISHER
    })

    assert program.root_analysis.functions.key?("main")
  end

  def test_type_checks_cross_module_event_unsubscribe
    source = <<~MT
      # module demo.consumer

      import demo.publisher as publisher

      function on_ready() -> void:
          return

      function main(sub: Subscription) -> bool:
          return publisher.ready.unsubscribe(sub)
    MT

    program = check_program_source(source, {
      File.join("demo", "publisher.mt") => <<~PUBLISHER,
        # module demo.publisher

        public event ready[4]
      PUBLISHER
    })

    assert program.root_analysis.functions.key?("main")
  end

end
