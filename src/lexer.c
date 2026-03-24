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

// --- Giao diện công cộng ---

void init_lexer(Lexer* lexer, const char* source, uint32_t source_length)
{
}

Token get_next_token(Lexer* lexer)
{
}
