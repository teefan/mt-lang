project(
  'milk-tea',
  'c',
  version: '0.1.0',
  default_options: ['c_std=c11', 'warning_level=2', 'buildtype=debug'],
)

include_dir = include_directories('include')

sources = ['src/main.c', 'src/lexer.c']

executable('mtc', sources, include_directories: include_dir)
