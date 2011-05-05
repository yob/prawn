# encoding: ASCII-8BIT

# png.rb : Extracts the data from a PNG that is needed for embedding
#
# Based on some similar code in PDF::Writer by Austin Ziegler
#
# Copyright April 2008, James Healy.  All Rights Reserved.
#
# This is free software. Please see the LICENSE and COPYING files for details.

require 'stringio'
require 'enumerator'
require 'chunky_png'

module Prawn
  module Images
    # A convenience class that wraps the logic for extracting the parts
    # of a PNG image that we need to embed them in a PDF
    #
    class PNG
      attr_reader :palette, :img_data, :transparency
      attr_reader :width, :height, :bits
      attr_reader :color_type, :compression_method, :filter_method
      attr_reader :interlace_method, :alpha_channel
      attr_accessor :scaled_width, :scaled_height

      # Process a new PNG image
      #
      # <tt>data</tt>:: A binary string of PNG data
      #
      def initialize(data)
        @data = StringIO.new(data.dup)

        @data.read(8)  # Skip the default header

        @palette  = ""
        @img_data = ""
        @transparency = {}

        loop do
          chunk_size  = @data.read(4).unpack("N")[0]
          section     = @data.read(4)
          case section
          when 'IHDR'
            # we can grab other interesting values from here (like width,
            # height, etc)
            values = @data.read(chunk_size).unpack("NNCCCCC")

            @width              = values[0]
            @height             = values[1]
            @bits               = values[2]
            @color_type         = values[3]
            @compression_method = values[4]
            @filter_method      = values[5]
            @interlace_method   = values[6]
          when 'PLTE'
            @palette << @data.read(chunk_size)
          when 'IDAT'
            @img_data << @data.read(chunk_size)
          when 'tRNS'
            # This chunk can only occur once and it must occur after the
            # PLTE chunk and before the IDAT chunk
            @transparency = {}
            case @color_type
            when 3
              # Indexed colour, RGB. Each byte in this chunk is an alpha for
              # the palette index in the PLTE ("palette") chunk up until the
              # last non-opaque entry. Set up an array, stretching over all
              # palette entries which will be 0 (opaque) or 1 (transparent).
              @transparency[:indexed]  = @data.read(chunk_size).unpack("C*")
              short = 255 - @transparency[:indexed].size
              @transparency[:indexed] += ([255] * short) if short > 0
            when 0
              # Greyscale. Corresponding to entries in the PLTE chunk.
              # Grey is two bytes, range 0 .. (2 ^ bit-depth) - 1
              grayval = @data.read(chunk_size).unpack("n").first
              @transparency[:grayscale] = grayval
            when 2
              # True colour with proper alpha channel.
              @transparency[:rgb] = @data.read(chunk_size).unpack("nnn")
            end
          when 'IEND'
            # we've got everything we need, exit the loop
            break
          else
            # unknown (or un-important) section, skip over it
            @data.seek(@data.pos + chunk_size)
          end

          @data.read(4)  # Skip the CRC
        end
      end

      # number of color components to each pixel
      #
      def colors
        case self.color_type
        when 0, 3, 4
          return 1
        when 2, 6
          return 3
        end
      end

      # number of bits used per pixel
      #
      def pixel_bitlength
        if alpha_channel?
          self.bits * (self.colors + 1)
        else
          self.bits * self.colors
        end
      end

      # split the alpha channel data from the raw image data in images
      # where it's required.
      #
      def split_alpha_channel!
        unfilter_image_data if alpha_channel?
      end

      def alpha_channel?
        @color_type == 4 || @color_type == 6
      end

      # Adobe Reader can't handle 16-bit png channels -- chop off the second
      # byte (least significant)
      #
      def alpha_channel_bits
        8
      end

      # Build a PDF object representing this image in +document+, and return
      # a Reference to it.
      #
      def build_pdf_object(document)
        if compression_method != 0
          raise Errors::UnsupportedImageType,
            'PNG uses an unsupported compression method'
        end

        if filter_method != 0
          raise Errors::UnsupportedImageType,
            'PNG uses an unsupported filter method'
        end

        if interlace_method != 0
          raise Errors::UnsupportedImageType,
            'PNG uses unsupported interlace method'
        end

        # some PNG types store the colour and alpha channel data together,
        # which the PDF spec doesn't like, so split it out.
        split_alpha_channel!

        case colors
        when 1
          color = :DeviceGray
        when 3
          color = :DeviceRGB
        else
          raise Errors::UnsupportedImageType,
            "PNG uses an unsupported number of colors (#{png.colors})"
        end

        # build the image dict
        obj = document.ref!(
          :Type             => :XObject,
          :Subtype          => :Image,
          :Height           => height,
          :Width            => width,
          :BitsPerComponent => bits,
          :Length           => img_data.size,
          :Filter           => :FlateDecode
        )

        unless alpha_channel
          obj.data[:DecodeParms] = {:Predictor => 15,
                                    :Colors    => colors,
                                    :BitsPerComponent => bits,
                                    :Columns   => width}
        end

        # append the actual image data to the object as a stream
        obj << img_data
        
        # sort out the colours of the image
        if palette.empty?
          obj.data[:ColorSpace] = color
        else
          # embed the colour palette in the PDF as a object stream
          palette_obj = document.ref!(:Length => palette.size)
          palette_obj << palette

          # build the color space array for the image
          obj.data[:ColorSpace] = [:Indexed, 
                                   :DeviceRGB,
                                   (palette.size / 3) -1,
                                   palette_obj]
        end

        # *************************************
        # add transparency data if necessary
        # *************************************

        # For PNG color types 0, 2 and 3, the transparency data is stored in
        # a dedicated PNG chunk, and is exposed via the transparency attribute
        # of the PNG class.
        if transparency[:grayscale]
          # Use Color Key Masking (spec section 4.8.5)
          # - An array with N elements, where N is two times the number of color
          #   components.
          val = transparency[:grayscale]
          obj.data[:Mask] = [val, val]
        elsif transparency[:rgb]
          # Use Color Key Masking (spec section 4.8.5)
          # - An array with N elements, where N is two times the number of color
          #   components.
          rgb = transparency[:rgb]
          obj.data[:Mask] = rgb.collect { |x| [x,x] }.flatten
        elsif transparency[:indexed]
          # TODO: broken. I was attempting to us Color Key Masking, but I think
          #       we need to construct an SMask i think. Maybe do it inside
          #       the PNG class, and store it in alpha_channel
          #obj.data[:Mask] = transparency[:indexed]
        end

        # For PNG color types 4 and 6, the transparency data is stored as a alpha
        # channel mixed in with the main image data. The PNG class seperates
        # it out for us and makes it available via the alpha_channel attribute
        if alpha_channel?
          smask_obj = document.ref!(
            :Type             => :XObject,
            :Subtype          => :Image,
            :Height           => height,
            :Width            => width,
            :BitsPerComponent => alpha_channel_bits,
            :Length           => alpha_channel.size,
            :Filter           => :FlateDecode,
            :ColorSpace       => :DeviceGray,
            :Decode           => [0, 1]
          )
          smask_obj << alpha_channel
          obj.data[:SMask] = smask_obj
        end

        obj
      end

      # Returns the minimum PDF version required to support this image.
      def min_pdf_version
        if bits > 8
          # 16-bit color only supported in 1.5+ (ISO 32000-1:2008 8.9.5.1)
          1.5
        elsif alpha_channel?
          # Need transparency for SMask
          1.4
        else
          1.0
        end
      end

      private

      def unfilter_image_data
        chunky = ChunkyPNG::Image.from_blob(@data.string)
        if chunky.palette.grayscale?
          @img_data = Zlib::Deflate.deflate(chunky.to_grayscale_stream)
        else
          @img_data = Zlib::Deflate.deflate(chunky.to_rgb_stream)
        end

        @alpha_channel = Zlib::Deflate.deflate(chunky.to_alpha_channel_stream)
      end
    end
  end
end
