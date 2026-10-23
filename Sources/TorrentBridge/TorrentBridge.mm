#import <Foundation/Foundation.h>
#include "TorrentBridge.h"
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/peer_info.hpp>
#if __has_include("GeoIP.hpp")
#include "GeoIP.hpp"
#endif
#include <libtorrent/hex.hpp>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <deque>
#include <chrono>
#include <thread>
#include <algorithm>
#include <functional>

namespace lt = libtorrent;
namespace path = std::filesystem;
static NSString *ns(std::string const& s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"�"; }
static char *json(id obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return strdup("{\"ok\":false,\"error\":\"JSON encoding failed\"}");
    return strndup((const char *)data.bytes, data.length);
}
static char *ok() { return json(@{@"ok":@YES}); }
static char *failure(std::string const& message) { return json(@{@"ok":@NO, @"error":ns(message)}); }
struct Entry {
    std::string id;
    bool draft = true;
    lt::add_torrent_params params;
    lt::torrent_handle handle;
    bool removing = false;
};
struct LogRecord {
    std::uint64_t id;
    double timestamp;
    std::string level, message, torrentID;
};
struct Engine {
    std::unique_ptr<lt::session> session;
    std::map<std::string, Entry> entries;
    std::string state, staging;
    double ratioLimit = 0;
    std::deque<LogRecord> logs;
    std::uint64_t nextLogID = 1;
    std::size_t logBytes = 0;
    void log(std::string level, std::string message, std::string torrentID = {}) {
        if(message.empty()) return;
        if(message.size()>4096) message.resize(4096);
        double now=std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
        if(!logs.empty()) {
            auto const& last=logs.back();
            if(last.level==level && last.message==message && last.torrentID==torrentID && now-last.timestamp<5) return;
        }
        logBytes+=message.size()+torrentID.size();
        logs.push_back({nextLogID++,now,std::move(level),std::move(message),std::move(torrentID)});
        while(logs.size()>2000 || logBytes>1024*1024) {
            logBytes-=logs.front().message.size()+logs.front().torrentID.size(); logs.pop_front();
        }
    }
    std::vector<lt::alert*> drain() {
        std::vector<lt::alert*> alerts; session->pop_alerts(&alerts);
        for(auto const* a:alerts) {
            if(a->type()==lt::cache_flushed_alert::alert_type || a->type()==lt::file_prio_alert::alert_type) continue;
            std::string id;
            if(auto const* ta=dynamic_cast<lt::torrent_alert const*>(a)) {
                for(auto const& [key,value]:entries) if(value.handle==ta->handle) { id=key; break; }
            }
            std::string level=bool(a->category() & lt::alert_category::error)?"error":"info";
            if(a->type()==lt::tracker_warning_alert::alert_type || bool(a->category() & lt::alert_category::performance_warning)) level="warning";
            log(level,a->message(),id);
        }
        return alerts;
    }
    template<typename Expected> void waitFor(lt::torrent_handle const& handle, std::string const& operation, std::function<bool(Expected const&)> matches = {}) {
        auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        while(std::chrono::steady_clock::now()<deadline) {
            auto alerts=drain();
            for(auto const* a:alerts) {
                auto const* t=dynamic_cast<lt::torrent_alert const*>(a);
                if(!t || t->handle!=handle) continue;
                if(auto const* expected=lt::alert_cast<Expected>(a)) { if(!matches || matches(*expected)) return; }
                if(auto const* failed=lt::alert_cast<lt::storage_moved_failed_alert>(a)) throw std::runtime_error(failed->message());
                if(auto const* failed=lt::alert_cast<lt::file_error_alert>(a)) throw std::runtime_error(failed->message());
            }
            session->wait_for_alert(std::chrono::milliseconds(50));
        }
        throw std::runtime_error("Превышено время ожидания: "+operation);
    }
    Engine(std::string s, std::string d): state(s), staging(d) {
        path::create_directories(state);
        path::create_directories(staging);
        lt::settings_pack cfg;
        cfg.set_str(lt::settings_pack::user_agent, std::string("TorrentFlow/0.2 libtorrent/") + LIBTORRENT_VERSION);
        cfg.set_int(lt::settings_pack::alert_mask, lt::alert_category::error | lt::alert_category::status | lt::alert_category::storage | lt::alert_category::tracker | lt::alert_category::port_mapping | lt::alert_category::performance_warning);
        cfg.set_int(lt::settings_pack::alert_queue_size, 1000);
        cfg.set_int(lt::settings_pack::connections_limit, 400);
        cfg.set_bool(lt::settings_pack::enable_dht, true);
        cfg.set_bool(lt::settings_pack::enable_lsd, true);
        cfg.set_bool(lt::settings_pack::enable_upnp, true);
        cfg.set_bool(lt::settings_pack::enable_natpmp, true);
        session = std::make_unique<lt::session>(cfg);
        log("info",std::string("TorrentFlow: движок libtorrent ")+LIBTORRENT_VERSION+" запущен");
#if __has_include("GeoIP.hpp")
        std::string geoPath;
        if(char const* custom=std::getenv("TORRENTFLOW_GEOIP_DB")) geoPath=custom;
        else if(NSString *bundlePath=[NSBundle.mainBundle pathForResource:@"GeoIP" ofType:@"bin"]) geoPath=bundlePath.UTF8String;
        if(geoPath.empty() || !tfgeo::load(geoPath)) log("warning","Локальная база стран IP недоступна; страны пиров не определяются");
#endif
        for (auto const& file: path::directory_iterator(state)) {
            if (file.path().extension() != ".resume") continue;
            try {
                std::ifstream in(file.path(), std::ios::binary);
                std::vector<char> bytes((std::istreambuf_iterator<char>(in)), {});
                lt::error_code ec;
                auto p = lt::read_resume_data(bytes, ec);
                if (ec || p.save_path.empty()) { log("warning","Не удалось прочитать сохранённую задачу: "+file.path().filename().string()); continue; }
                p.flags &= ~lt::torrent_flags::auto_managed;
                auto h = session->add_torrent(p, ec);
                if (!ec) { auto id=file.path().stem().string(); entries.emplace(id, Entry{id, false, std::move(p), h}); log("info","Задача восстановлена",id); }
                else log("error","Не удалось восстановить задачу: "+ec.message());
            } catch (std::exception const& ex) { log("warning",std::string("Ошибка восстановления задачи: ")+ex.what()); }
        }
    }
    void writeResume(std::string const& id, lt::add_torrent_params const& p) {
        auto bytes=lt::write_resume_data_buf(p);
        auto target=path::path(state)/(id+".resume"); auto tmp=target; tmp+=".tmp";
        { std::ofstream out(tmp,std::ios::binary|std::ios::trunc); out.write(bytes.data(),bytes.size()); if(!out) throw std::runtime_error("Не удалось сохранить состояние загрузок"); }
        path::rename(tmp,target);
    }
    void restoreRemoval(Entry& item) {
        auto params=item.params;
        params.flags |= lt::torrent_flags::paused | lt::torrent_flags::duplicate_is_error;
        params.flags &= ~lt::torrent_flags::auto_managed;
        lt::error_code ec; auto h=session->add_torrent(params,ec);
        if(ec) throw std::runtime_error("Не удалось восстановить задачу после удаления: "+ec.message());
        item.handle=h; item.params=std::move(params); item.removing=false;
        h.force_recheck(); h.pause();
        log("warning","Удаление файлов не завершено; задача восстановлена на паузе",item.id);
    }
    void save() {
        for (auto& [id,e]: entries) {
            if (e.draft || !e.handle.is_valid()) continue;
            auto p = e.handle.get_resume_data(lt::torrent_handle::save_info_dict);
            writeResume(id,p);
        }
    }
};
static Engine& engine(TFEngine e) { if (!e) throw std::runtime_error("Движок недоступен"); return *static_cast<Engine*>(e); }
static char *loggedFailure(TFEngine opaque,std::string const& message,std::string const& id={}) {
    if(opaque) static_cast<Engine*>(opaque)->log("error",message,id);
    return failure(message);
}
static Entry& entry(Engine& e, const char *id) { auto i=e.entries.find(id); if(i==e.entries.end()) throw std::runtime_error("Задача уже удалена"); return i->second; }
static std::shared_ptr<lt::torrent_info const> metadata(Entry const& e) { return e.handle.is_valid() ? e.handle.torrent_file() : e.params.ti; }
static std::string hashOf(lt::info_hash_t const& hashes) {
    return hashes.has_v2() ? lt::aux::to_hex(hashes.v2) : lt::aux::to_hex(hashes.v1);
}
static void validatePriorities(lt::torrent_info const& ti, const int *values, int count, std::vector<lt::download_priority_t>& result) {
    auto const& files=ti.files();
    if(count != files.num_files()) throw std::runtime_error("Список файлов изменился. Повторите выбор.");
    bool any=false;
    for(int i=0;i<count;++i) {
        lt::file_index_t ix(i);
        bool excluded=files.pad_file_at(ix) || bool(files.file_flags(ix) & lt::file_storage::flag_symlink);
        int value=excluded?0:values[i];
        if(value!=0 && value!=1 && value!=4 && value!=7) throw std::runtime_error("Неверный приоритет файла");
        result.push_back(lt::download_priority_t(value)); any|=value>0;
    }
    if(!any) throw std::runtime_error("Выберите хотя бы один файл");
}
extern "C" {
TFEngine tf_create(const char *state, const char *staging) { try { return new Engine(state, staging); } catch (...) { return nullptr; } }
void tf_destroy(TFEngine opaque) { if(!opaque)return; auto e=static_cast<Engine*>(opaque); try{e->save();}catch(...){} delete e; }
const char *tf_version(void) { return LIBTORRENT_VERSION; }
void tf_free(char *s) { free(s); }
char *tf_stage(TFEngine opaque, const char *source) {
    @autoreleasepool { try {
        auto& e=engine(opaque);
        Entry item; item.id=std::string([NSUUID.UUID.UUIDString UTF8String]);
        std::string src(source);
        lt::error_code ec;
        if(src.rfind("magnet:?",0)==0) {
            item.params=lt::parse_magnet_uri(src,ec);
            if(ec) return loggedFailure(opaque,"Некорректная magnet-ссылка: " + ec.message());
        } else {
            if(!path::is_regular_file(src)) return loggedFailure(opaque,"Торрент-файл не найден");
            if(path::file_size(src)>64*1024*1024) return loggedFailure(opaque,"Торрент-файл превышает 64 МБ");
            item.params=lt::load_torrent_file(src);
        }
        auto hashes=item.params.ti?item.params.ti->info_hashes():item.params.info_hashes;
        for(auto const& [id,old]:e.entries) {
            auto oldHash=old.handle.is_valid()?old.handle.info_hashes():(old.params.ti?old.params.ti->info_hashes():old.params.info_hashes);
            if((hashes.has_v1() && oldHash.has_v1() && hashes.v1==oldHash.v1) || (hashes.has_v2() && oldHash.has_v2() && hashes.v2==oldHash.v2)) return loggedFailure(opaque,"Этот торрент уже добавлен или открыт в окне выбора");
        }
        if(!item.params.ti) {
            // Defense in depth: no file payload may be requested during metadata discovery.
            item.params.save_path=(path::path(e.staging)/item.id).string();
            item.params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
            item.params.flags |= lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download | lt::torrent_flags::duplicate_is_error;
            item.params.file_priorities.clear();
            item.handle=e.session->add_torrent(item.params,ec);
            if(ec) return loggedFailure(opaque,ec.message());
        }
        auto id=item.id; e.entries.emplace(id,std::move(item)); e.log("info",src.rfind("magnet:?",0)==0?"Magnet открыт: получение метаданных без загрузки содержимого":"Торрент открыт: ожидание выбора файлов",id);
        return json(@{@"ok":@YES,@"id":ns(id)});
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_snapshot_scoped(TFEngine opaque, const char *selected) {
    @autoreleasepool { try {
        auto& e=engine(opaque);
        e.drain();
        NSMutableArray *items=[NSMutableArray array];
        for(auto& [id,item]:e.entries) {
            auto ti=metadata(item);
            auto h=item.handle;
            lt::torrent_status s;
            if(h.is_valid()) s=h.status();
            else if(item.removing) { s.flags|=lt::torrent_flags::paused; s.save_path=item.params.save_path; }
            // Keep the live metadata handle in upload_mode so discovered peers survive confirmation.
            // upload_mode + default_dont_download prevents all payload requests.
            std::string name=ti?ti->name():s.name;
            if(name.empty()) name=item.params.name.empty()?"Magnet · получение метаданных":item.params.name;
            bool paused=(h.is_valid() || item.removing) && bool(s.flags & lt::torrent_flags::paused);
            std::string phase="metadata";
            if(ti) {
                if(item.draft) phase="ready";
                else if(s.errc) phase="error";
                else if(paused) phase="paused";
                else if(s.state==lt::torrent_status::checking_files || s.state==lt::torrent_status::checking_resume_data) phase="checking";
                else if(s.is_finished) phase="seeding";
                else phase="downloading";
            }
            double ratio=s.all_time_download>0?double(s.all_time_upload)/s.all_time_download:0;
            if(!item.draft && !paused && s.is_finished && e.ratioLimit>0 && ratio>=e.ratioLimit) h.pause();
            NSMutableArray *files=[NSMutableArray array];
            if(ti && (!selected || item.draft || id==selected)) {
                auto const& f=ti->files();
                std::vector<std::int64_t> progress;
                std::vector<lt::download_priority_t> priorities;
                if(h.is_valid()) { h.file_progress(progress); priorities=h.get_file_priorities(); }
                else if(item.removing) priorities=item.params.file_priorities;
                for(int i=0;i<f.num_files();++i) {
                    lt::file_index_t ix(i);
                    bool pad=f.pad_file_at(ix), link=bool(f.file_flags(ix) & lt::file_storage::flag_symlink);
                    int p=pad||link?0:(!item.draft && i<int(priorities.size())?int(static_cast<std::uint8_t>(priorities[i])):4);
                    [files addObject:@{@"index":@(i),@"path":ns(f.file_path(ix)),@"size":@(f.file_size(ix)),@"done":@(i<int(progress.size())?progress[i]:0),@"priority":@(p),@"padding":@(pad),@"symlink":@(link)}];
                }
            }
            NSMutableArray *trackers=[NSMutableArray array];
            if(h.is_valid()) for(auto const& t:h.trackers()) [trackers addObject:ns(t.url)];
            else for(auto const& t:item.params.trackers) [trackers addObject:ns(t)];
            [items addObject:@{@"id":ns(id),@"draft":@(item.draft),@"name":ns(name),@"phase":ns(phase),@"hasMetadata":@(ti!=nullptr),@"size":@(ti?ti->total_size():0),@"wanted":@(s.total_wanted),@"done":@(s.total_wanted_done),@"downloadRate":@(s.download_payload_rate),@"uploadRate":@(s.upload_payload_rate),@"downloaded":@(s.all_time_download),@"uploaded":@(s.all_time_upload),@"peers":@(s.num_peers),@"seeds":@(s.num_seeds),@"ratio":@(ratio),@"destination":ns(s.save_path),@"error":ns(s.errc?s.errc.message():""),@"hash":ns(hashOf(h.is_valid()?h.info_hashes():item.params.ti->info_hashes())),@"files":files,@"trackers":trackers}];
        }
        return json(@{@"ok":@YES,@"items":items});
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_snapshot(TFEngine opaque) { return tf_snapshot_scoped(opaque,nullptr); }
char *tf_commit(TFEngine opaque,const char *id,const char *destination,const int *values,int count,int start) {
    @autoreleasepool { try {
        auto& e=engine(opaque); auto& item=entry(e,id);
        if(!item.draft) return loggedFailure(opaque,"Задача уже добавлена");
        auto ti=metadata(item); if(!ti) return loggedFailure(opaque,"Дождитесь списка файлов magnet-ссылки");
        std::vector<lt::download_priority_t> priorities; validatePriorities(*ti,values,count,priorities);
        path::path dest(destination);
        if(!dest.is_absolute()) return loggedFailure(opaque,"Выберите абсолютный путь папки загрузки");
        path::create_directories(dest);
        if(!path::is_directory(dest) || access(destination,W_OK)!=0) return loggedFailure(opaque,"Папка недоступна для записи");
        if(item.handle.is_valid()) {
            // Retain DHT/tracker-discovered peers and protocol state. Removing and re-adding
            // the original magnet params loses this information and may stall the task.
            auto handle=item.handle;
            handle.clear_error();
            handle.set_flags(lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download);
            e.drain();
            bool existing=false;
            for(auto index:ti->files().file_range()) if(path::exists(dest/ti->files().file_path(index))) { existing=true; break; }
            handle.move_storage(dest.string(),lt::move_flags_t::reset_save_path_unchecked);
            e.waitFor<lt::storage_moved_alert>(handle,"перемещение в папку загрузки",[&](auto const& alert) { return path::weakly_canonical(alert.storage_path())==path::weakly_canonical(dest); });
            handle.prioritize_files(priorities);
            e.waitFor<lt::file_prio_alert>(handle,"применение приоритетов файлов",[&](auto const&) { return handle.get_file_priorities()==priorities; });
            if(existing) { handle.force_recheck(); e.log("info","Найдены существующие файлы; выполняется проверка перед загрузкой",item.id); }
            if(!start) handle.pause();
            handle.unset_flags(lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download);
            handle.unset_flags(lt::torrent_flags::auto_managed);
            if(start) handle.resume();
            item.params=handle.get_resume_data(lt::torrent_handle::save_info_dict);
            item.draft=false;
            e.log("info",start?"Magnet подтверждён: загрузка начата, найденные пиры сохранены":"Magnet подтверждён: добавлено на паузе",item.id);
        } else {
            auto p=item.params;
            p.ti=std::make_shared<lt::torrent_info>(*ti); p.save_path=dest.string(); p.file_priorities=std::move(priorities);
            p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download);
            p.flags |= lt::torrent_flags::paused | lt::torrent_flags::duplicate_is_error;
            lt::error_code ec;
            auto handle=e.session->add_torrent(p,ec);
            if(ec) return loggedFailure(opaque,ec.message(),item.id);
            item.handle=handle; item.params=std::move(p); item.draft=false;
            if(start) handle.resume();
            e.log("info",start?"Загрузка подтверждена и запущена":"Загрузка добавлена на паузе",item.id);
        }
        // The task is already committed. A persistence error must not trap the Add sheet.
        try { e.save(); } catch(std::exception const& ex) { e.log("warning",std::string("Загрузка добавлена, но состояние пока не сохранено: ")+ex.what(),item.id); }
        return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_command(TFEngine opaque,const char *id,const char *command) {
    @autoreleasepool { try {
        auto& e=engine(opaque); auto& item=entry(e,id); std::string cmd(command);
        if(cmd=="finalize-remove") {
            if(!item.removing) return loggedFailure(opaque,"Удаление файлов не было подготовлено",item.id);
            path::remove(path::path(e.state)/(item.id+".resume"));
            e.log("info","Загрузка и её файлы удалены в Корзину",item.id); e.entries.erase(id); return ok();
        }
        if(cmd=="restore-remove") {
            if(item.removing) e.restoreRemoval(item);
            return ok();
        }
        if(cmd=="prepare-remove") {
            if(item.draft) return loggedFailure(opaque,"Сначала подтвердите задачу",item.id);
            if(item.removing) return ok();
            auto handle=item.handle;
            auto params=handle.get_resume_data(lt::torrent_handle::save_info_dict);
            params.flags |= lt::torrent_flags::paused;
            params.flags &= ~lt::torrent_flags::auto_managed;
            e.writeResume(item.id,params); // Fail safely while the original task still exists.
            item.params=std::move(params); item.removing=true;
            e.drain(); e.session->remove_torrent(handle);
            // In libtorrent 2.1 async_stop_torrent completes through on_torrent_aborted(),
            // which releases m_storage and posts torrent_removed_alert. cache_flushed_alert
            // is not posted on this normal removal path (only on explicit flush/legacy paths).
            try { e.waitFor<lt::torrent_removed_alert>(handle,"освобождение файлов перед перемещением в Корзину"); }
            catch(...) { item.handle={}; try { e.restoreRemoval(item); } catch(std::exception const& ex) { e.log("error",ex.what(),item.id); } throw; }
            item.handle={};
            e.log("info","Файлы освобождены; сохранено состояние для восстановления при ошибке Корзины",item.id); return ok();
        }
        if(cmd=="cancel" || cmd=="remove") {
            bool draft=item.draft;
            if(cmd=="cancel" && !draft) return loggedFailure(opaque,"Нельзя отменить подтверждённую задачу");
            if(item.handle.is_valid()) e.session->remove_torrent(item.handle);
            if(!draft) path::remove(path::path(e.state)/(item.id+".resume"));
            e.log("info",cmd=="cancel"?"Добавление отменено":"Задача удалена из списка; файлы сохранены",item.id);
            e.entries.erase(id); return ok();
        }
        if(item.draft || !item.handle.is_valid()) return loggedFailure(opaque,"Сначала подтвердите выбор файлов");
        if(cmd=="pause") item.handle.pause();
        else if(cmd=="resume") item.handle.resume();
        else if(cmd=="verify") item.handle.force_recheck();
        else return loggedFailure(opaque,"Неизвестная команда");
        e.log("info",cmd=="pause"?"Загрузка приостановлена":cmd=="resume"?"Загрузка возобновлена":"Запущена проверка файлов",item.id);
        e.save(); return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_priorities(TFEngine opaque,const char *id,const int *values,int count) {
    @autoreleasepool { try {
        auto& item=entry(engine(opaque),id); auto ti=metadata(item);
        if(item.draft || !ti) return loggedFailure(opaque,"Задача ещё не запущена");
        std::vector<lt::download_priority_t> p; validatePriorities(*ti,values,count,p);
        item.handle.prioritize_files(p); engine(opaque).log("info","Изменён выбор файлов и приоритеты",item.id); return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_configure(TFEngine opaque,const char *input) {
    @autoreleasepool { try {
        auto& e=engine(opaque);
        NSData *bytes=[NSData dataWithBytes:input length:strlen(input)];
        NSDictionary *d=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
        if(![d isKindOfClass:NSDictionary.class]) return loggedFailure(opaque,"Неверные настройки");
        lt::settings_pack p;
        bool alt=[d[@"alternate"] boolValue];
        int down=[d[alt?@"altDown":@"downLimit"] intValue], up=[d[alt?@"altUp":@"upLimit"] intValue];
        p.set_int(lt::settings_pack::download_rate_limit,std::max(0,down)*1024);
        p.set_int(lt::settings_pack::upload_rate_limit,std::max(0,up)*1024);
        p.set_int(lt::settings_pack::connections_limit,std::max(20,[d[@"connections"] intValue]));
        p.set_bool(lt::settings_pack::enable_dht,[d[@"dht"] boolValue]);
        p.set_bool(lt::settings_pack::enable_lsd,[d[@"lsd"] boolValue]);
        p.set_bool(lt::settings_pack::enable_upnp,[d[@"portMapping"] boolValue]);
        p.set_bool(lt::settings_pack::enable_natpmp,[d[@"portMapping"] boolValue]);
        int port=[d[@"port"] intValue]; if(port<1024 || port>65535) return loggedFailure(opaque,"Порт должен быть от 1024 до 65535");
        p.set_str(lt::settings_pack::listen_interfaces,"0.0.0.0:"+std::to_string(port)+",[::]:"+std::to_string(port));
        int encryption=[d[@"requireEncryption"] boolValue]?lt::settings_pack::pe_forced:lt::settings_pack::pe_enabled;
        p.set_int(lt::settings_pack::out_enc_policy,encryption); p.set_int(lt::settings_pack::in_enc_policy,encryption);
        e.ratioLimit=[d[@"ratioLimit"] doubleValue]; e.session->apply_settings(p); return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_details_filtered(TFEngine opaque,const char *identifier,int includePeers,int includeLogs) {
    @autoreleasepool { try {
        auto& e=engine(opaque); e.drain();
        std::string id=identifier?identifier:"";
        NSMutableArray *peers=[NSMutableArray array], *logs=[NSMutableArray array];
        auto found=e.entries.find(id);
        if(includePeers && found!=e.entries.end() && found->second.handle.is_valid()) {
            std::vector<lt::peer_info> infos; found->second.handle.get_peer_info(infos);
            for(auto const& p:infos) {
                bool i2p=bool(p.flags & lt::peer_info::i2p_socket);
                lt::tcp::endpoint remote;
                std::string address,endpoint,country;
                if(i2p) {
#if TORRENT_USE_I2P
                    endpoint="I2P:"+lt::aux::to_hex(p.i2p_destination());
#else
                    endpoint="I2P";
#endif
                } else {
                    remote=p.remote_endpoint(); address=remote.address().to_string();
                    endpoint=(remote.address().is_v6()?"["+address+"]":address)+":"+std::to_string(remote.port());
                }
#if __has_include("GeoIP.hpp")
                if(!i2p) country=tfgeo::country(address);
#else
                if(!i2p && (remote.address().is_loopback() || remote.address().is_unspecified())) country="LOCAL";
#endif
                [peers addObject:@{@"id":ns(endpoint),@"address":ns(endpoint),@"client":ns(p.client.empty()?"Определяется…":p.client),@"countryCode":ns(country),@"downloadRate":@(p.payload_down_speed),@"uploadRate":@(p.payload_up_speed),@"progress":@(p.progress),@"seed":@(bool(p.flags & lt::peer_info::seed))}];
            }
        }
        if(includeLogs) for(auto const& l:e.logs) {
            if(!id.empty() && !l.torrentID.empty() && id!=l.torrentID) continue;
            [logs addObject:@{@"id":@(l.id),@"timestamp":@(l.timestamp),@"level":ns(l.level),@"message":ns(l.message),@"torrentID":ns(l.torrentID)}];
        }
        return json(@{@"ok":@YES,@"peers":peers,@"logs":logs});
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_details(TFEngine opaque,const char *identifier) { return tf_details_filtered(opaque,identifier,1,1); }
char *tf_clear_logs(TFEngine opaque,const char *identifier) {
    @autoreleasepool { try {
        auto& e=engine(opaque); e.drain(); std::string id=identifier?identifier:"";
        for(auto it=e.logs.begin();it!=e.logs.end();) {
            if(id.empty() || it->torrentID.empty() || it->torrentID==id) { e.logBytes-=it->message.size()+it->torrentID.size(); it=e.logs.erase(it); }
            else ++it;
        }
        return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_note(TFEngine opaque,const char *message,const char *level) {
    @autoreleasepool { try {
        std::string severity=level?level:"info";
        if(severity!="error" && severity!="warning") severity="info";
        engine(opaque).log(severity,message?message:""); return ok();
    } catch(std::exception const& ex) { return loggedFailure(opaque,ex.what()); } }
}
char *tf_save(TFEngine opaque) { @autoreleasepool { try{engine(opaque).save();return ok();}catch(std::exception const& ex){return loggedFailure(opaque,ex.what());} } }
}
