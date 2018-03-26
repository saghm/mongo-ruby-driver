module Mongo
  class Error
    class StringPrep < Error
      INVALID_BIDIRECTIONAL = 'StringPrep bidirectional data is invalid'
      PROHIBITED_CHARACTER = 'StringPrep data contains a prohibited character.'.freeze

      def initialize(msg)
        super(msg)
      end
    end
  end
end
