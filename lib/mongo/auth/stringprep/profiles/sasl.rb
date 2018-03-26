require 'mongo/auth/stringprep/tables'

module Mongo
  module Auth
    module StringPrep
      module Profiles
        # Contains the mappings and prohibited lists for SASLPrep (RFC 4013).
        #
        # @since 2.6.0
        module SASL
          MAP_NON_ASCII_TO_SPACE = {
            0x00A0 => [0x0020],
            0x1680 => [0x0020],
            0x2000 => [0x0020],
            0x2001 => [0x0020],
            0x2002 => [0x0020],
            0x2003 => [0x0020],
            0x2004 => [0x0020],
            0x2005 => [0x0020],
            0x2006 => [0x0020],
            0x2007 => [0x0020],
            0x2008 => [0x0020],
            0x2009 => [0x0020],
            0x200A => [0x0020],
            0x200B => [0x0020],
            0x202F => [0x0020],
            0x205F => [0x0020],
            0x3000 => [0x0020],
          }.freeze

          # The mappings to use for SASL string preparation.
          #
          # @since 2.6.0
          MAPPINGS = [
            Tables::B1,
            MAP_NON_ASCII_TO_SPACE,
          ].freeze

          # The prohibited character lists to use for SASL string preparation.
          #
          # @since 2.6.0
          PROHIBITIED = [
            Tables::A1,
            Tables::C1_2,
            Tables::C2_1,
            Tables::C2_2,
            Tables::C3,
            Tables::C4,
            Tables::C5,
            Tables::C6,
            Tables::C7,
            Tables::C8,
            Tables::C9,
          ].freeze
        end
      end
    end
  end
end
