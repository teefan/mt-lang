#include "lexer.h"
#include "utils.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// Cấu trúc biểu diễn ký hiệu mong đợi theo thứ tự bộ phân tích từ ngữ phải trả về
typedef struct ExpectedToken
{
    // Kiểu ký hiệu
    TokenType type;

    // Chuỗi từ ngữ
    const char *lexeme;
} ExpectedToken;

// Chạy kiểm tra tích hợp bộ phân tích từ ngữ dựa trên một tệp fixture .mtl đầy đủ
static bool run_fixture_test(void)
{
    // Fixture chứa hầu hết điểm quét chính của  bộ phân tích từ ngữ (từ khóa, văn bản, toán tử, vặt vãnh...)
    static const char *fixture_path = "tests/fixtures/lexer-test.mtl";

    // Danh sách token kỳ vọng theo đúng thứ tự lexer phải scan được
    static const ExpectedToken expected[] = {
        {TOKEN_AS, "as"},
        {TOKEN_AND, "and"},
        {TOKEN_ALIAS, "alias"},
        {TOKEN_BREAK, "break"},
        {TOKEN_CASE, "case"},
        {TOKEN_CONST, "const"},
        {TOKEN_CONTINUE, "continue"},
        {TOKEN_DO, "do"},
        {TOKEN_DEFAULT, "default"},
        {TOKEN_DESTROY, "destroy"},
        {TOKEN_ELSE, "else"},
        {TOKEN_ENUM, "enum"},
        {TOKEN_EXPORT, "export"},
        {TOKEN_FN, "fn"},
        {TOKEN_FOR, "for"},
        {TOKEN_FROM, "from"},
        {TOKEN_FIXED, "fixed"},
        {TOKEN_FALSE, "false"},
        {TOKEN_FOREIGN, "foreign"},
        {TOKEN_FUNCTION, "function"},
        {TOKEN_HEAP, "heap"},
        {TOKEN_IF, "if"},
        {TOKEN_IN, "in"},
        {TOKEN_IS, "is"},
        {TOKEN_IMPORT, "import"},
        {TOKEN_INCLUDE, "include"},
        {TOKEN_LET, "let"},
        {TOKEN_LOCAL, "local"},
        {TOKEN_MANY, "many"},
        {TOKEN_NOT, "not"},
        {TOKEN_NULL, "null"},
        {TOKEN_NAMESPACE, "namespace"},
        {TOKEN_OR, "or"},
        {TOKEN_OUT, "out"},
        {TOKEN_OWN, "own"},
        {TOKEN_OPAQUE, "opaque"},
        {TOKEN_PASS, "pass"},
        {TOKEN_RAW, "raw"},
        {TOKEN_REF, "ref"},
        {TOKEN_RECORD, "record"},
        {TOKEN_RETURN, "return"},
        {TOKEN_STACK, "stack"},
        {TOKEN_SWITCH, "switch"},
        {TOKEN_TRUE, "true"},
        {TOKEN_UNSAFE, "unsafe"},
        {TOKEN_VARIANT, "variant"},
        {TOKEN_WHILE, "while"},
        {TOKEN_IDENTIFIER, "identifier_name"},
        {TOKEN_NUMBER, "123"},
        {TOKEN_NUMBER, "0x1F"},
        {TOKEN_NUMBER, "0b101"},
        {TOKEN_NUMBER, "3.14"},
        {TOKEN_STRING, "\"hello\""},
        {TOKEN_STRING_BLOCK, "\"\"\"\ntext\n\"\"\""},
        {TOKEN_CHAR, "'A'"},
        {TOKEN_CHAR, "'\\\''"},
        {TOKEN_LEFT_PAREN, "("},
        {TOKEN_RIGHT_PAREN, ")"},
        {TOKEN_LEFT_BRACKET, "["},
        {TOKEN_RIGHT_BRACKET, "]"},
        {TOKEN_LEFT_BRACE, "{"},
        {TOKEN_RIGHT_BRACE, "}"},
        {TOKEN_COLON, ":"},
        {TOKEN_SEMICOLON, ";"},
        {TOKEN_COMMA, ","},
        {TOKEN_DOT, "."},
        {TOKEN_DOT_DOT, ".."},
        {TOKEN_PLUS, "+"},
        {TOKEN_PLUS_EQUAL, "+="},
        {TOKEN_MINUS, "-"},
        {TOKEN_MINUS_EQUAL, "-="},
        {TOKEN_ARROW, "->"},
        {TOKEN_STAR, "*"},
        {TOKEN_STAR_EQUAL, "*="},
        {TOKEN_SLASH, "/"},
        {TOKEN_SLASH_EQUAL, "/="},
        {TOKEN_SLASH_SLASH, "//"},
        {TOKEN_PERCENT, "%"},
        {TOKEN_PERCENT_EQUAL, "%="},
        {TOKEN_AMP, "&"},
        {TOKEN_AMP_EQUAL, "&="},
        {TOKEN_AND_AND, "&&"},
        {TOKEN_PIPE, "|"},
        {TOKEN_PIPE_EQUAL, "|="},
        {TOKEN_OR_OR, "||"},
        {TOKEN_CARET, "^"},
        {TOKEN_CARET_EQUAL, "^="},
        {TOKEN_BANG, "!"},
        {TOKEN_BANG_EQUAL, "!="},
        {TOKEN_EQUAL, "="},
        {TOKEN_EQUAL_EQUAL, "=="},
        {TOKEN_FAT_ARROW, "=>"},
        {TOKEN_LESSER, "<"},
        {TOKEN_LESSER_EQUAL, "<="},
        {TOKEN_SHIFT_LEFT, "<<"},
        {TOKEN_SHIFT_LEFT_EQUAL, "<<="},
        {TOKEN_GREATER, ">"},
        {TOKEN_GREATER_EQUAL, ">="},
        {TOKEN_SHIFT_RIGHT, ">>"},
        {TOKEN_SHIFT_RIGHT_EQUAL, ">>="},
        {TOKEN_IDENTIFIER, "foo"},
        {TOKEN_IDENTIFIER, "bar"},
        {TOKEN_IF, "if"},
        {TOKEN_TRUE, "true"},
        {TOKEN_COLON, ":"},
        {TOKEN_INDENT, NULL},
        {TOKEN_PASS, "pass"},
        {TOKEN_DEDENT, NULL},
        {TOKEN_PASS, "pass"},
        {TOKEN_UNKNOWN, "@"},
        {TOKEN_EOF, NULL},
    };

    // Nạp toàn bộ mã nguồn fixture vào bộ nhớ để bộ phân tích từ ngữ quét liên tục
    char *source = NULL;
    uint32_t source_length = 0;

    // Nếu không đọc được fixture thì kiểm tra thất bại ngay
    if (!read_file(fixture_path, &source, &source_length))
    {
        return false;
    }

    // Khởi tạo bộ phân tích từ ngữ với dữ liệu fixture đã đọc
    Lexer lexer;

    init_lexer(&lexer, source, source_length);

    // So khớp từng ký hiệu trả về với mảng mong đợi
    for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); i++)
    {
        Token token = get_next_token(&lexer);

        // So khớp kiểu token trước
        if (token.type != expected[i].type)
        {
            fprintf(
                stderr,
                "Token[%zu] type mismatch: expected=%s actual=%s\n",
                i,
                token_name(expected[i].type),
                token_name(token.type));

            free(source);

            return false;
        }

        // Sau đó so khớp luôn từ ngữ để xác nhận bộ phân tích từ ngữ cắt đúng mảnh nguồn
        if (!lexeme_equals(source, &token, expected[i].lexeme))
        {
            fprintf(
                stderr,
                "Token[%zu] lexeme mismatch for %s\n",
                i,
                token_name(token.type));

            free(source);

            return false;
        }
    }

    // Dọn bộ nhớ fixture sau khi kiểm tra hoàn tất
    free(source);

    return true;
}

int main(void)
{
    // Chạy một fixture tổng hợp để kiểm tra toàn bộ đường quét chính
    if (!run_fixture_test())
    {
        return 1;
    }

    return 0;
}
