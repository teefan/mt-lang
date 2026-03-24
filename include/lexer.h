#pragma once

#include "tokens.h"
#include <stdio.h>
#include <stdint.h>

#define MAX_INDENT_LEVEL 64 // Cấp độ canh lề tối đa

typedef struct Lexer
{
    const char* source; // Nội dung mã nguồn

    uint32_t source_length; // Độ dài mã nguồn
    uint32_t current_offset; // Vị trí hiện tại

    uint32_t line; // Số dòng hiện tại
    uint32_t column; // Số cột hiện tại

    uint8_t indent_stack[MAX_INDENT_LEVEL]; // Chồng hộp canh lề
    int indent_top; // Vị trí đỉnh chồng hộp
} Lexer;
