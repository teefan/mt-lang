#include "tokens.h"
#include <stdio.h>
#include <stdint.h>

#define MAX_INDENT_LEVEL 64 // Cấp độ thụt lề tối đa

typedef struct Token
{
    TokenType type; // Kiểu ký hiệu

    uint32_t offset; // Vị trí byte tương đối trong mã nguồn
    uint16_t length; // Độ dài của ký hiệu

    uint16_t leading_trivia_length; // Độ dài khoảng trắng và ghi chú đi trước ký hiệu
    uint16_t trailing_trivia_length; // Độ dài khoảng trắng và ghi chú đi sau ký hiệu
} Token;
