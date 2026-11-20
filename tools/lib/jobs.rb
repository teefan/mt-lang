# frozen_string_literal: true

# Parallel-fan-out ceiling for the tooling.
#
# The compiler is a large process: a full analyze/lint of a compiler-sized file
# peaks at several GiB, so a wide fan-out exhausts a workstation's RAM long
# before it saturates the CPU.  Every harness that spawns concurrent compilers
# routes its job count through this clamp; the ceiling is deliberately not
# configurable.
module Jobs
  MAX = 4

  def self.clamp(requested, label: "--jobs")
    if requested > MAX
      warn "warning: #{label} #{requested} capped at #{MAX} (each compiler process can peak several GiB)"
      return MAX
    end
    requested < 1 ? 1 : requested
  end
end
