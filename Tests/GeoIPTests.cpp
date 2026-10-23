#include "GeoIP.hpp"
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <vector>
static int checks=0;
static void check(bool passed,const char *name) { if(!passed)throw std::runtime_error(name);++checks;std::cout<<"PASS "<<name<<'\n'; }
int main(int argc,char **argv) { try {
    if(argc<3)throw std::runtime_error("Expected fixture.bin temporary-directory [real-GeoIP.bin]");
    check(tfgeo::country("127.0.0.1")=="LOCAL","local addresses classified without database");
    check(tfgeo::country("8.8.8.8").empty(),"absent database returns unknown");
    check(tfgeo::load(argv[1]),"valid binary loads");
    check(tfgeo::country("8.8.8.8")=="US","IPv4 country lookup");
    check(tfgeo::country("8.8.8.0")=="US","IPv4 inclusive start boundary");
    check(tfgeo::country("8.8.8.255")=="US","IPv4 inclusive end boundary");
    check(tfgeo::country("8.8.7.255").empty(),"IPv4 gap before range");
    check(tfgeo::country("8.8.9.0").empty(),"IPv4 gap after range");
    check(tfgeo::country("2001:4860::")=="US","IPv6 inclusive start boundary");
    check(tfgeo::country("2001:4860:ffff:ffff:ffff:ffff:ffff:ffff")=="US","IPv6 inclusive end boundary");
    check(tfgeo::country("2001:485f:ffff:ffff:ffff:ffff:ffff:ffff").empty(),"IPv6 gap before range");
    check(tfgeo::country("2001:4861::").empty(),"IPv6 gap after range");
    check(tfgeo::country("::ffff:8.8.8.8")=="US","IPv4-mapped IPv6 lookup");
    for(const auto& ip:std::vector<std::string>{"10.5.2.1","172.16.0.1","172.31.255.255","192.168.1.1","169.254.1.1","100.64.0.1","::1","fc00::1","fd80::1","fe80::1%en0","::ffff:192.168.0.1"}) check(tfgeo::country(ip)=="LOCAL",("private address: "+ip).c_str());
    for(const auto& ip:std::vector<std::string>{"","not-an-ip","256.1.1.1","8.8.8.8:443","[::1]:80","8.8.8.8%en0","::::","224.0.0.1","ff02::1"})check(tfgeo::country(ip).empty(),("invalid or multicast address: "+ip).c_str());
    std::string invalid=std::string(argv[2])+"/invalid.bin";
    {std::ofstream out(invalid,std::ios::binary);out<<"TFGEO001";}
    check(!tfgeo::load(invalid),"truncated database rejected");
    check(tfgeo::country("8.8.8.8")=="US","failed load preserves validated database");
    {std::ofstream out(invalid,std::ios::binary);std::string b(42,0);b.replace(0,8,"TFGEO001");b[15]=1;b[32]=8;b[36]=7;b[40]='U';b[41]='S';out.write(b.data(),b.size());}
    check(!tfgeo::load(invalid),"reversed range rejected");
    {std::ofstream out(invalid,std::ios::binary);std::string b(42,0);b.replace(0,8,"TFGEO001");b[15]=1;b[32]=8;b[36]=8;b[40]='1';b[41]='S';out.write(b.data(),b.size());}
    check(!tfgeo::load(invalid),"invalid country code rejected");
    if(argc>3) {
        check(tfgeo::load(argv[3]),"bundled DB-IP database loads");
        check(tfgeo::country("8.8.8.8")=="US","bundled DB: Google IPv4 US");
        // This pinned DB-IP release places this anycast address in CA, not US.
        // Independently checked against mirror CSV range 2001:4860:4802::—2001:4860:6dff:ffff:ffff:ffff:ffff:ffff.
        check(tfgeo::country("2001:4860:4860::8888")=="CA","bundled DB: pinned Google anycast IPv6 CA range");
        check(tfgeo::country("2001:4860:1c00::1")=="US","bundled DB: neighboring Google IPv6 US range");
    }
    std::cout<<"ALL "<<checks<<" GEOIP CHECKS PASSED\n";return 0;
} catch(const std::exception& ex){std::cerr<<"FAIL "<<ex.what()<<'\n';return 1;}}
