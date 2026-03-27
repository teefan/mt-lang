#pragma once

#include "lexer.h"

#include <stdbool.h>
#include <stdint.h>

const char *token_name(TokenType type);
bool read_file(const char *path, char **out_content, uint32_t *out_length);
bool lexeme_equals(const char *source, const Token *token, const char *expected);
