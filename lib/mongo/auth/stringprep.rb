require 'mongo/auth/stringprep/tables'

module Mongo
  module Auth
    # This namespace contains all behavior related to string preparation (RFC 3454). It's used to
    # implement SCRAM-SHA-256 authentication, which is usable with MongoDB server versions 4.0 and
    # newer.
    #
    # @since 2.6.0
    module StringPrep
      extend self

      # Prepare a string given a set of mappings and prohibited character tables.
      #
      # @example Prepare a string.
      #   StringPrep.prepare("some string",
      #                      StringPrep::SASL::Mappings,
      #                      StringPrep::SASL::Prohibited,
      #                      normalize: true, bidi: true)
      #
      # @param [ String ] data The string to prepare.
      # @param [ Array ] mappings A list of mappings to apply to the data.
      # @param [ Array ] prohibited A list of prohibited character lists to ensure the data doesn't
      #   contain after mapping and normalizing the data. If the mapped and normalized data contains
      #   a character in one of the lists, this method will raise an error.
      # @param [ Hash ] options Optional operations to perform during string preparation.
      #
      # @option options [ Boolean ] :normalize Whether or not to apply Unicode normalization to the
      #   data.
      # @option options [ Boolean ] :bidi Whether or not to ensure that the data contains valid
      #   bidirectional input. If the option is true and the bidirectional data is invalid, this
      #   method will raise an error.
      #
      # @since 2.6.0
      def prepare(data, mappings, prohibited, options = {})
        apply_maps(data, mappings).tap do |mapped|
          normalize(mapped) if options[:normalize]
          check_prohibited(mapped, prohibited)
          check_bidi(mapped) if options[:bidi]
        end
      end

      private

      def apply_maps(data, mappings)
        data.inject('') do |out, c|
          out << mapping(c, mappings)
        end
      end

      def check_bidi(out)
        if out.each_char.any? { |c| table_contains?(Tables::C8, c) }
          raise Mongo::Error::StringPrep.new(Error::StringPrep::INVALID_BIDIRECTIONAL)
        end

        if out.each_char.any? { |c| table_contains?(Tables::D1, c) }
          unless table_contains?(Tables::D1, out[0]) && table_contains?(Tables::D1, out[-1])
            raise Mongo::Error::StringPrep.new(Error::StringPrep::INVALID_BIDIRECTIONAL)
          end
        end
      end

      def check_prohibited(out, prohibited)
        out.each do |c|
          prohibited.each do |table|
            if table_contains?(table, c)
              raise Error::StringPrep(Error::StringPrep::PROHIBITED_CHARACTER)
            end
          end
        end
      end

      def mapping(c, mappings)
        m = mappings.find { |m| m.has_key?(c) }
        (m && m[c]) || c
      end

      def normalize(out)
        out.unicode_normalize!(:nfkc)
      end

      def table_contains?(table, c)
        table.any? do |r|
          r.member?(c)
        end
      end
    end
  end
end
