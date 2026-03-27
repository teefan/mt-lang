#include "utils.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Các hàm tiện ích dùng chung cho test ---

// Chuyển TokenType sang tên ký hiệu để in nhật ký dễ đọc khi kiểm tra thất bại
const char *token_name(TokenType type)
{
    // Tra cứu trực tiếp theo enum để không cần cấp phát động
    switch (type)
    {
    case TOKEN_LEFT_PAREN:
        return "TOKEN_LEFT_PAREN";
    case TOKEN_RIGHT_PAREN:
        return "TOKEN_RIGHT_PAREN";
    case TOKEN_LEFT_BRACKET:
        return "TOKEN_LEFT_BRACKET";
    case TOKEN_RIGHT_BRACKET:
        return "TOKEN_RIGHT_BRACKET";
    case TOKEN_LEFT_BRACE:
        return "TOKEN_LEFT_BRACE";
    case TOKEN_RIGHT_BRACE:
        return "TOKEN_RIGHT_BRACE";
    case TOKEN_COLON:
        return "TOKEN_COLON";
    case TOKEN_SEMICOLON:
        return "TOKEN_SEMICOLON";
    case TOKEN_COMMA:
        return "TOKEN_COMMA";
    case TOKEN_DOT:
        return "TOKEN_DOT";
    case TOKEN_EQUAL:
        return "TOKEN_EQUAL";
    case TOKEN_EQUAL_EQUAL:
        return "TOKEN_EQUAL_EQUAL";
    case TOKEN_AMP:
        return "TOKEN_AMP";
    case TOKEN_AMP_EQUAL:
        return "TOKEN_AMP_EQUAL";
    case TOKEN_PIPE:
        return "TOKEN_PIPE";
    case TOKEN_PIPE_EQUAL:
        return "TOKEN_PIPE_EQUAL";
    case TOKEN_CARET:
        return "TOKEN_CARET";
    case TOKEN_CARET_EQUAL:
        return "TOKEN_CARET_EQUAL";
    case TOKEN_BANG:
        return "TOKEN_BANG";
    case TOKEN_BANG_EQUAL:
        return "TOKEN_BANG_EQUAL";
    case TOKEN_LESSER:
        return "TOKEN_LESSER";
    case TOKEN_LESSER_EQUAL:
        return "TOKEN_LESSER_EQUAL";
    case TOKEN_GREATER:
        return "TOKEN_GREATER";
    case TOKEN_GREATER_EQUAL:
        return "TOKEN_GREATER_EQUAL";
    case TOKEN_SHIFT_LEFT:
        return "TOKEN_SHIFT_LEFT";
    case TOKEN_SHIFT_RIGHT:
        return "TOKEN_SHIFT_RIGHT";
    case TOKEN_SHIFT_LEFT_EQUAL:
        return "TOKEN_SHIFT_LEFT_EQUAL";
    case TOKEN_SHIFT_RIGHT_EQUAL:
        return "TOKEN_SHIFT_RIGHT_EQUAL";
    case TOKEN_AND_AND:
        return "TOKEN_AND_AND";
    case TOKEN_OR_OR:
        return "TOKEN_OR_OR";
    case TOKEN_PLUS:
        return "TOKEN_PLUS";
    case TOKEN_PLUS_EQUAL:
        return "TOKEN_PLUS_EQUAL";
    case TOKEN_MINUS:
        return "TOKEN_MINUS";
    case TOKEN_MINUS_EQUAL:
        return "TOKEN_MINUS_EQUAL";
    case TOKEN_STAR:
        return "TOKEN_STAR";
    case TOKEN_STAR_EQUAL:
        return "TOKEN_STAR_EQUAL";
    case TOKEN_SLASH:
        return "TOKEN_SLASH";
    case TOKEN_SLASH_EQUAL:
        return "TOKEN_SLASH_EQUAL";
    case TOKEN_PERCENT:
        return "TOKEN_PERCENT";
    case TOKEN_PERCENT_EQUAL:
        return "TOKEN_PERCENT_EQUAL";
    case TOKEN_DOT_DOT:
        return "TOKEN_DOT_DOT";
    case TOKEN_ARROW:
        return "TOKEN_ARROW";
    case TOKEN_FAT_ARROW:
        return "TOKEN_FAT_ARROW";
    case TOKEN_SLASH_SLASH:
        return "TOKEN_SLASH_SLASH";
    case TOKEN_IDENTIFIER:
        return "TOKEN_IDENTIFIER";
    case TOKEN_STRING:
        return "TOKEN_STRING";
    case TOKEN_STRING_BLOCK:
        return "TOKEN_STRING_BLOCK";
    case TOKEN_NUMBER:
        return "TOKEN_NUMBER";
    case TOKEN_CHAR:
        return "TOKEN_CHAR";
    case TOKEN_TRUE:
        return "TOKEN_TRUE";
    case TOKEN_FALSE:
        return "TOKEN_FALSE";
    case TOKEN_OWN:
        return "TOKEN_OWN";
    case TOKEN_REF:
        return "TOKEN_REF";
    case TOKEN_MANY:
        return "TOKEN_MANY";
    case TOKEN_RAW:
        return "TOKEN_RAW";
    case TOKEN_NULL:
        return "TOKEN_NULL";
    case TOKEN_STACK:
        return "TOKEN_STACK";
    case TOKEN_HEAP:
        return "TOKEN_HEAP";
    case TOKEN_UNSAFE:
        return "TOKEN_UNSAFE";
    case TOKEN_DESTROY:
        return "TOKEN_DESTROY";
    case TOKEN_IMPORT:
        return "TOKEN_IMPORT";
    case TOKEN_EXPORT:
        return "TOKEN_EXPORT";
    case TOKEN_INCLUDE:
        return "TOKEN_INCLUDE";
    case TOKEN_FOREIGN:
        return "TOKEN_FOREIGN";
    case TOKEN_LOCAL:
        return "TOKEN_LOCAL";
    case TOKEN_NAMESPACE:
        return "TOKEN_NAMESPACE";
    case TOKEN_OPAQUE:
        return "TOKEN_OPAQUE";
    case TOKEN_FROM:
        return "TOKEN_FROM";
    case TOKEN_ALIAS:
        return "TOKEN_ALIAS";
    case TOKEN_RECORD:
        return "TOKEN_RECORD";
    case TOKEN_ENUM:
        return "TOKEN_ENUM";
    case TOKEN_VARIANT:
        return "TOKEN_VARIANT";
    case TOKEN_FUNCTION:
        return "TOKEN_FUNCTION";
    case TOKEN_FN:
        return "TOKEN_FN";
    case TOKEN_LET:
        return "TOKEN_LET";
    case TOKEN_FIXED:
        return "TOKEN_FIXED";
    case TOKEN_CONST:
        return "TOKEN_CONST";
    case TOKEN_IF:
        return "TOKEN_IF";
    case TOKEN_ELSE:
        return "TOKEN_ELSE";
    case TOKEN_DO:
        return "TOKEN_DO";
    case TOKEN_SWITCH:
        return "TOKEN_SWITCH";
    case TOKEN_CASE:
        return "TOKEN_CASE";
    case TOKEN_DEFAULT:
        return "TOKEN_DEFAULT";
    case TOKEN_FOR:
        return "TOKEN_FOR";
    case TOKEN_IN:
        return "TOKEN_IN";
    case TOKEN_WHILE:
        return "TOKEN_WHILE";
    case TOKEN_PASS:
        return "TOKEN_PASS";
    case TOKEN_CONTINUE:
        return "TOKEN_CONTINUE";
    case TOKEN_BREAK:
        return "TOKEN_BREAK";
    case TOKEN_RETURN:
        return "TOKEN_RETURN";
    case TOKEN_OUT:
        return "TOKEN_OUT";
    case TOKEN_AND:
        return "TOKEN_AND";
    case TOKEN_OR:
        return "TOKEN_OR";
    case TOKEN_NOT:
        return "TOKEN_NOT";
    case TOKEN_AS:
        return "TOKEN_AS";
    case TOKEN_IS:
        return "TOKEN_IS";
    case TOKEN_NEWLINE:
        return "TOKEN_NEWLINE";
    case TOKEN_INDENT:
        return "TOKEN_INDENT";
    case TOKEN_DEDENT:
        return "TOKEN_DEDENT";
    case TOKEN_ERROR:
        return "TOKEN_ERROR";
    case TOKEN_UNKNOWN:
        return "TOKEN_UNKNOWN";
    case TOKEN_EOF:
        return "TOKEN_EOF";
    }

    // Trường hợp enum chưa được ánh xạ trong hàm này
    return "TOKEN_INVALID";
}

