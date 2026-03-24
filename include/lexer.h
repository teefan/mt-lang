#pragma once

#include "tokens.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#define MAX_INDENT_LEVEL 64 // Cấp độ canh lề tối đa

// Cấu trúc bộ phân tích từ ngữ
typedef struct Lexer
{
    // Thông tin mã nguồn để phân tích
    const char *source;     // Nội dung mã nguồn
    uint32_t source_length; // Độ dài mã nguồn

    // Xác định vị trí để phân tích ký hiệu
    uint32_t start_offset;   // Vị trí bắt đầu phân tích
    uint32_t current_offset; // Vị trí hiện tại đang dò

    // Hỗ trợ hệ thống định dạng canh lề
    uint8_t indent_stack[MAX_INDENT_LEVEL]; // Chồng hộp canh lề
    int indent_top;                         // Vị trí đỉnh chồng hộp
    uint16_t current_indent;                // Số khoảng trắng canh lề hiện tại
    uint16_t pending_dedents;               // Số lượng canh lề cần xả trước khi đọc ký hiệu mới
    bool is_at_line_start;                  // Cờ xác định vị trí đang ở dòng mới
} Lexer;

// Khởi tạo bộ phân tích ký hiệu từ ngữ (lexer)
void init_lexer(Lexer *lexer, const char *source, uint32_t source_length);

// Dò tìm ký hiệu tiếp theo
Token get_next_token(Lexer *lexer);
