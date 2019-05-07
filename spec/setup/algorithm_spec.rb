require 'rspec'

describe 'My behaviour' do

  it 'should do something' do
=begin
=end

    if item = items.shift
      ruc = sk_dt['PartyIdentification']
      rec = st.create_from_json(item)
      id = rec["ID"]["value"]
      bill_name = ruc.to_s + "-03-" + id.to_s

      sunat_signature_template1(rec, sk_dt)
      xml_data = rec.to_xml(encoding: "UTF-8") # ISO-8859-1
      xml_sign = sunat_xmldsign_sign(xml_data, sk_dt["PKey"])

      Cenit.namespace('UBLPE').data_type('XmlDocument').create_from(xml_sign, filename: "#{bill_name}.xml")

      secret_key = Digest::SHA256.hexdigest "20518203470-03-#{id}"

      data[:data].append({
                             :documentName => id,
                             :responseDescription => "Boleta de Venta con XML adjuntado",
                             :state => "Boleta de Venta con XML adjuntado",
                             :statusCode => 0,
                             :secret_key => secret_key,
                             :xml_sign => xml_sign,
                             :responseContent => "Boleta de Venta con XML adjuntado"
                         }
      )

      Cenit.namespace('SUNAT_2_1').algorithm('process_sales_tickets').run_asynchronous([data, items, sk_dt, st]) do |task|
      end
    end
=begin
=end

    true.should == false
  end
end