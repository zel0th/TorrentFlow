#ifndef TORRENTFLOW_GEOIP_HPP
#define TORRENTFLOW_GEOIP_HPP
// Offline IP country lookup. DB-IP Lite attribution: Documentation/Licenses/GeoIP.txt.
// Format TFGEO001: 32-byte header, sorted 10-byte IPv4 and 34-byte IPv6 ranges.
#include <arpa/inet.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <atomic>

namespace tfgeo {
namespace detail {
struct Database {
    void *mapping = MAP_FAILED;
    std::size_t size = 0;
    std::uint64_t count4 = 0, count6 = 0;
    const unsigned char *v4 = nullptr, *v6 = nullptr;
    ~Database() { if (mapping != MAP_FAILED) munmap(mapping, size); }
};
inline std::shared_ptr<const Database> database;
inline std::mutex loadMutex;
inline std::uint64_t be64(const unsigned char *p) {
    std::uint64_t n=0; for(int i=0;i<8;++i) n=(n<<8)|p[i]; return n;
}
inline bool countryCode(const unsigned char *p) { return p[0]>='A' && p[0]<='Z' && p[1]>='A' && p[1]<='Z'; }
inline bool validate(const unsigned char *p,std::uint64_t count,std::size_t width) {
    const std::size_t stride=2*width+2;
    for(std::uint64_t i=0;i<count;++i) {
        auto row=p+i*stride;
        if(std::memcmp(row,row+width,width)>0 || !countryCode(row+2*width)) return false;
        if(i && std::memcmp(row-stride+width,row,width)>=0) return false;
    }
    return true;
}
inline std::string find(const unsigned char *rows,std::uint64_t count,const unsigned char *ip,std::size_t width) {
    std::uint64_t low=0,high=count; const std::size_t stride=2*width+2;
    while(low<high) {
        auto mid=low+(high-low)/2;
        if(std::memcmp(rows+mid*stride,ip,width)<=0) low=mid+1; else high=mid;
    }
    if(!low) return {};
    auto row=rows+(low-1)*stride;
    if(std::memcmp(ip,row+width,width)>0) return {};
    return std::string(reinterpret_cast<const char*>(row+2*width),2);
}
inline bool local4(const unsigned char *p) {
    return p[0]==0 || p[0]==10 || p[0]==127 || (p[0]==169 && p[1]==254) ||
       (p[0]==172 && p[1]>=16 && p[1]<=31) || (p[0]==192 && p[1]==168) ||
       (p[0]==100 && p[1]>=64 && p[1]<=127);
}
}
// A failed reload leaves the previously validated database usable.
inline bool load(std::string const& path) {
    std::lock_guard<std::mutex> guard(detail::loadMutex);
    int fd=open(path.c_str(),O_RDONLY|O_CLOEXEC); if(fd<0) return false;
    struct stat st{};
    if(fstat(fd,&st)!=0 || st.st_size<32 || st.st_size>128*1024*1024) {close(fd);return false;}
    auto next=std::make_shared<detail::Database>(); next->size=static_cast<std::size_t>(st.st_size);
    next->mapping=mmap(nullptr,next->size,PROT_READ,MAP_PRIVATE,fd,0);close(fd);
    if(next->mapping==MAP_FAILED) return false;
    auto p=static_cast<const unsigned char*>(next->mapping);
    if(std::memcmp(p,"TFGEO001",8)!=0 || detail::be64(p+24)!=0) return false;
    next->count4=detail::be64(p+8); next->count6=detail::be64(p+16);
    if(next->count4>5000000 || next->count6>5000000) return false;
    if(32+next->count4*10+next->count6*34!=next->size) return false;
    next->v4=p+32;next->v6=next->v4+next->count4*10;
    if(!detail::validate(next->v4,next->count4,4) || !detail::validate(next->v6,next->count6,16)) return false;
    std::atomic_store_explicit(&detail::database,std::shared_ptr<const detail::Database>(next),std::memory_order_release);
    return true;
}
inline std::string country(std::string const& input) {
    if(input.empty() || input.size()>128) return {};
    std::string ip=input;
    if(ip.front()=='[' && ip.back()==']') ip=ip.substr(1,ip.size()-2);
    auto zone=ip.find('%'); if(zone!=std::string::npos) { if(ip.find(':')==std::string::npos) return {}; ip.resize(zone); }
    std::array<unsigned char,16> address{};
    bool ipv4=inet_pton(AF_INET,ip.c_str(),address.data())==1;
    if(!ipv4) {
        if(inet_pton(AF_INET6,ip.c_str(),address.data())!=1) return {};
        static const unsigned char mapped[]={0,0,0,0,0,0,0,0,0,0,255,255};
        if(std::memcmp(address.data(),mapped,12)==0) {std::memmove(address.data(),address.data()+12,4);ipv4=true;}
    }
    if(ipv4) { if(detail::local4(address.data())) return "LOCAL"; if(address[0]>=224) return {}; }
    else {
        static const unsigned char zero[15]={};
        if((std::memcmp(address.data(),zero,15)==0 && address[15]<=1) || (address[0]&0xfe)==0xfc ||
            (address[0]==0xfe && (address[1]&0xc0)==0x80)) return "LOCAL";
        if(address[0]==0xff) return {};
    }
    auto db=std::atomic_load_explicit(&detail::database,std::memory_order_acquire);
    if(!db) return {};
    return ipv4?detail::find(db->v4,db->count4,address.data(),4):detail::find(db->v6,db->count6,address.data(),16);
}
}
#endif
