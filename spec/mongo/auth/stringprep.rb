require 'spec_helper'

describe Mongo::Auth::StringPrep do
  describe '#prepare' do
    context 'with no options' do
      it 'does not check bidi' do
        # expect(Mongo::Auth::StringPrep.prepare("\u0627\u0031", [], [])).to eq("\u0627\u0031")
      end
    end
  end
end
