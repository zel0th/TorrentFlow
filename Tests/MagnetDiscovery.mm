#import <Foundation/Foundation.h>
#include "TorrentBridge.h"
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/bencode.hpp>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <filesystem>
#include <fstream>
#include <thread>
#include <chrono>
#include <atomic>
#include <iostream>
namespace lt = libtorrent;
namespace path = std::filesystem;
using namespace std::chrono_literals;
static int checks=0;
static void check(bool condition,char const *message) {
    if(!condition) throw std::runtime_error(message);
    ++checks;std::cout<<"PASS "<<message<<std::endl;
}
static NSDictionary *decode(char *value) {
    if(!value)throw std::runtime_error("Null bridge response");
    NSData *data=[NSData dataWithBytes:value length:strlen(value)];tf_free(value);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static NSDictionary *success(char *value) {
    auto result=decode(value);
    if(![result[@"ok"] boolValue])throw std::runtime_error([result[@"error"] UTF8String]);
    return result;
}
static NSDictionary *snapshot(TFEngine e,NSString *id) {
    for(NSDictionary *item in success(tf_snapshot(e))[@"items"])
        if([item[@"id"] isEqual:id])return item;
    return nil;
}
static NSDictionary *wait(TFEngine e,NSString *id,bool complete,int seconds=20) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(seconds);
    while(std::chrono::steady_clock::now()<deadline) {
        auto t=snapshot(e,id);
        if(complete?([t[@"wanted"] longLongValue]>0 && [t[@"done"] longLongValue]>=[t[@"wanted"] longLongValue]):[t[@"hasMetadata"] boolValue])return t;
        std::this_thread::sleep_for(40ms);
    }
    auto t=snapshot(e,id);
    std::cerr<<"Last state: "<<[[t description] UTF8String]<<std::endl;
    throw std::runtime_error(complete?"payload transfer timed out after metadata handoff":"tracker-only magnet metadata timed out");
}
static std::string encoded(std::string const& text) {
    static char const hex[]="0123456789ABCDEF";std::string result;
    for(unsigned char c:text) {
        if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~')result+=c;
        else {result+='%';result+=hex[c>>4];result+=hex[c&15];}
    }
    return result;
}
class Tracker {
    int listener=-1;
    std::thread worker;
    std::atomic<bool> running{true};
    unsigned short peerPort;
public:
    std::atomic<bool> online{true};
    std::atomic<int> requests{0};
    unsigned short port=0;
    explicit Tracker(unsigned short seedPort):peerPort(seedPort) {
        listener=socket(AF_INET,SOCK_STREAM,0);
        if(listener<0)throw std::runtime_error("tracker socket failed");
        int yes=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=0;
        if(bind(listener,(sockaddr*)&address,sizeof(address))<0 || listen(listener,16)<0)throw std::runtime_error("tracker bind failed");
        socklen_t size=sizeof(address);getsockname(listener,(sockaddr*)&address,&size);port=ntohs(address.sin_port);
        worker=std::thread([this]{run();});
    }
    ~Tracker() {running=false;shutdown(listener,SHUT_RDWR);close(listener);if(worker.joinable())worker.join();}
    std::string url()const{return "http://127.0.0.1:"+std::to_string(port)+"/announce";}
private:
    void run() {
        while(running) {
            int client=accept(listener,nullptr,nullptr);if(client<0)break;
            int yes=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
            timeval timeout{1,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            std::string request;char buffer[8192];
            while(request.find("\r\n\r\n")==std::string::npos && request.size()<32768) {
                auto count=recv(client,buffer,sizeof(buffer),0);if(count<=0)break;request.append(buffer,count);
            }
            if(!request.empty())++requests;
            std::string body;
            if(online) {
                lt::entry response(lt::entry::dictionary_t);
                response["interval"]=3600;response["min interval"]=3600;response["complete"]=1;response["incomplete"]=0;
                std::string peer;peer+=char(127);peer+=char(0);peer+=char(0);peer+=char(1);peer+=char(peerPort>>8);peer+=char(peerPort&255);
                response["peers"]=peer;
                auto bytes=lt::bencode(response);body.assign(bytes.data(),bytes.size());
            } else {
                lt::entry response(lt::entry::dictionary_t);response["failure reason"]="simulated tracker outage after metadata";
                auto bytes=lt::bencode(response);body.assign(bytes.data(),bytes.size());
            }
            std::string response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: "+std::to_string(body.size())+"\r\n\r\n"+body;
            std::size_t sent=0;while(sent<response.size()){auto n=send(client,response.data()+sent,response.size()-sent,0);if(n<=0)break;sent+=n;}
            shutdown(client,SHUT_RDWR);close(client);
        }
    }
};
static bool same(path::path a,path::path b) {
    std::ifstream one(a,std::ios::binary),two(b,std::ios::binary);
    if(!one||!two)return false;
    return std::vector<char>((std::istreambuf_iterator<char>(one)),{})==std::vector<char>((std::istreambuf_iterator<char>(two)),{});
}
int main(int argc,char **argv){@autoreleasepool {try {
    std::string root=argc>1?argv[1]:"/tmp/torrentflow-magnet-discovery";
    check(!path::exists(root),"fresh regression directory");path::create_directories(root);
    lt::settings_pack cfg;cfg.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    cfg.set_bool(lt::settings_pack::enable_dht,false);cfg.set_bool(lt::settings_pack::enable_lsd,false);
    cfg.set_bool(lt::settings_pack::enable_upnp,false);cfg.set_bool(lt::settings_pack::enable_natpmp,false);
    cfg.set_bool(lt::settings_pack::allow_multiple_connections_per_ip,true);
    cfg.set_bool(lt::settings_pack::enable_outgoing_utp,false);
    cfg.set_str(lt::settings_pack::user_agent,"TorrentFlow Regression Seeder/0.2");
    lt::session seeder(cfg);
    for(int n=0;n<100&&seeder.listen_port()==0;++n)std::this_thread::sleep_for(40ms);
    check(seeder.listen_port()>0,"local seeder listens");
    Tracker tracker(seeder.listen_port());
    auto source=path::path(root)/"source";lt::file_storage layout;
    std::vector<std::string> names={"TrackerRegression/selected.bin","TrackerRegression/excluded.bin"};
    for(int i=0;i<2;++i) {
        auto file=source/names[i];path::create_directories(file.parent_path());
        std::string bytes(2*1024*1024,char('X'+i));for(int n=0;n<int(bytes.size());n+=43)bytes[n]=char((n+i)%255);
        std::ofstream out(file,std::ios::binary);out.write(bytes.data(),bytes.size());layout.add_file(names[i],bytes.size());
    }
    lt::create_torrent creator(layout,65536);creator.add_tracker(tracker.url());lt::set_piece_hashes(creator,source.string());
    auto data=lt::bencode(creator.generate());auto torrent=path::path(root)/"sample.torrent";
    {std::ofstream out(torrent,std::ios::binary);out.write(data.data(),data.size());}
    auto params=lt::load_torrent_file(torrent.string());params.save_path=source.string();
    params.flags|=lt::torrent_flags::seed_mode|lt::torrent_flags::override_trackers;params.trackers.clear();
    params.flags&=~(lt::torrent_flags::paused|lt::torrent_flags::auto_managed);
    auto handle=seeder.add_torrent(params);
    auto state=(path::path(root)/"state").string(),drafts=(path::path(root)/"drafts").string();
    TFEngine engine=tf_create(state.c_str(),drafts.c_str());check(engine,"downloader starts");
    success(tf_configure(engine,"{\"dht\":false,\"lsd\":false,\"portMapping\":false,\"port\":54988,\"connections\":80}"));
    // Control: identical swarm discovered through the .torrent tracker list.
    NSString *id=success(tf_stage(engine,torrent.c_str()))[@"id"];
    NSArray *files=snapshot(engine,id)[@"files"];std::vector<int> priorities([files count],0);int selected=-1;
    for(NSDictionary *file in files)if([file[@"path"] hasSuffix:@"selected.bin"]){selected=[file[@"index"] intValue];priorities[selected]=7;}
    check(selected>=0,"selected file index resolved from metadata");
    auto control=(path::path(root)/"torrent-control").string();
    success(tf_commit(engine,id.UTF8String,control.c_str(),priorities.data(),int(priorities.size()),1));
    wait(engine,id,true);
    check(same(source/names[0],path::path(control)/names[0]),"torrent control downloads through tracker");
    check(!path::exists(path::path(control)/names[1]),"torrent control excludes unwanted file");
    success(tf_command(engine,id.UTF8String,"remove"));
    std::string magnet=lt::make_magnet_uri(handle)+"&tr="+encoded(tracker.url());
    check(magnet.find("x.pe=")==std::string::npos,"magnet contains tracker but no explicit peer");
    id=success(tf_stage(engine,magnet.c_str()))[@"id"];
    auto metadata=wait(engine,id,false);
    check([metadata[@"files"] count]==2,"tracker-only magnet receives metadata");
    check([metadata[@"downloaded"] longLongValue]==0,"metadata discovery downloads zero file payload");
    bool noPayload=true;for(auto const& f:path::recursive_directory_iterator(drafts))if(f.is_regular_file())noPayload=false;
    check(noPayload,"metadata discovery creates no content files");
    check(tracker.requests>0,"peer discovered from real HTTP tracker");
#ifdef TF_DIAGNOSTICS_TEST
    bool metadataEvent=false,trackerEvent=false;
    auto metadataDetails=success(tf_details(engine,id.UTF8String));
    for(NSDictionary *log in metadataDetails[@"logs"]) {
        NSString *message=log[@"message"];
        metadataEvent|=[message containsString:@"metadata successfully received"];
        trackerEvent|=[message containsString:@"received peers:"];
    }
    check(metadataEvent,"log contains actual libtorrent metadata event");
    check(trackerEvent,"log contains actual tracker peer reply");
#endif
    // Re-discovery cannot rescue a lost peer list: retain the working metadata connection
    // and peer cache, just as when a tracker becomes unavailable in a real swarm.
    tracker.online=false;
    auto target=(path::path(root)/"magnet-download").string();
    success(tf_configure(engine,"{\"dht\":false,\"lsd\":false,\"portMapping\":false,\"port\":54988,\"connections\":80,\"downLimit\":512}"));
    success(tf_commit(engine,id.UTF8String,target.c_str(),priorities.data(),int(priorities.size()),1));
#ifdef TF_DIAGNOSTICS_TEST
    // A metadata-only torrent may disconnect an unneeded payload peer. Inspect
    // live peers during the actual capped transfer rather than assuming a socket
    // must remain connected while all files have priority zero.
    bool localPeer=false,localCountry=false,realClient=false;
    NSArray *observedPeers=nil;
    for(int n=0;n<250;++n) {
        auto details=success(tf_details(engine,id.UTF8String));observedPeers=details[@"peers"];
        for(NSDictionary *peer in observedPeers) {
            NSString *address=peer[@"address"],*client=peer[@"client"];
            if([address hasPrefix:@"127.0.0.1:"]) {
                localPeer=true;localCountry|=[peer[@"countryCode"] isEqual:@"LOCAL"];
                if([client containsString:@"TorrentFlow Regression Seeder"])realClient=true;
            }
        }
        if(localPeer&&localCountry&&realClient)break;
        std::this_thread::sleep_for(40ms);
    }
    if(!localPeer||!realClient)std::cerr<<"Observed active peers: "<<[[observedPeers description] UTF8String]<<std::endl;
    check(localPeer,"inspector exposes actual connected tracker-discovered peer");
    check(localCountry,"loopback peer marked as local country");
    check(realClient,"peer client comes from seeder advertised handshake");
#endif
    auto done=wait(engine,id,true,15);
    check([done[@"done"] longLongValue]==2*1024*1024,"magnet payload finishes with tracker unavailable after metadata");
    check(same(source/names[0],path::path(target)/names[0]),"magnet-selected payload matches byte-for-byte");
    check(!path::exists(path::path(target)/names[1]),"magnet excluded file remains absent");
    check([done[@"destination"] isEqual:[NSString stringWithUTF8String:target.c_str()]],"magnet writes only to confirmed destination");
    check([done[@"files"][selected][@"priority"] intValue]==7,"magnet handoff preserves selected high priority");
    success(tf_command(engine,id.UTF8String,"remove"));
    // Existing valid files must be reused when selecting a different destination
    // after metadata discovery. No network peer is available to hide a broken recheck.
    tracker.online=true;
    id=success(tf_stage(engine,magnet.c_str()))[@"id"];
    auto existingMetadata=wait(engine,id,false);
    check([existingMetadata[@"downloaded"] longLongValue]==0,"second metadata probe starts without payload");
    auto existing=path::path(root)/"existing-destination";
    auto existingFile=existing/names[0];path::create_directories(existingFile.parent_path());
    path::copy_file(source/names[0],existingFile);
    {std::ofstream out(existing/"unrelated.txt");out<<"Keep this unrelated user file";}
    tracker.online=false;handle.pause();std::this_thread::sleep_for(100ms);
    success(tf_commit(engine,id.UTF8String,existing.c_str(),priorities.data(),int(priorities.size()),1));
    auto reused=wait(engine,id,true,15);
    check([reused[@"downloaded"] longLongValue]==0,"magnet reuses existing valid files without redownloading");
    check(same(source/names[0],existingFile),"existing destination payload remains byte-identical");
    {std::ifstream in(existing/"unrelated.txt");std::string text;std::getline(in,text);check(text=="Keep this unrelated user file","unrelated destination file preserved");}
    check(!path::exists(existing/names[1]),"existing destination still excludes unselected file");
    success(tf_command(engine,id.UTF8String,"remove"));tf_destroy(engine);
    std::cout<<"ALL "<<checks<<" TRACKER-DISCOVERY CHECKS PASSED; libtorrent "<<tf_version()<<std::endl;
    return 0;
} catch(std::exception const& ex){std::cerr<<"FAIL "<<ex.what()<<std::endl;return 1;} }}
