# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandCompletions
      def completions_command
        shell = @argv.shift
        unless %w[bash zsh fish].include?(shell)
          @err.puts("completions: shell must be bash, zsh, or fish")
          print_command_help("completions", @err)
          return 1
        end

        @out.puts(completion_script(shell))
        0
      end

      def completion_script(shell)
        names = COMMANDS.map(&:first)
        case shell
        when "bash"
          [
            "# mtc bash completion. Source this file or install it into your bash",
            "# completion directory (e.g. /etc/bash_completion.d/mtc).",
            "_mtc() {",
            %(  local cur="${COMP_WORDS[COMP_CWORD]}"),
            %(  if [ "${COMP_CWORD}" -eq 1 ]; then),
            %(    COMPREPLY=( $(compgen -W "#{(names + %w[help version]).join(' ')}" -- "${cur}") )),
            "  fi",
            "}",
            "complete -F _mtc mtc",
          ].join("\n")
        when "zsh"
          lines = ["#compdef mtc", "# mtc zsh completion. Install onto your $fpath as _mtc.", "_mtc() {", "  local -a commands", "  commands=("]
          COMMANDS.each { |name, summary| lines << "    '#{name}:#{summary}'" }
          lines.concat(["  )", "  if (( CURRENT == 2 )); then", "    _describe 'mtc command' commands", "  fi", "}", %(_mtc "$@")])
          lines.join("\n")
        when "fish"
          lines = ["# mtc fish completion. Install into ~/.config/fish/completions/mtc.fish."]
          COMMANDS.each do |name, summary|
            lines << "complete -c mtc -f -n '__fish_use_subcommand' -a #{name} -d '#{summary}'"
          end
          lines.join("\n")
        end
      end
    end
  end
end
