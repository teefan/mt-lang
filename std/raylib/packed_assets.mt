module std.raylib.packed_assets

import std.asset_pack as pack
import std.bytes as bytes
import std.maybe as maybe
import std.raylib as rl
import std.string as string
import std.status as status
import std.str as text


public enum Error: int
    open_failed = 1
    closed = 2
    invalid_magic = 3
    unsupported_version = 4
    unsupported_flags = 5
    range = 6
    malformed_header = 7
    malformed_index = 8
    entry_not_found = 9
    io = 10
    missing_file_type = 101
    invalid_image = 102
    invalid_texture = 103
    invalid_wave = 104
    invalid_sound = 105
    invalid_music = 106


public type Reader = pack.Reader


public struct PackedMusic:
    music: rl.Music
    backing_data: bytes.Bytes


methods PackedMusic:
    public function is_valid() -> bool:
        return rl.is_music_valid(this.music)


    public function play() -> void:
        rl.play_music_stream(this.music)
        return


    public function is_playing() -> bool:
        return rl.is_music_stream_playing(this.music)


    public function update() -> void:
        rl.update_music_stream(this.music)
        return


    public function stop() -> void:
        rl.stop_music_stream(this.music)
        return


    public function pause() -> void:
        rl.pause_music_stream(this.music)
        return


    public function resume() -> void:
        rl.resume_music_stream(this.music)
        return


    public function seek(position: float) -> void:
        rl.seek_music_stream(this.music, position)
        return


    public function set_volume(volume: float) -> void:
        rl.set_music_volume(this.music, volume)
        return


    public function set_pitch(pitch: float) -> void:
        rl.set_music_pitch(this.music, pitch)
        return


    public function set_pan(pan: float) -> void:
        rl.set_music_pan(this.music, pan)
        return


    public function time_length() -> float:
        return rl.get_music_time_length(this.music)


    public function time_played() -> float:
        return rl.get_music_time_played(this.music)


    public editable function release() -> void:
        if rl.is_music_valid(this.music):
            rl.unload_music_stream(this.music)

        this.music = zero[rl.Music]
        this.backing_data.release()
        return


public function open_assets_pack_if_present() -> status.Status[maybe.Maybe[Reader], Error]:
    let open_result = open_pack_relative_to_application("assets.mtpack")
    match open_result:
        status.Status.err as payload:
            if payload.error == Error.open_failed:
                return status.Status[maybe.Maybe[Reader], Error].ok(value= maybe.Maybe[Reader].none)

            return status.Status[maybe.Maybe[Reader], Error].err(error= payload.error)
        status.Status.ok as payload:
            return status.Status[maybe.Maybe[Reader], Error].ok(value= maybe.Maybe[Reader].some(value= payload.value))


public function open_assets_pack() -> status.Status[Reader, Error]:
    return open_pack_relative_to_application("assets.mtpack")


public function close_reader(reader: ref[Reader]) -> void:
    reader.close()


public function load_image(reader: pack.Reader, logical_path: str) -> status.Status[rl.Image, Error]:
    let file_type_result = detect_file_type(logical_path)
    match file_type_result:
        status.Status.err as payload:
            return status.Status[rl.Image, Error].err(error= payload.error)
        status.Status.ok as file_type_payload:
            let data_result = map_pack_result(reader.read_bytes(logical_path))
            match data_result:
                status.Status.err as payload:
                    return status.Status[rl.Image, Error].err(error= payload.error)
                status.Status.ok as data_payload:
                    var data = data_payload.value
                    defer data.release()

                    let image = rl.load_image_from_memory(file_type_payload.value, data.as_span())
                    if not rl.is_image_valid(image):
                        return status.Status[rl.Image, Error].err(error= Error.invalid_image)

                    return status.Status[rl.Image, Error].ok(value= image)


public function load_texture(reader: pack.Reader, logical_path: str) -> status.Status[rl.Texture2D, Error]:
    let image_result = load_image(reader, logical_path)
    match image_result:
        status.Status.err as payload:
            return status.Status[rl.Texture2D, Error].err(error= payload.error)
        status.Status.ok as image_payload:
            let image = image_payload.value
            defer rl.unload_image(image)

            let texture = rl.load_texture_from_image(image)
            if not rl.is_texture_valid(texture):
                return status.Status[rl.Texture2D, Error].err(error= Error.invalid_texture)

            return status.Status[rl.Texture2D, Error].ok(value= texture)


