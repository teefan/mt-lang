#pragma once

#include <stdint.h>

// Ký hiệu của ngôn ngữ lập trình Milk Tea
typedef enum TokenType
{
    // --- Ký tự đơn ---
    TOKEN_LEFT_PAREN,    // (
    TOKEN_RIGHT_PAREN,   // )
    TOKEN_LEFT_BRACKET,  // [
    TOKEN_RIGHT_BRACKET, // ]
    TOKEN_LEFT_BRACE,    // {
    TOKEN_RIGHT_BRACE,   // }
    TOKEN_COLON,         // :
    TOKEN_SEMICOLON,     // ;
    TOKEN_COMMA,         // ,
    TOKEN_DOT,           // .

    // --- Toán tử & Ký tự kép ---
    TOKEN_EQUAL,         // =
    TOKEN_EQUAL_EQUAL,   // ==
    TOKEN_BANG,          // !
    TOKEN_BANG_EQUAL,    // !=
    TOKEN_LESS,          // <
    TOKEN_LESS_EQUAL,    // <=
    TOKEN_GREATER,       // >
    TOKEN_GREATER_EQUAL, // >=
    TOKEN_PLUS,          // +
    TOKEN_MINUS,         // -
    TOKEN_STAR,          // *
    TOKEN_SLASH,         // /
    TOKEN_PERCENT,       // % (Chia lấy dư)

    // --- Các toán tử đặc trưng ---
    TOKEN_DOT_DOT,     // .. Khoảng
    TOKEN_ARROW,       // -> Kiểu trả về
    TOKEN_FAT_ARROW,   // => Nội dung hàm ẩn danh
    TOKEN_SLASH_SLASH, // //

    // --- Giá trị văn bản ---
    TOKEN_IDENTIFIER,
    TOKEN_STRING,
    TOKEN_STRING_BLOCK,
    TOKEN_NUMBER,
    TOKEN_CHAR,
    TOKEN_TRUE,
    TOKEN_FALSE, // giá trị đúng/sai

    // --- Từ khóa: Quản lý và an toàn bộ nhớ ---
    TOKEN_OWN,
    TOKEN_REF,
    TOKEN_MANY,
    TOKEN_RAW,
    TOKEN_NULL,
    TOKEN_STACK,
    TOKEN_HEAP,
    TOKEN_UNSAFE,
    TOKEN_DESTROY,

    // --- Từ khóa: Khai báo & mô-đun ---
    TOKEN_IMPORT,
    TOKEN_EXPORT,
    TOKEN_INCLUDE,
    TOKEN_FOREIGN,
    TOKEN_LOCAL,
    TOKEN_NAMESPACE,
    TOKEN_ALIAS,
    TOKEN_RECORD,
    TOKEN_ENUM,
    TOKEN_VARIANT,
    TOKEN_FUNCTION,
    TOKEN_FN,
    TOKEN_LET,
    TOKEN_FIXED,
    TOKEN_CONST,

    // --- Từ khóa: Điều khiển luồng ---
    TOKEN_IF,
    TOKEN_ELSE,
    TOKEN_SWITCH,
    TOKEN_CASE,
    TOKEN_FOR,
    TOKEN_IN,
    TOKEN_WHILE,
    TOKEN_CONTINUE,
    TOKEN_BREAK,
    TOKEN_RETURN,
    TOKEN_AS, // Ép kiểu: x as T
    TOKEN_IS, // Kiểm tra kiểu: x is T

    // --- Kí hiệu đặc biệt để phân tích từ ngữ (kiểu thụt lề) ---
    TOKEN_NEWLINE,
    TOKEN_INDENT, // Canh lề tới (mở khối)
    TOKEN_DEDENT, // Canh lề lùi (đóng khối)

    // --- Trạng thái hệ thống ---
    TOKEN_UNKNOWN,
    TOKEN_EOF
} TokenType;

typedef struct Token
{
    TokenType type; // Kiểu ký hiệu: xác định ký hiệu này là cái gì

    uint32_t start_offset; // Vị trí (byte) tương đối của ký hiệu trong mã nguồn
    uint16_t length;       // Độ dài của ký hiệu

    uint16_t leading_trivia_length;  // Độ dài vặt vãnh (khoảng trắng và ghi chú) đi trước ký hiệu
    uint16_t trailing_trivia_length; // Độ dài vặt vãnh (khoảng trắng và ghi chú) đi sau ký hiệu
} Token;
