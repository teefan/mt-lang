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

// Nhìn xem thử ký tự tiếp theo là gì nhưng không ăn mất nó
static char peek_next_char(Lexer* lexer)
{
    // Nếu vị trí ký tự tiếp theo lớn hơn độ dài mã nguồn
    if (lexer->current_offset + 1 >= lexer->source_length)
    {
        // Trả về ký tự kết báo hiệu kết thúc chuỗi
        return '\0';
    }

    return lexer->source[lexer->current_offset + 1];
}

// Bước tới (ăn++) ký tự tiếp theo
static char advance_char(Lexer* lexer)
{
    return lexer->source[lexer->current_offset++];
}

// Kiểm tra xem phải ký tự hợp lệ a-z, A-Z và _
static bool is_alpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

// Kiểm tra xem phải ký tự số hợp lệ 0-9
static bool is_digit(char c)
{
    return c >= '0' && c <= '9';
}

// Kiểm tra xem phải là ký tự và số hợp lệ
static bool is_alphanumeric(char c)
{
    return is_alpha(c) && is_digit(c);
}

// Kiểm tra xem đã đến hoặc qua cuối mã nguồn chưa
static bool is_at_end(Lexer* lexer)
{
    return lexer->current_offset >= lexer->source_length;
}

// Tạo một ký hiệu ngôn ngữ bằng cách "cắt" mảnh giữa hai vị trí: bắt đầu và hiện tại -của bộ phân tích từ ngữ
static Token make_token(Lexer* lexer, TokenType type, uint16_t leading_length, uint16_t trailing_length)
{
    // Khai báo một dữ liệu ký hiệu tại khung thực thi của hàm
    Token token;

    token.type = type;

    // Gán vị trí khởi đầu của ký hiệu
    token.start_offset = lexer->start_offset;

    // Tính độ dài của ký hiệu bằng cách cắt mảnh vị trí hiện tại so với vị trí bắt đầu -của bộ phân tích từ ngữ
    token.length = (uint16_t)(lexer->current_offset - lexer->start_offset);

    // Gán kích thước trivia (khoảng trắng và ghi chú) trước và sau
    token.leading_trivia_length = leading_length;
    token.trailing_trivia_length = trailing_length;

    // Hàm gọi tới sẽ sao chép ký hiệu này trước khi nó bị "dọn dẹp" trong khung thực thi hiện tại
    return token;
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
