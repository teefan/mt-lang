import std.base64 as base64
import std.bytes as bytes
import std.crypto as crypto
import std.http as http
import std.json as json
import std.str as text
import std.string as string
import std.url as url
import std.vec as vec

public struct Config:
    client_id: string.String
    client_secret: string.String
    authorize_url: string.String
    token_url: string.String
    redirect_uri: string.String
    scopes: vec.Vec[string.String]

public struct Tokens:
    access_token: string.String
    refresh_token: Option[string.String]
    token_type: string.String
    expires_in: Option[ptr_int]
    id_token: Option[string.String]

public struct Error:
    message: string.String


function oauth_error(message: str) -> Error:
    return Error(message = string.String.from_str(message))


public function create_config(
    client_id: str,
    client_secret: str,
    authorize_url: str,
    token_url: str,
    redirect_uri: str,
    scopes: span[str]
) -> Config:
    var scope_vec = vec.Vec[string.String].create()
    var index: ptr_uint = 0
    while index < scopes.len:
        scope_vec.push(string.String.from_str(unsafe: read(scopes.data + index)))
        index += 1

    return Config(
        client_id = string.String.from_str(client_id),
        client_secret = string.String.from_str(client_secret),
        authorize_url = string.String.from_str(authorize_url),
        token_url = string.String.from_str(token_url),
        redirect_uri = string.String.from_str(redirect_uri),
        scopes = scope_vec
    )


public function generate_state() -> Result[string.String, Error]:
    let random_result = crypto.random_bytes(32)
    match random_result:
        Result.failure:
            return Result[string.String, Error].failure(error = oauth_error("failed to generate state"))
        Result.success as ok_payload:
            var random_data = ok_payload.value
            let state = base64.encode_urlsafe(random_data.as_span())
            random_data.release()
            return Result[string.String, Error].success(value = state)


public function generate_pkce() -> Result[PkcePair, Error]:
    let random_result = crypto.random_bytes(32)
    match random_result:
        Result.failure:
            return Result[PkcePair, Error].failure(error = oauth_error("failed to generate PKCE verifier"))
        Result.success as ok_payload:
            var random_data = ok_payload.value
            let verifier = base64.encode_urlsafe(random_data.as_span())
            random_data.release()

            var challenge = crypto.sha256(text.as_byte_span(verifier.as_str()))
            defer challenge.release()

            let challenge_b64 = base64.encode_urlsafe(challenge.as_span())

            return Result[PkcePair, Error].success(
                value = PkcePair(
                    verifier = verifier,
                    challenge = challenge_b64
                )
            )

public struct PkcePair:
    verifier: string.String
    challenge: string.String


public function build_authorization_url(
    config: Config,
    state: str,
    pkce_challenge: Option[str]
) -> string.String:
    var result = string.String.from_str(config.authorize_url.as_str())

    result.push_byte(63)

    append_query_param(ref_of(result), "response_type", "code")
    append_query_param(ref_of(result), "client_id", config.client_id.as_str())
    append_query_param(ref_of(result), "redirect_uri", config.redirect_uri.as_str())
    append_query_param(ref_of(result), "state", state)

    if config.scopes.len() > 0:
        var scope_str = string.String.create()
        var index: ptr_uint = 0
        while index < config.scopes.len():
            if index > 0:
                scope_str.push_byte(32)

            let name_ptr = config.scopes.get(index) else:
                break

            scope_str.append(unsafe: read(name_ptr).as_str())
            index += 1

        append_query_param(ref_of(result), "scope", scope_str.as_str())
        scope_str.release()

    match pkce_challenge:
        Option.none:
            pass
        Option.some as payload:
            append_query_param(ref_of(result), "code_challenge", payload.value)
            append_query_param(ref_of(result), "code_challenge_method", "S256")

    return result


function append_query_param(target: ref[string.String], key: str, value: str) -> void:
    if target.len() > 0:
        let last_byte = target.as_str().byte_at(target.len() - 1)
        if last_byte != 63 and last_byte != 38:
            target.push_byte(38)

    var encoded_key = url.percent_encode(key)
    defer encoded_key.release()
    var encoded_value = url.percent_encode(value)
    defer encoded_value.release()

    target.append(encoded_key.as_str())
    target.push_byte(61)
    target.append(encoded_value.as_str())