// Đọc toàn bộ nội dung một tệp vào bộ nhớ, trả về con trỏ bộ đệm + độ dài
bool read_file(const char *path, char **out_content, uint32_t *out_length)
{
    // Mở tệp dạng nhị phân để đọc đúng byte theo fixture gốc
    FILE *fp = fopen(path, "rb");

    // Không mở được tệp -> kiểm tra không thể chạy tiếp
    if (fp == NULL)
    {
        fprintf(stderr, "Cannot open fixture: %s\n", path);
        return false;
    }

    // Di chuyển con trỏ tới cuối tệp để lấy kích thước
    if (fseek(fp, 0, SEEK_END) != 0)
    {
        fclose(fp);
        return false;
    }

    // Lấy kích thước tệp hiện tại
    long size = ftell(fp);

    // Kích thước âm nghĩa là lỗi hệ thống I/O
    if (size < 0)
    {
        fclose(fp);
        return false;
    }

    // Quay lại đầu tệp để bắt đầu đọc nội dung
    if (fseek(fp, 0, SEEK_SET) != 0)
    {
        fclose(fp);
        return false;
    }

    // Cấp phát thêm 1 byte để gắn '\0' tiện xử lý chuỗi C
    char *buffer = (char *)malloc((size_t)size + 1);

    // Cấp phát thất bại -> đóng tệp và báo lỗi
    if (buffer == NULL)
    {
        fclose(fp);
        return false;
    }

    // Đọc toàn bộ dữ liệu vào bộ đệm
    size_t read_size = fread(buffer, 1, (size_t)size, fp);
    fclose(fp);

    // Đọc thiếu byte -> dữ liệu không nhất quán
    if (read_size != (size_t)size)
    {
        free(buffer);
        return false;
    }

    // Chốt chuỗi C và trả dữ liệu ra ngoài
    buffer[size] = '\0';

    *out_content = buffer;
    *out_length = (uint32_t)size;

    return true;
}

// So sánh từ ngữ thực tế của ký hiệu với chuỗi kỳ vọng trong dữ liệu kiểm tra
bool lexeme_equals(const char *source, const Token *token, const char *expected)
{
    // Ký hiệu kỳ vọng rỗng (ví dụ INDENT/DEDENT/EOF) -> yêu cầu độ dài phải bằng 0
    if (expected == NULL)
    {
        return token->length == 0;
    }

    // So sánh độ dài trước để loại nhanh các trường hợp khác nhau
    size_t expected_len = strlen(expected);

    if (token->length != expected_len)
    {
        return false;
    }

    // So sánh trực tiếp vùng byte trong mã nguồn theo start_offset + length
    return memcmp(source + token->start_offset, expected, expected_len) == 0;
}
