require 'mongo/auth/stringprep/tables'

module Mongo
  module Auth
    module StringPrep
      extend self

      def prepare(data, mappings, prohibited, options = {})
        mapped = apply_maps(data, mappings)
        normalize(mapped) if options[:normalize]
        check_prohibited(mapped, prohibited)
        check_bidi(mapped) if options[:bidi]
        mapped
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
          unless table_contains?(Tables::D1, out.first) && table_contains?(Tables::D1, out.last)
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
