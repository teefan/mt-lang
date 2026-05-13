# frozen_string_literal: true

require "fileutils"
require "tempfile"

module MilkTea
  class AssetPackError < StandardError; end

  class AssetPack
    MAGIC = "MTAP".b.freeze
    VERSION = 1
    HEADER_FLAGS = 0
    ENTRY_FLAGS_RAW = 0
    HEADER_FORMAT = "a4vvVQ<Q<".freeze
    ENTRY_PREFIX_FORMAT = "VVQ<Q<Q<".freeze
    HEADER_SIZE = [MAGIC, VERSION, HEADER_FLAGS, 0, 0, 0].pack(HEADER_FORMAT).bytesize
    ENTRY_PREFIX_SIZE = [0, ENTRY_FLAGS_RAW, 0, 0, 0].pack(ENTRY_PREFIX_FORMAT).bytesize

    SourceEntry = Data.define(:source_path, :logical_path, :stored_size, :unpacked_size, :flags)
    Entry = Data.define(:source_path, :logical_path, :data_offset, :stored_size, :unpacked_size, :flags)

    def self.write(output_path, source_paths)
      new(output_path, source_paths).write
    end

    def initialize(output_path, source_paths)
      @output_path = File.expand_path(output_path)
      @source_paths = source_paths.map { |source_path| File.expand_path(source_path) }
    end

    def write
      ensure_output_does_not_overlap_sources!

      source_entries = collect_source_entries
      index_size = source_entries.sum { |entry| ENTRY_PREFIX_SIZE + entry.logical_path.bytesize }
      data_offset = HEADER_SIZE + index_size
      entries = assign_offsets(source_entries, data_offset)

      FileUtils.mkdir_p(File.dirname(@output_path))
      Tempfile.create(["milk-tea-asset-pack", ".bin"], File.dirname(@output_path)) do |file|
        file.binmode
        write_header(file, entries.length, index_size, data_offset)
        write_index(file, entries)
        write_data(file, entries)
        file.flush
        file.close

        FileUtils.rm_f(@output_path)
        FileUtils.mv(file.path, @output_path)
      end

      @output_path
    end

    private

    def ensure_output_does_not_overlap_sources!
      @source_paths.each do |source_path|
        if File.directory?(source_path)
          next unless path_within?(@output_path, source_path)

          raise AssetPackError, "asset pack output would be written inside source tree: #{@output_path}"
        end

        next unless @output_path == source_path

        raise AssetPackError, "asset pack output would overwrite source file: #{@output_path}"
      end
    end

    def collect_source_entries
      @source_paths.flat_map do |source_path|
        collect_source_path(source_path, File.basename(source_path))
      end.sort_by(&:logical_path)
    end

    def collect_source_path(source_path, logical_path)
      stat = File.lstat(source_path)

      if stat.directory?
        Dir.children(source_path).sort.flat_map do |child|
          collect_source_path(File.join(source_path, child), join_logical_path(logical_path, child))
        end
      elsif stat.file?
        file_size = File.size(source_path)
        [SourceEntry.new(source_path:, logical_path:, stored_size: file_size, unpacked_size: file_size, flags: ENTRY_FLAGS_RAW)]
      else
        raise AssetPackError, "asset pack supports only regular files and directories: #{source_path}"
      end
    rescue Errno::ENOENT
      raise AssetPackError, "asset pack source not found: #{source_path}"
    end

    def assign_offsets(source_entries, first_data_offset)
      next_offset = first_data_offset

      source_entries.map do |entry|
        packed_entry = Entry.new(
          source_path: entry.source_path,
          logical_path: entry.logical_path,
          data_offset: next_offset,
          stored_size: entry.stored_size,
          unpacked_size: entry.unpacked_size,
          flags: entry.flags,
        )
        next_offset += entry.stored_size
        packed_entry
      end
    end

    def write_header(io, entry_count, index_size, data_offset)
      io.write([MAGIC, VERSION, HEADER_FLAGS, entry_count, index_size, data_offset].pack(HEADER_FORMAT))
    end

    def write_index(io, entries)
      entries.each do |entry|
        path_bytes = entry.logical_path.b
        io.write([path_bytes.bytesize, entry.flags, entry.data_offset, entry.stored_size, entry.unpacked_size].pack(ENTRY_PREFIX_FORMAT))
        io.write(path_bytes)
      end
    end

    def write_data(io, entries)
      entries.each do |entry|
        File.open(entry.source_path, "rb") do |source_file|
          IO.copy_stream(source_file, io)
        end
      end
    end

    def join_logical_path(left, right)
      "#{left}/#{right}"
    end

    def path_within?(path, root)
      normalized_path = File.expand_path(path)
      normalized_root = File.expand_path(root)
      normalized_path == normalized_root || normalized_path.start_with?(normalized_root + File::SEPARATOR)
    end
  end
end