public async function exchange_code(
    config: Config,
    code: str,
    pkce_verifier: Option[str]
) -> Result[Tokens, Error]:
    var body_params = vec.Vec[url.FormField].create()
    defer release_form_fields(ref_of(body_params))

    body_params.push(url.FormField(key = "grant_type", value = "authorization_code"))
    body_params.push(url.FormField(key = "code", value = code))
    body_params.push(url.FormField(key = "redirect_uri", value = config.redirect_uri.as_str()))
    body_params.push(url.FormField(key = "client_id", value = config.client_id.as_str()))

    match pkce_verifier:
        Option.none:
            pass
        Option.some as payload:
            body_params.push(url.FormField(key = "code_verifier", value = payload.value))

    var form_body = url.encode_form(body_params.as_span())
    defer form_body.release()

    var auth_header = build_basic_auth_header(config.client_id.as_str(), config.client_secret.as_str())
    defer auth_header.release()

    var headers = array[http.RequestHeader, 2](
        http.RequestHeader(name = "Content-Type", value = "application/x-www-form-urlencoded"),
        http.RequestHeader(name = "Authorization", value = auth_header.as_str())
    )

    let header_span = span[http.RequestHeader](data = ptr_of(headers[0]), len = 2)
    let body_span = text.as_byte_span(form_body.as_str())

    let request_result = await http.request(
        config.token_url.as_str(),
        "POST",
        header_span,
        Option[span[ubyte]].some(value = body_span)
    )
    match request_result:
        Result.failure as payload:
            return Result[Tokens, Error].failure(error = http_error_to_oauth(payload.error))
        Result.success as payload:
            var response = payload.value
            defer response.release()

            let body_str = response.body_as_str() else:
                return Result[Tokens, Error].failure(error = oauth_error("token response body is not valid UTF-8"))

            return parse_token_response(body_str, response.status_code)


function build_basic_auth_header(client_id: str, client_secret: str) -> string.String:
    var credentials = string.String.with_capacity(client_id.len + client_secret.len + 2)
    credentials.append(client_id)
    credentials.push_byte(58)
    credentials.append(client_secret)

    var encoded = base64.encode(text.as_byte_span(credentials.as_str()))
    credentials.release()

    var header = string.String.with_capacity(encoded.len() + 7)
    header.append("Basic ")
    header.append(encoded.as_str())

    encoded.release()
    return header


function parse_token_response(body_str: str, status_code: int) -> Result[Tokens, Error]:
    let parsed_json = json.parse(body_str)
    match parsed_json:
        Result.failure:
            return Result[Tokens, Error].failure(error = oauth_error("token response is not valid JSON"))
        Result.success as json_payload:
            let json_value = json_payload.value
            defer json.release_value(json_value)

            if status_code != 200:
                let object_ptr = json_value.as_object() else:
                    return Result[Tokens, Error].failure(error = oauth_error("token error response is not an object"))

                let error_desc = unsafe: read(object_ptr).get_string("error_description")
                match error_desc:
                    Option.some as payload:
                        let msg = string.String.from_str(payload.value)
                        return Result[Tokens, Error].failure(error = Error(message = msg))
                    Option.none:
                        return Result[
                            Tokens,
                            Error
                        ].failure(error = oauth_error("token endpoint returned error status"))

            let object_ptr = json_value.as_object() else:
                return Result[Tokens, Error].failure(error = oauth_error("token response is not an object"))

            unsafe:
                let access_token_opt = read(object_ptr).get_string("access_token")
                let access_token = access_token_opt else:
                    return Result[Tokens, Error].failure(error = oauth_error("token response missing access_token"))

                let token_type = read_json_string(read(object_ptr), "token_type")
                var token_type_str = string.String.from_str("Bearer")
                match token_type:
                    Option.some as payload:
                        let owned = string.String.from_str(payload.value)
                        token_type_str = owned
                    Option.none:
                        pass

                var refresh_token: Option[string.String] = Option[string.String].none
                let refresh_opt = read_json_string(read(object_ptr), "refresh_token")
                match refresh_opt:
                    Option.some as payload:
                        refresh_token = Option[string.String].some(value = string.String.from_str(payload.value))
                    Option.none:
                        pass

                var expires_in: Option[ptr_int] = Option[ptr_int].none
                let expires_opt = read_json_number(read(object_ptr), "expires_in")
                match expires_opt:
                    Option.some as payload:
                        expires_in = Option[ptr_int].some(value = ptr_int<-payload.value)
                    Option.none:
                        pass

                var id_token: Option[string.String] = Option[string.String].none
                let id_opt = read_json_string(read(object_ptr), "id_token")
                match id_opt:
                    Option.some as payload:
                        id_token = Option[string.String].some(value = string.String.from_str(payload.value))
                    Option.none:
                        pass

                return Result[Tokens, Error].success(value = Tokens(
                    access_token = string.String.from_str(access_token),
                    refresh_token = refresh_token,
                    token_type = token_type_str,
                    expires_in = expires_in,
                    id_token = id_token
                ))


