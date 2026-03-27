project(
  'milk-tea',
  'c',
  version: '0.0.1',
  default_options: ['c_std=c11', 'warning_level=2', 'buildtype=debug'],
)

include_dir = include_directories('include')

sources = ['src/main.c', 'src/lexer.c']

executable('mtc', sources, include_directories: include_dir)

lexer_test_sources = ['tests/lexer_test.c', 'src/utils.c', 'src/lexer.c']

lexer_test_executable = executable(
  'lexer_test',
  lexer_test_sources,
  include_directories: include_dir,
)

test('lexer', lexer_test_executable, workdir: meson.current_source_dir())
