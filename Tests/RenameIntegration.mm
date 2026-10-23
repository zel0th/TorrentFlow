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
#include <set>

namespace lt=libtorrent;
namespace path=std::filesystem;
using namespace std::chrono_literals;
static int checks=0;
static void check(bool condition,char const *message) {
    if(!condition)throw std::runtime_error(message);
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
static std::string jsonNames(NSDictionary *names) {
    auto data=[NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
    return std::string((char const*)data.bytes,data.length);
}
static NSDictionary *snapshot(TFEngine e,NSString *id) {
    for(NSDictionary *item in success(tf_snapshot(e))[@"items"])
        if([item[@"id"] isEqual:id])return item;
    return nil;
}
static NSDictionary *wait(TFEngine e,NSString *id,bool complete) {
    auto deadline=std::chrono::steady_clock::now()+20s;
    while(std::chrono::steady_clock::now()<deadline) {
        auto item=snapshot(e,id);
        if(complete?([item[@"wanted"] longLongValue]>0 && [item[@"done"] longLongValue]>=[item[@"wanted"] longLongValue]):[item[@"hasMetadata"] boolValue])return item;
        std::this_thread::sleep_for(40ms);
    }
    std::cerr<<"Last state: "<<[[snapshot(e,id) description] UTF8String]<<std::endl;
    throw std::runtime_error(complete?"renamed download timed out":"magnet metadata timed out");
}
static bool same(path::path first,path::path second) {
    std::ifstream a(first,std::ios::binary),b(second,std::ios::binary);
    if(!a||!b)return false;
    return std::vector<char>((std::istreambuf_iterator<char>(a)),{})==std::vector<char>((std::istreambuf_iterator<char>(b)),{});
}
static std::string read(path::path file) {
    std::ifstream input(file,std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(input)),{});
}
class Tracker {
    int listener=-1;
    std::thread worker;
    std::atomic<bool> running{true};
    unsigned short peerPort;
public:
    unsigned short port=0;
    explicit Tracker(unsigned short seedPort):peerPort(seedPort) {
        listener=socket(AF_INET,SOCK_STREAM,0);
        if(listener<0)throw std::runtime_error("tracker socket failed");
        int yes=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(bind(listener,(sockaddr*)&address,sizeof(address))<0 || listen(listener,16)<0)throw std::runtime_error("tracker bind failed");
        socklen_t size=sizeof(address);getsockname(listener,(sockaddr*)&address,&size);port=ntohs(address.sin_port);
        worker=std::thread([this]{run();});
    }
    ~Tracker(){running=false;shutdown(listener,SHUT_RDWR);close(listener);if(worker.joinable())worker.join();}
    std::string url()const{return "http://127.0.0.1:"+std::to_string(port)+"/announce";}
private:
    void run(){while(running){
        int client=accept(listener,nullptr,nullptr);if(client<0)break;
        int yes=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        timeval timeout{1,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        std::string request;char buffer[8192];
        while(request.find("\r\n\r\n")==std::string::npos && request.size()<32768){auto n=recv(client,buffer,sizeof(buffer),0);if(n<=0)break;request.append(buffer,n);}
        lt::entry result(lt::entry::dictionary_t);result["interval"]=60;result["complete"]=1;result["incomplete"]=0;
        std::string peer;peer+=char(127);peer+=char(0);peer+=char(0);peer+=char(1);peer+=char(peerPort>>8);peer+=char(peerPort&255);result["peers"]=peer;
        auto bytes=lt::bencode(result);std::string body(bytes.data(),bytes.size());
        auto response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: "+std::to_string(body.size())+"\r\n\r\n"+body;
        std::size_t sent=0;while(sent<response.size()){auto n=send(client,response.data()+sent,response.size()-sent,0);if(n<=0)break;sent+=n;}
        shutdown(client,SHUT_RDWR);close(client);
    }}
};
static std::string key(int index){return std::to_string(index);}
static NSString *ns(std::string const& s){return [NSString stringWithUTF8String:s.c_str()];}
static std::string currentFilePath(NSDictionary *transfer,int index) {
    for(NSDictionary *file in transfer[@"files"])if([file[@"index"] intValue]==index)return [file[@"path"] UTF8String];
    throw std::runtime_error("file index missing from snapshot");
}
static std::vector<int> findIndices(NSDictionary *transfer) {
    std::vector<int> indices(3,-1);
    for(NSDictionary *file in transfer[@"files"]){NSString *name=file[@"path"];int index=[file[@"index"] intValue];
        if([name hasSuffix:@"/first.bin"])indices[0]=index;
        if([name hasSuffix:@"/second.bin"])indices[1]=index;
        if([name hasSuffix:@"/excluded.bin"])indices[2]=index;
    }
    check(indices[0]>=0&&indices[1]>=0&&indices[2]>=0,"original file indices resolved");return indices;
}
int main(int argc,char **argv){@autoreleasepool {try {
    std::string root=argc>1?argv[1]:"/tmp/torrentflow-rename-regression";
    check(!path::exists(root),"fresh rename test directory");path::create_directories(root);
    auto source=path::path(root)/"source";
    std::vector<std::string> original={"RenamePack/first.bin","RenamePack/second.bin","RenamePack/Sub/excluded.bin"};
    lt::file_storage layout;
    for(int i=0;i<3;++i){auto file=source/original[i];path::create_directories(file.parent_path());std::string content(262149,char('R'+i));
        for(int n=0;n<int(content.size());n+=29)content[n]=char((n+i)%255);
        std::ofstream output(file,std::ios::binary);output.write(content.data(),content.size());layout.add_file(original[i],content.size());
    }
    lt::settings_pack cfg;cfg.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    cfg.set_bool(lt::settings_pack::enable_dht,false);cfg.set_bool(lt::settings_pack::enable_lsd,false);
    cfg.set_bool(lt::settings_pack::enable_upnp,false);cfg.set_bool(lt::settings_pack::enable_natpmp,false);
    cfg.set_bool(lt::settings_pack::allow_multiple_connections_per_ip,true);cfg.set_bool(lt::settings_pack::enable_outgoing_utp,false);
    lt::session seeder(cfg);for(int n=0;n<100&&seeder.listen_port()==0;++n)std::this_thread::sleep_for(40ms);
    check(seeder.listen_port()>0,"rename seeder listens");Tracker tracker(seeder.listen_port());
    lt::create_torrent creator(layout,65536);creator.add_tracker(tracker.url());lt::set_piece_hashes(creator,source.string());
    auto encoded=lt::bencode(creator.generate());auto torrent=path::path(root)/"sample.torrent";
    {std::ofstream output(torrent,std::ios::binary);output.write(encoded.data(),encoded.size());}
    auto params=lt::load_torrent_file(torrent.string());params.save_path=source.string();params.trackers.clear();
    params.flags|=lt::torrent_flags::seed_mode|lt::torrent_flags::override_trackers;
    params.flags&=~(lt::torrent_flags::paused|lt::torrent_flags::auto_managed);auto seed=seeder.add_torrent(params);
    auto state=(path::path(root)/"state").string(),drafts=(path::path(root)/"drafts").string();
    TFEngine e=tf_create(state.c_str(),drafts.c_str());check(e,"rename downloader starts");
    success(tf_configure(e,"{\"dht\":false,\"lsd\":false,\"portMapping\":false,\"port\":54990,\"connections\":80}"));
    NSString *id=success(tf_stage(e,torrent.c_str()))[@"id"];auto metadata=snapshot(e,id);auto indices=findIndices(metadata);
    std::set<std::string> padPaths;int padCount=0;bool repeatedPad=false;
    for(NSDictionary *file in metadata[@"files"])if([file[@"padding"] boolValue]) {
        ++padCount;std::string name=[file[@"path"] UTF8String];
        if(!padPaths.insert(name).second)repeatedPad=true;
    }
    check(padCount>=2&&repeatedPad,"hybrid fixture retains repeated virtual padding paths");
    std::vector<int> priorities([metadata[@"files"] count],0);priorities[indices[0]]=7;priorities[indices[1]]=1;
    auto destination=path::path(root)/"torrent-target";
    auto invalid=[&](NSDictionary *names,char const *label,path::path dest=path::path()){
        auto json=jsonNames(names);auto target=dest.empty()?destination:dest;
        check(![decode(tf_commit_with_names(e,id.UTF8String,target.c_str(),priorities.data(),int(priorities.size()),1,json.c_str()))[@"ok"] boolValue],label);
        auto current=snapshot(e,id);check([current[@"draft"] boolValue] && [current[@"downloaded"] longLongValue]==0,"invalid rename leaves draft without payload");
        for(int n=0;n<3;++n)check(currentFilePath(current,indices[n])==original[n],"invalid rename leaves original path mapping");
    };
    NSString *firstKey=ns(key(indices[0])),*secondKey=ns(key(indices[1]));
    for(NSString *bad in @[@"",@".",@"..",@"../escape.bin",@"nested/name.bin",@"nested\\name.bin"])
        invalid(@{firstKey:bad},"invalid basename rejected");
    invalid(@{firstKey:@"SECOND.BIN"},"case-insensitive collision rejected");
    invalid(@{firstKey:@"é.bin",secondKey:@"é.bin"},"Unicode-normalized collision rejected");
    invalid(@{firstKey:@"Sub"},"file-versus-directory prefix collision rejected");
    invalid(@{@"999999":@"unknown.bin"},"unknown file index rejected");
    invalid(@{@"-1":@"negative.bin"},"negative file index rejected");
    check(!path::exists(destination),"invalid names do not create download destination");
    auto conflict=path::path(root)/"conflict-target";path::create_directories(conflict/"RenamePack");
    {std::ofstream output(conflict/"RenamePack/existing.bin");output<<"Unrelated existing content";}
    invalid(@{firstKey:@"existing.bin"},"existing unrelated renamed destination rejected",conflict);
    check(read(conflict/"RenamePack/existing.bin")=="Unrelated existing content","existing unrelated file unchanged");
    auto outside=path::path(root)/"outside";path::create_directories(outside);
    {std::ofstream output(outside/"marker.txt");output<<"Outside marker";}
    auto symlinkTarget=path::path(root)/"symlink-target";path::create_directories(symlinkTarget);path::create_directory_symlink(outside,symlinkTarget/"RenamePack");
    invalid(@{firstKey:@"renamed.bin"},"symlink ancestor rejected",symlinkTarget);
    check(read(outside/"marker.txt")=="Outside marker" && !path::exists(outside/"renamed.bin"),"symlink ancestor target untouched");
    auto leafTarget=path::path(root)/"symlink-leaf-target";path::create_directories(leafTarget/"RenamePack");
    path::create_symlink(outside/"marker.txt",leafTarget/"RenamePack/link.bin");
    invalid(@{firstKey:@"link.bin"},"symlink leaf rejected",leafTarget);
    check(read(outside/"marker.txt")=="Outside marker","symlink leaf target unchanged");
    NSDictionary *names=@{firstKey:@"Первый.mkv",secondKey:@"renamed second.bin",ns(key(indices[2])):@"Не загружать.bin"};
    auto namesJSON=jsonNames(names);
    success(tf_commit_with_names(e,id.UTF8String,destination.c_str(),priorities.data(),int(priorities.size()),0,namesJSON.c_str()));
    auto paused=snapshot(e,id);check([paused[@"phase"] isEqual:@"paused"],"renamed torrent can be added on pause");
    check(currentFilePath(paused,indices[0])=="RenamePack/Первый.mkv","torrent snapshot exposes renamed selected path");
    check(currentFilePath(paused,indices[2])=="RenamePack/Sub/Не загружать.bin","excluded rename preserves original parent directory");
    success(tf_command(e,id.UTF8String,"resume"));wait(e,id,true);
    check(same(source/original[0],destination/"RenamePack/Первый.mkv"),"renamed torrent first file byte-identical");
    check(same(source/original[1],destination/"RenamePack/renamed second.bin"),"renamed torrent second file byte-identical");
    check(!path::exists(destination/original[0])&&!path::exists(destination/original[1]),"original selected basenames not created");
    check(!path::exists(destination/"RenamePack/Sub/Не загружать.bin"),"renamed excluded file not downloaded");
    success(tf_command(e,id.UTF8String,"pause"));success(tf_save(e));tf_destroy(e);
    e=tf_create(state.c_str(),drafts.c_str());auto restored=snapshot(e,id);
    check(restored!=nil,"renamed torrent restored");
    check(currentFilePath(restored,indices[0])=="RenamePack/Первый.mkv"&&currentFilePath(restored,indices[2])=="RenamePack/Sub/Не загружать.bin","resume restores selected and excluded rename mappings");
    check([restored[@"phase"] isEqual:@"paused"],"renamed torrent paused state restored");
    success(tf_command(e,id.UTF8String,"remove"));
    std::string magnet=lt::make_magnet_uri(seed)+"&x.pe=127.0.0.1:"+std::to_string(seeder.listen_port());
    id=success(tf_stage(e,magnet.c_str()))[@"id"];auto magnetMetadata=wait(e,id,false);
    check([magnetMetadata[@"downloaded"] longLongValue]==0,"magnet rename waits without file payload");
    auto magnetTarget=path::path(root)/"magnet-target";
    auto magnetNames=jsonNames(@{firstKey:@"Magnet-one.bin",secondKey:@"Magnet-two.bin",ns(key(indices[2])):@"Skipped-magnet.bin"});
    success(tf_commit_with_names(e,id.UTF8String,magnetTarget.c_str(),priorities.data(),int(priorities.size()),1,magnetNames.c_str()));
    auto done=wait(e,id,true);
    check(same(source/original[0],magnetTarget/"RenamePack/Magnet-one.bin"),"renamed magnet first file byte-identical");
    check(same(source/original[1],magnetTarget/"RenamePack/Magnet-two.bin"),"renamed magnet second file byte-identical");
    check(!path::exists(magnetTarget/original[0])&&!path::exists(magnetTarget/original[1]),"magnet original selected basenames not created");
    check(!path::exists(magnetTarget/"RenamePack/Sub/Skipped-magnet.bin"),"magnet renamed excluded file absent");
    check(currentFilePath(done,indices[0])=="RenamePack/Magnet-one.bin","magnet snapshot uses committed rename mapping");
    success(tf_command(e,id.UTF8String,"pause"));success(tf_save(e));tf_destroy(e);
    e=tf_create(state.c_str(),drafts.c_str());restored=snapshot(e,id);
    check(currentFilePath(restored,indices[1])=="RenamePack/Magnet-two.bin","magnet rename survives restart");
    success(tf_command(e,id.UTF8String,"remove"));tf_destroy(e);
    std::cout<<"ALL "<<checks<<" RENAME CHECKS PASSED; libtorrent "<<tf_version()<<std::endl;return 0;
} catch(std::exception const& ex){std::cerr<<"FAIL "<<ex.what()<<std::endl;return 1;} }}
