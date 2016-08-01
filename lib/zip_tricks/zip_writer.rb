# A low-level ZIP file data writer. You can use it to write out various headers and central directory elements
# separately. The class handles the actual encoding of the data according to the ZIP format APPNOTE document.
class ZipTricks::ZipWriter
  FOUR_BYTE_MAX_UINT = 0xFFFFFFFF
  TWO_BYTE_MAX_UINT = 0xFFFF
  ZIP_TRICKS_COMMENT = 'Written using ZipTricks %s' % ZipTricks::VERSION
  VERSION_MADE_BY                        = 52
  VERSION_NEEDED_TO_EXTRACT              = 20
  VERSION_NEEDED_TO_EXTRACT_ZIP64        = 45
  DEFAULT_EXTERNAL_ATTRS = begin
    # These need to be set so that the unarchived files do not become executable on UNIX, for
    # security purposes. Strictly speaking we would want to make this user-customizable,
    # but for now just putting in sane defaults will do. For example, Trac with zipinfo does this:
    # zipinfo.external_attr = 0644 << 16L # permissions -r-wr--r--.
    # We snatch the incantations from Rubyzip for this.
    unix_perms = 0644
    file_type_file = 010
    external_attrs = (file_type_file << 12 | (unix_perms & 07777)) << 16
  end
  MADE_BY_SIGNATURE = begin
    # A combination of the VERSION_MADE_BY low byte and the OS type high byte
    os_type = 3 # UNIX
    [VERSION_MADE_BY, os_type].pack('CC')
  end

  C_V = 'V'.freeze
  C_v = 'v'.freeze
  C_Qe = 'Q<'.freeze

  # Writes the local file header, that precedes the actual file _data_. 
  # 
  # @param io[#<<] the buffer to write the local file header to
  # @param filename[String]  the name of the file in the archive
  # @param compressed_size[Fixnum]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Fixnum]  The size of the file once extracted
  # @param crc32[Fixnum] The CRC32 checksum of the file
  # @param mtime[Time]  the modification time to be recorded in the ZIP
  # @param gp_flags[Fixnum] bit-packed general purpose flags
  # @param storage_mode[Fixnum] 8 for deflated, 0 for stored...
  # @return [void]
  def write_local_file_header(io:, filename:, compressed_size:, uncompressed_size:, crc32:, gp_flags:, mtime:, storage_mode:)
    requires_zip64 = (compressed_size > FOUR_BYTE_MAX_UINT || uncompressed_size > FOUR_BYTE_MAX_UINT)

    io << [0x04034b50].pack(C_V)                        # local file header signature     4 bytes  (0x04034b50)
    if requires_zip64                                   # version needed to extract       2 bytes
      io << [VERSION_NEEDED_TO_EXTRACT_ZIP64].pack(C_v)
    else
      io << [VERSION_NEEDED_TO_EXTRACT].pack(C_v)
    end

    io << [gp_flags].pack(C_v)                          # general purpose bit flag        2 bytes
    io << [storage_mode].pack(C_v)                      # compression method              2 bytes
    io << [to_binary_dos_time(mtime)].pack(C_v)         # last mod file time              2 bytes
    io << [to_binary_dos_date(mtime)].pack(C_v)         # last mod file date              2 bytes
    io << [crc32].pack(C_V)                             # crc-32                          4 bytes

    if requires_zip64
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)              # compressed size              4 bytes
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)              # uncompressed size            4 bytes
    else
      io << [compressed_size].pack(C_V)                 # compressed size              4 bytes
      io << [uncompressed_size].pack(C_V)               # uncompressed size            4 bytes
    end

    # Filename should not be longer than 0xFFFF otherwise this wont fit here
    io << [filename.bytesize].pack(C_v)                 # file name length             2 bytes

    extra_size = 0
    if requires_zip64
      extra_size += bytesize_of {|buf| write_zip_64_extra_for_local_file_header(io: buf, compressed_size: 0, uncompressed_size: 0) }
    end
    io << [extra_size].pack(C_v)                      # extra field length              2 bytes

    io << filename                                    # file name (variable size)

    # Interesting tidbit:
    # https://social.technet.microsoft.com/Forums/windows/en-US/6a60399f-2879-4859-b7ab-6ddd08a70948
    # TL;DR of it is: Windows 7 Explorer _will_ open Zip64 entries. However, it desires to have the
    # Zip64 extra field as _the first_ extra field. If we decide to add the Info-ZIP UTF-8 field...
    if requires_zip64
      write_zip_64_extra_for_local_file_header(io: io, compressed_size: compressed_size, uncompressed_size: uncompressed_size)
    end
  end

  # Writes the file header for the central directory, for a particular file in the archive. When writing out this data,
  # ensure that the CRC32 and both sizes (compressed/uncompressed) are correct for the entry in question.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param filename[String]  the name of the file in the archive
  # @param compressed_size[Fixnum]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Fixnum]  The size of the file once extracted
  # @param crc32[Fixnum] The CRC32 checksum of the file
  # @param mtime[Time]  the modification time to be recorded in the ZIP
  # @param external_attrs[Fixnum] bit-packed external attributes (defaults to UNIX file with 0644 permissions set)
  # @param gp_flags[Fixnum] bit-packed general purpose flags
  # @return [void]
  def write_central_directory_file_header(io:, local_file_header_location:, gp_flags:, storage_mode:, compressed_size:, uncompressed_size:, mtime:, crc32:, 
    filename:, external_attrs: DEFAULT_EXTERNAL_ATTRS)
    # At this point if the header begins somewhere beyound 0xFFFFFFFF we _have_ to record the offset
    # of the local file header as a zip64 extra field, so we give up, give in, you loose, love will always win...
    add_zip64 = (local_file_header_location > FOUR_BYTE_MAX_UINT) ||
        (compressed_size > FOUR_BYTE_MAX_UINT) || (uncompressed_size > FOUR_BYTE_MAX_UINT)

    io << [0x02014b50].pack(C_V)                        # central file header signature   4 bytes  (0x02014b50)
    io << MADE_BY_SIGNATURE                             # version made by                 2 bytes
    if add_zip64
      io << [VERSION_NEEDED_TO_EXTRACT_ZIP64].pack(C_v) # version needed to extract       2 bytes
    else
      io << [VERSION_NEEDED_TO_EXTRACT].pack(C_v)       # version needed to extract       2 bytes
    end

    io << [gp_flags].pack(C_v)                          # general purpose bit flag        2 bytes
    io << [storage_mode].pack(C_v)                      # compression method              2 bytes
    io << [to_binary_dos_time(mtime)].pack(C_v)         # last mod file time              2 bytes
    io << [to_binary_dos_date(mtime)].pack(C_v)         # last mod file date              2 bytes
    io << [crc32].pack(C_V)                             # crc-32                          4 bytes

    if add_zip64
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)              # compressed size              4 bytes
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)              # uncompressed size            4 bytes
    else
      io << [compressed_size].pack(C_V)                 # compressed size              4 bytes
      io << [uncompressed_size].pack(C_V)               # uncompressed size            4 bytes
    end

    # Filename should not be longer than 0xFFFF otherwise this wont fit here
    io << [filename.bytesize].pack(C_v)                 # file name length                2 bytes

    extra_size = 0
    if add_zip64
      extra_size += bytesize_of {|buf|
        # Supply zeroes for most values as we obnly care about the size of the data written
        write_zip_64_extra_for_central_directory_file_header(io: buf, compressed_size: 0, uncompressed_size: 0, local_file_header_location: 0)
      }
    end
    io << [extra_size].pack(C_v)                        # extra field length              2 bytes

    io << [0].pack(C_v)                                 # file comment length             2 bytes

    # For The Unarchiver < 3.11.1 this field has to be set to the overflow value if zip64 is used
    # because otherwise it does not properly advance the pointer when reading the Zip64 extra field
    # https://bitbucket.org/WAHa_06x36/theunarchiver/pull-requests/2/bug-fix-for-zip64-extra-field-parser/diff
    if add_zip64                                        # disk number start               2 bytes
      io << [TWO_BYTE_MAX_UINT].pack(C_v)
    else
      io << [0].pack(C_v)
    end
    io << [0].pack(C_v)                                # internal file attributes        2 bytes
    io << [DEFAULT_EXTERNAL_ATTRS].pack(C_V)           # external file attributes        4 bytes

    if add_zip64                                       # relative offset of local header 4 bytes
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)
    else
      io << [local_file_header_location].pack(C_V)
    end
    io << filename                                     # file name (variable size)

    if add_zip64                                       # extra field (variable size)
      write_zip_64_extra_for_central_directory_file_header(io: io, local_file_header_location: local_file_header_location,
        compressed_size: compressed_size, uncompressed_size: uncompressed_size)
    end
    #(empty)                                           # file comment (variable size)
  end

  # Writes the data descriptor following the file data for a file whose local file header
  # was written with general-purpose flag bit 3 set. If the one of the sizes exceeds the Zip64 threshold,
  # the data descriptor will have the sizes written out as 8-byte values instead of 4-byte values.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param crc32[Fixnum]    The CRC32 checksum of the file
  # @param compressed_size[Fixnum]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Fixnum]  The size of the file once extracted
  # @return [void]
  def write_data_descriptor(io:, compressed_size:, uncompressed_size:, crc32:)
    io << [0x08074b50].pack(C_V)  # Although not originally assigned a signature, the value
                                  # 0x08074b50 has commonly been adopted as a signature value
                                  # for the data descriptor record.
    io << [crc32].pack(C_V)                             # crc-32                          4 bytes


    # If one of the sizes is above 0xFFFFFFF use ZIP64 lengths (8 bytes) instead. A good unarchiver
    # will decide to unpack it as such if it finds the Zip64 extra for the file in the central directory.
    # So also use the opportune moment to switch the entry to Zip64 if needed
    requires_zip64 = (compressed_size > FOUR_BYTE_MAX_UINT || uncompressed_size > FOUR_BYTE_MAX_UINT)
    pack_spec = requires_zip64 ? C_Qe : C_V

    io << [compressed_size].pack(pack_spec)       # compressed size                 4 bytes, or 8 bytes for ZIP64
    io << [uncompressed_size].pack(pack_spec)     # uncompressed size               4 bytes, or 8 bytes for ZIP64
  end

  # Writes the "end of central directory record" (including the Zip6 salient bits if necessary)
  #
  # @param io[#<<] the buffer to write the central directory to.
  # @param start_of_central_directory_location[Fixnum] byte offset of the start of central directory form the beginning of ZIP file
  # @param central_directory_size[Fixnum] the size of the central directory (only file headers) in bytes
  # @param num_files_in_archive[Fixnum] How many files the archive contains
  # @return [void]
  def write_end_of_central_directory(io:, start_of_central_directory_location:, central_directory_size:, num_files_in_archive:)
    zip64_eocdr_offset = start_of_central_directory_location + central_directory_size
    
    zip64_required = central_directory_size > FOUR_BYTE_MAX_UINT ||
      start_of_central_directory_location > FOUR_BYTE_MAX_UINT ||
      zip64_eocdr_offset > FOUR_BYTE_MAX_UINT ||
      num_files_in_archive > TWO_BYTE_MAX_UINT

    # Then, if zip64 is used
    if zip64_required
      # [zip64 end of central directory record]
                                                             # zip64 end of central dir
      io << [0x06064b50].pack(C_V)                           # signature                       4 bytes  (0x06064b50)
      io << [44].pack(C_Qe)                                  # size of zip64 end of central
                                                             # directory record                8 bytes
                                                             # (this is ex. the 12 bytes of the signature and the size value itself).
                                                             # Without the extensible data sector (which we are not using)
                                                             # it is always 44 bytes.
      io << MADE_BY_SIGNATURE                                # version made by                 2 bytes
      io << [VERSION_NEEDED_TO_EXTRACT_ZIP64].pack(C_v)      # version needed to extract       2 bytes
      io << [0].pack(C_V)                                    # number of this disk             4 bytes
      io << [0].pack(C_V)                                    # number of the disk with the
                                                             # start of the central directory  4 bytes
      io << [num_files_in_archive].pack(C_Qe)                # total number of entries in the
                                                             # central directory on this disk  8 bytes
      io << [num_files_in_archive].pack(C_Qe)                # total number of entries in the
                                                             # central directory               8 bytes
      io << [central_directory_size].pack(C_Qe)              # size of the central directory   8 bytes
                                                             # offset of start of central
                                                             # directory with respect to
      io << [start_of_central_directory_location].pack(C_Qe) # the starting disk number        8 bytes
                                                             # zip64 extensible data sector    (variable size), blank for us

      # [zip64 end of central directory locator]
      io << [0x07064b50].pack(C_V)                           # zip64 end of central dir locator
                                                             # signature                       4 bytes  (0x07064b50)
      io << [0].pack(C_V)                                    # number of the disk with the
                                                             # start of the zip64 end of
                                                             # central directory               4 bytes
      io << [zip64_eocdr_offset].pack(C_Qe)                  # relative offset of the zip64
                                                             # end of central directory record 8 bytes
                                                             # (note: "relative" is actually "from the start of the file")
      io << [1].pack(C_V)                                    # total number of disks           4 bytes
    end

    # Then the end of central directory record:
    io << [0x06054b50].pack(C_V)                            # end of central dir signature     4 bytes  (0x06054b50)
    io << [0].pack(C_v)                                     # number of this disk              2 bytes
    io << [0].pack(C_v)                                     # number of the disk with the
                                                            # start of the central directory 2 bytes

    if zip64_required # the number of entries will be read from the zip64 part of the central directory
      io << [TWO_BYTE_MAX_UINT].pack(C_v)                   # total number of entries in the
                                                            # central directory on this disk   2 bytes
      io << [TWO_BYTE_MAX_UINT].pack(C_v)                   # total number of entries in
                                                            # the central directory            2 bytes
    else
      io << [num_files_in_archive].pack(C_v)                # total number of entries in the
                                                            # central directory on this disk   2 bytes
      io << [num_files_in_archive].pack(C_v)                # total number of entries in
                                                            # the central directory            2 bytes
    end

    if zip64_required
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)                  # size of the central directory    4 bytes
      io << [FOUR_BYTE_MAX_UINT].pack(C_V)                  # offset of start of central
                                                            # directory with respect to
                                                            # the starting disk number        4 bytes
    else
      io << [central_directory_size].pack(C_V)              # size of the central directory    4 bytes
      io << [start_of_central_directory_location].pack(C_V) # offset of start of central
                                                            # directory with respect to
                                                            # the starting disk number        4 bytes
    end
    io << [ZIP_TRICKS_COMMENT.bytesize].pack(C_v)           # .ZIP file comment length        2 bytes
    io << ZIP_TRICKS_COMMENT                                # .ZIP file comment       (variable size)
  end

  private_constant :FOUR_BYTE_MAX_UINT, :TWO_BYTE_MAX_UINT,
    :VERSION_MADE_BY, :VERSION_NEEDED_TO_EXTRACT, :VERSION_NEEDED_TO_EXTRACT_ZIP64,
    :DEFAULT_EXTERNAL_ATTRS, :MADE_BY_SIGNATURE,
    :C_V, :C_v, :C_Qe, :ZIP_TRICKS_COMMENT
  
  private

  # Writes the Zip64 extra field for the local file header. Will be used by `write_local_file_header` when any sizes given to it warrant that.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param compressed_size[Fixnum]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Fixnum]  The size of the file once extracted
  # @return [void]
  def write_zip_64_extra_for_local_file_header(io:, compressed_size:, uncompressed_size:)
    io << [0x0001].pack(C_v)                        # 2 bytes    Tag for this "extra" block type
    io << [16].pack(C_v)                            # 2 bytes    Size of this "extra" block. For us it will always be 16 (2x8)
    io << [uncompressed_size].pack(C_Qe)            # 8 bytes    Original uncompressed file size
    io << [compressed_size].pack(C_Qe)              # 8 bytes    Size of compressed data
  end
  
  # Writes the Zip64 extra field for the central directory header.It differs from the extra used in the local file header because it
  # also contains the location of the local file header in the ZIP as an 8-byte int.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param compressed_size[Fixnum]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Fixnum]  The size of the file once extracted
  # @param local_file_header_location[Fixnum] Byte offset of the start of the local file header from the beginning of the ZIP archive
  # @return [void]
  def write_zip_64_extra_for_central_directory_file_header(io:, compressed_size:, uncompressed_size:, local_file_header_location:)
    io << [0x0001].pack(C_v)                        # 2 bytes    Tag for this "extra" block type
    io << [28].pack(C_v)                            # 2 bytes    Size of this "extra" block. For us it will always be 28
    io << [uncompressed_size].pack(C_Qe)            # 8 bytes    Original uncompressed file size
    io << [compressed_size].pack(C_Qe)              # 8 bytes    Size of compressed data
    io << [local_file_header_location].pack(C_Qe)   # 8 bytes    Offset of local header record
    io << [0].pack(C_V)                             # 4 bytes    Number of the disk on which this file starts
  end
  
  def bytesize_of
    ''.force_encoding(Encoding::BINARY).tap {|b| yield(b) }.bytesize
  end

  def to_binary_dos_time(t)
    (t.sec/2) + (t.min << 5) + (t.hour << 11)
  end

  def to_binary_dos_date(t)
    (t.day) + (t.month << 5) + ((t.year - 1980) << 9)
  end
end