#include "tokens.h"
#include "lexer.h"

// --- Các hàm nội bộ ---

// Nhìn xem thử ký tự hiện tại là gì?
static char peek_char(Lexer* lexer)
{
    // Nếu vị trí hiện tại lớn hơn độ dài mã nguồn
    if (lexer->current_offset > lexer->source_length)
    {
        // Trả về ký tự kết báo hiệu kết thúc chuỗi
        return '\0';
    }

    return lexer->source[lexer->current_offset];
}

// Bước tới (ăn++) ký tự tiếp theo
static char advance_char(Lexer* lexer)
{
    return lexer->source[lexer->current_offset++];
}

// Xác định đã đến hoặc qua cuối mã nguồn chưa
static bool is_at_end(Lexer* lexer)
{
    return lexer->current_offset >= lexer->source_length;
}

// --- Giao diện công cộng ---

void init_lexer(Lexer* lexer, const char* source, uint32_t source_length)
{
    // Gán thông tin mã nguồn
    lexer->source = source;
    lexer->source_length = source_length;

    // Khởi động lại các biến theo dõi
    lexer->start_offset = 0;
    lexer->current_offset = 0;
    lexer->is_at_line_start = true;

    // Khởi động lại các biến theo dõi canh lề
    lexer->indent_stack[0] = 0;
    lexer->indent_top = 0;
}

Token get_next_token(Lexer* lexer)
{
}
