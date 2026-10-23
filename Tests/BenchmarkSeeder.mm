#import <Foundation/Foundation.h>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/peer_class.hpp>
#include <filesystem>
#include <fstream>
#include <chrono>
#include <thread>
#include <iostream>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using namespace std::chrono_literals;
static NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()]; }
static void writeJSON(fs::path const& path, NSDictionary *value) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if(![bytes writeToFile:ns(path.string()) options:NSDataWritingAtomic error:nil]) throw std::runtime_error("Could not write fixture status");
}
int main(int argc,char **argv) { @autoreleasepool { try {
    if(argc<2) throw std::runtime_error("Usage: benchmark-seeder ROOT [MiB]");
    fs::path root(argv[1]);
    if(fs::exists(root/"fixture.json")) throw std::runtime_error("Refusing to overwrite an existing benchmark fixture");
    int size=argc>2?std::stoi(argv[2]):256;
    if(size<16 || size>2048) throw std::runtime_error("Fixture size must be between 16 and 2048 MiB");
    fs::create_directories(root/"seed"/"TorrentFlow Benchmark");
    std::string filename="TorrentFlow Benchmark/Benchmark Payload.bin";
    std::vector<char> block(1024*1024);
    for(std::size_t i=0;i<block.size();++i) block[i]=char((i*131+17+(i>>13))&255);
    { std::ofstream out(root/"seed"/filename,std::ios::binary); for(int n=0;n<size;++n)out.write(block.data(),block.size()); if(!out)throw std::runtime_error("Could not create payload"); }
    lt::file_storage files; files.add_file(filename,std::int64_t(size)*1024*1024);
    lt::create_torrent creator(files,262144);
    lt::set_piece_hashes(creator,(root/"seed").string());
    auto bytes=lt::bencode(creator.generate());
    auto torrent=root/"fixture.torrent";
    {std::ofstream out(torrent,std::ios::binary);out.write(bytes.data(),bytes.size());}
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    settings.set_str(lt::settings_pack::user_agent,"TorrentFlow Benchmark Seeder/0.2.0");
    settings.set_bool(lt::settings_pack::enable_dht,false);
    settings.set_bool(lt::settings_pack::enable_lsd,false);
    settings.set_bool(lt::settings_pack::enable_upnp,false);
    settings.set_bool(lt::settings_pack::enable_natpmp,false);
    settings.set_bool(lt::settings_pack::enable_outgoing_utp,false);
    settings.set_bool(lt::settings_pack::enable_incoming_utp,false);
    settings.set_int(lt::settings_pack::upload_rate_limit,8*1024*1024);
    lt::session session(settings);
    // libtorrent deliberately exempts local peers from the global limit.
    // Cap the local class explicitly so the loopback fixture lasts ~32 s;
    // the measured application's normal networking settings stay unchanged.
    auto local=session.get_peer_class(lt::session::local_peer_class_id);
    local.upload_limit=8*1024*1024;
    session.set_peer_class(lt::session::local_peer_class_id,local);
    auto params=lt::load_torrent_file(torrent.string());
    params.save_path=(root/"seed").string(); params.flags|=lt::torrent_flags::seed_mode;
    params.flags&=~(lt::torrent_flags::paused|lt::torrent_flags::auto_managed);
    auto handle=session.add_torrent(params);
    for(int n=0;n<100 && !session.listen_port();++n)std::this_thread::sleep_for(50ms);
    if(!session.listen_port()) throw std::runtime_error("No listening socket");
    auto magnet=lt::make_magnet_uri(handle)+"&x.pe=127.0.0.1:"+std::to_string(session.listen_port());
    writeJSON(root/"fixture.json",@{@"magnet":ns(magnet),@"size":@(std::int64_t(size)*1024*1024),@"file":ns(filename),@"port":@(session.listen_port())});
    std::cout<<"READY "<<(root/"fixture.json").string()<<std::endl;
    while(!fs::exists(root/"stop-seeder")) {
        auto state=handle.status();
        writeJSON(root/"seeder-status.json",@{@"peers":@(state.num_peers),@"uploaded":@(state.all_time_upload),@"uploadRate":@(state.upload_payload_rate)});
        std::this_thread::sleep_for(500ms);
    }
    return 0;
} catch(std::exception const& ex) { std::cerr<<ex.what()<<std::endl; return 1; } } }
