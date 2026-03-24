#include "tokens.h"
#include "lexer.h"

// --- Các hàm nội bộ ---

// Nhìn xem thử ký tự hiện tại là gì?
static char peek_char(Lexer *lexer)
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
static char peek_next_char(Lexer *lexer)
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
static char advance_char(Lexer *lexer)
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

// Kiểm tra xem phải ký tự số thập lục phân hợp lệ 0-9, a-f, A-F
static bool is_hex_digit(char c)
{
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// Kiểm tra xem phải ký tự số nhị phân hợp lệ 0-1
static bool is_binary_digit(char c)
{
    return c == '0' || c == '1';
}

// Kiểm tra xem phải là ký tự và số hợp lệ
static bool is_alphanumeric(char c)
{
    return is_alpha(c) && is_digit(c);
}

// Kiểm tra xem đã đến hoặc qua cuối mã nguồn chưa
static bool is_at_end(Lexer *lexer)
{
    return lexer->current_offset >= lexer->source_length;
}

// Quét các vặt vãnh (ghi chú và khoảng trắng) đi trước ký hiệu
static void scan_leading_trivia(Lexer *lexer)
{
    while (true)
    {
        // Lấy giá trị ký tự tiếp theo để kiểm tra
        char c = peek_char(lexer);

        // Ăn khoảng trắng, căn lề hay đầu dòng
        if (c == ' ' || c == '\t' || c == '\r')
        {
            advance_char(lexer);
        }
        // Khi đang quét đằng trước ký hiệu, ăn xuống hàng và bật cờ báo hiệu hàng mới
        else if (c == '\n')
        {
            lexer->is_at_line_start = true;
            advance_char(lexer);
        }
        // Khi gặp '--', tức là báo hiệu ghi chú trong hàng
        else if (c == '-' && peek_next_char(lexer) == '-')
        {
            // Ăn hai dấu --
            advance_char(lexer);
            advance_char(lexer);

            // Ăn ghi chú cho tới khi hết hàng và chưa tới cuối mã nguồn
            while (peek_char(lexer) != '\n' && !is_at_end(lexer))
            {
                advance_char(lexer);
            }
        }
        // Khi gặp '++' đầu tiên, tức là báo hiệu mở ra ghi chú nhiều hàng
        else if (c == '+' && peek_next_char(lexer) == '+')
        {
            // Ăn hai dấu ++
            advance_char(lexer);
            advance_char(lexer);

            while (!is_at_end(lexer))
            {
                // Khi gặp '++' tiếp theo, tức là báo hiệu kết thúc ghi chú nhiều hàng
                if (c == '+' && peek_next_char(lexer) == '+')
                {
                    // Ăn hai dấu ++
                    advance_char(lexer);
                    advance_char(lexer);
                    break;
                }

                // Nếu gặp xuống hàng thì bật cờ báo hiệu hàng mới
                if (peek_char(lexer) == '\n')
                {
                    lexer->is_at_line_start = true;
                }

                // Ăn hết bất kì ký tự nào vẫn thuộc ghi chú nhiều hàng
                advance_char(lexer);
            }
        }
        // Không thuộc bất kỳ vặt vãnh nào đang xem xét
        else
        {
            // Gặp ký hiệu khác, ngừng, không ăn
            break;
        }
    }
}

// Quét các vặt vãnh (ghi chú và khoảng trắng) đi sau ký hiệu
static void scan_trailing_trivia(Lexer *lexer)
{
    while (true)
    {
        // Lấy giá trị ký tự tiếp theo để kiểm tra
        char c = peek_char(lexer);

        // Ăn khoảng trắng, căn lề hay đầu dòng
        if (c == ' ' || c == '\t' || c == '\r')
        {
            advance_char(lexer);
        }
        // Khi gặp '--', tức là báo hiệu ghi chú trong hàng
        else if (c == '-' && peek_next_char(lexer) == '-')
        {
            // Ăn hai dấu --
            advance_char(lexer);
            advance_char(lexer);

            // Ăn ghi chú cho tới khi hết hàng và chưa tới cuối mã nguồn
            while (peek_char(lexer) != '\n' && !is_at_end(lexer))
            {
                advance_char(lexer);
            }

            // Ghi chú một hàng luôn là thứ cuối cùng trên một hàng
            // Ăn xong thì dừng quét vặt vãnh theo sau
            break;
        }
        // Không thuộc bất kỳ vặt vãnh nào đang xem xét
        else
        {
            // Nếu là xuống hàng \n, bắt đầu ghi chú nhiều dòng ++, hoặc ký hiệu khác thì dừng
            // Nhường \n và ++ cho các vặt vãnh đứng trước của ký hiệu tiếp theo
            break;
        }
    }
}

// Tạo một ký hiệu ngôn ngữ giữa hai vị trí: bắt đầu và hiện tại -của bộ phân tích từ ngữ
static Token make_token(
    Lexer *lexer, TokenType type, uint16_t length, uint16_t leading_length, uint16_t trailing_length)
{
    // Khai báo một dữ liệu ký hiệu tại khung thực thi của hàm
    Token token;

    // Gán kiểu ký hiệu
    token.type = type;

    // Gán vị trí khởi đầu của ký hiệu
    token.start_offset = lexer->start_offset;

    // Gán độ dài của ký hiệu cắt mảnh đã được tính bởi bộ phân tích từ ngữ
    token.length = length;

    // Gán kích thước trivia (khoảng trắng và ghi chú) trước và sau, được tính bởi bộ phân tích từ ngữ
    token.leading_trivia_length = leading_length;
    token.trailing_trivia_length = trailing_length;

    // Hàm gọi tới sẽ sao chép ký hiệu này trước khi nó bị "dọn dẹp" trong khung thực thi hiện tại
    return token;
}

// --- Giao diện công cộng ---

void init_lexer(Lexer *lexer, const char *source, uint32_t source_length)
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

Token get_next_token(Lexer *lexer)
{
    // Đo độ dài các vặt vãnh đứng trước ký hiệu
    uint16_t leading_start = lexer->current_offset;
    scan_leading_trivia(lexer);
    uint16_t leading_length = (uint16_t)(lexer->current_offset - leading_start);

    // Xác định vị trí ký hiệu hiện tại sau khi đã dọn dẹp vặt vãnh đứng trước
    lexer->start_offset = lexer->current_offset;

    // Nếu vị trí này là kết thúc mã nguồn, chính là ký hiệu EOF
    if (is_at_end(lexer))
    {
        // Tạo và trả về ký hiệu kết thúc EOF
        return make_token(lexer, TOKEN_EOF, 0, leading_length, 0);
    }

    // TODO: xây dựng ký hiệu canh lề
    if (lexer->is_at_line_start)
    {
        // Tắt cờ để không kiểm tra ở ký hiệu sau
        lexer->is_at_line_start = false;
    }
}
