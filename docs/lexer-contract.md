# Hợp đồng Bộ phân tích từ ngữ (Lexer Contract)

Tài liệu này chốt giao kèo đầu ra của Bộ phân tích từ ngữ (Lexer) trong trạng thái hiện tại, để các tầng sau (Bộ phân tích ngữ pháp (Parser), báo lỗi, kiểm tra) dựa vào một chuẩn duy nhất.

## 1) Phạm vi và trách nhiệm

- Bộ phân tích từ ngữ nhận vào `source + source_length`, trả ra dãy `Ký hiệu` (`Token`).
- Mỗi `Ký hiệu` có:
  - `type`
  - `start_offset`
  - `length`
  - `leading_trivia_length`
  - `trailing_trivia_length`
- Bộ phân tích từ ngữ **không** làm phân tích cú pháp ngữ nghĩa (không kiểm tra kiểu, không kiểm tra tính đúng sai biểu thức).

## 2) Vặt vãnh (Trivia) và canh lề (Indentation)

- Vặt vãnh được ăn bởi bộ phân tích từ ngữ:
  - khoảng trắng: ` `, `\t`, `\r`
  - ghi chú một dòng: `-- ...`
  - ghi chú nhiều dòng: `++ ... ++`
- Ký tự Xuống hàng `\n` được ăn trong quá trình quét vặt vãnh, đồng thời cập nhật cờ `is_at_line_start`.
- Canh lề dùng cơ chế stack:
  - tăng canh lề -> phát `TOKEN_INDENT`
  - giảm canh lề -> phát một hay nhiều `TOKEN_DEDENT`
  - cuối tệp nếu còn mức canh lề mở -> phát dần `TOKEN_DEDENT` trước `TOKEN_EOF`

## 3) Ký hiệu được phát ra

### 3.1. Ký hiệu đơn và toán tử (Single char/Operator)

- Dấu đơn: `(` `)` `[` `]` `{` `}` `:` `;` `,` `.`
- Toán tử/kết hợp: `=` `==` `!` `!=` `<` `<=` `>` `>=`
- Số học: `+` `-` `*` `/` `%`
- Gán kết hợp: `+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=` `<<=` `>>=`
- Bitwise/logic ký hiệu: `&` `|` `^` `&&` `||` `<<` `>>`
- Đặc trưng: `..` `->` `=>` `//`

### 3.2. Văn bản (Literal)

- `TOKEN_NUMBER`:
  - decimal (`123`)
  - float đơn giản (`3.14`)
  - hex (`0x1F`)
  - binary (`0b101`)
- `TOKEN_STRING`: chuỗi thường `"..."`
- `TOKEN_STRING_BLOCK`: chuỗi khối `"""..."""`
- `TOKEN_CHAR`: ký tự `'...'`
- `TOKEN_TRUE`, `TOKEN_FALSE`

### 3.3. Từ khóa (Keyword)

- Quản lý bộ nhớ/an toàn: `own ref many raw null stack heap unsafe destroy`
- Khai báo/mô-đun: `import export include foreign local namespace opaque from alias record enum variant function fn let fixed const`
- Điều khiển luồng: `if else do switch case default for in while pass continue break return out and or not as is`

### 3.4. Ký hiệu điều khiển hệ thống

- `TOKEN_INDENT`, `TOKEN_DEDENT`, `TOKEN_EOF`
- `TOKEN_UNKNOWN`: ký tự không nhận diện được
- `TOKEN_ERROR`: hằng văn bản bị lỗi (ví dụ chưa đóng)

## 4) Quy tắc lỗi từ ngữ

Trong trạng thái hiện tại, bộ phân tích từ ngữ phát `TOKEN_ERROR` cho các trường hợp:

- chuỗi thường chưa đóng: `"abc`
- chuỗi khối chưa đóng: `"""abc`
- hằng ký tự chưa đóng: `'A`
- "thoát" (escape) dang dở trong hằng ký tự: `'\\` (hết tệp ngay sau `\\`)

## 5) Vì sao `TOKEN_NEWLINE` chưa phát

`TOKEN_NEWLINE` đang tồn tại trong enum nhưng hiện chưa được bộ phân tích từ ngữ phát ra vì thiết kế hiện tại chọn mô hình **canh lề kiểu Python**:

- Xuống hàng được xem là vặt vãnh để phục vụ tính canh lề.
- Cấu trúc khối được truyền cho Bộ phân tích ngữ pháp qua `TOKEN_INDENT/TOKEN_DEDENT`, không qua `TOKEN_NEWLINE`.

Nói thẳng: `TOKEN_NEWLINE` hiện là Ký hiệu dự phòng/chưa dùng.

## 6) Giao kèo cho Bộ phân tích ngữ pháp

- Bộ phân tích ngữ pháp phải dựa vào `INDENT/DEDENT` để dựng khối.
- Bộ phân tích ngữ pháp không được trông đợi `TOKEN_NEWLINE` từ Bộ phân tích từ ngữ ở trạng thái hiện tại.
- Bộ phân tích ngữ pháp phải xử lý `TOKEN_ERROR` như lỗi từ ngữ cấp 1, có thể dừng sớm hoặc gom lỗi tùy chiến lược.

## 7) Điều cần chốt ở bước sau

- Quyết định giữ hay bỏ `TOKEN_NEWLINE` khỏi enum.
- Nếu giữ, xác định rõ khi nào Bộ phân tích từ ngữ phát `TOKEN_NEWLINE` (trước hay sau vặt vãnh/canh lề).
- Chuẩn hóa quy tắc escape hợp lệ cho `STRING`/`CHAR`.
