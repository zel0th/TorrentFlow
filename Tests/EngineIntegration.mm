#import <Foundation/Foundation.h>
#include "TorrentBridge.h"
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/load_torrent.hpp>
#include <filesystem>
#include <fstream>
#include <thread>
#include <chrono>
#include <iostream>
namespace lt = libtorrent;
namespace p = std::filesystem;
using namespace std::chrono_literals;
static int checks = 0;
static void check(bool b, char const *label) { if(!b) throw std::runtime_error(label); ++checks; std::cout << "PASS " << label << std::endl; }
static NSDictionary *decode(char *bytes) {
    if(!bytes) throw std::runtime_error("Null bridge response");
    NSData *d=[NSData dataWithBytes:bytes length:strlen(bytes)]; tf_free(bytes);
    NSDictionary *r=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return r;
}
static NSDictionary *success(char *b) { auto r=decode(b); if(![r[@"ok"] boolValue]) throw std::runtime_error([r[@"error"] UTF8String]); return r; }
static NSDictionary *item(TFEngine e, NSString *id) {
    for(NSDictionary *t in success(tf_snapshot(e))[@"items"]) if([t[@"id"] isEqual:id]) return t;
    return nil;
}
static NSDictionary *waitFor(TFEngine e, NSString *id, bool finish) {
    for(int n=0;n<300;++n) {
        auto t=item(e,id);
        if(finish ? ([t[@"wanted"] longLongValue]>0 && [t[@"done"] longLongValue]>=[t[@"wanted"] longLongValue]) : [t[@"hasMetadata"] boolValue]) return t;
        std::this_thread::sleep_for(50ms);
    }
    throw std::runtime_error(finish?"Local transfer timed out":"Magnet metadata timed out");
}
static bool same(p::path a, p::path b) {
    std::ifstream x(a,std::ios::binary), y(b,std::ios::binary);
    return std::vector<char>((std::istreambuf_iterator<char>(x)),{})==std::vector<char>((std::istreambuf_iterator<char>(y)),{});
}
int main(int argc,char **argv) { @autoreleasepool { try {
    std::string root=argc>1?argv[1]:"/tmp/torrentflow-integration";
    // Tests own this unique root; never remove a caller's pre-existing directory.
    check(!p::exists(root),"fresh test directory"); p::create_directories(root);
    auto seedPath=p::path(root)/"seed";
    std::vector<std::string> names={"Набор/Фильм.mkv","Набор/Extras/Трейлер.mp4","Набор/Субтитры/Русский.srt"};
    lt::file_storage files;
    for(int i=0;i<3;++i) {
        auto path=seedPath/names[i]; p::create_directories(path.parent_path());
        std::ofstream out(path,std::ios::binary); std::string data(262144,char('A'+i));
        for(int j=0;j<int(data.size());j+=37) data[j]=char((j+i)%255);
        out.write(data.data(),data.size()); files.add_file(names[i],data.size());
    }
    lt::create_torrent creator(files,65536);
    lt::set_piece_hashes(creator,seedPath.string());
    auto encoded=lt::bencode(creator.generate());
    auto torrent=p::path(root)/"sample.torrent";
    {std::ofstream out(torrent,std::ios::binary);out.write(encoded.data(),encoded.size());}
    auto params=lt::load_torrent_file(torrent.string());
    lt::settings_pack config; config.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    config.set_bool(lt::settings_pack::enable_dht,false); config.set_bool(lt::settings_pack::enable_lsd,false);
    config.set_bool(lt::settings_pack::enable_upnp,false); config.set_bool(lt::settings_pack::enable_natpmp,false);
    config.set_bool(lt::settings_pack::allow_multiple_connections_per_ip,true);
    config.set_bool(lt::settings_pack::enable_outgoing_utp,false);
    lt::session seeder(config); params.save_path=seedPath.string(); params.flags|=lt::torrent_flags::seed_mode; params.flags&=~(lt::torrent_flags::paused|lt::torrent_flags::auto_managed);
    auto sh=seeder.add_torrent(params);
    for(int n=0;n<100 && seeder.listen_port()==0;++n)std::this_thread::sleep_for(50ms);
    check(seeder.listen_port()>0,"local seeder listens");
    std::string magnet=lt::make_magnet_uri(sh)+"&x.pe=127.0.0.1:"+std::to_string(seeder.listen_port());
    auto state=(p::path(root)/"state").string(), drafts=(p::path(root)/"drafts").string();
    TFEngine e=tf_create(state.c_str(),drafts.c_str()); check(e,"engine starts");
    success(tf_configure(e,"{\"dht\":false,\"lsd\":false,\"portMapping\":false,\"port\":54987,\"connections\":80}"));
    check(![decode(tf_stage(e,"magnet:?xt=invalid"))[@"ok"] boolValue],"invalid magnet rejected");
    check(![decode(tf_stage(e,"/missing.torrent"))[@"ok"] boolValue],"missing file rejected");
    auto diagnostics=success(tf_details(e,""));
    bool hasError=false; for(NSDictionary *log in diagnostics[@"logs"]) if([log[@"level"] isEqual:@"error"]) hasError=true;
    check(hasError,"staging errors recorded in session logs");
    for(int n=0;n<2100;++n) { auto message="bounded-log-"+std::to_string(n);success(tf_note(e,message.c_str(),"info")); }
    diagnostics=success(tf_details(e,""));
    check([diagnostics[@"logs"] count]<=2000,"log ring count bounded after event flood");
    bool lastPresent=false; for(NSDictionary *log in diagnostics[@"logs"]) if([log[@"message"] isEqual:@"bounded-log-2099"]) lastPresent=true;
    check(lastPresent,"bounded log retains latest event");
    success(tf_clear_logs(e,"")); diagnostics=success(tf_details(e,""));
    bool markerPresent=false; for(NSDictionary *log in diagnostics[@"logs"]) if([log[@"message"] hasPrefix:@"bounded-log-"]) markerPresent=true;
    check(!markerPresent,"clear logs removes visible session history");
    NSString *id=success(tf_stage(e,torrent.c_str()))[@"id"];
    check([item(e,id)[@"hasMetadata"] boolValue],"torrent files ready before task starts");
    check(![decode(tf_stage(e,torrent.c_str()))[@"ok"] boolValue],"duplicate torrent rejected");
    std::string v1magnet="magnet:?xt=urn:btih:";
    static char const hex[]="0123456789abcdef";
    for(unsigned char b:params.ti->info_hashes().v1) { v1magnet+=hex[b>>4]; v1magnet+=hex[b&15]; }
    check(![decode(tf_stage(e,v1magnet.c_str()))[@"ok"] boolValue],"v1 magnet duplicate of hybrid draft rejected");
    int skip[]={0,0,0}; auto dest=(p::path(root)/"download").string();
    check(![decode(tf_commit(e,id.UTF8String,dest.c_str(),skip,3,1))[@"ok"] boolValue],"empty selection rejected");
    check(!p::exists(dest),"validation does not create download destination");
    success(tf_command(e,id.UTF8String,"cancel"));
    id=success(tf_stage(e,magnet.c_str()))[@"id"];
    auto metadata=waitFor(e,id,false);
    check([metadata[@"files"] count]==3,"magnet reveals full file list");
    check([metadata[@"downloaded"] longLongValue]==0,"magnet downloaded zero payload before confirmation");
    bool noFiles=true;
    for(auto const& file:p::recursive_directory_iterator(drafts)) if(file.is_regular_file()) noFiles=false;
    check(noFiles,"metadata mode creates no content files");
    int priorities[]={0,0,0}; int movie=-1,extra=-1,subtitle=-1;
    for(NSDictionary *f in metadata[@"files"]) {
        int ix=[f[@"index"] intValue]; NSString *name=f[@"path"];
        if([name hasSuffix:@"Фильм.mkv"]) {movie=ix;priorities[ix]=7;}
        if([name hasSuffix:@"Трейлер.mp4"]) {extra=ix;priorities[ix]=0;}
        if([name hasSuffix:@"Русский.srt"]) {subtitle=ix;priorities[ix]=1;}
    }
    check(movie>=0 && extra>=0 && subtitle>=0,"file priorities mapped by torrent index");
    check(![decode(tf_commit(e,id.UTF8String,dest.c_str(),priorities,2,1))[@"ok"] boolValue],"incorrect priority vector rejected");
    success(tf_commit(e,id.UTF8String,dest.c_str(),priorities,3,0));
    check([item(e,id)[@"phase"] isEqual:@"paused"],"add on pause honored");
    auto scoped=success(tf_snapshot_scoped(e,""));
    check([scoped[@"items"][0][@"files"] count]==0,"unselected summary omits file traversal payload");
    scoped=success(tf_snapshot_scoped(e,id.UTF8String));
    check([scoped[@"items"][0][@"files"] count]==3,"selected summary includes file details");
    check(![decode(tf_stage(e,v1magnet.c_str()))[@"ok"] boolValue],"v1 magnet duplicate of committed hybrid rejected");
    success(tf_command(e,id.UTF8String,"resume"));
    // Explicit peer survives the metadata-to-task handoff via add_torrent_params.peers.
    auto done=waitFor(e,id,true);
    check([done[@"done"] longLongValue]==524288,"only selected bytes counted");
    check(same(seedPath/names[0],p::path(dest)/names[0]),"high priority file matches byte-for-byte");
    check(!p::exists(p::path(dest)/names[1]),"excluded file not created");
    check(same(seedPath/names[2],p::path(dest)/names[2]),"low priority Unicode file matches byte-for-byte");
    NSArray *list=done[@"files"];
    check([list[movie][@"priority"] intValue]==7 && [list[extra][@"priority"] intValue]==0 && [list[subtitle][@"priority"] intValue]==1,"priorities survive metadata handoff");
    success(tf_command(e,id.UTF8String,"pause")); success(tf_save(e)); tf_destroy(e);
    e=tf_create(state.c_str(),drafts.c_str()); auto restored=item(e,id);
    check(restored!=nil,"task restored from disk");
    check([restored[@"phase"] isEqual:@"paused"],"paused state restored");
    for(int n=0;n<100;++n) { restored=item(e,id); if([restored[@"done"] longLongValue]==524288)break; std::this_thread::sleep_for(50ms); }
    check([restored[@"done"] longLongValue]==524288,"download progress restored");
    list=restored[@"files"];
    check([list[extra][@"priority"] intValue]==0 && [list[movie][@"priority"] intValue]==7,"file selection restored");
    int changed[]={0,0,0}; changed[movie]=4; changed[subtitle]=7; success(tf_priorities(e,id.UTF8String,changed,3));
    std::this_thread::sleep_for(100ms); list=item(e,id)[@"files"];
    check([list[subtitle][@"priority"] intValue]==7,"file priorities editable after addition");
    success(tf_command(e,id.UTF8String,"prepare-remove"));
    check(p::exists(p::path(state)/(std::string(id.UTF8String)+".resume")),"prepare removal retains recovery resume record");
    check([item(e,id)[@"phase"] isEqual:@"paused"],"prepared removal retains paused task row");
    check(p::exists(p::path(dest)/names[0]),"prepare removal does not delete content");
    // Simulated Trash failure: resume transaction instead of finalizing removal.
    success(tf_command(e,id.UTF8String,"restore-remove"));
    check([item(e,id)[@"phase"] isEqual:@"paused"],"failed Trash transaction restores task on pause");
    success(tf_command(e,id.UTF8String,"prepare-remove"));
    success(tf_command(e,id.UTF8String,"finalize-remove"));
    check(!p::exists(p::path(state)/(std::string(id.UTF8String)+".resume")),"final removal deletes recovery record only after success");
    success(tf_save(e)); tf_destroy(e);
    e=tf_create(state.c_str(),drafts.c_str()); check([success(tf_snapshot(e))[@"items"] count]==0,"removed task stays removed on restart");
    check(p::exists(p::path(dest)/names[0]),"removing task preserves downloaded files");
    // v2-only metadata, BEP 52 magnet parsing and file layout.
    lt::create_torrent v2creator(files,65536,lt::create_torrent::v2_only); lt::set_piece_hashes(v2creator,seedPath.string());
    auto v2bytes=lt::bencode(v2creator.generate()); auto v2path=p::path(root)/"v2.torrent";
    {std::ofstream out(v2path,std::ios::binary);out.write(v2bytes.data(),v2bytes.size());}
    NSString *v2id=success(tf_stage(e,v2path.c_str()))[@"id"]; check([item(e,v2id)[@"files"] count]==3,"v2-only torrents supported");
    success(tf_command(e,v2id.UTF8String,"cancel")); tf_destroy(e);
    std::cout << "ALL " << checks << " CHECKS PASSED; libtorrent " << tf_version() << std::endl;
    return 0;
} catch(std::exception const& ex) { std::cerr << "FAIL " << ex.what() << std::endl; return 1; } } }