function read_json_string(object_value: json.Object, key: str) -> Option[str]:
    return object_value.get_string(key)


function read_json_number(object_value: json.Object, key: str) -> Option[double]:
    return object_value.get_number(key)


public async function refresh_access_token(
    config: Config,
    refresh_token: str
) -> Result[Tokens, Error]:
    var body_params = vec.Vec[url.FormField].create()
    defer release_form_fields(ref_of(body_params))

    body_params.push(url.FormField(key = "grant_type", value = "refresh_token"))
    body_params.push(url.FormField(key = "refresh_token", value = refresh_token))
    body_params.push(url.FormField(key = "client_id", value = config.client_id.as_str()))

    var form_body = url.encode_form(body_params.as_span())
    defer form_body.release()

    var auth_header = build_basic_auth_header(config.client_id.as_str(), config.client_secret.as_str())
    defer auth_header.release()

    var headers = array[http.RequestHeader, 2](
        http.RequestHeader(name = "Content-Type", value = "application/x-www-form-urlencoded"),
        http.RequestHeader(name = "Authorization", value = auth_header.as_str())
    )

    let header_span = span[http.RequestHeader](data = ptr_of(headers[0]), len = 2)
    let body_span = text.as_byte_span(form_body.as_str())

    let request_result = await http.request(
        config.token_url.as_str(),
        "POST",
        header_span,
        Option[span[ubyte]].some(value = body_span)
    )
    match request_result:
        Result.failure as payload:
            return Result[Tokens, Error].failure(error = http_error_to_oauth(payload.error))
        Result.success as payload:
            var response = payload.value
            defer response.release()

            let body_str = response.body_as_str() else:
                return Result[Tokens, Error].failure(error = oauth_error("token response body is not valid UTF-8"))

            return parse_token_response(body_str, response.status_code)


function http_error_to_oauth(http_error: http.Error) -> Error:
    var owned_error = http_error
    let message = string.String.from_str(owned_error.message.as_str())
    owned_error.release()
    return Error(message = message)


function release_form_fields(fields: ref[vec.Vec[url.FormField]]) -> void:
    fields.release()


extending Config:
    public editable function release() -> void:
        this.client_id.release()
        this.client_secret.release()
        this.authorize_url.release()
        this.token_url.release()
        this.redirect_uri.release()

        var index: ptr_uint = 0
        while index < this.scopes.len():
            let scope_ptr = this.scopes.get(index) else:
                break

            unsafe:
                var scope = read(scope_ptr)
                scope.release()

            index += 1

        this.scopes.release()


extending Tokens:
    public editable function release() -> void:
        this.access_token.release()

        match this.refresh_token:
            Option.some as payload:
                payload.value.release()
            Option.none:
                pass

        this.token_type.release()

        match this.id_token:
            Option.some as payload:
                payload.value.release()
            Option.none:
                pass


extending PkcePair:
    public editable function release() -> void:
        this.verifier.release()
        this.challenge.release()


extending Error:
    public editable function release() -> void:
        this.message.release()
