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
            // Nếu là khoảng trắng và đang ở đầu dòng, nghĩa là đang bắt đầu đi vào canh lề (khối) mới
            if (lexer->is_at_line_start)
            {
                // Trường hợp khoảng trắng
                if (c == ' ')
                {
                    // Đếm lên số khoảng trắng lề (khối) của hàng hiện tại
                    lexer->current_indent++;
                }
                // Trường hợp kí tự căn lề
                else if (c == '\t')
                {
                    // Tăng số khoảng trắng lề (khối) của hàng hiện tại lên 4 khoảng trắng
                    lexer->current_indent += 4;
                }
            }

            advance_char(lexer);
        }
        // Khi đang quét đằng trước ký hiệu, ăn xuống hàng và bật cờ báo hiệu hàng mới
        else if (c == '\n')
        {
            // Bật cờ báo hiệu hàng mới
            lexer->is_at_line_start = true;

            // Đưa số khoảng trắng của hàng về 0
            lexer->current_indent = 0;

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

// Quét đơn giản các vặt vãnh (ghi chú và khoảng trắng) đi sau ký hiệu, nhường phần lớn cho hàm quét trước
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

// Xác định kiểu ký hiệu của khoảng ký tự hiện tại (đại diện ký hiệu) của bộ phân tích từ ngữ
// dựa trên thuật toán tìm kiếm bằng cây Trie
static TokenType get_token_type(Lexer *lexer)
{
    // Lấy độ dài ký hiệu (từ vị trí bắt đầu ký hiệu -> đên vị trí hiện tại của bộ phân tích từ ngữ)
    uint16_t token_length = (uint16_t)(lexer->current_offset - lexer->start_offset);

    // Lấy ký tự đầu tiên để phân nhánh từ loại
    char first_char = lexer->source[lexer->start_offset];

    // Truy xuất con trỏ tới đầu chữ hiện tại để dùng trong memcmp
    const char *start = lexer->source + lexer->start_offset;

    // Phân nhánh từ loại dựa trên ký tự đầu tiên, sau đó dùng memcmp để so sánh nhanh với khoảng ký tự hiện tại
    switch (first_char)
    {
    case 'a':
        if (token_length == 2 && memcmp(start, "as", 2) == 0)
        {
            return TOKEN_AS;
        }

        if (token_length == 5 && memcmp(start, "alias", 5) == 0)
        {
            return TOKEN_ALIAS;
        }

        break;
    case 'b':
        if (token_length == 5 && memcmp(start, "break", 5) == 0)
        {
            return TOKEN_BREAK;
        }

        break;
    case 'c':
        if (token_length == 4 && memcmp(start, "case", 4) == 0)
        {
            return TOKEN_CASE;
        }

        if (token_length == 5 && memcmp(start, "const", 5) == 0)
        {
            return TOKEN_CONST;
        }

        if (token_length == 8 && memcmp(start, "continue", 8) == 0)
        {
            return TOKEN_CONTINUE;
        }

        break;
    case 'd':
        if (token_length == 7 && memcmp(start, "destroy", 7) == 0)
        {
            return TOKEN_DESTROY;
        }

        break;
    case 'e':
        if (token_length == 4)
        {
            if (memcmp(start, "else", 4) == 0)
            {
                return TOKEN_ELSE;
            }

            if (memcmp(start, "enum", 4) == 0)
            {
                return TOKEN_ENUM;
            }
        }

        if (token_length == 6 && memcmp(start, "export", 6) == 0)
        {
            return TOKEN_EXPORT;
        }

        break;
    case 'f':
        if (token_length == 2 && memcmp(start, "fn", 2) == 0)
        {
            return TOKEN_FN;
        }

        if (token_length == 3 && memcmp(start, "for", 3) == 0)
        {
            return TOKEN_FOR;
        }

        if (token_length == 5)
        {
            if (memcmp(start, "fixed", 5) == 0)
            {
                return TOKEN_FIXED;
            }

            if (memcmp(start, "false", 5) == 0)
            {
                return TOKEN_FALSE;
            }
        }

        if (token_length == 7 && memcmp(start, "foreign", 7) == 0)
        {
            return TOKEN_FOREIGN;
        }

        if (token_length == 8 && memcmp(start, "function", 8) == 0)
        {
            return TOKEN_FUNCTION;
        }

        break;
    case 'i':
        if (token_length == 2)
        {
            if (memcmp(start, "if", 2) == 0)
            {
                return TOKEN_IF;
            }

            if (memcmp(start, "in", 2) == 0)
            {
                return TOKEN_IN;
            }
        }

        if (token_length == 6 && memcmp(start, "import", 6) == 0)
        {
            return TOKEN_IMPORT;
        }

        if (token_length == 7 && memcmp(start, "include", 7) == 0)
        {
            return TOKEN_INCLUDE;
        }

        break;
    case 'l':
        if (token_length == 3 && memcmp(start, "let", 3) == 0)
        {
            return TOKEN_LET;
        }

        if (token_length == 5 && memcmp(start, "local", 5) == 0)
        {
            return TOKEN_LOCAL;
        }

        break;
    case 'm':
        if (token_length == 4 && memcmp(start, "many", 4) == 0)
        {
            return TOKEN_MANY;
        }

        if (token_length == 9 && memcmp(start, "namespace", 9) == 0)
        {
            return TOKEN_NAMESPACE;
        }

        break;
    case 'n':
        if (token_length == 4 && memcmp(start, "null", 4) == 0)
        {
            return TOKEN_NULL;
        }

        break;
    case 'o':
        if (token_length == 3 && memcmp(start, "own", 3) == 0)
        {
            return TOKEN_OWN;
        }

        break;
    case 'r':
        if (token_length == 3)
        {
            if (memcmp(start, "raw", 3) == 0)
            {
                return TOKEN_RAW;
            }

            if (memcmp(start, "ref", 3) == 0)
            {
                return TOKEN_REF;
            }
        }

        if (token_length == 6)
        {
            if (memcmp(start, "record", 6) == 0)
            {
                return TOKEN_RECORD;
            }

            if (memcmp(start, "return", 6) == 0)
            {
                return TOKEN_RETURN;
            }
        }

        break;
    case 's':
        if (token_length == 5 && memcmp(start, "stack", 5) == 0)
        {
            return TOKEN_STACK;
        }

        if (token_length == 6 && memcmp(start, "switch", 6) == 0)
        {
            return TOKEN_SWITCH;
        }

        break;
    case 't':
        if (token_length == 4 && memcmp(start, "true", 4) == 0)
        {
            return TOKEN_TRUE;
        }

        break;
    case 'u':
        if (token_length == 6 && memcmp(start, "unsafe", 6) == 0)
        {
            return TOKEN_UNSAFE;
        }

        break;
    case 'v':
        if (token_length == 7 && memcmp(start, "variant", 7) == 0)
        {
            return TOKEN_VARIANT;
        }

        break;
    case 'w':
        if (token_length == 5 && memcmp(start, "while", 5) == 0)
        {
            return TOKEN_WHILE;
        }

        break;
    }

    return TOKEN_IDENTIFIER;
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

    // Khởi động lại các biến theo dõi canh lề
    lexer->indent_stack[0] = 0;
    lexer->indent_top = 0;
    lexer->current_indent = 0;
    lexer->pending_dedents = 0;
    lexer->is_at_line_start = true;
}

Token get_next_token(Lexer *lexer)
{
    // Nếu có canh lề đang cần xả (đóng khối)
    if (lexer->pending_dedents > 0)
    {
        // Xả canh lề
        lexer->pending_dedents--;

        // Tạo và trả về ký hiệu lùi lề (đóng khối)
        return make_token(lexer, TOKEN_DEDENT, 0, 0, 0);
    }

    // Đo độ dài các vặt vãnh đứng trước ký hiệu

    // Vị trí ký tự bắt đầu quét
    uint16_t leading_start = lexer->current_offset;

    // Quét các vặt vãnh đầu ký hiệu, khi quét sẽ tự động nhảy vị trí ký tự
    scan_leading_trivia(lexer);

    // Đã quét xong, tính toán độ dài của vặt vãnh trước ký hiệu
    uint16_t leading_length = (uint16_t)(lexer->current_offset - leading_start);

    // Xác định vị trí ký hiệu hiện tại sau khi đã dọn dẹp vặt vãnh đứng trước
    lexer->start_offset = lexer->current_offset;

    // Nếu vị trí này là kết thúc mã nguồn, chính là ký hiệu EOF
    if (is_at_end(lexer))
    {
        // Tạo và trả về ký hiệu kết thúc EOF
        return make_token(lexer, TOKEN_EOF, 0, leading_length, 0);
    }

    // Xây dựng ký hiệu canh lề (mở/đóng khối)
    if (lexer->is_at_line_start)
    {
        // Tắt cờ xuống hàng để không kiểm tra ở ký hiệu sau
        lexer->is_at_line_start = false;

        uint16_t current_indent = lexer->current_indent;              // Số khoảng trắng canh lề hàng
        uint16_t top_indent = lexer->indent_stack[lexer->indent_top]; // Số khoảng trắng canh lề đỉnh

        // Nếu số khoảng trắng canh lề hàng lớn hơn số khoảng trắng canh lề đỉnh: -> đi sâu vào lề (mở khối)
        if (current_indent > top_indent)
        {
            // Gán số khoảng trắng vào độ sâu lề hiện tại (khối đang mở)
            lexer->indent_stack[lexer->indent_top] = current_indent;

            // Tăng độ sâu của lề (khối)
            lexer->indent_top++;

            // Tạo và trả về ký hiệu tăng lề (mở khối)
            return make_token(lexer, TOKEN_INDENT, 0, leading_length, 0);
        }
        // Nếu số khoảng trắng canh lề hàng nhỏ hơn số khoảng trắng canh lề đỉnh: <- lùi lề (đóng khối)
        else if (current_indent < top_indent)
        {
            // Thụt lề (đóng khối) liên tục nếu số khoảng trắng hàng nhỏ hơn số khoảng trắng canh để đỉnh
            while (lexer->indent_top > 0 && current_indent < lexer->indent_stack[lexer->indent_top])
            {
                // Giảm độ sâu lề (khối)
                lexer->indent_top--;

                // Lưu số kết thúc lề cần có (số lần phải đóng khối)
                lexer->pending_dedents++;
            }

            // Xả lề (đóng khối) đầu tiên nếu có lề cần xả (khối cần đóng)
            if (lexer->pending_dedents > 0)
            {
                // Xả lề (đóng khối)
                lexer->pending_dedents--;

                // Tạo và trả về ký hiệu lùi lề (đóng khối)
                return make_token(lexer, TOKEN_DEDENT, 0, leading_length, 0);
            }
        }
    }

    // Bắt đầu đi vào quét ký hiệu trung tâm

    // Sau khi quét xong các vặt vãnh đứng trước, ta tiếp tục quét các ký tự để xác định ký hiệu đó
    char c = advance_char(lexer);

    // Khởi tạo một ký hiệu, gán kiểu chưa biết
    TokenType token = TOKEN_UNKNOWN;
}
