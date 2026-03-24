#pragma once

// Ký hiệu của ngôn ngữ lập trình Milk Tea
typedef enum TokenType
{
    // --- Ký tự đơn (Single-character tokens) ---
    TOKEN_LEFT_PAREN, TOKEN_RIGHT_PAREN,     // ( )
    TOKEN_LEFT_BRACKET, TOKEN_RIGHT_BRACKET, // [ ]
    TOKEN_LEFT_BRACE, TOKEN_RIGHT_BRACE,     // { }
    TOKEN_COLON, TOKEN_SEMICOLON,            // : ;
    TOKEN_COMMA, TOKEN_DOT,                  // , .

    // --- Toán tử & Ký tự kép (One or two character tokens) ---
    TOKEN_EQUAL, TOKEN_EQUAL_EQUAL,          // = ==
    TOKEN_BANG, TOKEN_BANG_EQUAL,            // ! !=
    TOKEN_LESS, TOKEN_LESS_EQUAL,            // < <=
    TOKEN_GREATER, TOKEN_GREATER_EQUAL,      // > >=
    TOKEN_PLUS,                              // +
    TOKEN_MINUS,                             // -
    TOKEN_STAR, TOKEN_SLASH,                 // * /
    TOKEN_PERCENT,                           // % (Chia lấy dư)

    // --- Các toán tử đặc trưng của Milk Tea ---
    TOKEN_DOT_DOT,                           // .. (Range)
    TOKEN_ARROW,                             // -> (Return type)
    TOKEN_FAT_ARROW,                         // => (Lambda/Body)
    TOKEN_SLASH_SLASH,                       // // (Integer division)

    // --- Giá trị văn bản ---
    TOKEN_IDENTIFIER,
    TOKEN_STRING,
    TOKEN_STRING_BLOCK,
    TOKEN_NUMBER,
    TOKEN_CHAR,
    TOKEN_TRUE, TOKEN_FALSE,                 // bool literals

    // --- Quản lý và an toàn bộ nhớ ---
    TOKEN_OWN, TOKEN_REF, TOKEN_MANY, TOKEN_RAW,
    TOKEN_NULL,
    TOKEN_STACK, TOKEN_HEAP,
    TOKEN_UNSAFE,
    TOKEN_DESTROY,

    // --- Từ khóa: Khai báo & mô-đun ---
    TOKEN_IMPORT, TOKEN_EXPORT, TOKEN_INCLUDE,
    TOKEN_FOREIGN, TOKEN_LOCAL,
    TOKEN_NAMESPACE, TOKEN_ALIAS,
    TOKEN_RECORD, TOKEN_ENUM, TOKEN_VARIANT,
    TOKEN_FUNCTION,
    TOKEN_LET, TOKEN_FIXED, TOKEN_CONST,

    // --- Từ khóa: Điều khiển luồng (Control Flow) ---
    TOKEN_IF, TOKEN_ELSE,
    TOKEN_SWITCH, TOKEN_CASE,
    TOKEN_FOR, TOKEN_IN, TOKEN_WHILE,
    TOKEN_CONTINUE, TOKEN_BREAK,
    TOKEN_RETURN,
    TOKEN_AS,                               // Ép kiểu: x as T
    TOKEN_IS,                               // Kiểm tra kiểu: x is T

    // --- Kí hiệu đặc biệt để phân tích từ ngữ (Layout-based) ---
    TOKEN_NEWLINE,
    TOKEN_INDENT,
    TOKEN_DEDENT,

    // --- Trạng thái hệ thống ---
    TOKEN_UNKNOWN,
    TOKEN_EOF
} TokenType;