public function load_wave(reader: pack.Reader, logical_path: str) -> status.Status[rl.Wave, Error]:
    let file_type_result = detect_file_type(logical_path)
    match file_type_result:
        status.Status.err as payload:
            return status.Status[rl.Wave, Error].err(error= payload.error)
        status.Status.ok as file_type_payload:
            let data_result = map_pack_result(reader.read_bytes(logical_path))
            match data_result:
                status.Status.err as payload:
                    return status.Status[rl.Wave, Error].err(error= payload.error)
                status.Status.ok as data_payload:
                    var data = data_payload.value
                    defer data.release()

                    let wave = rl.load_wave_from_memory(file_type_payload.value, data.as_span())
                    if not rl.is_wave_valid(wave):
                        return status.Status[rl.Wave, Error].err(error= Error.invalid_wave)

                    return status.Status[rl.Wave, Error].ok(value= wave)


public function load_sound(reader: pack.Reader, logical_path: str) -> status.Status[rl.Sound, Error]:
    let wave_result = load_wave(reader, logical_path)
    match wave_result:
        status.Status.err as payload:
            return status.Status[rl.Sound, Error].err(error= payload.error)
        status.Status.ok as wave_payload:
            let wave = wave_payload.value
            defer rl.unload_wave(wave)

            let sound = rl.load_sound_from_wave(wave)
            if not rl.is_sound_valid(sound):
                return status.Status[rl.Sound, Error].err(error= Error.invalid_sound)

            return status.Status[rl.Sound, Error].ok(value= sound)


public function load_music(reader: pack.Reader, logical_path: str) -> status.Status[PackedMusic, Error]:
    let file_type_result = detect_file_type(logical_path)
    match file_type_result:
        status.Status.err as payload:
            return status.Status[PackedMusic, Error].err(error= payload.error)
        status.Status.ok as file_type_payload:
            let data_result = map_pack_result(reader.read_bytes(logical_path))
            match data_result:
                status.Status.err as payload:
                    return status.Status[PackedMusic, Error].err(error= payload.error)
                status.Status.ok as data_payload:
                    var data = data_payload.value
                    let span = data.as_span()
                    let music = rl.load_music_stream_from_memory(file_type_payload.value, span.data, int<-span.len)
                    if rl.is_music_valid(music):
                        return status.Status[PackedMusic, Error].ok(value= PackedMusic(music = music, backing_data = data))

                    data.release()
                    return status.Status[PackedMusic, Error].err(error= Error.invalid_music)


function open_pack_relative_to_application(pack_name: str) -> status.Status[pack.Reader, Error]:
    var application_path = application_relative_path(pack_name)
    defer application_path.release()

    let application_result = pack.open(application_path.as_str())
    match application_result:
        status.Status.ok as payload:
            return status.Status[pack.Reader, Error].ok(value= payload.value)
        status.Status.err as payload:
            if payload.error != pack.Error.open_failed:
                return status.Status[pack.Reader, Error].err(error= from_pack_error(payload.error))

            return map_pack_result(pack.open(pack_name))


function application_relative_path(relative_path: str) -> string.String:
    let application_dir = text.cstr_as_str(rl.get_application_directory())
    var result = string.String.from_str(application_dir)

    if application_dir.len > 0:
        let last = application_dir.byte_at(application_dir.len - 1)
        if last != ubyte<-47 and last != ubyte<-92:
            result.append("/")

    result.append(relative_path)
    return result


function detect_file_type(logical_path: str) -> status.Status[str, Error]:
    match file_type(logical_path):
        maybe.Maybe.some as payload:
            return status.Status[str, Error].ok(value= payload.value)
        maybe.Maybe.none:
            return status.Status[str, Error].err(error= Error.missing_file_type)


function from_pack_error(error: pack.Error) -> Error:
    match error:
        pack.Error.open_failed:
            return Error.open_failed
        pack.Error.closed:
            return Error.closed
        pack.Error.invalid_magic:
            return Error.invalid_magic
        pack.Error.unsupported_version:
            return Error.unsupported_version
        pack.Error.unsupported_flags:
            return Error.unsupported_flags
        pack.Error.range:
            return Error.range
        pack.Error.malformed_header:
            return Error.malformed_header
        pack.Error.malformed_index:
            return Error.malformed_index
        pack.Error.entry_not_found:
            return Error.entry_not_found
        pack.Error.io:
            return Error.io


function map_pack_result[T](result: status.Status[T, pack.Error]) -> status.Status[T, Error]:
    match result:
        status.Status.err as payload:
            return status.Status[T, Error].err(error= from_pack_error(payload.error))
        status.Status.ok as payload:
            return status.Status[T, Error].ok(value= payload.value)


function file_type(logical_path: str) -> maybe.Maybe[str]:
    var index = logical_path.len
    while index > 0:
        index -= 1

        let byte = logical_path.byte_at(index)
        if byte == ubyte<-47:
            return maybe.Maybe[str].none

        if byte == ubyte<-46:
            if index + 1 == logical_path.len:
                return maybe.Maybe[str].none

            return maybe.Maybe[str].some(value= logical_path.slice(index, logical_path.len - index))

    return maybe.Maybe[str].none
